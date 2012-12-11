#!/usr/bin/ruby

require 'rubygems'
require 'xmlsimple'
require 'yaml'
require 'json'

BIOS_SVC_CLASS = "DCIM_BIOSService"
RAID_SVC_CLASS = "DCIM_RAIDService"
JOB_SVC_CLASS  = "DCIM_JOBService"
LC_SVC_CLASS   = "DCIM_LCService"
SOFT_SVC_CLASS = "DCIM_SoftwareInstallationService"
WSMAN_BASE_URI = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2"
WSMAN_URI_NS   = "#{WSMAN_BASE_URI}/root/dcim"
SOFT_IDEN_URI  = "#{WSMAN_URI_NS}/DCIM_SoftwareIdentity"
SOFT_SVC_URI   = "#{WSMAN_URI_NS}/DCIM_SoftwareInstallationService"
SYS_VIEW_URI   = "#{WSMAN_URI_NS}/DCIM_SystemView"
BIOS_ENUM_URI  = "#{WSMAN_URI_NS}/DCIM_BIOSEnumeration"
CHANGE_BOOT_ORDER_CMD = "ChangeBootOrderByInstanceID"


RETURN_CFG_OK         = 0
RETURN_VAL_OK         = '0'
RETURN_CONFIG_VAL_OK  = 4096
RETURN_CFG_JOB        = 4096
RETURN_VAL_FAIL       = '2'
RETURN_VAL_NO_ACTION  = '-1'

