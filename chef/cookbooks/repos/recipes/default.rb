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

file "/tmp/.repo_update" do
  action :nothing
end

states = [ "ready", "readying", "recovering", "applying" ]
if provisioner and states.include?(node[:state])
  web_port = provisioner["provisioner"]["web_port"]
  online = provisioner["provisioner"]["online"]
  repositories = provisioner["provisioner"]["repositories"][os_token]

  case node["platform"]
  when "ubuntu","debian"
    cookbook_file "/etc/apt/apt.conf.d/99-crowbar-no-auth" do
      source "apt.conf"
    end
    file "/etc/apt/sources.list" do
      action :delete
    end unless online
    template "/etc/apt/apt.conf.d/00-proxy" do
      source "apt-proxy.erb"
      variables(:node => provisioner)
    end
    repositories.each do |repo,urls|
      case repo
      when "base"
        template "/etc/apt/sources.list.d/00-base.list" do
          variables(:urls => urls)
          notifies :create, "file[/tmp/.repo_update]", :immediately
        end
      else
        template "/etc/apt/sources.list.d/10-barclamp-#{repo}.list" do
          source "10-crowbar-extra.list.erb"
          variables(:urls => urls)
          notifies :create, "file[/tmp/.repo_update]", :immediately
        end
      end
    end
    if online
      online_repos = {}
      data_bag("barclamps").each do |bc_name|
        bc = data_bag_item("barclamps",bc_name)
        next unless bc["debs"]
        bc["debs"]["repos"].each { |repo|
          online_repos[repo] = true
        } if bc["debs"]["repos"]
        bc["debs"][os_token]["repos"].each { |repo|
          online_repos[repo] = true
        } if (bc["debs"][os_token]["repos"] rescue nil)
      end
      template "/etc/apt/sources.list.d/20-online.list" do
        source "10-crowbar-extra.list.erb"
        variables(:urls => online_repos)
        notifies :create, "file[/tmp/.repo_update]", :immediately
      end unless online_repos.empty?
    end
    bash "update software sources" do
      code "apt-get update"
      notifies :delete, "file[/tmp/.repo_update]", :immediately
      only_if { ::File.exists? "/tmp/.repo_update" }
    end
    package "rubygems"
  when "redhat","centos"
    bash "update software sources" do
      code "yum clean expire-cache"
      action :nothing
    end
    bash "add yum proxy" do
      code "echo http_proxy=http://#{provisioner.address.addr}:#{provisioner["provisioner"]["local_proxy_port"]} >> /etc/yum.conf"
      not_if "grep -q http_proxy /etc/yum.conf"
    end
    repositories.each do |repo,urls|
      template "/etc/yum.repos.d/crowbar-#{repo}.repo" do
        source "crowbar-xtras.repo.erb"
        variables(:repo => repo, :urls => urls)
        notifies :create, "file[/tmp/.repo_update]", :immediately
      end
    end
    if online
      online_repos = {}
      data_bag("barclamps").each do |barclamp_name|
        barclamp = data_bag_item('barclamps',barclamp_name)
        next unless barclamp["rpms"]
        barclamp["rpms"]["repos"].each {|repo|
          online_repos[repo] = true
        } if barclamp["rpms"]["repos"]
        barclamp["rpms"][os_token]["repos"].each {|repo|
          online_repos[repo] = true
        } if (barclamp["rpms"][os_token]["repos"] rescue nil)
      end
      unless online_repos.empty?
        rpm_repos, bare_repos = online_repos.keys.partition{ |r|
          r =~ /^rpm /
        }
        bare_repos.each do |repo|
          _, name, _, url = repo.split
          url = "baseurl=#{url}" if url =~ /^http/
          template "/etc/yum.repos.d/online-#{name}.repo" do
            source "crowbar-xtras.repo.erb"
            variables(:repo => name, :urls => {url => true})
            notifies :create, "file[/tmp/.repo_update]", :immediately
          end
        end
        rpm_repos.each do |repo|
          url = repo.split(' ',2)[1]
          file = url.split('/').last
          file = file << ".rpm" unless file =~ /\.rpm$/
          remote_file "/var/cache/#{file}" do
            source url
            action :create_if_missing
            notifies :install, "package[install yum repo #{file}]", :immediately
          end
          package "install yum repo #{file}" do
            provider Chef::Provider::Package::Rpm
            source "/var/cache/#{file}"
            notifies :create, "file[/tmp/.repo_update]", :immediately
            action :nothing
          end
        end
      end
    end
    bash "update software sources" do
      code "yum clean expire-cache"
      notifies :delete, "file[/tmp/.repo_update]", :immediately
      only_if { ::File.exists? "/tmp/.repo_update" }
    end
  end
  template "/etc/gemrc" do
    variables(:node => provisioner)
  end
end
