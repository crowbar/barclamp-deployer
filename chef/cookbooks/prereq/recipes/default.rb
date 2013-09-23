=begin
# Install wsman in case we need it
rpm -Uvh /updates/wsman/libwsman1-2.2.7-1.x86_64.rpm
rpm -Uvh /updates/wsman/wsmancli-2.2.7.1-11.x86_64.rpm

=end
if (node["crowbar"]["provisioner"]["server"] rescue nil)
  provisioner = node["crowbar"]["provisioner"]["server"]
  platform = node[:platform]
  t = template "/etc/gemrc" do
    variables(:webserver => provisioner["webserver"])
  end
  t.run_action(:create_if_missing)
  gem_repo = "#{provisioner["webserver"]}/gemsite"
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
end

Gem.clear_paths
require 'libxml'
require 'xmlsimple'
require 'wsman'
