=begin
# Install wsman in case we need it
rpm -Uvh /updates/wsman/libwsman1-2.2.7-1.x86_64.rpm
rpm -Uvh /updates/wsman/wsmancli-2.2.7.1-11.x86_64.rpm

=end
provisioners = search(:node, "roles:provisioner-server")
provisioner = provisioners[0] if provisioners
web_port = provisioner["provisioner"]["web_port"] rescue 3001
address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(provisioner, "admin").address rescue "127.0.0.1"
path = "/gemsite/"
path = "" if web_port == 3001

platform = node[:platform]
 

t = template "/etc/gemrc" do
    variables(:admin_ip => address, :web_port => web_port, :path => path)
    mode "0644"
end
t.run_action(:create_if_missing)

gem_repo = "http://#{address}:#{web_port}#{path}"
gems = ["xml-simple","libxml-ruby","wsman"]
rpms = ["libwsman1-2.2.7-1.x86_64.rpm","wsmancli-2.2.7.1-11.x86_64.rpm"]
gems.each do |gem|
  log("gem_package: #{gem}, next")
  g = gem_package gem do
    action :nothing
    version ">0"
    options "--source #{gem_repo}"
  end
  g.run_action(:install);
end  

case platform
 when "centos", "redhat"
  rpms.each do |rpm|
    log("rpm_package: #{rpm}, next")
    r = rpm_package rpm do
      action :nothing
    end
    r.run_action(:install);
  end
end


Gem.clear_paths 
require 'libxml'
require 'xmlsimple'
require 'wsman'


