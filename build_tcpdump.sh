#!/bin/bash
bc_needs_build() {
    [[ ! -x $BC_DIR/chef/cookbooks/ohai/files/default/tcpdump ]]
}

bc_build() {
    sudo cp "$BC_DIR/build_tcpdump_chroot.sh" "$CHROOT/tmp/"
    in_chroot /tmp/build_tcpdump_chroot.sh
    cp "$CHROOT/tmp/tcpdump" "$BC_DIR/chef/cookbooks/ohai/files/default/"
}