class Crowbar 
 class WSMAN
  attr :host
  attr :user
  attr :password
  attr :port
  attr :debug_time

  def self.certname(host)
    "/tmp/cer-#{host}.cer"
  end

  def self.setup_env(host, user, password)
    filename = WSMAN.certname(host)
    return true if File.exists?(filename)

    output = %x{ping -W 3 -c 2 #{host} 2>/dev/null >/dev/null}
    if $?.exitstatus != 0 
      Chef::Log.error "Failed to ping host: #{host}"
      return false
    end
  
    output = %x{echo | openssl s_client -connect #{host}:443 2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' >#{filename} 2>&1}
    if $?.exitstatus != 0
      Chef::Log.error output
      return false
    end
    true
  end

  def initialize(opts = {})
    @host = opts[:host]
    @user = opts[:user]
    @password = opts[:password]
    @port = opts[:port] || 443
    @debug_time = opts[:debug_time] || false
    @debug = opts[:debug] || false
  end

  def measure_time(msg)
    start = Time.now if @debug_time
    yield
    puts "#{msg}: #{Time.now - start}" if @debug_time
  end

  def setup_env
    retVal  = WSMAN.setup_env(@host, @user, @password)
    return retVal
  end

  # Action = enumerate, invoke, ...
  # url = http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/DCIM_SoftwareIdentity
  # args = non-standard args (not -h, -P, -u, -p, -c)
  def command(action, url, args = "", count = 0)
    retVal = self.setup_env
    if (!retVal)
      Chef::Log.error "Unable to ping system...exiting"
      return false
    end
    filename = WSMAN.certname(@host)
    output = ""
    ret=0
    stdargs = "-N root/dcim -v -o -j utf-8 -y basic"
    self.measure_time "WSMAN #{action} #{url} call" do
      cmd = "wsman #{action} #{url} -h #{@host} -P #{@port} -u #{@user} -p #{@password} -c #{filename} #{stdargs} #{args} 2>&1"
      output = %x{#{cmd}}
      ret = $?.exitstatus
    end
    if ret != 0
      Chef::Log.error "wsman command failed: #{action}"
      Chef::Log.error output
      return false
    end

    # Retry this three times
    if output =~ /Connection failed. response code = 0/
      return false if count >= 3
      puts "Retrying the command: #{count} #{action}"
      sleep 20
      return command(action, url, args, count + 1)
    end

    return output
  end

  #
  # time is:
  #   YYYYMMDDHHmmSS
  #   TIME_NOW
  #
  def schedule_job(jid, time)
    job_svc_uri = find_instance_uri(JOB_SVC_CLASS)
    output = self.command("invoke -a SetupJobQueue",job_svc_uri, " -k JobArray=\"#{jid}\" -k StartTimeInterval=\"#{time}\"")
    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]
    if t["Fault"]
      return false, t["Fault"]
    end

    # Some versions don't actually give a return code on success.
    if (t["SetupJobQueue_OUTPUT"]["ReturnValue"].instance_of? Hash)
      return true, "nil value" 
    end

    if t["SetupJobQueue_OUTPUT"]["ReturnValue"] != "0"
      return false, t["SetupJobQueue_OUTPUT"]["Message"]
    end

    return true, 0
  end

  def clear_all_jobs
    job_svc_uri = find_instance_uri(JOB_SVC_CLASS)
    output = self.command("invoke -a DeleteJobQueue",job_svc_uri, " -m 256 -k JobID=\"JID_CLEARALL\"")
    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]
    if t["Fault"]
      return false, t["Fault"]
    end

    # Some versions don't actually give a return code on success.
    if (t["DeleteJobQueue_OUTPUT"]["ReturnValue"].instance_of? Hash)
      return true, "nil value" 
    end
    ret = t["DeleteJobQueue_OUTPUT"]["ReturnValue"].to_i == 0 rescue false
    return ret, t["DeleteJobQueue_OUTPUT"]["Message"]
  end

  def get_job_status(jid)
    output = self.command("get","#{WSMAN_URI_NS}/DCIM_LifecycleJob?InstanceID=#{jid}")
    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]
    if t["Fault"]
      return false, t["Fault"]["Reason"]["Text"]["content"]
    end

    # Sometime the job will hang 
    js = t["DCIM_LifecycleJob"]["JobStatus"]
    if js == "New"
      if t["DCIM_LifecycleJob"]["MessageID"] == "RED023"
        return false, "In Use"
      end
    end

    return true, js
  end

  def is_RS_ready?
    lc_svc_uri = find_instance_uri(LC_SVC_CLASS) 
    output = self.command("invoke -a GetRSStatus", lc_svc_uri)
    return false unless output

    hash = XmlSimple.xml_in(output, "ForceArray" => false)
    t = hash["Body"]
    if t["Fault"]
      return false, t["Fault"]
    end

    # Some versions don't actually give a return code on success.
    if (t["GetRSStatus_OUTPUT"]["ReturnValue"].instance_of? Hash)
      return true, "Ready"
    end

    if t["GetRSStatus_OUTPUT"]["ReturnValue"] != "0"
      return false, t["GetRSStatus_OUTPUT"]["Message"]
    end

    status = t["GetRSStatus_OUTPUT"]["Status"]
    puts "Status from getrsstatus is #{status}"
    return status == "Ready", status
  end

  ## Utility method to determine resource URI for a given class ##
  ## Enumerates instance with EPR and parses keys to construct URI ##
  def find_instance_uri(serviceClass)
    url = "#{WSMAN_URI_NS}/#{serviceClass}"
    xml = self.command(ENUMERATE_CMD, url, " -m 512 -M epr")
    selectorStr = "#{url}?"
    content = self.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]')
    if content
      selectorSet = content["EndpointReference"]["ReferenceParameters"]["SelectorSet"]
      selectorSet["Selector"].each do |selector|
        selectorStr += "," unless selectorStr == "#{url}?"
        selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
      end
    end
    selectorStr
  end

  ## Utility method to determine resource URI for a given class ##
  ## Enumerates instance with EPR and parses keys to construct URI ##
  def find_base_instance_uri(serviceClass)
    url = "#{WSMAN_BASE_URI}/#{serviceClass}"
    xml = self.command(ENUMERATE_CMD, url, " -m 512 -M epr")
    selectorStr = "#{url}?"
    content = self.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]')
    if content
      selectorSet = content["EndpointReference"]["ReferenceParameters"]["SelectorSet"]
      selectorSet["Selector"].each do |selector|
        selectorStr += "," unless selectorStr == "#{url}?"
        selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
      end
    end
    selectorStr
  end


  ## Utility method to determine resource URI when enumeration ##
  ## uses flag for both object and EPR                         ##
  def find_instance_uri_from_objepr(content)
    selectorStr = "?"
    if content
      selectorSet = content["EndpointReference"]["ReferenceParameters"]["SelectorSet"]
      selectorSet["Selector"].each do |selector|
        selectorStr += "," unless selectorStr == "?"
        selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
      end
    end
    selectorStr
  end

  def get_selector_string(instHash)
    selectorStr = ""
    selectorSet = instHash["EndpointReference"]["ReferenceParameters"]["SelectorSet"]
    if (selectorSet["Selector"].is_a?(Array))
      selectorSet["Selector"].each do |selector|
        if (!selector.nil?)
          selectorStr += %Q[<w:Selector Name="#{selector["Name"]}">#{selector["content"]}</w:Selector>] unless selector["Name"] == "__cimnamespace"
        end
      end
    ## 11G returns this differently from 12G ...yeesh
    elsif (selectorSet["Selector"].is_a?(Hash))
      selectorStr += %Q[<w:Selector Name="#{selectorSet["Selector"]["Name"]}">#{selectorSet["Selector"]["content"]}</w:Selector>]
    end
    puts "selector string is #{selectorStr}"
    selectorStr
  end

  ## Utility method to extract job id from the output of a job creation ##
  ## command returning a reference to a CIM_ConcreteJob subclass instance ##
  def get_job_id(instHash)
    jobID = ""
    selectorSet = ""
    testFor12G  = instHash["EndpointReference"]
    if (testFor12G.nil?)
      selectorSet = instHash["ReferenceParameters"]["SelectorSet"]
    else
      selectorSet = instHash["EndpointReference"]["ReferenceParameters"]["SelectorSet"]
    end
    if (selectorSet["Selector"].is_a?(Array))
      selectorSet["Selector"].each do |selector|
        if (!selector.nil?)
          jobID = selector["content"] if selector["Name"] != "__cimnamespace"
        end
      end
    ## 11G returns this differently from 12G ...yeesh
    elsif (selectorSet["Selector"].is_a?(Hash))
      jobID = selectorSet["Selector"]["content"]
    end
    puts "parsed job id string is #{jobID}"
    jobID
  end

  def get_job_selector(instHash)
    puts "Parsing job selector string"
    selectorStr = instHash["ReferenceParameters"]["ResourceURI"] + "?"
    selectorSet = instHash["ReferenceParameters"]["SelectorSet"]
    selectorSet["Selector"].each do |selector|
      selectorStr += selector["Name"] + "=" + selector["content"] unless selector["Name"] == "__cimnamespace"
    end
    selectorStr
  end

  ## Utility method to turn a host off - this is needed if you are booted ##
  ## into an OS .. the reboot jobs in that case doesn't seem to hard reset ##
  def power_down_system()
    retVal = false
    method = "RequestStateChange"
    ## Enumerate instances of CIM_ComputerSystem
    xml = self.command(ENUMERATE_CMD, CS_INST_URI, " -m 512 -M objepr")
    instanceList = self.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["Item"]')
    instanceList = (instanceList.instance_of?(Array))?instanceList:[instanceList]
    instanceList.each do |instance|
      if (instance.is_a?(Hash))
        classNames = instance.keys
        classNames.delete("EndpointReference")
        ## Filter out the service processor instance and get only host instance
        if ((instance[classNames[0]]['Dedicated']).to_i == 0)
          newcsinst = "#{WSMAN_URI_NS}/#{classNames[0]}"
          csuri = newcsinst + find_instance_uri_from_objepr(instance)
          ## Invoke method RequestStateChange on the base server instance
          xml = self.command("#{INVOKE_CMD} -a #{method} -k RequestedState='3'", csuri)
          returnVal = self.returnValue(xml,method)
          if returnVal.to_i == RETURN_CFG_OK
            retVal = true
          end
        end
      end
    end
    retVal
  end

  ## Utility method to create reboot jobs for updates ## 
  ## this needs to replace current job creation routines eventually ##
  def create_update_reboot_job()
    retVal = false
    jobID  = ""
    puts "Creating reboot job for updates..."
    method = "CreateRebootJob"
    inputFile = "/tmp/#{method}.xml"
    File.open("#{inputFile}", "w+") do |ff|
      ff.write %Q[
       <p:#{method}_INPUT xmlns:p="#{WSMAN_URI_NS}/DCIM_SoftwareInstallationService">
          <p:RebootJobType>3</p:RebootJobType>
        </p:#{method}_INPUT>
      ]
    end
    cmd  = "#{INVOKE_CMD} -a #{method}"
    instURI = find_instance_uri(SOFT_SVC_CLASS)
    output = self.command(cmd, instURI , "-J #{inputFile}")
    puts "Debug: create reboot job failed no output" unless output
    return [ false, "Failed to create update job" ] unless output
    retVal = self.returnValue(output,method)
    if (retVal.to_i == RETURN_CFG_OK)
      puts "No RID returned...invocation of downgrade failed"
    elsif (retVal.to_i == RETURN_CFG_JOB)
      wsInstance = self.processResponse(output, '["Body"]["CreateRebootJob_OUTPUT"]["RebootJobID"]')
      jobID = get_job_id(wsInstance)
      retVal = true
    else
      puts "Error encountered in job creation..."
    end
    [retVal, jobID]
  end

  def create_reboot_job()
    retVal = false
    jobID  = ""
    puts "Creating reboot job for stacking in job queue..."
    method = "CreateRebootJob"
    cmd  = "#{INVOKE_CMD} -a #{method}"
    instURI = find_instance_uri(JOB_SVC_CLASS)
    output = self.command(cmd, instURI , "-k RebootJobType=3")
    puts "Debug: create reboot job failed no output" unless output
    return [ false, "Failed to create update job" ] unless output
    retVal = self.returnValue(output,method)
    if (retVal.to_i == RETURN_CFG_OK)
      puts "No RID returned...invocation of createrebootjob failed"
    elsif (retVal.to_i == RETURN_CFG_JOB)
      wsInstance = self.processResponse(output, '["Body"]["CreateRebootJob_OUTPUT"]["Job"]')
      jobID = get_job_id(wsInstance)
      retVal = true
    else
      puts "Error encountered in job creation..."
    end
    [retVal, jobID]
  end


  ## Utility method to set up the job queue with multiple update jobs ##
  ## and a reboot job ..useful for stacking updates / downgrades etc  ##
  def setup_job_queue_multi(jobArray)
    retVal = false
    jobStr = ""
    method = "SetupJobQueue"
    if (jobArray.nil?)
      puts "Input job array is nil...exiting"
    else
      inputFile = "/tmp/#{method}.xml"
      File.open("#{inputFile}", "w+") do |ff|
        ff.write %Q[<p:#{method}_INPUT xmlns:p="#{WSMAN_URI_NS}/#{JOB_SVC_CLASS}">]
        jobArray.each do |jobID|
          ff.write %Q[<p:JobArray>#{jobID}</p:JobArray>
                     ]
        end
        ff.write %Q[<p:StartTimeInterval>TIME_NOW</p:StartTimeInterval>]
        ff.write %Q[</p:#{method}_INPUT>]
      end
      cmd  = "#{INVOKE_CMD} -a #{method}"
      svcUri = find_instance_uri(JOB_SVC_CLASS)
      output = self.command(cmd, svcUri, "-J #{inputFile}")
      puts output
      returnVal = self.returnValue(output,method)
      if returnVal.to_i == RETURN_CFG_OK
        puts "Successfully set up job queue"
        retVal = true
      end
    end
    retVal
  end

  ## Utility method to create a targeted config job against a service   ##
  ## class and target denoted by FQDD - generic method that can be used ##
  ## against all hardware config etc                                    ##
  def create_targeted_config_job(svc_class_uri, fqdd)
    puts "Creating targeted config job..."
    cmd = "#{INVOKE_CMD} -a CreateTargetedConfigJob -k Target=#{fqdd} -k ScheduledStartTime=TIME_NOW -k RebootJobType=3"
    output = self.command(cmd, svc_class_uri)
    returnVal = self.returnValue(output,"CreateTargetedConfigJob")
    if returnVal.to_i == RETURN_CFG_JOB
      puts "Successfully created a config job..."
      wsInstance = self.processResponse(output,'["Body"]["CreateTargetedConfigJob_OUTPUT"]["Job"]')
      jobURI = get_job_selector(wsInstance)
      if (jobURI.nil?)
        puts "Unable to parse JID for targeted config job on #{fqdd}...Exiting"
      else
        poll_job_for_completion(jobURI)
      end
    end
  end

  ## Utility method to poll multiple jobs triggered by setting up   ##
  ## the job queue - this is useful when tracked from an admin node ##
  ## and not in the current scenarios for updates etc               ##
  ## Poll each job for it's status and when done, remove from the   ##
  ## job array until all jobs are cleared..                         ##
  def poll_multiple_jobs(jobArray)
    while (jobArray.length != 0)
      jobArray.each do |jobID|
        puts "Polling job id #{jobID}"
        ## ugh...hack because of bugs in wsman side
        jobURI = "#{WSMAN_URI_NS}/DCIM_LifecycleJob?InstanceID=#{jobID}"
        output = self.command("get", jobURI)
        jobStatus = self.processResponse(output,'["Body"]["DCIM_LifecycleJob"]["JobStatus"]')
        if (jobStatus.downcase =~ /.*completed.*/)
          puts "Job #{jobID} completed successfully...."
          jobArray.delete(jobID)
        elsif (jobStatus.downcase =~ /fail/)
          failReason = self.processResponse(output,'["Body"]["DCIM_LifecycleJob"]["Message"]')
          failReasonID = self.processResponse(output,'["Body"]["DCIM_LifecycleJob"]["MessageID"]')
          puts "Job failed..#{failReasonID}:#{failReason}"
          jobArray.delete(jobID)
        else
          puts "Job status = #{jobStatus}...Continue to poll"
          sleep(30)
        end
      end
    end
  end

  def poll_job_for_completion(uri)
    puts "Polling config job status... "
    for i in 0..20
      output = self.command("get", uri)
      jobStatus = self.processResponse(output,'["Body"]["DCIM_LifecycleJob"]["JobStatus"]')
      if (jobStatus.downcase =~ /completed/)
        puts "Job completed successfully...."
        break
      elsif (jobStatus.downcase =~ /fail/)
         failReason = self.processResponse(output,'["Body"]["DCIM_LifecycleJob"]["Message"]')
         failReasonID = self.processResponse(output,'["Body"]["DCIM_LifecycleJob"]["MessageID"]')
         puts "Job failed..#{failReasonID}:#{failReason}"
         break
       else
         puts "Job status = #{jobStatus}...Continue to poll"
         sleep(30)
       end
    end
  end

  def get_current_and_pending_bootmode()
    current_mode = nil
    pending_mode = nil
    begin
      output = self.command(ENUMERATE_CMD, BIOS_ENUM_URI, " -m 512 --dialect \"http://schemas.dmtf.org/wbem/cql/1/dsp0202.pdf\" --filter \"select * from DCIM_BIOSEnumeration where AttributeName='BootMode'\" ")
      if (output)
        wsInstance = self.processResponse(output, '["Body"]["EnumerateResponse"]["Items"]')
        current_mode = wsInstance["DCIM_BIOSEnumeration"]["CurrentValue"]
        pending_mode = wsInstance["DCIM_BIOSEnumeration"]["PendingValue"]
      else
        puts "No data returned from enumeration of boot mode attribute"
      end
    rescue Exception => e
      puts "Exception determining boot mode...#{e.message}"
    end
    [current_mode, pending_mode]
  end

  def get_uefi_boot_source_settings()
    puts "Determining UEFI boot source settings."
    bss     = nil
    uefibss = [] 
    url = "#{WSMAN_URI_NS}/DCIM_BootSourceSetting"
    xml = self.command(ENUMERATE_CMD, url, "-m 512")
    if (xml)
      bss = self.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_BootSourceSetting"]')
      if (bss)
        bss.each do |setting|
          if (setting['BootSourceType'] and setting['BootSourceType'] == "UEFI")
            uefibss << setting
          end
        end
      end
    else
      puts "No boot source settings found...Returning empty array of boot source settings"
    end
    uefibss
  end

  def get_bios_boot_source_settings()
    puts "Determining BIOS boot source settings."
    bss     = nil
    biosbss = [] 
    url = "#{WSMAN_URI_NS}/DCIM_BootSourceSetting"
    xml = self.command(ENUMERATE_CMD, url, "-m 512")
    if (xml)
      bss = self.processResponse(xml,'["Body"]["EnumerateResponse"]["Items"]["DCIM_BootSourceSetting"]')
      if (bss)
        bss.each do |setting|
          if (setting['BootSourceType'] and (setting['BootSourceType'] == "IPL" or setting['BootSourceType'] == "BCV"))
            biosbss << setting
          end
        end
      end
    else
      puts "No boot source settings found...Returning empty array of boot source settings"
    end
    biosbss
  end

  ## Method to manipulate boot sources on the system and return ##
  ## an array of modified boot sources used to create the config ##
  def set_boot_sources(boot_mode, boot_source_settings, nicFirst = true)
    puts "Setting boot sources - #{boot_mode}, #{nicFirst}"
    boot_source_list = []
    emb_nics         = []
    int_nics         = []
    all_other_nics   = []
    other_boot_srcs  = []

    return boot_source_list if (!boot_source_settings or boot_source_settings.length == 0)

    puts "DBG:Current boot source settings list is #{boot_source_settings}"

    if (boot_mode == "UEFI")
      if (nicFirst)
        boot_source_settings.each do |bss|
          emb_nics        << bss if (bss['InstanceID'].start_with?('UEFI:NIC.Embedded'))
          int_nics        << bss if (bss['InstanceID'].start_with?('UEFI:NIC.Integrated'))
          all_other_nics  << bss if (bss['InstanceID'].start_with?('UEFI:NIC') and !emb_nics.include?(bss) and !int_nics.include?(bss) )
          other_boot_srcs << bss if (!emb_nics.include?(bss) and !int_nics.include?(bss) and !all_other_nics.include?(bss))
        end
        boot_source_list = emb_nics.sort if (emb_nics and emb_nics.length > 0)
        boot_source_list = boot_source_list | int_nics.sort        if (int_nics and int_nics.length > 0)
        boot_source_list = boot_source_list | all_other_nics.sort  if (all_other_nics and all_other_nics.length > 0)
        boot_source_list = boot_source_list | other_boot_srcs.sort if (other_boot_srcs and other_boot_srcs.length > 0)
      else
        puts "nicFirst = false. Returning current boot order"
        boot_source_list = boot_source_settings
      end
    elsif (boot_mode == "BIOS")
      if (nicFirst)
        boot_source_settings.each do |bss|
          emb_nics        << bss if (bss['InstanceID'].start_with?('IPL:NIC.Embedded'))
          int_nics        << bss if (bss['InstanceID'].start_with?('IPL:NIC.Integrated'))
          all_other_nics  << bss if (bss['InstanceID'].start_with?('IPL:NIC') and !emb_nics.include?(bss) and !int_nics.include?(bss) )
          other_boot_srcs << bss if (!emb_nics.include?(bss) and !int_nics.include?(bss) and !all_other_nics.include?(bss))
        end
        boot_source_list = emb_nics.sort if (emb_nics and emb_nics.length > 0)
        boot_source_list = boot_source_list | int_nics.sort        if (int_nics and int_nics.length > 0)
        boot_source_list = boot_source_list | all_other_nics.sort  if (all_other_nics and all_other_nics.length > 0)
        boot_source_list = boot_source_list | other_boot_srcs.sort if (other_boot_srcs and other_boot_srcs.length > 0)
      else
        puts "nicFirst = false. Returning current boot order"
        boot_source_list = boot_source_settings
      end
    else
      puts "Unknown boot mode #{boot_mode} - Not manipulating boot sources"
    end
    puts "DBG:Re-ordered boot source settings list is #{boot_source_list}"
    boot_source_list
  end

  def writeBootSourceFile(inputFile, instanceIds)
    File.open("#{inputFile}", "w+") do |f|
          f.write %Q[
             <p:#{CHANGE_BOOT_ORDER_CMD}_INPUT xmlns:p="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_BootConfigSetting"> 
          ]
          instanceIds.each do |instanceId|
            next unless instanceId
            next if instanceId == ""
            f.write %Q[
               <p:source>#{instanceId}</p:source> 
            ]
          end
          f.write %Q[
             </p:#{CHANGE_BOOT_ORDER_CMD}_INPUT>
          ]
        end
    true
  end


  ## Utility methods culled from xml_util.rb
    def  processResponse(xml, path, options={"ForceArray" => false})
    hash = XmlSimple.xml_in(xml, options)
    output = eval("hash#{path}")
    return output
  end

  def returnValue(xml,cmd)
    path = '["Body"]["' + cmd + '_OUTPUT"]["ReturnValue"]'
    processResponse(xml , path)
  end



 end
end
