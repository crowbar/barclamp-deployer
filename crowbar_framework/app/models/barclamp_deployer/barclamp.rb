# Copyright 2013, Dell
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

# This class is the fall back class for barclamps that are missing Barclamp subclasses
class BarclampDeployer::Barclamp < Barclamp
  
  def process_inbound_data jig_run, node, data
    jig = jig_run.jig
    maps = JigMap.where :jig_id=>jig.id, :barclamp_id=>self.id
    maps.each do |map|
      # there is only 1 map per barclamp/jig/attrib
      a = map.attrib
      # there can be multiple AttribInstances per node/barclamp instance
      attribs = Attrib.where :attrib_id=>a.id, :node_id=>node.id
      if attribs.empty?
        # create the AIs for the data using the unbound role attribes that are already there
        unset_attribs = Attrib.where :attrib_id=>a.id, :node_id => nil
        unset_attribs.each do |na|
          # attach node to barclamp data (from role association)
          if na.barclamp.id == self.id
            # create a node specific version of it
            node_attrib = na.dup
            node_attrib.node_id = node.id
            node_attrib.save
          end
        end
      end
      # THIS NEEDS TO BE UPDATED TO ONLY UPDATE THE ACTIVE INSTANCES!
      attribs.each do |ai|
        # we only update the attribs linked to this barclamp 
        # performance note: this is an expensive thing to figure out!
        if !ai.role_instance_id.nil? and ai.barclamp.id == self.id 
          # get the value
          value = jig.find_attrib_in_data data, map.map
          # store the value
          target = Attrib.find ai.id
          target.actual = value
          target.jig_run_id = jig_run.id
          target.save!
        end
      end
    end
    node
  end
end
