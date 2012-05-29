class Chef
  class Node
    def addresses(net="admin",type=::IP)
      (self[:crowbar_wall][:network][:addrs][net] rescue []).map{|a|
        ::IP.coerce(a)
      }.select{|a|a.kind_of? type}
    end
    def address(net="admin",type=::IP)
      self.addresses(net,type).first ||
        (::IP.coerce("#{self[:network][net][:address]}/#{self[:network][net][:netmask]}") rescue nil) ||
        ::IP.coerce(self[:ipaddress])
    end
    def interfaces(net="admin")
      (self[:crowbar_wall][:network][:nets][net] rescue []).map {|n|::Nic.new(n)}
    end
    def interface(net="admin")
      self.interfaces(net).last
    end
  end
end
