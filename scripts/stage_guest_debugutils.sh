#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

root=''
bin_dir=''
source_dir=''
include_source=false
build_tmp=''
work_dir=''

usage() {
    cat <<'USAGE'
Usage:
  scripts/stage_guest_debugutils.sh --root DIR --bin-dir DIR \
    [--source-dir DIR] [--include-source]

Install statically linked pci_debug and reg_display binaries into an already
mounted Guest root.  --include-source also installs a sanitized source copy at
/opt/dpu-debugutils.

Security boundary: the repository/worktree and the user invoking this script
are trusted.  All staging temporaries stay in the repository's build/tmp tree;
the script rejects symlinked build paths and Guest destination paths.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "${work_dir}" ]]; then
        rm -rf -- "${work_dir}"
    fi
    exit "${status}"
}

handle_int() {
    exit 130
}

handle_term() {
    exit 143
}

trap cleanup EXIT
trap handle_int INT
trap handle_term TERM

validate_optional_directory() {
    local relative_path=$1
    local path="${root}/${relative_path}"

    [[ ! -L "${path}" ]] ||
        fail "Guest destination is a symlink: /${relative_path}"
    if [[ -e "${path}" && ! -d "${path}" ]]; then
        fail "Guest destination is not a directory: /${relative_path}"
    fi
}

validate_optional_file() {
    local relative_path=$1
    local path="${root}/${relative_path}"

    [[ ! -L "${path}" ]] ||
        fail "Guest destination is a symlink: /${relative_path}"
    if [[ -e "${path}" && ! -f "${path}" ]]; then
        fail "Guest destination is not a regular file: /${relative_path}"
    fi
}

validate_target_destinations() {
    local relative_path

    for relative_path in \
        usr usr/local usr/local/bin usr/local/share usr/local/share/doc \
        usr/local/share/doc/cosim-dpu-debugutils opt; do
        validate_optional_directory "${relative_path}"
    done
    for relative_path in \
        usr/local/bin/pci_debug \
        usr/local/bin/reg_display \
        usr/local/share/doc/cosim-dpu-debugutils/README; do
        validate_optional_file "${relative_path}"
    done
    if "${include_source}"; then
        validate_optional_directory opt/dpu-debugutils
    fi
}

validate_created_directory() {
    local relative_path=$1
    local path="${root}/${relative_path}"
    local canonical_path

    [[ ! -L "${path}" ]] ||
        fail "Guest destination became a symlink: /${relative_path}"
    [[ -d "${path}" ]] ||
        fail "Guest destination is not a directory: /${relative_path}"
    canonical_path="$(cd "${path}" && pwd -P)"
    case "${canonical_path}" in
        "${root}"|"${root}/"*) ;;
        *) fail "Guest destination escapes target root: /${relative_path}" ;;
    esac
}

validate_created_directories() {
    local relative_path

    for relative_path in \
        usr usr/local usr/local/bin usr/local/share usr/local/share/doc \
        usr/local/share/doc/cosim-dpu-debugutils; do
        validate_created_directory "${relative_path}"
    done
    if "${include_source}"; then
        validate_created_directory opt
    fi
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

    work_dir="$(mktemp -d "${build_tmp}/stage-debugutils.XXXXXX")"
    chmod 0700 "${work_dir}"
    [[ ! -L "${work_dir}" && -d "${work_dir}" ]] ||
        fail "invalid staging work directory: ${work_dir}"
    canonical_path="$(cd "${work_dir}" && pwd -P)"
    case "${canonical_path}" in
        "${build_tmp}/stage-debugutils."*) ;;
        *) fail "staging work directory escaped build/tmp: ${canonical_path}" ;;
    esac
    [[ "$(stat -c '%a' "${work_dir}")" == 700 ]] ||
        fail "staging work directory is not mode 0700: ${work_dir}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || fail '--root requires a directory'
            root=$2
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

[[ -n "${root}" ]] || fail '--root is required'
[[ -n "${bin_dir}" ]] || fail '--bin-dir is required'
[[ -d "${root}" ]] || fail "root is not a directory: ${root}"
root="$(cd "${root}" && pwd -P)"
[[ "${root}" != / ]] || fail 'refusing to use the host root directory'
[[ -d "${bin_dir}" ]] || fail "binary directory is not a directory: ${bin_dir}"
bin_dir="$(cd "${bin_dir}" && pwd -P)"

