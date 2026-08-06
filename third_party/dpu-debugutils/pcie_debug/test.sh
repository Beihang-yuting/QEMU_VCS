vblk_spec() {
/bin/expect <<EOF
set timeout -1
spawn /root/project/debug/pci_debug/dpu-debugutils/pcie_debug-master/bin/pci_debug -s 03:00.0
expect {
    "PCI>" { send "d 0x01000114 4\r" }
}
sleep 1
interact
EOF
}
