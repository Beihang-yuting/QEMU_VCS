#!/usr/bin/env bash
# Build the full Ubuntu Server guest profile.  The dry-run path is deliberately
# metadata-only; the real path requires root, network access, and debootstrap.
set -euo pipefail

capture_guest_password() {
    unset GUEST_PASSWORD GUEST_PASSWORD_WAS_SET
    GUEST_PASSWORD=''
    GUEST_PASSWORD_WAS_SET=false
    if [[ -v COSIM_GUEST_SSH_PASSWORD ]]; then
        GUEST_PASSWORD="${COSIM_GUEST_SSH_PASSWORD}"
        GUEST_PASSWORD_WAS_SET=true
    fi
    unset COSIM_GUEST_SSH_PASSWORD
}

capture_guest_password

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
PUBLISH_STAGE_ID=''
NEW_OUTPUT_ID=''
OUTPUT_BACKUP=''
PUBLISH_PARENT=''
PUBLISH_NAME=''
publish_boundary_ready=false
old_output_moved=false
new_output_installed=false
publish_committed=false
publish_transition=false
OUTPUT_LOCK_DIR=''
OUTPUT_LOCK_CANDIDATE=''
OUTPUT_LOCK_OWNER=''
output_lock_held=false
mounted_root=false
mounted_sys=false
mounted_proc=false
mounted_dev=false
mounted_devpts=false
cleanup_unmount_failed=false
mount_transition=false
pending_signal=0
cleanup_publish_failed=false

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

publish_temp_path_is_safe() {
    local path="$1"
    local kind="$2"
    local prefix
    local suffix

    [[ "${publish_boundary_ready}" == true ]] || return 1
    [[ -n "${PUBLISH_PARENT}" && -n "${PUBLISH_NAME}" ]] || return 1
    prefix="${PUBLISH_PARENT}/.${PUBLISH_NAME}.${kind}."
    [[ "${path}" == "${prefix}"* ]] || return 1
    suffix="${path#"${prefix}"}"
    [[ -n "${suffix}" && "${suffix}" != */* ]]
}

remove_publish_temp() {
    local path="$1"
    local kind="$2"

    [[ -n "${path}" ]] || return 0
    if ! publish_temp_path_is_safe "${path}" "${kind}"; then
        echo "WARNING: refusing to remove unexpected publish path: ${path}" >&2
        cleanup_publish_failed=true
        return 1
    fi
    if ! rm -rf -- "${path}"; then
        echo "WARNING: could not remove publish path: ${path}" >&2
        cleanup_publish_failed=true
        return 1
    fi
}

cleanup_publication() {
    local current_output_id=''

    [[ "${publish_boundary_ready}" == true ]] || return 0
    if [[ "${OUTPUT_DIR}" != "${PUBLISH_PARENT}/${PUBLISH_NAME}" ]]; then
        echo "WARNING: refusing publication cleanup outside its boundary: ${OUTPUT_DIR}" >&2
        cleanup_publish_failed=true
        return 1
    fi

    if [[ "${publish_committed}" == true ]]; then
        if [[ -n "${OUTPUT_BACKUP}" ]]; then
            remove_publish_temp "${OUTPUT_BACKUP}" old || true
        fi
        if [[ -n "${PUBLISH_STAGE}" ]]; then
            remove_publish_temp "${PUBLISH_STAGE}" new || true
        fi
        return 0
    fi

    if [[ "${new_output_installed}" == true ]]; then
        if [[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]]; then
            current_output_id="$(stat -c '%d:%i' "${OUTPUT_DIR}" 2>/dev/null || true)"
        fi
        if [[ -n "${NEW_OUTPUT_ID}" && "${current_output_id}" == "${NEW_OUTPUT_ID}" ]]; then
            rm -rf -- "${OUTPUT_DIR}"
        else
            echo "WARNING: refusing to remove a replaced uncommitted output: ${OUTPUT_DIR}" >&2
            cleanup_publish_failed=true
        fi
        if [[ -e "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
            echo "WARNING: could not remove uncommitted output: ${OUTPUT_DIR}" >&2
            cleanup_publish_failed=true
        fi
    fi

    if [[ "${old_output_moved}" == true ]]; then
        if ! publish_temp_path_is_safe "${OUTPUT_BACKUP}" old ||
                [[ ! -d "${OUTPUT_BACKUP}" || -L "${OUTPUT_BACKUP}" ]]; then
            echo "WARNING: previous output backup is missing or unsafe: ${OUTPUT_BACKUP}" >&2
            cleanup_publish_failed=true
        elif [[ -e "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
            echo "WARNING: refusing to overwrite output while restoring backup: ${OUTPUT_DIR}" >&2
            cleanup_publish_failed=true
        elif ! mv -T -- "${OUTPUT_BACKUP}" "${OUTPUT_DIR}"; then
            echo "WARNING: could not restore previous output: ${OUTPUT_BACKUP}" >&2
            cleanup_publish_failed=true
        else
            OUTPUT_BACKUP=''
            old_output_moved=false
        fi
    elif [[ -n "${OUTPUT_BACKUP}" ]]; then
        remove_publish_temp "${OUTPUT_BACKUP}" old || true
        OUTPUT_BACKUP=''
    fi

    if [[ -n "${PUBLISH_STAGE}" ]]; then
        remove_publish_temp "${PUBLISH_STAGE}" new || true
        PUBLISH_STAGE=''
    fi
}

begin_publish_transition() {
    pending_signal=0
    publish_transition=true
}

finish_publish_transition() {
    local command_status="$1"
    local signal_status

    publish_transition=false
    if [[ "${pending_signal}" -ne 0 ]]; then
        signal_status="${pending_signal}"
        pending_signal=0
        exit "${signal_status}"
    fi
    return "${command_status}"
}

output_lock_path_is_safe() {
    local prefix="${BUILD_TMP}/ubuntu-server-output."
    local suffix

    [[ -n "${OUTPUT_LOCK_DIR}" && "${OUTPUT_LOCK_DIR}" == "${prefix}"*.lock ]] ||
        return 1
    suffix="${OUTPUT_LOCK_DIR#"${prefix}"}"
    suffix="${suffix%.lock}"
    [[ "${suffix}" =~ ^[[:xdigit:]]{64}$ ]]
}

output_lock_candidate_is_safe() {
    local prefix="${BUILD_TMP}/.ubuntu-server-lock-candidate."
    local suffix

    [[ -n "${OUTPUT_LOCK_CANDIDATE}" &&
       "${OUTPUT_LOCK_CANDIDATE}" == "${prefix}"* ]] || return 1
    suffix="${OUTPUT_LOCK_CANDIDATE#"${prefix}"}"
    [[ -n "${suffix}" && "${suffix}" != */* ]]
}

