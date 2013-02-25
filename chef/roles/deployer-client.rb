
name "deployer-client"
description "Deployer Client role - Discovery components"
run_list(
         "recipe[barclamp]",
         "recipe[repos]",
         "recipe[crowbar-hacks]",
         "recipe[ohai]",
         "recipe[kernel-panic]"
)
default_attributes "deployer" => {
  "use_allocate" => true,
  "ignore_address_suggestions" => false,
  "bios_map" => {
    "pattern" => ".*",
    "bios_set" => "Virtualization",
    "raid_set" => "SingleRaid10"
  },
  "os_map" => [ { "pattern" => ".*", "install_os" => "default_os" } ],
  "config" => {
    "environment" => "deployer-config-default"
  }
}
override_attributes()

