#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
STAGE_SCRIPT="${SCRIPT_DIR}/stage_guest_debugutils.sh"

rootfs=''
bin_dir=''
source_dir=''
include_source=false
build_tmp=''
mount_dir=''
mounted=false
mount_attempted=false
mount_state_checked=false
fsck_needed=false
pending_exit=0

usage() {
    cat <<'USAGE'
Usage:
  scripts/install_guest_debugutils.sh --rootfs IMAGE --bin-dir DIR \
    [--source-dir DIR] [--include-source]

Mount an ext4 Guest image, stage the DPU debug utilities, unmount it, and run
e2fsck.  Privileged operations are performed with non-interactive sudo.

Security boundary: IMAGE, the repository/worktree, and the invoking user are
trusted.  The mount directory is mode 0700 below repository build/tmp, whose
path must not contain a symlink.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

handle_int() {
    pending_exit=130
}

handle_term() {
    pending_exit=143
}

mount_is_active() {
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q -- "${mount_dir}"
        return
    fi
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -rn -M "${mount_dir}" >/dev/null
        return
    fi
    return 1
}

cleanup() {
    local status=$?
    local cleanup_status=0
    local fsck_status=0

    trap - EXIT INT TERM
    set +e
    if (( pending_exit != 0 )); then
        status=${pending_exit}
    fi

    # If a signal arrived at mount's return boundary, recover the state before
    # deciding whether this script owns a mount that must be unwound.
    if "${mount_attempted}" && ! "${mount_state_checked}" && ! "${mounted}"; then
        if mount_is_active; then
            mounted=true
            fsck_needed=true
        fi
        mount_state_checked=true
    fi

    if "${mounted}"; then
        if sudo -n umount "${mount_dir}"; then
            mounted=false
        else
            echo "ERROR: failed to unmount ${mount_dir}" >&2
            cleanup_status=1
        fi
    fi

    if [[ -n "${mount_dir}" ]] && ! "${mounted}"; then
        if ! rmdir -- "${mount_dir}"; then
            echo "ERROR: failed to remove mount directory ${mount_dir}" >&2
            cleanup_status=1
        fi
    fi

    if "${fsck_needed}" && ! "${mounted}"; then
        sudo -n e2fsck -fy "${rootfs}"
        fsck_status=$?
        if (( fsck_status >= 2 )); then
            echo "ERROR: e2fsck failed for ${rootfs} with status ${fsck_status}" >&2
            cleanup_status=1
        fi
    fi

    if (( status == 0 && cleanup_status != 0 )); then
        status=${cleanup_status}
    fi
    exit "${status}"
}

prepare_build_tmp() {
    local build_dir="${REPO_ROOT}/build"
    local canonical_path

    [[ ! -L "${build_dir}" ]] || fail "repository build path is a symlink: ${build_dir}"
    if [[ -e "${build_dir}" && ! -d "${build_dir}" ]]; then
        fail "repository build path is not a directory: ${build_dir}"
    fi
    mkdir -p "${build_dir}"
    canonical_path="$(cd "${build_dir}" && pwd -P)"
    [[ "${canonical_path}" == "${build_dir}" ]] ||
        fail "repository build path resolves outside the worktree: ${build_dir}"

    build_tmp="${build_dir}/tmp"
    [[ ! -L "${build_tmp}" ]] || fail "repository build/tmp is a symlink: ${build_tmp}"
    if [[ -e "${build_tmp}" && ! -d "${build_tmp}" ]]; then
        fail "repository build/tmp is not a directory: ${build_tmp}"
    fi
    mkdir -p "${build_tmp}"
    canonical_path="$(cd "${build_tmp}" && pwd -P)"
    [[ "${canonical_path}" == "${build_tmp}" ]] ||
        fail "repository build/tmp resolves outside the worktree: ${build_tmp}"

    mount_dir="$(mktemp -d "${build_tmp}/install-debugutils.XXXXXX")"
    chmod 0700 "${mount_dir}"
    [[ ! -L "${mount_dir}" && -d "${mount_dir}" ]] ||
        fail "invalid mount directory: ${mount_dir}"
    canonical_path="$(cd "${mount_dir}" && pwd -P)"
    case "${canonical_path}" in
        "${build_tmp}/install-debugutils."*) ;;
        *) fail "mount directory escaped build/tmp: ${canonical_path}" ;;
    esac
    [[ "$(stat -c '%a' "${mount_dir}")" == 700 ]] ||
        fail "mount directory is not mode 0700: ${mount_dir}"
}

