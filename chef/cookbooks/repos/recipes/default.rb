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

provisioners = search(:node, "roles:provisioner-server")
provisioner = provisioners[0] if provisioners
os_token="#{node[:platform]}-#{node[:platform_version]}"

states = [ "ready", "readying", "problem", "applying" ]
if provisioner and states.include?(node[:state])
  web_port = provisioner["provisioner"]["web_port"]
  address = provisioner["ipaddress"]
  on_admin = node["crowbar"] and node["crowbar"]["admin_node"]

  case node["platform"]
  when "ubuntu","debian"
    bash "update apt sources" do
      code "apt-get update"
      action :nothing
    end
    
    cookbook_file "/etc/apt/apt.conf.d/99-crowbar-no-auth" do
      source "apt.conf"
    end
    
    file "/etc/apt/sources.list" do
      action :delete
    end unless on_admin
    
    template "/etc/apt/sources.list.d/00-base.list" do
      variables(:admin_ip => address, :web_port => web_port)
      notifies :run, resources("bash[update apt sources]"), :immediately
    end
    template "/etc/apt/sources.list.d/10-crowbar-extra.list" do
      variables(:os_token => os_token, :admin_ip => address, :web_port => web_port)
      notifies :run, resources("bash[update apt sources]"), :immediately
    end
    package "rubygems"
  when "redhat","centos"
    bash "update yum sources" do
      code "yum clean expire-cache"
      action :nothing
    end

    template "/etc/yum.repos.d/#{os_token}-Base.repo" do
      variables(:admin_ip => address, :web_port => web_port, :os_token => os_token)
      source "yum-base.repo.erb"
      notifies :run, resources("bash[update yum sources]"), :immediately
    end

    template "/etc/yum.repos.d/crowbar-xtras.repo" do
      variables(:admin_ip => address, :web_port => web_port, :os_token => os_token)
      notifies :run, resources("bash[update yum sources]"), :immediately
    end
  end


  bash "fixup rubygems repo" do
    code <<__EOC__
gem source -c
gem source list |grep -q "#{address}" || gem source -a "http://#{address}:3001/"
gem source list |grep -q rubygems.org && gem source -r "http://rubygems.org/"
__EOC__
    only_if "gem source list |grep -q rubygems.org"
  end

end

