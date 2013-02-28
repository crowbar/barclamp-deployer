# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# This is pure steaming evil
# Force the omniinstalled version of Chef to know about gems
# from outside its little sandbox.
# This hackjob is needed for loading the cstruct gem.
Gem.clear_paths
outer_paths=%x{gem env gempath}.split(':')
outer_paths.each do |p|
  next if Gem.path.member?(p)
  Gem.paths.path << p
end


require 'etc'
require 'pathname'
require 'tempfile'
require 'timeout'
require 'rubygems'
require 'socket'
require 'cstruct'

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
rm -f #{fd.path}
EOF
    fd.close

    if background
      system(fd.path + " &")
    else
      system(fd.path)
    end
  end
end

# From: "/usr/include/linux/sockios.h"
SIOCETHTOOL = 0x8946

# From: "/usr/include/linux/ethtool.h"
ETHTOOL_GSET = 1
ETHTOOL_GLINK = 10

# From: "/usr/include/linux/ethtool.h"
class EthtoolCmd < CStruct
  uint32 :cmd
  uint32 :supported
  uint32 :advertising
  uint16 :speed
  uint8  :duplex
  uint8  :port
  uint8  :phy_address
  uint8  :transceiver
  uint8  :autoneg
  uint8  :mdio_support
  uint32 :maxtxpkt
  uint32 :maxrxpkt
  uint16 :speed_hi
  uint8  :eth_tp_mdix
  uint8  :reserved2
  uint32 :lp_advertising
  uint32 :reserved_a0
  uint32 :reserved_a1
end

# From: "/usr/include/linux/ethtool.h"
#define SUPPORTED_10baseT_Half      (1 << 0)
#define SUPPORTED_10baseT_Full      (1 << 1)
#define SUPPORTED_100baseT_Half     (1 << 2)
#define SUPPORTED_100baseT_Full     (1 << 3)
#define SUPPORTED_1000baseT_Half    (1 << 4)
#define SUPPORTED_1000baseT_Full    (1 << 5)
#define SUPPORTED_Autoneg           (1 << 6)
#define SUPPORTED_TP                (1 << 7)
#define SUPPORTED_AUI               (1 << 8)
#define SUPPORTED_MII               (1 << 9)
#define SUPPORTED_FIBRE             (1 << 10)
#define SUPPORTED_BNC               (1 << 11)
#define SUPPORTED_10000baseT_Full   (1 << 12)
#define SUPPORTED_Pause             (1 << 13)
#define SUPPORTED_Asym_Pause        (1 << 14)
#define SUPPORTED_2500baseX_Full    (1 << 15)
#define SUPPORTED_Backplane         (1 << 16)
#define SUPPORTED_1000baseKX_Full   (1 << 17)
#define SUPPORTED_10000baseKX4_Full (1 << 18)
#define SUPPORTED_10000baseKR_Full  (1 << 19)
#define SUPPORTED_10000baseR_FEC    (1 << 20)

class EthtoolValue < CStruct
  uint32 :cmd
  uint32 :value
end

def get_supported_speeds(interface)
  begin
    ecmd = EthtoolCmd.new
    ecmd.cmd = ETHTOOL_GSET

    ifreq = [interface, ecmd.data].pack("a16p")
    sock = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
    sock.ioctl(SIOCETHTOOL, ifreq)

    rv = ecmd.class.new
    rv.data = ifreq.unpack("a16p")[1]

    speeds = []
    speeds << "10m" if (rv.supported & ((1<<0)|(1<<1))) != 0
    speeds << "100m" if (rv.supported & ((1<<2)|(1<<3))) != 0
    speeds << "1g" if (rv.supported & ((1<<4)|(1<<5))) != 0
    speeds << "10g" if (rv.supported & ((0xf<<17)|(1<<12))) != 0
    speeds
  rescue Exception => e
    puts "Failed to get ioctl for speed: #{e.message}"
    speeds = [ "1g", "0g" ]
  end
end

#
# true for up
# false for down
#
def get_link_status(interface)
  begin
    ecmd = EthtoolValue.new
    ecmd.cmd = ETHTOOL_GLINK

    ifreq = [interface, ecmd.data].pack("a16p")
    sock = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
    sock.ioctl(SIOCETHTOOL, ifreq)

    rv = ecmd.class.new
    rv.data = ifreq.unpack("a16p")[1]

    rv.value != 0
  rescue Exception => e
    puts "Failed to get ioctl for link status: #{e.message}"
    false
  end
end

crowbar_ohai Mash.new
crowbar_ohai[:switch_config] = Mash.new unless crowbar_ohai[:switch_config]

# Packet captures are cached from previous runs; however this requires
# the use of predictable pathnames. To prevent this becoming a security
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
  speeds = get_supported_speeds(entry)
  crowbar_ohai[:detected][:network][entry] = { :path => spath, :speeds => speeds }

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
  crowbar_ohai[:switch_config][network][:port_link] = get_link_status(network)
  crowbar_ohai[:switch_config][network][:switch_name] = sw_name
  crowbar_ohai[:switch_config][network][:switch_port] = sw_port
  crowbar_ohai[:switch_config][network][:switch_port_name] = sw_port_name
  crowbar_ohai[:switch_config][network][:switch_unit] = sw_unit
end

