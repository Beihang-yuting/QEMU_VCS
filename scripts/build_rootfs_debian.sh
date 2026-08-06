#!/bin/bash
# build_rootfs_debian.sh -- build Debian rootfs.ext4
# Usage: sudo ./scripts/build_rootfs_debian.sh [output_dir]
# Requires: sudo, debootstrap, network
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$(cd "${1:-${PROJECT_DIR}/guest/images/debian}" 2>/dev/null && pwd || echo "${PROJECT_DIR}/guest/images/debian")"
DEBIAN_SUITE="bookworm"
DEBIAN_MIRROR="http://deb.debian.org/debian"
ROOTFS_SIZE_MB=1536
ROOTFS_IMG="${OUTPUT_DIR}/rootfs.ext4"
BUILD_DIR="${PROJECT_DIR}/build"
BUILD_TMP="${PROJECT_DIR}/build/tmp"
DEBUG_TOOLS_DIR="${PROJECT_DIR}/build/guest_tools"
DEBUG_BIN_DIR="${DEBUG_TOOLS_DIR}/dpu-debugutils"
BUILD_USER=""
MOUNT_DIR=""
REPACK_DIR=""
LOOP_DEV=""
mounted_root=false
mounted_proc=false
mounted_sys=false
mounted_dev=false
unmount_failed=false
cleanup_failed=false
mount_transition=false
pending_signal=0

info()  { echo -e "\033[0;36m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $*"; }
fail()  { echo -e "\033[0;31m[FAIL]\033[0m $*"; exit 1; }

mount_state() {
    local mountpoint_status

    if mountpoint -q -- "$1"; then
        return 0
    else
        mountpoint_status=$?
    fi
    case "$mountpoint_status" in
        1|32) return 32 ;;
        *) return 2 ;;
    esac
}

begin_mount_transition() {
    pending_signal=0
    mount_transition=true
}

finish_mount_transition() {
    local command_status=$1
    local signal_status

    mount_transition=false
    if [ "$pending_signal" -ne 0 ]; then
        signal_status=$pending_signal
        pending_signal=0
        exit "$signal_status"
    fi
    return "$command_status"
}

tracked_mount() {
    local flag_name=$1
    local target=$2
    local mount_status
    local state
    shift 2

    begin_mount_transition
    if "$@"; then
        mount_status=0
    else
        mount_status=$?
    fi
    if mount_state "$target"; then
        printf -v "$flag_name" '%s' true
    else
        state=$?
        if [ "$state" -eq 32 ]; then
            printf -v "$flag_name" '%s' false
            if [ "$mount_status" -eq 0 ]; then
                echo "[WARN] Mount command succeeded but $target is not mounted" >&2
                mount_status=1
            fi
        else
            printf -v "$flag_name" '%s' true
            echo "[WARN] Could not determine mount state for $target" >&2
            [ "$mount_status" -ne 0 ] || mount_status=1
        fi
    fi
    finish_mount_transition "$mount_status"
}

record_unmount_failure() {
    unmount_failed=true
    cleanup_failed=true
}

unmount_if_mounted() {
    local flag_name=$1
    local target=$2
    local umount_status=0
    local state

    begin_mount_transition
    if [ "${!flag_name}" != true ]; then
        if mount_state "$target"; then
            printf -v "$flag_name" '%s' true
        else
            state=$?
            if [ "$state" -eq 32 ]; then
                printf -v "$flag_name" '%s' false
                finish_mount_transition 0
                return 0
            fi
            printf -v "$flag_name" '%s' true
            echo "[WARN] Could not determine mount state for $target" >&2
            record_unmount_failure
            finish_mount_transition 0
            return 0
        fi
    fi

    if umount "$target"; then
        umount_status=0
    else
        umount_status=$?
    fi
    if mount_state "$target"; then
        echo "[WARN] $target remains mounted; preserving work directory" >&2
        printf -v "$flag_name" '%s' true
        record_unmount_failure
    else
        state=$?
        if [ "$state" -eq 32 ]; then
            printf -v "$flag_name" '%s' false
            if [ "$umount_status" -ne 0 ]; then
                echo "[WARN] umount failed for $target even though it is no longer mounted" >&2
                record_unmount_failure
            fi
        else
            printf -v "$flag_name" '%s' true
            echo "[WARN] Could not verify unmount of $target; preserving work directory" >&2
            record_unmount_failure
        fi
    fi
    finish_mount_transition 0
}

