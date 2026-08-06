#!/usr/bin/env bash
# Build the full Ubuntu Server guest profile.  The dry-run path is deliberately
# metadata-only; the real path requires root, network access, and debootstrap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

SUITE="noble"
KVER="6.8.0-107-generic"
ROOTFS_SIZE="8G"
ARCHIVE_MIRROR="http://archive.ubuntu.com/ubuntu"
SECURITY_MIRROR="http://security.ubuntu.com/ubuntu"
GUEST_USER="ryan"

PACKAGES=(
ubuntu-minimal
ubuntu-standard
systemd
systemd-sysv
openssh-server
sudo
build-essential
git
bc
flex
bison
pkg-config
libelf-dev
libreadline-dev
linux-headers-6.8.0-107-generic
pciutils
kmod
iproute2
iputils-ping
ethtool
tcpdump
curl
wget
vim-tiny
less
file
ca-certificates
)

DRY_RUN=false
OUTPUT_DIR="${PROJECT_DIR}/guest/images/ubuntu-server"
BUILD_DIR="${PROJECT_DIR}/build"
BUILD_TMP="${PROJECT_DIR}/build/tmp"
WORK_DIR=''
MOUNT_DIR=''
ROOTFS_IMAGE=''
PUBLISH_STAGE=''
OUTPUT_BACKUP=''
OUTPUT_PUBLISHED=false
mounted_root=false
mounted_sys=false
mounted_proc=false
mounted_dev=false
mounted_devpts=false
cleanup_unmount_failed=false
mount_transition=false
pending_signal=0

