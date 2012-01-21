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

states = [ "ready", "readying", "recovering", "applying" ]
if provisioner and states.include?(node[:state])
  web_port = provisioner["provisioner"]["web_port"]
  repositories = provisioner["provisioner"]["repositories"][os_token]
  address = Chef::Recipe::Barclamp::Inventory.get_network_by_type(provisioner, "admin").address

  case node["platform"]
  when "ubuntu","debian"
    cookbook_file "/etc/apt/apt.conf.d/99-crowbar-no-auth" do
      source "apt.conf"
    end
    
    file "/etc/apt/sources.list" do
      action :delete
    end
    repositories.each do |repo,url|
      case repo
      when "base"
        template "/etc/apt/sources.list.d/00-base.list" do
          variables(:url => url)
        end
      else
        template "/etc/apt/sources.list.d/10-barclamp-#{repo}.list" do
          source "10-crowbar-extra.list.erb"
          variables(:url => url)
        end
      end
    end
    bash "update apt sources" do
      code "apt-get update"
      action :nothing
    end
    package "rubygems"
  when "redhat","centos"
    repositories.each do |repo,url|
      template "/etc/yum.repos.d/crowbar-#{repo}.repo" do
        source "crowbar-xtras.repo.erb"
        variables(:repo => repo, :url => url)
      end
    end
       
    bash "update yum sources" do
      code "yum clean expire-cache"
      action :nothing
    end
  end

  template "/etc/gemrc" do
    variables(:admin_ip => address, :web_port => web_port)
  end

end

