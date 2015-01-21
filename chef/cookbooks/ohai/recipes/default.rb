#
# Cookbook Name:: ohai
# Recipe:: default
#
# Copyright 2010, Opscode, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

Ohai::Config[:plugin_path] << node.ohai.plugin_path
Chef::Log.info("ohai plugins will be at: #{node.ohai.plugin_path}")

# Make secure execution location for ohai
unless node[:platform] == "windows"
  d = directory "/var/run/ohai" do
    owner 'root'
    group 'root'
    mode 0700
    recursive true
    action :nothing
  end
  d.run_action(:create)
end

d = directory node.ohai.plugin_path do
  unless node[:platform] == "windows"
    owner 'root'
    group 'root'
    mode 0755
  end
  recursive true
  action :nothing
end
d.run_action(:create)

rd = remote_directory node.ohai.plugin_path do
  source 'plugins'
  unless node[:platform] == "windows"
    owner 'root'
    group 'root'
    mode 0755
  end
  action :nothing
end
rd.run_action(:create)

unless node[:platform] == "windows"
  # we need to ensure that the cstruct gem is available (since we use it in our
  # plugin), except on sledgehammer (because it's already installed and we can't
  # install/check packages there)
  unless CrowbarHelper.in_sledgehammer?(node)
    # During the upgrade process (stoney -> tex, old ruby&rails -> tex
    # ruby&rails), we need to run the new cookbook with the old ruby&rails once,
    # so we need to support this
    if node["languages"]["ruby"]["version"].to_f == 1.8
      pkg = "rubygem-cstruct"
    else
      pkg = "ruby#{node["languages"]["ruby"]["version"].to_f}-rubygem-cstruct"
    end
    package(pkg).run_action(:install)

    begin
      require 'cstruct'
    rescue LoadError
      # After installation of the gem, we have a new path for the new gem, so
      # we need to reset the paths if we can't load cstruct
      Gem.clear_paths
    end
  end
end

o = Ohai::System.new
o.all_plugins
node.automatic_attrs.merge! o.data