usage() {
    cat <<'USAGE'
Usage: scripts/build_rootfs_ubuntu_server.sh [--dry-run] [OUTPUT_DIR]

Build an 8G Ubuntu Server 24.04 Noble ext4 image using the fixed
6.8.0-107-generic kernel assets.  The real build requires root and network
access.  --dry-run prints the complete plan without writing, mounting, using
sudo, or accessing the network.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

unmount_if_mounted() {
    local flag_name="$1"
    local target="$2"

    if [[ "${!flag_name}" == true ]]; then
        if umount "${target}"; then
            printf -v "${flag_name}" '%s' false
        else
            echo "WARNING: could not unmount ${target}; leaving work directory intact" >&2
            cleanup_unmount_failed=true
        fi
    fi
}

tracked_mount() {
    local flag_name="$1"
    local target="$2"
    local mount_status
    local signal_status
    shift 2

    # Bash runs a trapped signal after the foreground mount command returns.
    # Keep the transition marked until its result and the kernel mount table
    # have both been reflected in our cleanup flag.
    pending_signal=0
    mount_transition=true
    if "$@"; then
        mount_status=0
    else
        mount_status=$?
    fi
    if [[ "${mount_status}" -eq 0 ]] || mountpoint -q "${target}"; then
        printf -v "${flag_name}" '%s' true
    fi
    mount_transition=false

    if [[ "${pending_signal}" -ne 0 ]]; then
        signal_status="${pending_signal}"
        pending_signal=0
        exit "${signal_status}"
    fi
    return "${mount_status}"
}

unmount_all() {
    # Keep this order aligned with the inverse of the mount sequence below.
    unmount_if_mounted mounted_devpts "${MOUNT_DIR}/dev/pts"
    unmount_if_mounted mounted_dev "${MOUNT_DIR}/dev"
    unmount_if_mounted mounted_proc "${MOUNT_DIR}/proc"
    unmount_if_mounted mounted_sys "${MOUNT_DIR}/sys"
    unmount_if_mounted mounted_root "${MOUNT_DIR}"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e

    if [[ "${mounted_root}" == true && -n "${MOUNT_DIR}" ]]; then
        rm -f -- "${MOUNT_DIR}/usr/sbin/policy-rc.d"
    fi
    cleanup_unmount_failed=false
    if [[ -n "${MOUNT_DIR}" ]]; then
        unmount_all
    fi

    if [[ -n "${OUTPUT_BACKUP}" && -d "${OUTPUT_BACKUP}" ]]; then
        if [[ "${OUTPUT_PUBLISHED}" == true ]]; then
            rm -rf -- "${OUTPUT_BACKUP}"
        elif [[ ! -e "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]]; then
            mv -- "${OUTPUT_BACKUP}" "${OUTPUT_DIR}"
        fi
    fi
    if [[ -n "${PUBLISH_STAGE}" && -d "${PUBLISH_STAGE}" ]]; then
        rm -rf -- "${PUBLISH_STAGE}"
    fi

    if [[ -n "${WORK_DIR}" ]]; then
        if [[ "${mounted_root}" == false && "${mounted_sys}" == false &&
              "${mounted_proc}" == false && "${mounted_dev}" == false &&
              "${mounted_devpts}" == false ]]; then
            case "${WORK_DIR}" in
                "${BUILD_TMP}"/ubuntu-server.*) rm -rf -- "${WORK_DIR}" ;;
                *) echo "WARNING: refusing to remove unexpected work path: ${WORK_DIR}" >&2 ;;
            esac
        else
            echo "WARNING: mounted paths remain under ${WORK_DIR}; not removing it" >&2
        fi
    fi

    if [[ "${cleanup_unmount_failed}" == true && "${status}" -eq 0 ]]; then
        status=1
    fi
    exit "${status}"
}

handle_signal() {
    local signal_status="$1"

    if [[ "${mount_transition}" == true ]]; then
        pending_signal="${signal_status}"
        return 0
    fi
    exit "${signal_status}"
}

handle_int() {
    handle_signal 130
}

handle_term() {
    handle_signal 143
}

# === builder main ===
trap cleanup EXIT
trap handle_int INT
trap handle_term TERM

if [[ "${1:-}" == --dry-run ]]; then
    DRY_RUN=true
    shift
elif [[ "${1:-}" == -* ]]; then
    usage >&2
    fail "unknown option: ${1}"
fi

[[ "$#" -le 1 ]] || {
    usage >&2
    fail 'too many arguments'
}
if [[ "${1:-}" == -* ]]; then
    usage >&2
    fail "unknown option: ${1}"
fi
if [[ "$#" -eq 1 ]]; then
    [[ -n "$1" ]] || fail 'output directory must not be empty'
    OUTPUT_DIR="$1"
fi
if [[ "${OUTPUT_DIR}" != /* ]]; then
    OUTPUT_DIR="$(pwd -P)/${OUTPUT_DIR#./}"
fi
while [[ "${OUTPUT_DIR}" != / && "${OUTPUT_DIR}" == */ ]]; do
    OUTPUT_DIR="${OUTPUT_DIR%/}"
done

print_plan() {
    cat <<EOF
Ubuntu Server rootfs build dry-run
Suite: ${SUITE}
Image size: ${ROOTFS_SIZE} (sparse; truncate, never dd)
Kernel: ${KVER}
Kernel assets: guest/images/ubuntu/{vmlinuz,modules.tar.gz}; run setup-ubuntu-kernel.sh ${KVER} if absent
Bootstrap: debootstrap --variant=minbase ${SUITE} ROOT ${ARCHIVE_MIRROR}
Apt sources:
  ${ARCHIVE_MIRROR} ${SUITE} main universe
  ${ARCHIVE_MIRROR} ${SUITE}-updates main universe
  ${SECURITY_MIRROR} ${SUITE}-security main universe
Packages: ${PACKAGES[*]}
Mounts: root loop nosuid,nodev (exec); sys/proc nosuid,nodev,noexec; dev/devpts nosuid
Cleanup order: /dev/pts -> /dev -> /proc -> /sys -> root
Modules: extract modules.tar.gz into ROOT; depmod -b ROOT ${KVER}
Headers: verify /lib/modules/${KVER}/build/Makefile and exact installed header package
Network: systemd-networkd.service; Driver=e1000e; DHCP=yes
SSH: ssh.service; PasswordAuthentication yes; PermitRootLogin no; user ${GUEST_USER}
Serial: serial-getty@ttyS0.service
Filesystem: /dev/vda mounted at /
Overlay: guest/overlay cosim-start, cosim-stop, motd, and profile
Debug staging: stage_guest_debugutils.sh --include-source
Debug outputs: /usr/local/bin/pci_debug /usr/local/bin/reg_display /opt/dpu-debugutils
Masked services: cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service
Masked apt services: apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
Final check: unmount, e2fsck -fy (accept status 0 or 1), then sparse safe publication
Output directory: ${OUTPUT_DIR}
Output rootfs: ${OUTPUT_DIR}/rootfs.ext4
Output kernel: ${OUTPUT_DIR}/vmlinuz
Output modules: ${OUTPUT_DIR}/modules.tar.gz
EOF
}

if [[ "${DRY_RUN}" == true ]]; then
    print_plan
    exit 0
fi

[[ "${EUID}" -eq 0 ]] || fail 'real Ubuntu Server image builds require root'
[[ "${OUTPUT_DIR}" != / ]] || fail 'refusing to replace the filesystem root'
output_leaf="${OUTPUT_DIR##*/}"
[[ -n "${output_leaf}" && "${output_leaf}" != . && "${output_leaf}" != .. ]] ||
    fail "unsafe output directory: ${OUTPUT_DIR}"
if [[ -e "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
    [[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] ||
        fail "output path is not a real directory: ${OUTPUT_DIR}"
fi

for required_command in \
    debootstrap truncate mkfs.ext4 mount umount chroot tar e2fsck depmod \
    install cp find mkdir mktemp chmod stat mv rm rmdir ln dirname id chown cat \
    mountpoint; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "missing required command: ${required_command}"
done

[[ ! -L "${BUILD_DIR}" ]] || fail "repository build path is a symlink: ${BUILD_DIR}"
if [[ -e "${BUILD_DIR}" && ! -d "${BUILD_DIR}" ]]; then
    fail "repository build path is not a directory: ${BUILD_DIR}"
fi
mkdir -p "${BUILD_DIR}"
[[ "$(cd "${BUILD_DIR}" && pwd -P)" == "${BUILD_DIR}" ]] ||
    fail "repository build path escapes the worktree: ${BUILD_DIR}"

[[ ! -L "${BUILD_TMP}" ]] || fail "repository build/tmp is a symlink: ${BUILD_TMP}"
if [[ -e "${BUILD_TMP}" && ! -d "${BUILD_TMP}" ]]; then
    fail "repository build/tmp is not a directory: ${BUILD_TMP}"
fi
mkdir -p "${BUILD_TMP}"
[[ "$(cd "${BUILD_TMP}" && pwd -P)" == "${BUILD_TMP}" ]] ||
    fail "repository build/tmp escapes the worktree: ${BUILD_TMP}"

KERNEL_DIR="${PROJECT_DIR}/guest/images/ubuntu"
KERNEL_IMAGE="${KERNEL_DIR}/vmlinuz"
KERNEL_MODULES="${KERNEL_DIR}/modules.tar.gz"
DEBUG_BIN_DIR="${PROJECT_DIR}/build/guest_tools/dpu-debugutils"
DEBUG_SOURCE_DIR="${PROJECT_DIR}/third_party/dpu-debugutils"
OVERLAY_DIR="${PROJECT_DIR}/guest/overlay"

for helper in \
    "${PROJECT_DIR}/scripts/setup-ubuntu-kernel.sh" \
    "${PROJECT_DIR}/scripts/build_dpu_debugutils.sh" \
    "${PROJECT_DIR}/scripts/stage_guest_debugutils.sh"; do
    [[ -x "${helper}" ]] || fail "required helper is missing or not executable: ${helper}"
done
for overlay_file in \
    etc/motd etc/profile.d/cosim.sh \
    usr/local/bin/cosim-start usr/local/bin/cosim-stop; do
    [[ -f "${OVERLAY_DIR}/${overlay_file}" ]] ||
        fail "required Guest overlay file is missing: ${overlay_file}"
done
[[ -d "${DEBUG_SOURCE_DIR}" ]] || fail "missing debug utility source: ${DEBUG_SOURCE_DIR}"

if [[ ! -f "${KERNEL_IMAGE}" || ! -f "${KERNEL_MODULES}" ]]; then
    "${PROJECT_DIR}/scripts/setup-ubuntu-kernel.sh" "${KVER}"
fi
[[ -f "${KERNEL_IMAGE}" ]] || fail "kernel setup did not produce ${KERNEL_IMAGE}"
[[ -f "${KERNEL_MODULES}" ]] || fail "kernel setup did not produce ${KERNEL_MODULES}"

if [[ ! -x "${DEBUG_BIN_DIR}/pci_debug" || ! -x "${DEBUG_BIN_DIR}/reg_display" ]]; then
    "${PROJECT_DIR}/scripts/build_dpu_debugutils.sh" "${DEBUG_BIN_DIR}"
fi
for utility in pci_debug reg_display; do
    [[ -x "${DEBUG_BIN_DIR}/${utility}" ]] ||
        fail "debug utility build did not produce ${DEBUG_BIN_DIR}/${utility}"
done

WORK_DIR="$(mktemp -d "${BUILD_TMP}/ubuntu-server.XXXXXX")"
chmod 0700 "${WORK_DIR}"
[[ ! -L "${WORK_DIR}" && -d "${WORK_DIR}" ]] || fail 'invalid build work directory'
[[ "$(cd "${WORK_DIR}" && pwd -P)" == "${WORK_DIR}" ]] ||
    fail "build work directory escaped build/tmp: ${WORK_DIR}"
[[ "$(stat -c '%a' "${WORK_DIR}")" == 700 ]] ||
    fail "build work directory is not mode 0700: ${WORK_DIR}"

MOUNT_DIR="${WORK_DIR}/root"
ROOTFS_IMAGE="${WORK_DIR}/rootfs.ext4"
install -d -m 0700 "${MOUNT_DIR}"
[[ "$(cd "${MOUNT_DIR}" && pwd -P)" == "${MOUNT_DIR}" ]] ||
    fail "mount directory escaped build/tmp: ${MOUNT_DIR}"

echo "Creating sparse ${ROOTFS_SIZE} ext4 image"
truncate -s "${ROOTFS_SIZE}" "${ROOTFS_IMAGE}"
mkfs.ext4 -F "${ROOTFS_IMAGE}"
tracked_mount mounted_root "${MOUNT_DIR}" mount -o loop,nosuid,nodev \
    "${ROOTFS_IMAGE}" "${MOUNT_DIR}"

echo "Bootstrapping Ubuntu ${SUITE}"
debootstrap --variant=minbase "${SUITE}" "${MOUNT_DIR}" "${ARCHIVE_MIRROR}"

tar -xzf "${KERNEL_MODULES}" -C "${MOUNT_DIR}"
MODULE_DIR="${MOUNT_DIR}/lib/modules/${KVER}"
[[ -d "${MODULE_DIR}" ]] || fail "modules archive does not contain ${KVER}"
mismatched_module_dir="$(find "${MOUNT_DIR}/lib/modules" -mindepth 1 -maxdepth 1 \
    -type d ! -name "${KVER}" -print -quit)"
[[ -z "${mismatched_module_dir}" ]] ||
    fail "modules archive contains the wrong kernel version: ${mismatched_module_dir}"

for mount_subdir in sys proc dev dev/pts; do
    mount_target="${MOUNT_DIR}/${mount_subdir}"
    [[ ! -L "${mount_target}" ]] ||
        fail "mount target is a symlink: ${mount_target}"
    if [[ -e "${mount_target}" && ! -d "${mount_target}" ]]; then
        fail "mount target is not a directory: ${mount_target}"
    fi
    install -d -m 0755 "${mount_target}"
    [[ "$(cd "${mount_target}" && pwd -P)" == "${mount_target}" ]] ||
        fail "mount target escaped the work directory: ${mount_target}"
done
tracked_mount mounted_sys "${MOUNT_DIR}/sys" mount -t sysfs \
    -o nosuid,nodev,noexec sysfs "${MOUNT_DIR}/sys"
tracked_mount mounted_proc "${MOUNT_DIR}/proc" mount -t proc \
    -o nosuid,nodev,noexec proc "${MOUNT_DIR}/proc"
tracked_mount mounted_dev "${MOUNT_DIR}/dev" mount --bind /dev "${MOUNT_DIR}/dev"
mount -o remount,bind,nosuid /dev "${MOUNT_DIR}/dev"
tracked_mount mounted_devpts "${MOUNT_DIR}/dev/pts" mount -t devpts \
    -o nosuid,noexec,mode=0620,ptmxmode=0666 devpts "${MOUNT_DIR}/dev/pts"

cp --remove-destination /etc/resolv.conf "${MOUNT_DIR}/etc/resolv.conf"
cat > "${MOUNT_DIR}/etc/apt/sources.list" <<EOF
deb ${ARCHIVE_MIRROR} ${SUITE} main universe
deb ${ARCHIVE_MIRROR} ${SUITE}-updates main universe
deb ${SECURITY_MIRROR} ${SUITE}-security main universe
EOF
cat > "${MOUNT_DIR}/usr/sbin/policy-rc.d" <<'POLICY'
#!/bin/sh
exit 101
POLICY
chmod 0755 "${MOUNT_DIR}/usr/sbin/policy-rc.d"

chroot "${MOUNT_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get update
chroot "${MOUNT_DIR}" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends "${PACKAGES[@]}"

printf '%s\n' 'cosim-guest' > "${MOUNT_DIR}/etc/hostname"
cat > "${MOUNT_DIR}/etc/hosts" <<'HOSTS'
127.0.0.1 localhost
127.0.1.1 cosim-guest
::1 localhost ip6-localhost ip6-loopback
HOSTS
cat > "${MOUNT_DIR}/etc/fstab" <<'FSTAB'
/dev/vda / ext4 rw,relatime 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
FSTAB

install -d -m 0755 \
    "${MOUNT_DIR}/etc/systemd/network" \
    "${MOUNT_DIR}/etc/ssh/sshd_config.d" \
    "${MOUNT_DIR}/etc/apt/apt.conf.d"
cat > "${MOUNT_DIR}/etc/systemd/network/10-cosim-management.network" <<'NETWORK'
[Match]
Driver=e1000e

[Network]
DHCP=yes
LinkLocalAddressing=no
NETWORK
cat > "${MOUNT_DIR}/etc/ssh/sshd_config.d/99-cosim-management.conf" <<EOF
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
UseDNS no
AllowUsers ${GUEST_USER}
EOF
cat > "${MOUNT_DIR}/etc/apt/apt.conf.d/99cosim-no-periodic" <<'APTCONF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APTCONF

if ! chroot "${MOUNT_DIR}" id -u "${GUEST_USER}" >/dev/null 2>&1; then
    chroot "${MOUNT_DIR}" useradd --create-home --shell /bin/bash "${GUEST_USER}"
fi
GUEST_PASSWORD="${COSIM_GUEST_SSH_PASSWORD:-123}"
printf '%s:%s\n' "${GUEST_USER}" "${GUEST_PASSWORD}" |
    chroot "${MOUNT_DIR}" chpasswd
unset GUEST_PASSWORD
chroot "${MOUNT_DIR}" usermod --append --groups sudo "${GUEST_USER}"
chroot "${MOUNT_DIR}" ssh-keygen -A
install -d -m 0755 "${MOUNT_DIR}/run/sshd"
chroot "${MOUNT_DIR}" /usr/sbin/sshd -t

chroot "${MOUNT_DIR}" systemctl enable \
    systemd-networkd.service systemd-resolved.service ssh.service \
    serial-getty@ttyS0.service
chroot "${MOUNT_DIR}" systemctl mask cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service
chroot "${MOUNT_DIR}" systemctl mask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service
ln -sf /run/systemd/resolve/stub-resolv.conf "${MOUNT_DIR}/etc/resolv.conf"

install -d -m 0755 \
    "${MOUNT_DIR}/usr/local/bin" "${MOUNT_DIR}/etc/profile.d"
cp -- "${OVERLAY_DIR}/etc/motd" "${MOUNT_DIR}/etc/motd"
cp -- "${OVERLAY_DIR}/etc/profile.d/cosim.sh" "${MOUNT_DIR}/etc/profile.d/cosim.sh"
install -m 0755 \
    "${OVERLAY_DIR}/usr/local/bin/cosim-start" \
    "${MOUNT_DIR}/usr/local/bin/cosim-start"
install -m 0755 \
    "${OVERLAY_DIR}/usr/local/bin/cosim-stop" \
    "${MOUNT_DIR}/usr/local/bin/cosim-stop"

"${PROJECT_DIR}/scripts/stage_guest_debugutils.sh" \
    --root "${MOUNT_DIR}" \
    --bin-dir "${DEBUG_BIN_DIR}" \
    --source-dir "${DEBUG_SOURCE_DIR}" \
    --include-source
[[ -x "${MOUNT_DIR}/usr/local/bin/pci_debug" ]] || fail 'pci_debug was not staged'
[[ -x "${MOUNT_DIR}/usr/local/bin/reg_display" ]] || fail 'reg_display was not staged'
[[ -d "${MOUNT_DIR}/opt/dpu-debugutils" ]] || fail 'debug utility source was not staged'

depmod -b "${MOUNT_DIR}" "${KVER}"
[[ -f "${MODULE_DIR}/build/Makefile" ]] ||
    fail "missing exact kernel headers: /lib/modules/${KVER}/build/Makefile"
if [[ -e "${MODULE_DIR}/source" || -L "${MODULE_DIR}/source" ]]; then
    [[ -f "${MODULE_DIR}/source/Makefile" ]] ||
        fail "invalid kernel source link for ${KVER}"
fi
if [[ -e "${MODULE_DIR}/build/Module.symvers" ]]; then
    [[ -f "${MODULE_DIR}/build/Module.symvers" ]] ||
        fail "invalid Module.symvers for ${KVER}"
fi
header_status="$(chroot "${MOUNT_DIR}" dpkg-query -W '-f=${Status}' \
    "linux-headers-${KVER}")"
[[ "${header_status}" == 'install ok installed' ]] ||
    fail "linux-headers-${KVER} is not installed"

chroot "${MOUNT_DIR}" apt-get clean
find "${MOUNT_DIR}/var/lib/apt/lists" -mindepth 1 -delete
find "${MOUNT_DIR}/var/cache/apt/archives" -mindepth 1 -type f -delete
rm -f -- "${MOUNT_DIR}/usr/sbin/policy-rc.d"

cleanup_unmount_failed=false
unmount_all
[[ "${cleanup_unmount_failed}" == false ]] || fail 'could not unmount rootfs safely'

set +e
e2fsck -fy "${ROOTFS_IMAGE}"
fsck_status=$?
set -e
case "${fsck_status}" in
    0|1) ;;
    *) fail "e2fsck failed with status ${fsck_status}" ;;
esac

publish_parent="${OUTPUT_DIR%/*}"
publish_name="${OUTPUT_DIR##*/}"
[[ -n "${publish_parent}" && -n "${publish_name}" &&
   "${publish_name}" != . && "${publish_name}" != .. ]] ||
    fail "unsafe output directory: ${OUTPUT_DIR}"
mkdir -p "${publish_parent}"
publish_parent="$(cd "${publish_parent}" && pwd -P)"
OUTPUT_DIR="${publish_parent}/${publish_name}"
if [[ -e "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
    [[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] ||
        fail "output path is not a real directory: ${OUTPUT_DIR}"
fi

PUBLISH_STAGE="$(mktemp -d "${publish_parent}/.${publish_name}.new.XXXXXX")"
chmod 0700 "${PUBLISH_STAGE}"
cp --sparse=always -- "${ROOTFS_IMAGE}" "${PUBLISH_STAGE}/rootfs.ext4"
cp -- "${KERNEL_IMAGE}" "${PUBLISH_STAGE}/vmlinuz"
cp -- "${KERNEL_MODULES}" "${PUBLISH_STAGE}/modules.tar.gz"

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] &&
        id -u "${SUDO_USER}" >/dev/null 2>&1; then
    output_uid="$(id -u "${SUDO_USER}")"
    output_gid="$(id -g "${SUDO_USER}")"
    chown "${output_uid}:${output_gid}" \
        "${PUBLISH_STAGE}" \
        "${PUBLISH_STAGE}/rootfs.ext4" \
        "${PUBLISH_STAGE}/vmlinuz" \
        "${PUBLISH_STAGE}/modules.tar.gz"
fi

if [[ -d "${OUTPUT_DIR}" ]]; then
    OUTPUT_BACKUP="$(mktemp -d "${publish_parent}/.${publish_name}.old.XXXXXX")"
    rmdir -- "${OUTPUT_BACKUP}"
    mv -- "${OUTPUT_DIR}" "${OUTPUT_BACKUP}"
fi
mv -- "${PUBLISH_STAGE}" "${OUTPUT_DIR}"
PUBLISH_STAGE=''
OUTPUT_PUBLISHED=true
if [[ -n "${OUTPUT_BACKUP}" ]]; then
    rm -rf -- "${OUTPUT_BACKUP}"
    OUTPUT_BACKUP=''
fi

echo "Ubuntu Server rootfs built at ${OUTPUT_DIR}/rootfs.ext4"