trap cleanup EXIT
trap handle_int INT
trap handle_term TERM

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs)
            [[ $# -ge 2 ]] || fail '--rootfs requires an image path'
            rootfs=$2
            shift 2
            ;;
        --bin-dir)
            [[ $# -ge 2 ]] || fail '--bin-dir requires a directory'
            bin_dir=$2
            shift 2
            ;;
        --source-dir)
            [[ $# -ge 2 ]] || fail '--source-dir requires a directory'
            source_dir=$2
            shift 2
            ;;
        --include-source)
            include_source=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ -n "${rootfs}" ]] || fail '--rootfs is required'
[[ -n "${bin_dir}" ]] || fail '--bin-dir is required'
if "${include_source}"; then
    [[ -n "${source_dir}" ]] ||
        fail '--source-dir is required with --include-source'
fi

# Reject invalid images before creating a mount path or invoking sudo/mount.
for required_command in file realpath; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "missing required command: ${required_command}"
done
[[ -f "${rootfs}" ]] || fail "rootfs is not a regular file: ${rootfs}"
rootfs="$(realpath -e -- "${rootfs}")"
rootfs_description="$(file -b -- "${rootfs}")" ||
    fail "could not inspect rootfs image: ${rootfs}"
[[ "${rootfs_description}" == *'ext4 filesystem data'* ]] ||
    fail "rootfs is not an ext4 image: ${rootfs}"

[[ -d "${bin_dir}" ]] || fail "binary directory is not a directory: ${bin_dir}"
if "${include_source}"; then
    [[ -d "${source_dir}" ]] ||
        fail "source directory is not a directory: ${source_dir}"
fi
[[ -x "${STAGE_SCRIPT}" ]] || fail "missing staging helper: ${STAGE_SCRIPT}"

for required_command in sudo mount umount e2fsck mktemp rmdir mkdir chmod stat; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "missing required command: ${required_command}"
done
if ! command -v mountpoint >/dev/null 2>&1 &&
   ! command -v findmnt >/dev/null 2>&1; then
    fail 'mountpoint or findmnt is required'
fi

prepare_build_tmp

# A deferred signal received during validation or temporary-directory setup
# must stop before the first privileged action.
if (( pending_exit != 0 )); then
    exit "${pending_exit}"
fi

mount_status=0
mount_attempted=true
if sudo -n mount -t ext4 -o loop,nosuid,nodev,noexec \
        "${rootfs}" "${mount_dir}"; then
    mount_status=0
else
    mount_status=$?
fi

if (( mount_status == 0 )); then
    mounted=true
    fsck_needed=true
elif mount_is_active; then
    mounted=true
    fsck_needed=true
fi
mount_state_checked=true

if (( pending_exit != 0 )); then
    exit "${pending_exit}"
fi
if (( mount_status != 0 )); then
    echo "ERROR: failed to mount ${rootfs} with status ${mount_status}" >&2
    exit "${mount_status}"
fi

stage_args=(
    "${STAGE_SCRIPT}"
    --root "${mount_dir}"
    --bin-dir "${bin_dir}"
)
if [[ -n "${source_dir}" ]]; then
    stage_args+=(--source-dir "${source_dir}")
fi
if "${include_source}"; then
    stage_args+=(--include-source)
fi

stage_status=0
if sudo -n "${stage_args[@]}"; then
    stage_status=0
else
    stage_status=$?
fi
if (( pending_exit != 0 )); then
    exit "${pending_exit}"
fi
if (( stage_status != 0 )); then
    exit "${stage_status}"
fi

echo "Installed DPU debug utilities into ${rootfs}"
