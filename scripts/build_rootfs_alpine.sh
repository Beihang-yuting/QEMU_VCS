#!/bin/bash
# build_rootfs_alpine.sh -- build Alpine Linux rootfs.ext4
# Usage: sudo ./scripts/build_rootfs_alpine.sh [output_dir]
# Requires: sudo, network (or pre-downloaded tar in third_party/)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="${1:-${PROJECT_DIR}/guest/images}"
ALPINE_VER="3.20"
ALPINE_ARCH="x86_64"
ALPINE_TAR="alpine-minirootfs-${ALPINE_VER}.0-${ALPINE_ARCH}.tar.gz"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/releases/${ALPINE_ARCH}/${ALPINE_TAR}"
ROOTFS_SIZE_MB=256
ROOTFS_IMG="${OUTPUT_DIR}/rootfs.ext4"
MOUNT_DIR=$(mktemp -d /tmp/cosim-rootfs.XXXXXX)
LOOP_DEV=""

info()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $*"; }
fail()  { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

cleanup() {
    info "Cleaning up..."
    umount "$MOUNT_DIR" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    fail "Need root. Run: sudo $0"
fi

mkdir -p "$OUTPUT_DIR" "${PROJECT_DIR}/third_party"

# ---- Download Alpine minirootfs ----
TARBALL="${PROJECT_DIR}/third_party/${ALPINE_TAR}"
if [ -f "$TARBALL" ]; then
    info "Using cached Alpine tar: $TARBALL"
else
    info "Downloading Alpine minirootfs..."
    if ! wget -q --show-progress -O "$TARBALL" "$ALPINE_URL"; then
        rm -f "$TARBALL"
        fail "Download failed. For offline use, place tar at: $TARBALL"
    fi
    ok "Download complete"
fi

# ---- Create ext4 image ----
info "Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=none
mkfs.ext4 -q -F "$ROOTFS_IMG"
LOOP_DEV=$(losetup --find --show "$ROOTFS_IMG")
mount "$LOOP_DEV" "$MOUNT_DIR"

# ---- Extract Alpine ----
info "Extracting Alpine rootfs..."
tar xzf "$TARBALL" -C "$MOUNT_DIR"

# ---- DNS for chroot ----
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf" 2>/dev/null || true

# ---- Install packages ----
info "Installing packages (apk add)..."
chroot "$MOUNT_DIR" /bin/sh -c '
    apk update
    apk add iperf3 iproute2 iputils ethtool tcpdump
    apk add pciutils usbutils
    apk add kmod util-linux procps coreutils
    apk add rdma-core perftest 2>/dev/null || echo "RDMA not available, skipping"
    apk add bash wget curl
    # 安装虚拟化内核（含 virtio 驱动）
    apk add linux-virt
    rm -rf /var/cache/apk/*
'

# ---- Extract kernel + initramfs ----
info "Extracting kernel and initramfs..."
VMLINUZ=$(ls "$MOUNT_DIR"/boot/vmlinuz-* 2>/dev/null | head -1)
if [ -n "$VMLINUZ" ]; then
    cp "$VMLINUZ" "${OUTPUT_DIR}/bzImage"
    ok "Kernel: ${OUTPUT_DIR}/bzImage"
else
    echo "[WARN] vmlinuz not found in /boot, bzImage not extracted"
fi

INITRAMFS=$(ls "$MOUNT_DIR"/boot/initramfs-* 2>/dev/null | head -1)
if [ -n "$INITRAMFS" ]; then
    cp "$INITRAMFS" "${OUTPUT_DIR}/initramfs.gz"
    ok "Initramfs: ${OUTPUT_DIR}/initramfs.gz"
else
    echo "[WARN] initramfs not found in /boot"
fi

# ---- Configure system ----
info "Configuring system..."

cat > "$MOUNT_DIR/etc/inittab" << 'INITTAB'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::sysinit:/sbin/openrc default
ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100
::shutdown:/sbin/openrc shutdown
INITTAB

echo "cosim-guest" > "$MOUNT_DIR/etc/hostname"

sed -i 's/^root:.*/root::0:0:root:\/root:\/bin\/ash/' "$MOUNT_DIR/etc/shadow" 2>/dev/null || \
    echo 'root::0:0:root:/root:/bin/ash' > "$MOUNT_DIR/etc/shadow"
chmod 640 "$MOUNT_DIR/etc/shadow"

cat > "$MOUNT_DIR/etc/fstab" << 'FSTAB'
/dev/vda    /        ext4    rw,relatime    0 1
proc        /proc    proc    defaults       0 0
sysfs       /sys     sysfs   defaults       0 0
devtmpfs    /dev     devtmpfs defaults      0 0
FSTAB

# ---- Copy cosim overlay ----
info "Copying cosim overlay..."
OVERLAY_DIR="${PROJECT_DIR}/guest/overlay"
if [ -d "$OVERLAY_DIR" ]; then
    cp -a "$OVERLAY_DIR"/* "$MOUNT_DIR/" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-start" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-stop" 2>/dev/null || true
    chmod +x "$MOUNT_DIR/etc/init.d/S99cosim" 2>/dev/null || true
fi

# ---- Copy custom test tools (if built) ----
TOOLS_DIR="${PROJECT_DIR}/build/guest_tools"
if [ -d "$TOOLS_DIR" ]; then
    info "Copying custom test tools..."
    cp -a "$TOOLS_DIR"/* "$MOUNT_DIR/usr/local/bin/" 2>/dev/null || true
fi

# ---- Done ----
umount "$MOUNT_DIR"
losetup -d "$LOOP_DEV"
LOOP_DEV=""

# 修复权限（sudo 构建，产出文件归还给调用者）
if [ -n "${SUDO_USER:-}" ]; then
    chown "$SUDO_USER:$SUDO_USER" "${OUTPUT_DIR}/bzImage" "${OUTPUT_DIR}/initramfs.gz" "$ROOTFS_IMG" 2>/dev/null || true
fi

ok "Alpine rootfs built: $ROOTFS_IMG"
ls -lh "${OUTPUT_DIR}/"
