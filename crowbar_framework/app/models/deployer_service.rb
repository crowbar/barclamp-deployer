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

  def initialize(thelogger)
    @bc_name = "deployer"
    @logger = thelogger
  end

  def create_proposal
    @logger.debug("Deployer create_proposal: entering")
    base = super
    @logger.debug("Deployer create_proposal: leaving")
    base
  end

  def transition(inst, name, state)
    @logger.debug("Deployer transition: entering #{name} for #{state}")

    node = NodeObject.find_node_by_name(name)
    if node.nil?
      @logger.error("Deployer transition: leaving #{name} for #{state}: Node not found")
      return [404, "Failed to find node"]
    end

    # 
    # If we are discovering the node, make sure that we add the deployer client to the node
    #
    if state == "discovering"
      @logger.debug("Deployer transition: leaving #{name} for #{state}: discovering mode")

      db = ProposalObject.find_proposal("deployer", inst)
      role = RoleObject.find_role_by_name "deployer-config-#{inst}"
      unless add_role_to_instance_and_node("deployer", inst, name, db, role, "deployer-client")
        @logger.debug("Deployer transition: leaving #{name} for #{state}: discovering failed.")
        return [404, "Failed to add role to node"]
      end
      @logger.debug("Deployer transition: leaving #{name} for #{state}: discovering passed.")
      return [200, NodeObject.find_node_by_name(name).to_hash ]
    end

    #
    # The temp booting images need to have clients cleared.
    # After installation, there is also no client available
    #
    if ["delete","discovered","hardware-installed","hardware-updated",
        "hardware-installing","hardware-updating","reset","reinstall",
        "burnin-starting","burnin-finished","completing","completed",
        "installing","installed","update"].member?(state) and !node.admin?
      @logger.debug("Deployer transition: should be deleting a client entry for #{node.name}")
      client = ClientObject.find_client_by_name node.name
      @logger.debug("Deployer transition: found and trying to delete a client entry for #{node.name}") unless client.nil?
      client.destroy unless client.nil?

      # Make sure that the node can be accessed by knife ssh or ssh
      if ["reset","reinstall","update","delete"].member?(state)
        system("sudo rm /root/.ssh/known_hosts")
      end
    end

    # if delete - clear out stuff
    if state == "delete"
      # Do more work here - one day.
      return [200, node.to_hash ]
    end

    save_it = false

    # 
    # Decide on the nodes role for the cloud
    #   * This includes adding a role for node type (for bios/raid update/config)
    #   * This includes adding an attribute on the node for inclusion in clouds
    # 
    if state == "discovered"
      @logger.debug("Deployer transition: discovered state for #{name}")

      if node.admin?
      # We are an admin node - display bios updates for now.
        node.crowbar["bios"] ||= {}
        node.crowbar["bios"]["bios_setup_enable"] = false
        node.crowbar["bios"]["bios_update_enable"] = false
        node.crowbar["raid"] ||= {}
        node.crowbar["raid"]["enable"] = false
        save_it = true
      end

      node.save if save_it

      # Allocate required addresses
      range = node.admin? ? "admin" : "host"
      @logger.debug("Deployer transition: Allocate admin address for #{name}")
      ns = NetworkService.new @logger
      result = ns.allocate_ip("default", "admin", range, name)
      @logger.error("Failed to allocate admin address for: #{node.name}: #{result[0]}") if result[0] != 200
      if result[0] == 200
        address = result[1]["address"]
        boot_ip_hex  = sprintf("%08X",address.split('.').inject(0){|acc,i|(acc << 8)+i.to_i})        
      end

      @logger.debug("Deployer transition: Done Allocate admin address for #{name} boot file:#{boot_ip_hex}")

      if node.admin?
        # If we are the admin node, we may need to add a vlan bmc address.
        # Add the vlan bmc if the bmc network and the admin network are not the same.
        # not great to do it this way, but hey.
        admin_net = ProposalObject.find_data_bag_item "crowbar/admin_network"
        bmc_net = ProposalObject.find_data_bag_item "crowbar/bmc_network"
        if admin_net["network"]["subnet"] != bmc_net["network"]["subnet"]
          @logger.debug("Deployer transition: Allocate bmc_vlan address for #{name}")
          result = ns.allocate_ip("default", "bmc_vlan", "host", name)
          @logger.error("Failed to allocate bmc_vlan address for: #{node.name}: #{result[0]}") if result[0] != 200
          @logger.debug("Deployer transition: Done Allocate bmc_vlan address for #{name}")
        end

        # Allocate the bastion network ip for the admin node if a bastion
        # network is defined in the network proposal
        bastion_net = ProposalObject.find_data_bag_item "crowbar/bastion_network"
        unless bastion_net.nil?
          result = ns.allocate_ip("default", "bastion", range, name)
          if result[0] != 200
            @logger.error("Failed to allocate bastion address for: #{node.name}: #{result[0]}")
          else
            @logger.debug("Allocated bastion address: #{result[1]["address"]} for the admin node.")
          end
        end
      end

      # Let it fly to the provisioner. Reload to get the address.
      node = NodeObject.find_node_by_name node.name
      node.crowbar["crowbar"]["usedhcp"] = true

      role = RoleObject.find_role_by_name "deployer-config-#{inst}"
      if role.default_attributes["deployer"]["use_allocate"] and !node.admin?
        node.allocated = false 
      else
        node.allocated = true
      end

      # save this on the node after it's been refreshed with the network info.
      node.crowbar["crowbar"]["boot_ip_hex"] = boot_ip_hex  if boot_ip_hex
      node.save

      @logger.debug("Deployer transition: leaving discovered for #{name} EOF")
      return [200, node.to_hash ]
    end

    #
    # Once we have been allocated, we will fly through here and we will setup the raid/bios info
    #
    if state == "hardware-installing"
      # build a list of current and pending roles to check against
      roles = []
      node.crowbar["crowbar"]["pending"].each do |k,v|
        roles << v
      end unless node.crowbar["crowbar"]["pending"].nil?
      roles << node.run_list_to_roles
      roles.flatten!

      # Walk map to categorize the node.  Choose first one from the bios map that matches.
      role = RoleObject.find_role_by_name "deployer-config-#{inst}"
      done = false
      role.default_attributes["deployer"]["bios_map"].each do |match|
        roles.each do |r|
          if r =~ /#{match["pattern"]}/
            node.crowbar["crowbar"]["hardware"] = {} if node.crowbar["crowbar"]["hardware"].nil? 
            node.crowbar["crowbar"]["hardware"]["bios_set"] = match["bios_set"] if node.crowbar["crowbar"]["hardware"]["bios_set"].nil?
            node.crowbar["crowbar"]["hardware"]["raid_set"] = match["raid_set"] if node.crowbar["crowbar"]["hardware"]["raid_set"].nil?
            done = true
            break
          end
        end 
        break if done
      end
      
      os_map = role.default_attributes["deployer"]["os_map"]
      node.crowbar["crowbar"]["hardware"]["os"] = os_map[0]["install_os"] 
      save_it = true
    end

    node.save if save_it

    @logger.debug("Deployer transition: leaving state for #{name} EOF")
    return [200, node.to_hash ]
  end

end

