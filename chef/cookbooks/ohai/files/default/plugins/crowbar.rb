# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'etc'
require 'pathname'
require 'tempfile'
require 'timeout'

provides "crowbar_ohai"

class System
  def self.background_time_command(timeout, background, name, command)
    fd = Tempfile.new("tcpdump-#{name}-")
    fd.chmod(0700)
    fd.puts <<-EOF.gsub(/^\s+/, '')
      #!/bin/bash
      #{command} &
      sleep #{timeout}
      kill %1
    EOF
    fd.close

    if background
      system(fd.path + " &")
    else
      system(fd.path)
    end

    fd.delete
  end
end

crowbar_ohai Mash.new
crowbar_ohai[:switch_config] = Mash.new unless crowbar_ohai[:switch_config]

# Packet captures are cached from previous runs; however this requires
# the use of predictable pathnames.  To prevent this becoming a security
# risk, we create a dedicated directory and ensure that we own it and
# it's not writable by anyone else.
#
# See https://bugzilla.novell.com/show_bug.cgi?id=774967
@tcpdump_dir = '/tmp/ohai-tcpdump'

begin
  Dir.mkdir(@tcpdump_dir, 0700)
rescue Errno::EEXIST
  # already created by previous run
rescue
  raise "Failed to mkdir #{@tcpdump_dir}: #$!"
end

me = Etc.getpwuid(Process.uid).name
unless File.owned? @tcpdump_dir
  raise "#{@tcpdump_dir} must be owned by #{me}"
end
File::chmod(0700, @tcpdump_dir)

def tcpdump_file(network)
  Pathname(@tcpdump_dir) + "#{network}.out"
end

networks = []
mac_map = {}
bus_found=false
logical_name=""
mac_addr=""
wait=false
Dir.foreach("/sys/class/net") do |entry|
  next if entry =~ /\./
  # We only care about actual physical devices.
  next unless File.exists? "/sys/class/net/#{entry}/device"
  Chef::Log.debug("examining network interface: " + entry)

  type = File::open("/sys/class/net/#{entry}/type") do |f|
    f.readline.strip
  end rescue "0"
  Chef::Log.debug("#{entry} is type #{type}")
  next unless type == "1"

  s1 = File.readlink("/sys/class/net/#{entry}") rescue ""
  spath = File.readlink("/sys/class/net/#{entry}/device") rescue "Unknown"
  spath = s1 if s1 =~ /pci/
  spath = spath.gsub(/.*pci/, "").gsub(/\/net\/.*/, "")
  Chef::Log.debug("#{entry} spath is #{spath}")

  crowbar_ohai[:detected] = Mash.new unless crowbar_ohai[:detected]
  crowbar_ohai[:detected][:network] = Mash.new unless crowbar_ohai[:detected][:network]
  crowbar_ohai[:detected][:network][entry] = spath

  logical_name = entry
  networks << logical_name
  f = File.open("/sys/class/net/#{entry}/address", "r")
  mac_addr = f.gets()
  mac_map[logical_name] = mac_addr.strip
  f.close
  Chef::Log.debug("MAC is #{mac_addr.strip}")

  tcpdump_out = tcpdump_file(logical_name)
  Chef::Log.debug("tcpdump to: #{tcpdump_out}")

  if ! File.exists? tcpdump_out
    cmd = "ifconfig #{logical_name} up ; tcpdump -c 1 -lv -v -i #{logical_name} -a -e -s 1514 ether proto 0x88cc > #{tcpdump_out}"
    Chef::Log.debug("cmd: #{cmd}")
    System.background_time_command(45, true, logical_name, cmd)
    wait=true
  end
end
system("sleep 45") if wait

networks.each do |network|
  tcpdump_out = tcpdump_file(network)

  sw_unit = -1
  sw_port = -1
  sw_port_name = nil

  line = IO.readlines(tcpdump_out).grep(/Subtype Interface Name/).join ''
  Chef::Log.debug("subtype intf name line: #{line}")
  if line =~ %r!(\d+)/\d+/(\d+)!
    sw_unit, sw_port = $1, $2
  end
  if line =~ /: Unit (\d+) Port (\d+)/
    sw_unit, sw_port = $1, $2
  end
  if line =~ %r!: (\S+ (\d+)/(\d+))!
    sw_port_name, sw_unit, sw_port = $1, $2, $3
  else
    sw_port_name = "#{sw_unit}/0/#{sw_port}"
  end

  sw_name = -1
  # Using mac for now, but should change to something else later.
  line = IO.readlines(tcpdump_out).grep(/Subtype MAC address/).join ''
  Chef::Log.debug("subtype MAC line: #{line}")
  if line =~ /: (.*) \(oui/
    sw_name = $1
  end

  crowbar_ohai[:switch_config][network] = Mash.new unless crowbar_ohai[:switch_config][network]
  crowbar_ohai[:switch_config][network][:interface] = network
  crowbar_ohai[:switch_config][network][:mac] = mac_map[network].downcase
  crowbar_ohai[:switch_config][network][:switch_name] = sw_name
  crowbar_ohai[:switch_config][network][:switch_port] = sw_port
  crowbar_ohai[:switch_config][network][:switch_port_name] = sw_port_name
  crowbar_ohai[:switch_config][network][:switch_unit] = sw_unit
end