prepare_output_lock_candidate() {
    local candidate_suffix
    local prepare_status=0

    begin_publish_transition
    if OUTPUT_LOCK_CANDIDATE="$(mktemp -d \
            "${BUILD_TMP}/.ubuntu-server-lock-candidate.XXXXXX")"; then
        :
    else
        prepare_status=$?
    fi
    if [[ "${prepare_status}" -eq 0 ]]; then
        if chmod 0700 "${OUTPUT_LOCK_CANDIDATE}"; then
            :
        else
            prepare_status=$?
        fi
    fi
    if [[ "${prepare_status}" -eq 0 ]] &&
            ! output_lock_candidate_is_safe; then
        prepare_status=1
    fi
    if [[ "${prepare_status}" -eq 0 ]]; then
        candidate_suffix="${OUTPUT_LOCK_CANDIDATE##*.}"
        OUTPUT_LOCK_OWNER="${BASHPID}:${candidate_suffix}"
        if printf '%s\n' "${OUTPUT_LOCK_OWNER}" \
                > "${OUTPUT_LOCK_CANDIDATE}/owner"; then
            :
        else
            prepare_status=$?
        fi
        if [[ "${prepare_status}" -eq 0 ]]; then
            if chmod 0600 "${OUTPUT_LOCK_CANDIDATE}/owner"; then
                :
            else
                prepare_status=$?
            fi
        fi
    fi
    finish_publish_transition "${prepare_status}" || return $?
}

