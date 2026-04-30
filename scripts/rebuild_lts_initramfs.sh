#!/bin/bash
# rebuild_lts_initramfs.sh -- Rebuild Alpine LTS initramfs for cosim
# Takes the working virt initramfs as base, replaces modules with LTS ones,
# and injects cosim-init.
#
# The original alpine-lts initramfs.gz had a dynamically-linked busybox
# without shared libraries, causing kernel panic (ENOENT on /init).
# This script uses the virt initramfs (which has proper shared libs + busybox)
# as a base and swaps in LTS kernel modules extracted from the LTS rootfs.
#
# Usage: ./scripts/rebuild_lts_initramfs.sh
# Requires: debugfs (from e2fsprogs)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

VIRT_INITRAMFS="${PROJECT_DIR}/guest/images/alpine/initramfs.gz"
LTS_ROOTFS="${PROJECT_DIR}/guest/images/alpine-lts/rootfs.ext4"
COSIM_INIT="${PROJECT_DIR}/guest/cosim-init"
OUTPUT="${PROJECT_DIR}/guest/images/alpine-lts/initramfs.gz"
KVER="6.6.134-0-lts"
DEBUGFS="/usr/sbin/debugfs"

WORK_DIR=$(mktemp -d /tmp/cosim-rebuild-initramfs.XXXXXX)
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "[1/8] Extracting virt initramfs as base..."
cd "$WORK_DIR"
zcat "$VIRT_INITRAMFS" | cpio -id 2>/dev/null

echo "[2/8] Removing virt kernel modules..."
rm -rf lib/modules/6.6.134-0-virt

echo "[3/8] Creating LTS modules directory..."
mkdir -p "lib/modules/$KVER/kernel/drivers/virtio"
mkdir -p "lib/modules/$KVER/kernel/drivers/block"
mkdir -p "lib/modules/$KVER/kernel/drivers/net"
mkdir -p "lib/modules/$KVER/kernel/drivers/pci"
mkdir -p "lib/modules/$KVER/kernel/drivers/vfio/pci"
mkdir -p "lib/modules/$KVER/kernel/drivers/vfio/mdev"
mkdir -p "lib/modules/$KVER/kernel/fs/ext4"
mkdir -p "lib/modules/$KVER/kernel/fs/jbd2"
mkdir -p "lib/modules/$KVER/kernel/virt/lib"
mkdir -p "lib/modules/$KVER/kernel/lib"
mkdir -p "lib/modules/$KVER/kernel/crypto"

echo "[4/8] Extracting essential LTS modules from rootfs..."
# Essential modules for boot + VFIO/SR-IOV testing
# Order: deps listed before dependents
MODULES=(
    "kernel/drivers/virtio/virtio.ko.gz"
    "kernel/drivers/virtio/virtio_ring.ko.gz"
    "kernel/drivers/virtio/virtio_pci_modern_dev.ko.gz"
    "kernel/drivers/virtio/virtio_pci_legacy_dev.ko.gz"
    "kernel/drivers/virtio/virtio_pci.ko.gz"
    "kernel/drivers/block/virtio_blk.ko.gz"
    "kernel/drivers/net/virtio_net.ko.gz"
    "kernel/drivers/pci/pci-stub.ko.gz"
    "kernel/lib/crc16.ko.gz"
    "kernel/crypto/crc32c_generic.ko.gz"
    "kernel/lib/libcrc32c.ko.gz"
    "kernel/fs/mbcache.ko.gz"
    "kernel/fs/jbd2/jbd2.ko.gz"
    "kernel/fs/ext4/ext4.ko.gz"
    "kernel/virt/lib/irqbypass.ko.gz"
    "kernel/drivers/vfio/vfio.ko.gz"
    "kernel/drivers/vfio/vfio_iommu_type1.ko.gz"
    "kernel/drivers/vfio/pci/vfio-pci-core.ko.gz"
    "kernel/drivers/vfio/pci/vfio-pci.ko.gz"
    "kernel/drivers/vfio/mdev/mdev.ko.gz"
)

FAIL_COUNT=0
for mod in "${MODULES[@]}"; do
    dst="lib/modules/$KVER/$mod"
    src="/lib/modules/$KVER/$mod"
    echo "  + $mod"
    if ! "$DEBUGFS" "$LTS_ROOTFS" -R "dump $src $WORK_DIR/$dst" 2>/dev/null; then
        echo "    [WARN] Failed to extract $mod"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

if [ "$FAIL_COUNT" -gt 3 ]; then
    echo "[ERROR] Too many modules failed to extract ($FAIL_COUNT). Check rootfs."
    exit 1
fi

echo "[5/8] Creating module metadata files..."
touch "lib/modules/$KVER/modules.dep"
touch "lib/modules/$KVER/modules.dep.bin"
touch "lib/modules/$KVER/modules.alias"
touch "lib/modules/$KVER/modules.alias.bin"
touch "lib/modules/$KVER/modules.symbols"
touch "lib/modules/$KVER/modules.symbols.bin"
touch "lib/modules/$KVER/modules.devname"
touch "lib/modules/$KVER/modules.softdep"

echo "[6/8] Injecting cosim-init..."
cp "$COSIM_INIT" init
chmod +x init

echo "[7/8] Listing extracted modules..."
find . -name "*.ko*" -exec ls -lh {} \;
echo ""
echo "Total files in initramfs:"
find . | wc -l

echo "[8/8] Repacking initramfs..."
if [ -f "$OUTPUT" ]; then
    cp "$OUTPUT" "${OUTPUT}.bak"
    echo "  Backed up old initramfs to ${OUTPUT}.bak"
fi
find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT"
echo "  Output: $OUTPUT"
ls -lh "$OUTPUT"

echo ""
echo "[DONE] LTS initramfs rebuilt successfully."
echo "  Old (broken): dynamically-linked busybox, no shared libs, 488K"
echo "  New (fixed):  virt base + LTS modules + cosim-init"
