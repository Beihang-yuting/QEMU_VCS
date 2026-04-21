#!/bin/bash
# build_guest_initramfs.sh — 在 QEMU 机器上构建 Guest initramfs
# 用法: bash scripts/build_guest_initramfs.sh
set -euo pipefail

GUEST_DIR="${HOME}/workspace/guest"
BUILD_DIR="/tmp/initrd_build"
OUTPUT="${GUEST_DIR}/rootfs-initramfs.gz"

echo "=== Building Guest initramfs ==="

# 清理并解压 Alpine rootfs
sudo rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
sudo tar xzf "${GUEST_DIR}/alpine-rootfs.tar.gz"

# 添加网络配置脚本
sudo tee etc/init.d/cosim_net > /dev/null << 'NETEOF'
#!/bin/sh
ip link set eth0 up 2>/dev/null
ip addr add 10.0.0.2/24 dev eth0 2>/dev/null
echo "cosim: eth0 = 10.0.0.2/24"
NETEOF
sudo chmod +x etc/init.d/cosim_net

# 创建 initramfs init 入口
sudo tee init > /dev/null << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
echo ""
echo "=== CoSim Guest Started ==="
echo ""
/etc/init.d/cosim_net
echo "--- PCI devices ---"
lspci 2>/dev/null || cat /proc/bus/pci/devices 2>/dev/null | head -20
echo "--- Network interfaces ---"
ip link show 2>/dev/null
echo ""
echo "Type commands or 'poweroff' to exit"
exec /bin/sh
INITEOF
sudo chmod +x init

# 打包为 cpio+gzip
cd "${BUILD_DIR}"
sudo find . -print0 | sudo cpio --null -o --format=newc 2>/dev/null | gzip > "${OUTPUT}"

echo ""
echo "=== Done ==="
echo "Output: ${OUTPUT} ($(ls -lh "${OUTPUT}" | awk '{print $5}'))"