claim_output_lock_once() {
    local move_status=1
    local claim_status=1
    local candidate_id=''
    local current_lock_id=''
    local current_owner=''

    if [[ -d "${OUTPUT_LOCK_CANDIDATE}" && ! -L "${OUTPUT_LOCK_CANDIDATE}" ]]; then
        candidate_id="$(stat -c '%d:%i' "${OUTPUT_LOCK_CANDIDATE}" 2>/dev/null || true)"
    fi
    begin_publish_transition
    if mv -T -- "${OUTPUT_LOCK_CANDIDATE}" "${OUTPUT_LOCK_DIR}" 2>/dev/null; then
        move_status=0
    else
        move_status=$?
    fi
    if [[ -d "${OUTPUT_LOCK_DIR}" && ! -L "${OUTPUT_LOCK_DIR}" ]]; then
        current_lock_id="$(stat -c '%d:%i' "${OUTPUT_LOCK_DIR}" 2>/dev/null || true)"
    fi
    if [[ -n "${candidate_id}" && "${current_lock_id}" == "${candidate_id}" ]]; then
        OUTPUT_LOCK_CANDIDATE=''
        if [[ -f "${OUTPUT_LOCK_DIR}/owner" && ! -L "${OUTPUT_LOCK_DIR}/owner" ]] &&
                current_owner="$(<"${OUTPUT_LOCK_DIR}/owner")" &&
                [[ -n "${OUTPUT_LOCK_OWNER}" &&
                   "${current_owner}" == "${OUTPUT_LOCK_OWNER}" ]]; then
            output_lock_held=true
            claim_status=0
        elif [[ ! -e "${OUTPUT_LOCK_DIR}/owner" &&
                ! -L "${OUTPUT_LOCK_DIR}/owner" ]]; then
            current_lock_id="$(stat -c '%d:%i' "${OUTPUT_LOCK_DIR}" 2>/dev/null || true)"
            if [[ "${current_lock_id}" == "${candidate_id}" ]]; then
                rmdir -- "${OUTPUT_LOCK_DIR}" 2>/dev/null || true
            fi
        fi
    else
        claim_status="${move_status}"
        [[ "${claim_status}" -ne 0 ]] || claim_status=1
    fi
    finish_publish_transition "${claim_status}" || return $?

    [[ "${output_lock_held}" == true ]]
}

acquire_output_lock() {
    local lock_key
    local owner_pid=''
    local owner_record=''

    [[ -d "${BUILD_TMP}" && ! -L "${BUILD_TMP}" ]] ||
        fail "invalid output lock parent: ${BUILD_TMP}"
    [[ "$(cd "${BUILD_TMP}" && pwd -P)" == "${BUILD_TMP}" ]] ||
        fail "output lock parent escaped build/tmp: ${BUILD_TMP}"

    lock_key="$(printf '%s' "${OUTPUT_DIR}" | sha256sum)"
    lock_key="${lock_key%% *}"
    OUTPUT_LOCK_DIR="${BUILD_TMP}/ubuntu-server-output.${lock_key}.lock"
    output_lock_path_is_safe || fail "unsafe output lock path: ${OUTPUT_LOCK_DIR}"
    prepare_output_lock_candidate

    if ! claim_output_lock_once; then
        [[ -n "${OUTPUT_LOCK_CANDIDATE}" ]] ||
            fail "could not verify newly claimed output lock: ${OUTPUT_DIR}"
        [[ -d "${OUTPUT_LOCK_DIR}" && ! -L "${OUTPUT_LOCK_DIR}" ]] ||
            fail "output lock is not a real directory: ${OUTPUT_LOCK_DIR}"
        [[ "$(cd "${OUTPUT_LOCK_DIR}" && pwd -P)" == "${OUTPUT_LOCK_DIR}" ]] ||
            fail "output lock escaped build/tmp: ${OUTPUT_LOCK_DIR}"
        if [[ -e "${OUTPUT_LOCK_DIR}/owner" || -L "${OUTPUT_LOCK_DIR}/owner" ]]; then
            [[ -f "${OUTPUT_LOCK_DIR}/owner" && ! -L "${OUTPUT_LOCK_DIR}/owner" ]] ||
                fail "unsafe output lock owner file: ${OUTPUT_LOCK_DIR}/owner"
            owner_record="$(<"${OUTPUT_LOCK_DIR}/owner")"
            [[ "${owner_record}" =~ ^[1-9][0-9]*:[[:alnum:]]+$ ]] ||
                fail "invalid output lock owner: ${OUTPUT_LOCK_DIR}/owner"
            owner_pid="${owner_record%%:*}"
            if kill -0 "${owner_pid}" 2>/dev/null; then
                fail "output is locked by active process ${owner_pid}: ${OUTPUT_DIR}"
            fi
            rm -f -- "${OUTPUT_LOCK_DIR}/owner"
        fi
        rmdir -- "${OUTPUT_LOCK_DIR}" ||
            fail "stale output lock contains unexpected state: ${OUTPUT_LOCK_DIR}"
        claim_output_lock_once ||
            fail "could not acquire output lock after stale-lock cleanup: ${OUTPUT_DIR}"
    fi
}