unmount_all() {
    unmount_if_mounted mounted_dev "$MOUNT_DIR/dev"
    unmount_if_mounted mounted_sys "$MOUNT_DIR/sys"
    unmount_if_mounted mounted_proc "$MOUNT_DIR/proc"
    unmount_if_mounted mounted_root "$MOUNT_DIR"
}

mounts_remain() {
    local flag_name
    local target
    local state
    local any_mounted=false

    while read -r flag_name target; do
        if mount_state "$target"; then
            printf -v "$flag_name" '%s' true
            any_mounted=true
        else
            state=$?
            if [ "$state" -eq 32 ]; then
                printf -v "$flag_name" '%s' false
            else
                printf -v "$flag_name" '%s' true
                echo "[WARN] Could not verify mount state for $target" >&2
                cleanup_failed=true
                any_mounted=true
            fi
        fi
    done <<EOF
mounted_dev $MOUNT_DIR/dev
mounted_sys $MOUNT_DIR/sys
mounted_proc $MOUNT_DIR/proc
mounted_root $MOUNT_DIR
EOF
    [ "$any_mounted" = true ]
}

detach_loop_if_safe() {
    [ -n "$LOOP_DEV" ] || return 0
    if mounts_remain; then
        echo "[WARN] Mounted paths remain; not detaching $LOOP_DEV" >&2
        cleanup_failed=true
        return 1
    fi
    if losetup -d "$LOOP_DEV"; then
        LOOP_DEV=""
        return 0
    fi
    echo "[WARN] Could not detach loop device $LOOP_DEV" >&2
    cleanup_failed=true
    return 1
}

remove_repack_dir() {
    [ -n "$REPACK_DIR" ] || return 0
    case "$REPACK_DIR" in
        "$BUILD_TMP"/debian-initramfs.*) ;;
        *)
            echo "[WARN] Refusing to remove unexpected initramfs path: $REPACK_DIR" >&2
            cleanup_failed=true
            return 1
            ;;
    esac
    if rm -rf -- "$REPACK_DIR"; then
        REPACK_DIR=""
        return 0
    fi
    echo "[WARN] Could not remove initramfs work directory: $REPACK_DIR" >&2
    cleanup_failed=true
    return 1
}

remove_mount_dir() {
    [ -n "$MOUNT_DIR" ] || return 0
    case "$MOUNT_DIR" in
        "$BUILD_TMP"/debian-rootfs.*) ;;
        *)
            echo "[WARN] Refusing to remove unexpected mount path: $MOUNT_DIR" >&2
            cleanup_failed=true
            return 1
            ;;
    esac
    if rm -rf -- "$MOUNT_DIR"; then
        MOUNT_DIR=""
        return 0
    fi
    echo "[WARN] Could not remove rootfs work directory: $MOUNT_DIR" >&2
    cleanup_failed=true
    return 1
}

cleanup() {
    local status=$?

    trap - EXIT
    trap '' INT TERM
    set +e
    info "Cleaning up..."
    if [ -n "$MOUNT_DIR" ]; then
        unmount_failed=false
        unmount_all
    fi
    detach_loop_if_safe || true
    remove_repack_dir || true
    if [ -n "$MOUNT_DIR" ]; then
        if ! mounts_remain; then
            remove_mount_dir || true
        else
            echo "[WARN] Mounted paths remain under $MOUNT_DIR; not removing it" >&2
            cleanup_failed=true
        fi
    fi
    if [ "$cleanup_failed" = true ] && [ "$status" -eq 0 ]; then
        status=1
    fi
    exit "$status"
}

handle_signal() {
    local signal_status=$1

    if [ "$mount_transition" = true ]; then
        pending_signal=$signal_status
        return 0
    fi
    exit "$signal_status"
}

handle_int() {
    handle_signal 130
}

handle_term() {
    handle_signal 143
}

run_as_build_user() {
    if [ -n "$BUILD_USER" ]; then
        sudo -u "$BUILD_USER" -- "$@"
    else
        "$@"
    fi
}

