#!/bin/bash
# build_rootfs_debian.sh -- build Debian rootfs.ext4
# Usage: sudo ./scripts/build_rootfs_debian.sh [output_dir]
# Requires: sudo, debootstrap, network
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$(cd "${1:-${PROJECT_DIR}/guest/images}" 2>/dev/null && pwd || echo "${PROJECT_DIR}/guest/images")"
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
ROOTFS_SIZE_MB=1024
ROOTFS_IMG="${OUTPUT_DIR}/rootfs.ext4"
MOUNT_DIR=$(mktemp -d /tmp/cosim-rootfs.XXXXXX)
LOOP_DEV=""

info()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $*"; }
fail()  { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

cleanup() {
    info "Cleaning up..."
    umount "$MOUNT_DIR/proc" 2>/dev/null || true
    umount "$MOUNT_DIR/sys" 2>/dev/null || true
    umount "$MOUNT_DIR/dev" 2>/dev/null || true
    umount "$MOUNT_DIR" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -rf "$MOUNT_DIR"
}
trap cleanup EXIT

if [ "$(id -u)" -ne 0 ]; then
    fail "Need root. Run: sudo $0"
fi

if ! command -v debootstrap &>/dev/null; then
    fail "debootstrap not installed. Run: sudo apt install debootstrap"
fi

# zstd 用于解压 Debian initramfs（bookworm 默认 zstd 压缩）
if ! command -v zstd &>/dev/null; then
    apt-get install -y -qq zstd 2>/dev/null || echo "[WARN] zstd not installed, initramfs repack may fail"
fi

mkdir -p "$OUTPUT_DIR"

# ---- Create ext4 image ----
info "Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=none
mkfs.ext4 -q -F "$ROOTFS_IMG"
LOOP_DEV=$(losetup --find --show "$ROOTFS_IMG")
mount "$LOOP_DEV" "$MOUNT_DIR"

# ---- Debootstrap ----
info "Running debootstrap ${DEBIAN_SUITE} (5-10 minutes)..."
debootstrap --variant=minbase "$DEBIAN_SUITE" "$MOUNT_DIR" "$DEBIAN_MIRROR"

# ---- Install packages ----
info "Installing packages (apt install)..."
mount -t proc proc "$MOUNT_DIR/proc"
mount -t sysfs sysfs "$MOUNT_DIR/sys"
mount --bind /dev "$MOUNT_DIR/dev"

chroot "$MOUNT_DIR" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq iperf3 iproute2 iputils-ping ethtool tcpdump
    apt-get install -y -qq pciutils usbutils
    apt-get install -y -qq kmod util-linux procps
    apt-get install -y -qq rdma-core perftest 2>/dev/null || echo "RDMA not available"
    apt-get install -y -qq gcc make 2>/dev/null || echo "Dev tools partially installed"
    apt-get install -y -qq wget curl bash-completion
    # 安装内核（含 virtio 驱动）
    apt-get install -y -qq linux-image-amd64 2>/dev/null || echo "Kernel package not available"
    apt-get clean
    rm -rf /var/lib/apt/lists/*
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

INITRD=$(ls "$MOUNT_DIR"/boot/initrd.img-* 2>/dev/null | head -1)
if [ -n "$INITRD" ]; then
    # 注入 cosim-init 替换 Debian 默认 init（适配 cosim 高延迟环境）
    COSIM_INIT="${PROJECT_DIR}/guest/cosim-init"
    if [ -f "$COSIM_INIT" ]; then
        REPACK_DIR=$(mktemp -d /tmp/cosim-initramfs.XXXXXX)
        cd "$REPACK_DIR"
        # Debian bookworm 可能用 zstd 或 gzip 压缩 initrd
        if file "$INITRD" | grep -q "Zstandard"; then
            zstd -d -c "$INITRD" | cpio -id 2>/dev/null
        else
            zcat "$INITRD" | cpio -id 2>/dev/null
        fi
        cp "$COSIM_INIT" init
        chmod +x init
        find . | cpio -o -H newc 2>/dev/null | gzip > "${OUTPUT_DIR}/initramfs.gz"
        cd /
        rm -rf "$REPACK_DIR"
        ok "Initramfs: ${OUTPUT_DIR}/initramfs.gz (cosim-init injected)"
    else
        cp "$INITRD" "${OUTPUT_DIR}/initramfs.gz"
        ok "Initramfs: ${OUTPUT_DIR}/initramfs.gz (original)"
    fi
else
    echo "[WARN] initrd not found in /boot"
fi

umount "$MOUNT_DIR/proc"
umount "$MOUNT_DIR/sys"
umount "$MOUNT_DIR/dev"

# ---- Configure system ----
info "Configuring system..."

echo "cosim-guest" > "$MOUNT_DIR/etc/hostname"

# root 密码设为 123
HASH=$(openssl passwd -6 '123')
sed -i "s|^root:[^:]*:|root:${HASH}:|" "$MOUNT_DIR/etc/shadow"

# 启用 ttyS0 串口 getty（systemd）
mkdir -p "$MOUNT_DIR/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
    "$MOUNT_DIR/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service" 2>/dev/null || true

# 允许 root 通过串口登录
echo "ttyS0" >> "$MOUNT_DIR/etc/securetty" 2>/dev/null || true

cat > "$MOUNT_DIR/etc/fstab" << 'FSTAB'
/dev/vda    /        ext4    rw,relatime    0 1
proc        /proc    proc    defaults       0 0
sysfs       /sys     sysfs   defaults       0 0
FSTAB

# ---- Copy cosim overlay ----
info "Copying cosim overlay..."
OVERLAY_DIR="${PROJECT_DIR}/guest/overlay"
if [ -d "$OVERLAY_DIR" ] && [ -f "$OVERLAY_DIR/usr/local/bin/cosim-start" ]; then
    mkdir -p "$MOUNT_DIR/usr/local/bin"
    mkdir -p "$MOUNT_DIR/etc/init.d"
    mkdir -p "$MOUNT_DIR/etc/profile.d"
    cp -v "$OVERLAY_DIR"/etc/motd "$MOUNT_DIR/etc/motd"
    # Debian 用 systemd，不需要 inittab，但拷贝不影响
    cp -v "$OVERLAY_DIR"/etc/init.d/S99cosim "$MOUNT_DIR/etc/init.d/S99cosim"
    cp -v "$OVERLAY_DIR"/etc/profile.d/cosim.sh "$MOUNT_DIR/etc/profile.d/cosim.sh"
    cp -v "$OVERLAY_DIR"/usr/local/bin/cosim-start "$MOUNT_DIR/usr/local/bin/cosim-start"
    cp -v "$OVERLAY_DIR"/usr/local/bin/cosim-stop "$MOUNT_DIR/usr/local/bin/cosim-stop"
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-start"
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-stop"
    chmod +x "$MOUNT_DIR/etc/init.d/S99cosim"
    ok "Overlay copied: cosim-start, cosim-stop, motd, profile, S99cosim"
else
    echo "[WARN] guest/overlay 目录不存在或内容不完整！"
    echo "  请确认: git checkout good -- guest/overlay/"
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

ok "Debian rootfs built: $ROOTFS_IMG"
ls -lh "${OUTPUT_DIR}/"