release_output_lock() {
    if [[ -n "${OUTPUT_LOCK_CANDIDATE}" ]]; then
        if ! output_lock_candidate_is_safe; then
            echo "WARNING: refusing unexpected output lock candidate: ${OUTPUT_LOCK_CANDIDATE}" >&2
            cleanup_publish_failed=true
        elif [[ -d "${OUTPUT_LOCK_CANDIDATE}" && ! -L "${OUTPUT_LOCK_CANDIDATE}" ]]; then
            rm -f -- "${OUTPUT_LOCK_CANDIDATE}/owner"
            if ! rmdir -- "${OUTPUT_LOCK_CANDIDATE}"; then
                echo "WARNING: could not remove output lock candidate: ${OUTPUT_LOCK_CANDIDATE}" >&2
                cleanup_publish_failed=true
            fi
        fi
        OUTPUT_LOCK_CANDIDATE=''
    fi

    [[ "${output_lock_held}" == true ]] || return 0
    if ! output_lock_path_is_safe; then
        echo "WARNING: refusing to release unexpected output lock: ${OUTPUT_LOCK_DIR}" >&2
        cleanup_publish_failed=true
        return 1
    fi
    if [[ -e "${OUTPUT_LOCK_DIR}/owner" || -L "${OUTPUT_LOCK_DIR}/owner" ]]; then
        if [[ ! -f "${OUTPUT_LOCK_DIR}/owner" || -L "${OUTPUT_LOCK_DIR}/owner" ]]; then
            echo "WARNING: refusing unsafe output lock owner file: ${OUTPUT_LOCK_DIR}/owner" >&2
            cleanup_publish_failed=true
            return 1
        fi
        if [[ "$(<"${OUTPUT_LOCK_DIR}/owner")" != "${OUTPUT_LOCK_OWNER}" ]]; then
            echo "WARNING: refusing to release an output lock owned by another process" >&2
            cleanup_publish_failed=true
            return 1
        fi
        rm -f -- "${OUTPUT_LOCK_DIR}/owner"
    fi
    if ! rmdir -- "${OUTPUT_LOCK_DIR}"; then
        echo "WARNING: could not release output lock: ${OUTPUT_LOCK_DIR}" >&2
        cleanup_publish_failed=true
        return 1
    fi
    output_lock_held=false
    OUTPUT_LOCK_DIR=''
}

cleanup() {
    local status=$?
    trap - EXIT
    trap '' INT TERM
    set +e

    if [[ "${mounted_root}" == true && -n "${MOUNT_DIR}" ]]; then
        rm -f -- "${MOUNT_DIR}/usr/sbin/policy-rc.d"
    fi
    cleanup_unmount_failed=false
    if [[ -n "${MOUNT_DIR}" ]]; then
        unmount_all
    fi

    cleanup_publish_failed=false
    cleanup_publication || true
    release_output_lock || true

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
    if [[ "${cleanup_publish_failed}" == true && "${status}" -eq 0 ]]; then
        status=1
    fi
    exit "${status}"
}