if "${include_source}"; then
    [[ -n "${source_dir}" ]] ||
        fail '--source-dir is required with --include-source'
    [[ -d "${source_dir}" ]] ||
        fail "source directory is not a directory: ${source_dir}"
    source_dir="$(cd "${source_dir}" && pwd -P)"
    [[ "${source_dir}" != / ]] || fail 'refusing to copy the host root directory'
fi

for required_command in file install cp find rm mktemp mkdir chmod stat; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "missing required command: ${required_command}"
done

for utility in pci_debug reg_display; do
    binary="${bin_dir}/${utility}"
    [[ -f "${binary}" ]] || fail "missing debug utility: ${binary}"
    [[ -x "${binary}" ]] || fail "debug utility is not executable: ${binary}"
done

# Fail closed on pre-existing Guest symlinks before preparing any destination.
validate_target_destinations
prepare_build_tmp

# Snapshot each input exactly once, then validate and install only that copy.
install -d -m 0700 "${work_dir}/binaries"
for utility in pci_debug reg_display; do
    install -m 0700 "${bin_dir}/${utility}" "${work_dir}/binaries/${utility}"
done

if "${include_source}"; then
    install -d -m 0700 "${work_dir}/source"
    # Plain recursive copy intentionally does not preserve host ownership or
    # xattrs.  Strip privilege bits before anything reaches the Guest.
    cp -R "${source_dir}/." "${work_dir}/source/"
    chmod -R u-s,g-s "${work_dir}/source"

    source_symlink="$(find "${work_dir}/source" -type l -print -quit)"
    [[ -z "${source_symlink}" ]] ||
        fail "debug utility source contains a symlink: ${source_symlink}"
    for required_source in Makefile pcie_debug/Makefile reg_display/Makefile; do
        [[ -f "${work_dir}/source/${required_source}" ]] ||
            fail "invalid debug utility source: missing ${required_source}"
    done
    find "${work_dir}/source" -depth \
        \( -name .git -o -name fpga -o -name contrib -o -name bin -o -name obj \
           -o -name '*.o' -o -name '*.ko' \) \
        -exec rm -rf -- {} +
    excluded_path="$(find "${work_dir}/source" \
        \( -name .git -o -name fpga -o -name contrib -o -name bin -o -name obj \
           -o -name '*.o' -o -name '*.ko' \) -print -quit)"
    [[ -z "${excluded_path}" ]] ||
        fail "could not sanitize source artifact: ${excluded_path}"
fi

for utility in pci_debug reg_display; do
    snapshot="${work_dir}/binaries/${utility}"
    file_output="$(file -- "${snapshot}")" ||
        fail "could not inspect debug utility snapshot: ${utility}"
    [[ "${file_output}" == *'statically linked'* ]] ||
        fail "debug utility is not statically linked: ${bin_dir}/${utility}"
done

cat >"${work_dir}/README" <<'README'
cosim DPU debug utilities

The statically linked tools are installed at /usr/local/bin/pci_debug and
/usr/local/bin/reg_display.  Use pci_debug for PCIe configuration and BAR
access, and reg_display for device register inspection.

When the image was staged with --include-source, the sanitized utility source
is available at /opt/dpu-debugutils.  Source installation is optional.
README

# Recheck immediately before the first Guest change, then verify all created
# directories canonically remain below the mounted root before writing files.
validate_target_destinations
install -d -m 0755 \
    "${root}/usr/local/bin" \
    "${root}/usr/local/share/doc/cosim-dpu-debugutils"
if "${include_source}"; then
    install -d -m 0755 "${root}/opt"
fi
validate_created_directories
validate_target_destinations

install -m 0755 \
    "${work_dir}/binaries/pci_debug" \
    "${root}/usr/local/bin/pci_debug"
install -m 0755 \
    "${work_dir}/binaries/reg_display" \
    "${root}/usr/local/bin/reg_display"
install -m 0644 \
    "${work_dir}/README" \
    "${root}/usr/local/share/doc/cosim-dpu-debugutils/README"

if "${include_source}"; then
    validate_optional_directory opt/dpu-debugutils
    rm -rf -- "${root}/opt/dpu-debugutils"
    install -d -m 0755 "${root}/opt/dpu-debugutils"
    validate_created_directory opt/dpu-debugutils
    cp -R "${work_dir}/source/." "${root}/opt/dpu-debugutils/"
    chmod -R u-s,g-s "${root}/opt/dpu-debugutils"
fi

echo "Staged DPU debug utilities under ${root}"