prepare_build_directory() {
    local path=$1
    local canonical_path

    [ ! -L "$path" ] || fail "Refusing symlinked build path: $path"
    if [ -e "$path" ] && [ ! -d "$path" ]; then
        fail "Build path is not a directory: $path"
    fi
    if [ ! -d "$path" ]; then
        run_as_build_user mkdir -p -- "$path"
    fi
    [ -d "$path" ] && [ ! -L "$path" ] || fail "Invalid build directory: $path"
    canonical_path=$(cd "$path" && pwd -P)
    [ "$canonical_path" = "$path" ] || fail "Build path escapes the worktree: $path"
    run_as_build_user test -w "$path" || fail "Build path is not writable: $path"
}

prepare_debug_build_paths() {
    prepare_build_directory "$BUILD_DIR"
    prepare_build_directory "$BUILD_TMP"
    prepare_build_directory "$DEBUG_TOOLS_DIR"
    prepare_build_directory "$DEBUG_BIN_DIR"
}

trap cleanup EXIT
trap handle_int INT
trap handle_term TERM

if [ "$(id -u)" -ne 0 ]; then
    fail "Need root. Run: sudo $0"
fi

if [ -n "${SUDO_USER:-}" ]; then
    [[ "$SUDO_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] ||
        fail "Invalid SUDO_USER: $SUDO_USER"
    id -u "$SUDO_USER" >/dev/null 2>&1 || fail "Unknown SUDO_USER: $SUDO_USER"
    id -g "$SUDO_USER" >/dev/null 2>&1 || fail "Invalid SUDO_USER group: $SUDO_USER"
    command -v sudo >/dev/null 2>&1 || fail "sudo is required for invoking-user builds"
    BUILD_USER=$SUDO_USER
fi

if ! command -v debootstrap &>/dev/null; then
    fail "debootstrap not installed. Run: sudo apt install debootstrap"
fi
if ! command -v mountpoint &>/dev/null; then
    fail "mountpoint not installed. Run: sudo apt install util-linux"
fi

# zstd 用于解压 Debian initramfs（bookworm 默认 zstd 压缩）
if ! command -v zstd &>/dev/null; then
    apt-get install -y -qq zstd 2>/dev/null || echo "[WARN] zstd not installed, initramfs repack may fail"
fi

prepare_debug_build_paths
run_as_build_user "${PROJECT_DIR}/scripts/build_dpu_debugutils.sh"
for utility in pci_debug reg_display; do
    [ -f "${DEBUG_BIN_DIR}/${utility}" ] &&
        [ ! -L "${DEBUG_BIN_DIR}/${utility}" ] &&
        [ -x "${DEBUG_BIN_DIR}/${utility}" ] ||
        fail "Invalid debug utility output: ${DEBUG_BIN_DIR}/${utility}"
    run_as_build_user test -w "${DEBUG_BIN_DIR}/${utility}" ||
        fail "Debug utility is not writable by build user: ${DEBUG_BIN_DIR}/${utility}"
done

MOUNT_DIR=$(mktemp -d "${BUILD_TMP}/debian-rootfs.XXXXXX")
mkdir -p "$OUTPUT_DIR"

# ---- Create ext4 image ----
info "Creating ${ROOTFS_SIZE_MB}MB ext4 image..."
dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=$ROOTFS_SIZE_MB status=none
mkfs.ext4 -q -F "$ROOTFS_IMG"
LOOP_DEV=$(losetup --find --show "$ROOTFS_IMG")
tracked_mount mounted_root "$MOUNT_DIR" mount "$LOOP_DEV" "$MOUNT_DIR"

# ---- Debootstrap ----
info "Running debootstrap ${DEBIAN_SUITE} (5-10 minutes)..."
debootstrap --variant=minbase "$DEBIAN_SUITE" "$MOUNT_DIR" "$DEBIAN_MIRROR"

# ---- Install packages ----
info "Installing packages (apt install)..."
tracked_mount mounted_proc "$MOUNT_DIR/proc" \
    mount -t proc proc "$MOUNT_DIR/proc"
tracked_mount mounted_sys "$MOUNT_DIR/sys" \
    mount -t sysfs sysfs "$MOUNT_DIR/sys"
tracked_mount mounted_dev "$MOUNT_DIR/dev" \
    mount --bind /dev "$MOUNT_DIR/dev"

chroot "$MOUNT_DIR" /bin/bash -c '
    export DEBIAN_FRONTEND=noninteractive
    # 禁用 invoke-rc.d（chroot 中无 init 系统）
    echo "exit 101" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        systemd systemd-sysv \
        iperf3 iproute2 iputils-ping ethtool tcpdump \
        pciutils usbutils kmod util-linux procps \
        wget curl bash-completion
    apt-get install -y -qq --no-install-recommends \
        rdma-core perftest || echo "RDMA not available"
    # 安装内核（含 virtio 驱动）
    apt-get install -y -qq linux-image-amd64
    rm -f /usr/sbin/policy-rc.d
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
        REPACK_DIR=$(mktemp -d "${BUILD_TMP}/debian-initramfs.XXXXXX")
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
        remove_repack_dir
        ok "Initramfs: ${OUTPUT_DIR}/initramfs.gz (cosim-init injected)"
    else
        cp "$INITRD" "${OUTPUT_DIR}/initramfs.gz"
        ok "Initramfs: ${OUTPUT_DIR}/initramfs.gz (original)"
    fi
else
    echo "[WARN] initrd not found in /boot"
fi

unmount_failed=false
unmount_if_mounted mounted_dev "$MOUNT_DIR/dev"
unmount_if_mounted mounted_sys "$MOUNT_DIR/sys"
unmount_if_mounted mounted_proc "$MOUNT_DIR/proc"
[ "$unmount_failed" = false ] || fail "Could not unmount Guest submounts safely"

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
    mkdir -p "$MOUNT_DIR/etc/profile.d"
    cp -v "$OVERLAY_DIR"/etc/motd "$MOUNT_DIR/etc/motd"
    # Debian 用 systemd，不拷贝 inittab 和 S99cosim
    cp -v "$OVERLAY_DIR"/etc/profile.d/cosim.sh "$MOUNT_DIR/etc/profile.d/cosim.sh"
    cp -v "$OVERLAY_DIR"/usr/local/bin/cosim-start "$MOUNT_DIR/usr/local/bin/cosim-start"
    cp -v "$OVERLAY_DIR"/usr/local/bin/cosim-stop "$MOUNT_DIR/usr/local/bin/cosim-stop"
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-start"
    chmod +x "$MOUNT_DIR/usr/local/bin/cosim-stop"
    ok "Overlay copied: cosim-start, cosim-stop, motd, profile"
else
    echo "[WARN] guest/overlay 目录不存在或内容不完整！"
    echo "  请确认: git checkout good -- guest/overlay/"
fi

# ---- Copy custom test tools (if built) ----
TOOLS_DIR="${PROJECT_DIR}/build/guest_tools"
if [ -d "$TOOLS_DIR" ]; then
    info "Copying custom test tools..."
    for tool in "$TOOLS_DIR"/*; do
        [ -e "$tool" ] || [ -L "$tool" ] || continue
        tool_name=${tool##*/}
        [ "$tool_name" = dpu-debugutils ] && continue
        cp -a -- "$tool" "$MOUNT_DIR/usr/local/bin/" 2>/dev/null || true
    done
fi

"${PROJECT_DIR}/scripts/stage_guest_debugutils.sh" \
    --root "$MOUNT_DIR" \
    --bin-dir "$DEBUG_BIN_DIR"

# ---- Done ----
unmount_failed=false
unmount_if_mounted mounted_root "$MOUNT_DIR"
[ "$unmount_failed" = false ] || fail "Could not unmount Guest root safely"
detach_loop_if_safe || fail "Could not detach Guest loop device safely"

# 修复权限（sudo 构建，产出文件归还给调用者）
if [ -n "${SUDO_USER:-}" ]; then
    chown "$SUDO_USER:$SUDO_USER" "${OUTPUT_DIR}/bzImage" "${OUTPUT_DIR}/initramfs.gz" "$ROOTFS_IMG" 2>/dev/null || true
fi

ok "Debian rootfs built: $ROOTFS_IMG"
ls -lh "${OUTPUT_DIR}/"