handle_signal() {
    local signal_status="$1"

    if [[ "${mount_transition}" == true || "${publish_transition}" == true ]]; then
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

validate_guest_password() {
    [[ "${GUEST_PASSWORD_WAS_SET}" == true && -n "${GUEST_PASSWORD}" ]] ||
        fail 'COSIM_GUEST_SSH_PASSWORD must be set to a non-empty value'
    if [[ "${GUEST_PASSWORD}" == *$'\r'* || "${GUEST_PASSWORD}" == *$'\n'* ]]; then
        fail 'COSIM_GUEST_SSH_PASSWORD must not contain CR or LF'
    fi
}

install_guest_password() {
    local guest_root="$1"
    local password_status

    if printf '%s:%s\n' "${GUEST_USER}" "${GUEST_PASSWORD}" |
            chroot "${guest_root}" chpasswd; then
        password_status=0
    else
        password_status=$?
    fi
    GUEST_PASSWORD=''
    return "${password_status}"
}

publish_results() {
    local publish_parent
    local publish_name
    local move_status
    local output_uid
    local output_gid
    local published_artifact
    local current_output_id=''

    publish_parent="${OUTPUT_DIR%/*}"
    publish_name="${OUTPUT_DIR##*/}"
    [[ -n "${publish_parent}" && -n "${publish_name}" &&
       "${publish_name}" != . && "${publish_name}" != .. ]] ||
        fail "unsafe output directory: ${OUTPUT_DIR}"
    mkdir -p "${publish_parent}"
    publish_parent="$(cd "${publish_parent}" && pwd -P)"

    PUBLISH_PARENT="${publish_parent}"
    PUBLISH_NAME="${publish_name}"
    OUTPUT_DIR="${PUBLISH_PARENT}/${PUBLISH_NAME}"
    publish_boundary_ready=true
    acquire_output_lock
    if [[ -e "${OUTPUT_DIR}" || -L "${OUTPUT_DIR}" ]]; then
        [[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] ||
            fail "output path is not a real directory: ${OUTPUT_DIR}"
    fi

    PUBLISH_STAGE="$(mktemp -d "${PUBLISH_PARENT}/.${PUBLISH_NAME}.new.XXXXXX")"
    chmod 0700 "${PUBLISH_STAGE}"
    cp --sparse=always -- "${ROOTFS_IMAGE}" "${PUBLISH_STAGE}/rootfs.ext4"
    cp -- "${KERNEL_IMAGE}" "${PUBLISH_STAGE}/vmlinuz"
    cp -- "${KERNEL_MODULES}" "${PUBLISH_STAGE}/modules.tar.gz"
    PUBLISH_STAGE_ID="$(stat -c '%d:%i' "${PUBLISH_STAGE}")"

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
        OUTPUT_BACKUP="$(mktemp -d \
            "${PUBLISH_PARENT}/.${PUBLISH_NAME}.old.XXXXXX")"
        rmdir -- "${OUTPUT_BACKUP}"

        begin_publish_transition
        if mv -T -- "${OUTPUT_DIR}" "${OUTPUT_BACKUP}"; then
            move_status=0
        else
            move_status=$?
        fi
        if [[ "${move_status}" -eq 0 ]] ||
                { [[ -d "${OUTPUT_BACKUP}" && ! -L "${OUTPUT_BACKUP}" ]] &&
                  [[ ! -e "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]]; }; then
            old_output_moved=true
        fi
        finish_publish_transition "${move_status}" || return $?
    fi

    begin_publish_transition
    if mv -nT -- "${PUBLISH_STAGE}" "${OUTPUT_DIR}"; then
        move_status=0
    else
        move_status=$?
    fi
    if [[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]]; then
        current_output_id="$(stat -c '%d:%i' "${OUTPUT_DIR}" 2>/dev/null || true)"
    fi
    if { [[ "${move_status}" -eq 0 ]] ||
            { [[ -d "${OUTPUT_DIR}" && ! -L "${OUTPUT_DIR}" ]] &&
              [[ ! -e "${PUBLISH_STAGE}" && ! -L "${PUBLISH_STAGE}" ]]; }; } &&
            [[ -n "${PUBLISH_STAGE_ID}" &&
               "${current_output_id}" == "${PUBLISH_STAGE_ID}" ]]; then
        new_output_installed=true
        NEW_OUTPUT_ID="${current_output_id}"
        PUBLISH_STAGE=''
    elif [[ "${move_status}" -eq 0 ]]; then
        echo "WARNING: published output identity changed during rename" >&2
        move_status=1
    fi
    finish_publish_transition "${move_status}" || return $?

    for published_artifact in rootfs.ext4 vmlinuz modules.tar.gz; do
        [[ -f "${OUTPUT_DIR}/${published_artifact}" &&
           ! -L "${OUTPUT_DIR}/${published_artifact}" ]] ||
            fail "published output is missing a top-level artifact: ${published_artifact}"
    done
    current_output_id="$(stat -c '%d:%i' "${OUTPUT_DIR}")"
    [[ -n "${NEW_OUTPUT_ID}" && "${current_output_id}" == "${NEW_OUTPUT_ID}" ]] ||
        fail 'published output identity changed before commit'

    # This assignment is the commit point.  Signals after it retain the new
    # complete output; all earlier exits are rolled back by cleanup.
    publish_committed=true
    if [[ -n "${OUTPUT_BACKUP}" ]]; then
        remove_publish_temp "${OUTPUT_BACKUP}" old
        OUTPUT_BACKUP=''
    fi
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
    GUEST_PASSWORD=''
    print_plan
    exit 0
fi

validate_guest_password
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
    mountpoint sha256sum; do
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
install_guest_password "${MOUNT_DIR}"
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

publish_results
echo "Ubuntu Server rootfs built at ${OUTPUT_DIR}/rootfs.ext4"
