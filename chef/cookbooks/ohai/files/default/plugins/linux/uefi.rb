provides "uefi"

if File.exists? "/sys/firmware/efi"
  result = Mash.new.tap do |result|
    result[:entries] = {}
    result[:boot] = {
      :order => [],
      :current => nil,
      :next => nil,
      :last_mac => nil
    }

    IO.popen("efibootmgr -v") do |p|
      p.each do |line|
        key, val = line.split(" ", 2)

        key.gsub! /:$/, ""
        val.strip!

        case
        when key == "BootCurrent"
          result[:boot][:current] = val.hex
        when key == "BootNext"
          result[:boot][:next] = val.hex
        when key == "BootOrder"
          result[:boot][:order] = val.split(",").map(&:hex)
        when key =~ /^Boot[0-9a-fA-F]{1,4}/
          current = key.match(/^Boot([0-9a-fA-F]+)/)[1].hex
          title, device = val.split("\t")

          result[:entries][current] = {
            :title => title,
            :device => device,
            :active => key[-1, 1] == "*"
          }
        else
          next
        end
      end
    end

    boot_entry = result[:entries][result[:boot][:current]]

    if boot_entry[:device] =~ /[\/)]MAC\(/i
      mac = boot_entry[:device].match(/[\/)]MAC\(([0-9a-f]+)/i)[1]

      result[:boot][:last_mac] = [].tap do |tmp|
        6.times do |i|
          tmp.push mac[(i * 2), 2]
        end   
      end.join(":")
    end
  end

  uefi result
end
