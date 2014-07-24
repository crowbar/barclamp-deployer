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

# This recipe is a placeholder for misc. hacks we want to do on every node,
# but that do not really belong with any specific barclamp.

states = [ "ready", "readying", "recovering", "applying" ]
if states.include?(node[:state])
  if node["platform"] != "suse" and node["platform"] != "windows"
    # Don't waste time with mlocate or updatedb
    %w{mlocate mlocate.cron updatedb}.each do |f|
      file "/etc/cron.daily/#{f}" do
        action :delete
      end
    end

    template "/etc/logrotate.d/chef" do
      source "logrotate.erb"
      owner "root"
      group "root"
      mode "0644"
      variables(:logfiles => "/var/log/chef/client.log",
                :postrotate => "bluepill chef-client restart")
    end

    # Set up some basic log rotation
    template "/etc/logrotate.d/crowbar-webserver" do
      source "logrotate.erb"
      owner "root"
      group "root"
      mode "0644"
      variables(:logfiles => "/var/log/crowbar/*.log /var/log/crowbar/*.out /var/log/crowbar/chef-client/*.log",
                  :action => "create 644 crowbar crowbar",
                :postrotate => "/usr/bin/killall -USR1 rainbows")
    end if node[:recipes].include?("crowbar")
    template "/etc/logrotate.d/node-logs" do
      source "logrotate.erb"
      owner "root"
      group "root"
      mode "0644"
      variables(:logfiles => "/var/log/nodes/*.log /var/log/nodes/.log",
                :postrotate => "/usr/bin/killall -HUP rsyslogd")
    end if node[:recipes].include?("logging::server")
    template "/etc/logrotate.d/client-join-logs" do
      source "logrotate.erb"
      owner "root"
      group "root"
      mode "0644"
      variables(:logfiles => ["/var/log/crowbar/crowbar_join/*"])
    end unless node[:recipes].include?("crowbar")
  end
  # Note: Hacks that are needed on SUSE platforms as well too come here

  if platform?("suse", "redhat", "centos")
    # Workaround sysctl not loading configs from /etc/sysctl.d/
    # during reboot
    directory "create /etc/sysctl.d for reload-sysctl.d cronjob" do
      path "/etc/sysctl.d"
      mode "755"
    end
    cookbook_file "/etc/cron.d/reload-sysctl.d" do
      source "reload-sysctl-d.cron"
    end
  end
end

if node["uefi"]
  node["uefi"]["boot"]["order"].each do |order|
    entry = node["uefi"]["entries"][order]
    next if entry[:active]

    Chef::Log.info("Activating UEFI boot entry #{sprintf("%x", order)}: #{entry["title"]}")
    ::Kernel.system("efibootmgr -a -b #{sprintf('%x', order)}")
  end

  neworder = node["uefi"]["boot"]["order"].partition do |order|
    node["uefi"]["entries"][order]["device"] =~ /[\/)]MAC\(/i rescue false
  end.flatten

  if neworder != node["uefi"]["boot"]["order"]
    Chef::Log.info("Change UEFI Boot Order: #{node[:provisioner_state]} #{node["uefi"]["boot"]["order"].inspect} => #{neworder.inspect}")
    ::Kernel.system("efibootmgr -o #{neworder.map{ |e| sprintf("%x", order) }.join(",")}")

    node["uefi"]["boot"]["order_old"] = node["uefi"]["boot"]["order"]
    node["uefi"]["boot"]["order"] = neworder

    node.save
  end
end
