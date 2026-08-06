#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE_SCRIPT="${SCRIPT_DIR}/stage_guest_debugutils.sh"

rootfs=''
bin_dir=''
source_dir=''
include_source=false
mount_dir=''
mounted=false
fsck_needed=false

usage() {
    cat <<'USAGE'
Usage:
  scripts/install_guest_debugutils.sh --rootfs IMAGE --bin-dir DIR \
    [--source-dir DIR] [--include-source]

Mount an ext4 Guest image, stage the DPU debug utilities, unmount it, and run
e2fsck.  Privileged operations are performed with non-interactive sudo.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    local cleanup_status=0
    local fsck_status=0

    trap - EXIT INT TERM
    set +e

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

for required_command in sudo mount umount e2fsck mktemp rmdir; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "missing required command: ${required_command}"
done

mkdir -p "${REPO_ROOT}/build/tmp"
mount_dir="$(mktemp -d "${REPO_ROOT}/build/tmp/install-debugutils.XXXXXX")"
trap cleanup EXIT INT TERM

sudo -n mount -o loop "${rootfs}" "${mount_dir}"
mounted=true
fsck_needed=true

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

sudo -n "${stage_args[@]}"

echo "Installed DPU debug utilities into ${rootfs}"
