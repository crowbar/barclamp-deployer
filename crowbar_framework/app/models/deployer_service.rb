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

class DeployerService < ServiceObject

  def transition(inst, name, state)
    @logger.debug("Deployer transition: entering #{name} for #{state}")

    node = Node.find_by_name(name)
    if node.nil?
      @logger.error("Deployer transition: leaving #{name} for #{state}: Node not found")
      return [404, "Node not found"] # GREG: Translate
    end

    # 
    # If we are discovering the node, make sure that we add the deployer client to the node
    #
    if state == "discovering"
      @logger.debug("Deployer transition: leaving #{name} for #{state}: discovering mode")

      if node.is_admin?
        roles = %w(deployer-client bmc-nat-router)
      else
        roles = %w(deployer-client bmc-nat-client)
      end
      roles.each do |r|
        next if add_role_to_instance_and_node(name, inst, r)
        @logger.debug("Deployer transition: leaving #{name} for #{state}: discovering failed.")
        return [500, "Failed to add role to node"] # GREG: Translate
      end
      @logger.debug("Deployer transition: leaving #{name} for #{state}: discovering passed.")
      return [200, ""]
    end

    # if delete - clear out stuff
    if state == "delete"
      # Do more work here - one day.
      return [200, ""]
    end

    # Get our proposal info
    prop = @barclamp.get_proposal(inst)
    prop_config = prop.active? ? prop.active_config : prop.current_config
    dep_config = prop_config.config_hash

    # READ ONLY Jig HASH - XXX: should be replaced by attributes one day
    jig_hash = node.jig_hash

    #
    # At this point, we need to create our resource maps and recommendations.
    #
    # This is hard coded for now.  Should be parameter driven one day.
    # 
    @logger.debug("Deployer transition: Update the inventory crowbar structures for #{name}")
    unless jig_hash[:block_device].nil? or jig_hash[:block_device].empty?
      chash = prop_config.get_node_config_hash(node)
      chash["crowbar"] = {} if chash["crowbar"].nil?
      chash["crowbar"]["disks"] = {} 
      jig_hash[:block_device].each do |disk, data|
        # XXX: Make this into a config map one day.
        next if disk.start_with?("ram")
        next if disk.start_with?("sr")
        next if disk.start_with?("loop")
        next if disk.start_with?("dm")
        next if disk.start_with?("ndb")
        next if disk.start_with?("nbd")
        next if disk.start_with?("md")
        next if disk.start_with?("sg")
        next if disk.start_with?("fd")

        next if data[:removable] == 1 or data[:removable] == "1" # Skip cdroms

        # RedHat under KVM reports drives as hdX.  Ubuntu reports them as sdX.
        disk = disk.gsub("hd", "sd") if disk.start_with?("h") and jig_hash[:dmi][:system][:product_name] == "KVM"
  
        chash["crowbar"]["disks"][disk] = data

        # "vda" is presumably unlikely on bare metal, but may be there if testing under KVM
        chash["crowbar"]["disks"][disk]["usage"] = "OS" if disk == "sda" || disk == "vda"
        chash["crowbar"]["disks"][disk]["usage"] = "Storage" unless disk == "sda" || disk == "vda"
      end 
      prop_config.set_node_config_hash(node, chash)
    end 

    # 
    # Decide on the nodes role for the cloud
    #   * This includes adding a role for node type (for bios/raid update/config)
    #   * This includes adding an attribute on the node for inclusion in clouds
    # 
    if state == "discovered"
      @logger.debug("Deployer transition: discovered state for #{name}")
      chash = prop_config.get_node_config_hash(node)
      chash["crowbar"] = {} if chash["crowbar"].nil?

      if node.is_admin?
        # We are an admin node - display bios updates for now.
        chash["bios"] ||= {}
        chash["bios"]["bios_setup_enable"] = false
        chash["bios"]["bios_update_enable"] = false
        chash["raid"] ||= {}
        chash["raid"]["enable"] = false
      end

      chash["crowbar"]["usage"] = [] if chash["crowbar"]["usage"].nil?
      if (chash["crowbar"]["disks"] and chash["crowbar"]["disks"].size > 1) and !chash["crowbar"]["usage"].include?("swift")
        chash["crowbar"]["usage"] << "swift"
      end

      if !chash["crowbar"]["usage"].include?("nova")
        chash["crowbar"]["usage"] << "nova"
      end

      # Allocate required addresses
      range = node.is_admin? ? "admin" : "host"
      @logger.debug("Deployer transition: Allocate admin address for #{name}")
      ns = Barclamp.find_by_name("network").operations(@logger)
      result = ns.allocate_ip("default", "admin", range, name)
      @logger.error("Failed to allocate admin address for: #{node.name}: #{result[0]}") if result[0] != 200
      @logger.debug("Deployer transition: Done Allocate admin address for #{name}")

      @logger.debug("Deployer transition: Allocate bmc address for #{name}")
      suggestion = jig_hash["crowbar_wall"]["ipmi"]["address"] rescue nil

      suggestion = nil if dep_config and dep_config["deployer"]["ignore_address_suggestions"]
      result = ns.allocate_ip("default", "bmc", "host", name, suggestion)
      @logger.error("Failed to allocate bmc address for: #{node.name}: #{result[0]}") if result[0] != 200
      @logger.debug("Deployer transition: Done Allocate bmc address for #{name}")

      # If we are the admin node, we may need to add a vlan bmc address.
      if node.is_admin?
        # Add the vlan bmc if the bmc network and the admin network are not the same.
        # not great to do it this way, but hey.
              # GREG: THIS NEEDS TO BE REPLACED LATER
        admin_net = ProposalObject.find_data_bag_item "crowbar/admin_network"
        bmc_net = ProposalObject.find_data_bag_item "crowbar/bmc_network"
        if admin_net["network"]["subnet"] != bmc_net["network"]["subnet"]
          @logger.debug("Deployer transition: Allocate bmc_vlan address for #{name}")
          result = ns.allocate_ip("default", "bmc_vlan", "host", name)
          @logger.error("Failed to allocate bmc_vlan address for: #{node.name}: #{result[0]}") if result[0] != 200
          @logger.debug("Deployer transition: Done Allocate bmc_vlan address for #{name}")
        end
      end

      # Let it fly to the provisioner. Reload to get the address.
      if dep_config["deployer"]["use_allocate"] and !node.is_admin?
        node.allocated = false
      else
        node.allocated = true
      end

      chash["crowbar"]["usedhcp"] = true
      prop_config.set_node_config_hash(node, chash)
      node.save

      @logger.debug("Deployer transition: leaving discovered for #{name} EOF")
      return [200, ""]
    end

    #
    # Once we have been allocated, we will fly through here and we will setup the raid/bios info
    #
    if state == "hardware-installing"
      chash = prop_config.get_node_config_hash(node)
      chash["crowbar"] = {} if chash["crowbar"].nil?

      # build a list of current and pending roles to check against
      roles = []
      chash["crowbar"]["pending"].each do |k,v|
        roles << v
      end unless chash["crowbar"]["pending"].nil?
      # GREG: THIS IS A HACK - we need a better way to get this
      # Use NodeRoles that are active
      roles << jig_hash.run_list_to_roles
      roles.flatten!
      done = false
      # Walk map to categorize the node.  Choose first one from the bios map that matches.
      done = false
      dep_config["deployer"]["bios_map"].each do |match|
        roles.each do |r|
          next unless r =~ /#{match["pattern"]}/
          chash["crowbar"]["hardware"] ||= {}
          chash["crowbar"]["hardware"]["bios_set"] ||= match["bios_set"]
          chash["crowbar"]["hardware"]["raid_set"] ||= match["raid_set"]
          done = true
          break
        end 
        break if done
      end
      prop_config.set_node_config_hash(node, chash)
    end

    if (state == "installing") || (state == "reinstall")
      chash = prop_config.get_node_config_hash(node)
      chash["crowbar"] = {} if chash["crowbar"].nil?

      # build a list of current and pending roles to check against
      roles = []
      chash["crowbar"]["pending"].each do |k,v|
        roles << v
      end unless chash["crowbar"]["pending"].nil?
      # GREG: THIS IS A HACK - we need a better way to get this
      # Use NodeRoles that are active
      roles << jig_hash.run_list_to_roles
      roles.flatten!

      done = false
      dep_config["deployer"]["os_map"].each do |match|
        roles.each do |r|
          next unless r =~ /#{match["pattern"]}/
          chash["crowbar"]["hardware"] ||= {}
          chash["crowbar"]["hardware"]["os"] = match["install_os"] 
          done = true
          break
        end
        break if done
      end
      prop_config.set_node_config_hash(node, chash)
    end

    @logger.debug("Deployer transition: leaving state for #{name} EOF")
    return [200, ""]
  end

end

