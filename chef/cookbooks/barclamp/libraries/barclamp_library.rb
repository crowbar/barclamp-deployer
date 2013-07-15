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

module BarclampLibrary
  class Barclamp
    class Inventory
      def self.list_networks(node)
        answer = []
        intf_to_if_map = Barclamp::Inventory.build_node_map(node)
        node[:crowbar][:network].each do |net, data|
          intf, interface_list, tm = Barclamp::Inventory.lookup_interface_info(node, data["conduit"], intf_to_if_map)
          answer << Network.new(net, data, intf, interface_list)
        end unless node[:crowbar].nil? or node[:crowbar][:network].nil?
        answer
      end

      def self.get_network_by_type(node, type)
        node[:crowbar][:network].each do |net, data|
          next if data[:usage] != type
          intf, interface_list, tm = Barclamp::Inventory.lookup_interface_info(node, data["conduit"])
          return Network.new(net, data, intf, interface_list)
        end unless node[:crowbar][:network].nil?
        node[:crowbar][:network].each do |net, data|
          next if data[:usage] != "admin"
          intf, interface_list, tm = Barclamp::Inventory.lookup_interface_info(node, data["conduit"])
          return Network.new(net, data, intf, interface_list)
        end unless node[:crowbar][:network].nil?
        nil
      end

      # IMPORTANT: This needs to be kept in sync with the bus_index method in
      # node_object.rb in the Crowbar framework.
      def self.bus_index(bus_order, path)
        return 999 if bus_order.nil?

        dpath = path.split("/")
        # For backwards compatibility with the old busid matching
        # which just stripped of everything after the first '.'
        # in the busid
        dpath_old = path.split(".")[0].split("/")

        index = 0
        bus_order.each do |b|
          subindex = 0
          bs = b.split("/")

          # When there is no '.' in the busid from the bus_order assume
          # that we are using the old method of matching busids
          if b.include?('.')
            dpath_used=dpath
            if bs.size != dpath_used.size
              next
            end
          else
            dpath_used=dpath_old
          end

          match = true
          bs.each do |bp|
            break if subindex >= dpath_used.size
            match = false if bp != dpath_used[subindex]
            break unless match
            subindex = subindex + 1
          end

          return index if match
          index = index + 1
        end

        999
      end

      def self.sort_ifs(map, bus_order)
        answer = map.sort{|a,b|
          aindex = Barclamp::Inventory.bus_index(bus_order, a[1]["path"])
          bindex = Barclamp::Inventory.bus_index(bus_order, b[1]["path"])
          aindex == bindex ? a[0] <=> b[0] : aindex <=> bindex
        }
        answer.map! { |x| x[0] }
      end

      # IMPORTANT: This needs to be kept in sync with the get_bus_order method in
      # node_object.rb in the Crowbar framework.
      def self.get_bus_order(node)
        bus_order = nil
        node["network"]["interface_map"].each do |data|
          if node[:dmi][:system][:product_name] =~ /#{data["pattern"]}/
            if data.has_key?("serial_number")
                bus_order = data["bus_order"] if node[:dmi][:system][:serial_number].strip == data["serial_number"].strip
            else
                bus_order = data["bus_order"]
            end
          end
          break if bus_order
        end rescue nil
        bus_order
      end

      def self.get_conduits(node)
        conduits = nil
        node["network"]["conduit_map"].each do |data|
          # conduit pattern format:  <mode>/#nics/role-pattern
          parts = data["pattern"].split("/")
          the_one = true
          ### find the right conduit mapping to be used based on the conduit's pattern and node info.
          # check that the networking config mode (e.g. single/dual etc) matches
          the_one = false unless node["network"]["mode"] =~ /#{parts[0]}/
          # check that the # of detected NIC's on the node matches.
          the_one = false unless node.automatic_attrs["crowbar_ohai"]["detected"]["network"].size.to_s =~ /#{parts[1]}/

          found = false
          # if the conduit map has a role, check that the node at least one matching role
          node.roles.each do |role|
            found = true if role =~ /#{parts[2]}/
            break if found
          end
          the_one = false unless found

          conduits = data["conduit_list"] if the_one
          break if conduits
        end rescue nil
        conduits
      end

      def self.get_detected_intfs(node)
        node.automatic_attrs["crowbar_ohai"]["detected"]["network"]
      end
        
      def self.build_node_map(node)
        bus_order = Barclamp::Inventory.get_bus_order(node)
        conduits = Barclamp::Inventory.get_conduits(node)

        return {} if conduits.nil?

        if_list = get_detected_intfs(node)

        # build a set of maps <intf-designator> -> <OS intf>
        # designators are <speed><#> (speed = 100m, 1g etc). # is a count of interfaces of the same speed.
        # OS intf is the name given to the interface by the operating system
        # The intf-designator is 'stable' in terms of renumbering because of addition/removal of add on cards (across machines)

        sorted_ifs = Barclamp::Inventory.sort_ifs(if_list, bus_order)
        if_remap = {}
        count_map = {}
        sorted_ifs.each do |intf|
          speeds = if_list[intf]["speeds"]
          speeds = ['1g'] unless speeds   #legacy object support
          speeds.each do |speed|
            count = count_map[speed] || 1
            if_remap["#{speed}#{count}"] = intf
            count_map[speed] = count + 1
          end
        end

        ans = {}
        conduits.each do |k,v|
          hash = {}
          v.each do |mk, mv|
            if mk == "if_list"
              hash["if_list"] = v["if_list"].map do |if_ref|
                map_if_ref(if_remap, if_ref)
              end
            else
              hash[mk] = mv
            end
          end
          ans[k] = hash
        end

        ans
      end

      ## 
      # given a map of available interfaces on the local machine, 
      # resolve references form conduit list. The supported reference format is <sign><speed><#> where
      #  - sign is optional, and determines behavior if exact match is not found. + allows speed upgrade, - allows downgrade
      #    ? allows either. If no sign is specified, an exact match must be found.
      #  - speed designates the interface speed. 10m, 100m, 1g and 10g are supported
      def self.map_if_ref(if_map, ref) 
        speeds= %w{10m 100m 1g 10g}
        m= /^([-+?]?)(\d{1,3}[mg])(\d+)$/.match(ref) # [1]=sign, [2]=speed, [3]=count
        if_cnt = m[3]
        desired = speeds.index(m[2]) 
        found = nil
          filter = lambda { |x| 
          found = if_map["#{speeds[x]}#{if_cnt}"] unless found
        }
        case m[1]
          when '+': (desired..speeds.length).each(&filter)
          when '-': desired.downto(0,&filter) 
          when '?':  
            (desired..speeds.length).each(&filter)
            desired.downto(0,&filter) unless found
          else
            found = if_map[ref]
          end
          found
      end
        
      def self.lookup_interface_info(node, conduit, intf_to_if_map = nil)
        intf_to_if_map = Barclamp::Inventory.build_node_map(node) if intf_to_if_map.nil?

        return [nil, nil] if intf_to_if_map[conduit].nil?

        c_info = intf_to_if_map[conduit]
        interface_list = c_info["if_list"]
        team_mode = c_info["team_mode"] rescue nil

        return [interface_list[0], interface_list, nil] if interface_list.size == 1

        node["crowbar"]["bond_list"] = {} if (node["crowbar"].nil? or node["crowbar"]["bond_list"].nil?)
        bond_list = node["crowbar"]["bond_list"]
        the_bond = nil
        bond_list.each do |bond, map|
          the_bond = bond if map == interface_list
          break if the_bond
        end

        if the_bond.nil?
          the_bond = "bond#{bond_list.size}"
          bond_list[the_bond] = interface_list
          # The rescue nil handles the case where we are looking up a node that isn't us
          node.save rescue nil  
        end

        [the_bond, interface_list, team_mode]
      end

      class Network
        attr_reader :name, :address, :broadcast, :mac, :netmask, :subnet, :router, :usage, :vlan, :use_vlan, :interface, :interface_list, :add_bridge, :conduit
        def initialize(net, data, rintf, interface_list)
          @name = net
          @address = data["address"]
          @broadcast = data["broadcast"]
          @mac = data["mac"]
          @netmask = data["netmask"]
          @subnet = data["subnet"]
          @router = data["router"]
          @usage = data["usage"]
          @vlan = data["vlan"]
          @use_vlan = data["use_vlan"]
          @conduit = data["conduit"]
          @interface = rintf
          @interface_list = interface_list
          @add_bridge = data["add_bridge"]
        end
      end

      class Disk
        attr_reader :device
        def initialize(node,name)
          @device = name
          @node = node
        end

        def self.all(node)
          node[:block_device].keys.map{|d|Disk.new(node,d)}
        end

        def self.unclaimed(node)
          all(node).select{|d|d.fixed && !d.claimed?}
        end

        def self.claimed(node,owner)
          all(node).select{|d| c = d.claimed?; c != nil && c[:owner] == owner}
        end

        def name
          File.join("/dev/",@device)
        end

        def model
          @node[:block_device][@device][:model] || "Unknown"
        end

        def removable
          @node[:block_device][@device][:removable] != "0"
        end

        def size
          (@node[:block_device][@device][:size] || 0).to_i
        end

        def state
          @node[:block_device][@device][:state] || "Unknown"
        end

        def vendor
          @node[:block_device][@device][:vendor] || "NA"
        end
        
        def owner
          (@node[:crowbar_wall][:claimed_disks][self.unique_name] rescue "")
        end

        def usage
          Chef::Log.error("Usage method for disks is deprecated!  Please update your code to use owner")
          self.owner
        end

        def fixed
          # This needs to be kept in sync with the number_of_drives method in
          # node_object.rb in the Crowbar framework.
          @device =~ /^[hsv]d/ && !removable
        end

        def <=>(other)
          self.name <=> other.name
        end

        def unique_name
          # SCSI device ids are likely to be more stable than hardware
          # paths to a device, and both are more stable than by-uuid,
          # which is actually a filesystem attribute.
          ["by-id","by-path"].each do |n|
            path = File.join("/dev/disk",n)
            next unless File.directory?(path)
            Dir.entries(path).each do |p|
              link = File.join(path,p)
              next unless File.symlink?(link)
              Chef::Log.debug("Considering #{link} for #{@device}")
              next unless File.readlink(link).split("/")[-1] == @device
              # We found our most unique name.
              Chef::Log.debug("Using #{link} for #{@device}")
              return link
            end
          end
          # I hope the actual device name won't change, but it likely will.
          Chef::Log.debug("Could not find better name than #{name}")
          name
        end

        def claimed?
          @node[:crowbar_wall][:claimed_disks][self.unique_name] rescue nil
        end
        
        def claim(owner)
          saver = {}
          saver[:owner]=owner
          @node[:crowbar_wall] ||= Mash.new
          @node[:crowbar_wall][:claimed_disks] ||= Mash.new
          k = self.unique_name
          if (@node[:crowbar_wall][:claimed_disks][k] rescue nil)
            return @node[:crowbar_wall][:claimed_disks][k] == saver
          end
          Chef::Log.info("Claiming #{k} for #{owner}")
          @node[:crowbar_wall][:claimed_disks][k] = saver
          @node.save
          true
        end

        def release(owner)
          k = self.unique_name
          Chef::Log.info("Releasing #{k} from #{owner}")
          return false unless (@node[:crowbar_wall][:claimed_disks][k] rescue "") == owner
          @node[:crowbar_wall][:claimed_disks][k] = nil
          @node.save
          true
        end

        def self.size_to_bytes(s)
          case s
            when /^([0-9]+)$/
            return $1.to_f

            when /^([0-9]+)[Kk][Bb]$/
            return $1.to_f * 1024

            when /^([0-9]+)[Mm][Bb]$/
            return $1.to_f * 1024 * 1024

            when /^([0-9]+)[Gg][Bb]$/
            return $1.to_f * 1024 * 1024 * 1024

            when /^([0-9]+)[Tt][Bb]$/
            return $1.to_f * 1024 * 1024 * 1024 * 1024
          end
          -1
        end

      end

    end
  end
end


