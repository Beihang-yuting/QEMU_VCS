#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

root=''
bin_dir=''
source_dir=''
include_source=false
work_dir=''

usage() {
    cat <<'USAGE'
Usage:
  scripts/stage_guest_debugutils.sh --root DIR --bin-dir DIR \
    [--source-dir DIR] [--include-source]

Install statically linked pci_debug and reg_display binaries into an already
mounted Guest root.  --include-source also installs a sanitized source copy at
/opt/dpu-debugutils.
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

for required_command in file install cp find rm mktemp; do
    command -v "${required_command}" >/dev/null 2>&1 ||
        fail "missing required command: ${required_command}"
done

# Validate both inputs before the first change below the target root.  In
# particular, a valid pci_debug must not be installed if reg_display fails.
for utility in pci_debug reg_display; do
    binary="${bin_dir}/${utility}"
    [[ -f "${binary}" ]] || fail "missing debug utility: ${binary}"
    [[ -x "${binary}" ]] || fail "debug utility is not executable: ${binary}"
    file_output="$(file -- "${binary}")" ||
        fail "could not inspect debug utility: ${binary}"
    [[ "${file_output}" == *'statically linked'* ]] ||
        fail "debug utility is not statically linked: ${binary}"
done

if "${include_source}"; then
    [[ -n "${source_dir}" ]] ||
        fail '--source-dir is required with --include-source'
    [[ -d "${source_dir}" ]] ||
        fail "source directory is not a directory: ${source_dir}"
    source_dir="$(cd "${source_dir}" && pwd -P)"
    [[ "${source_dir}" != / ]] || fail 'refusing to copy the host root directory'

    for required_source in Makefile pcie_debug/Makefile reg_display/Makefile; do
        [[ -f "${source_dir}/${required_source}" ]] ||
            fail "invalid debug utility source: missing ${required_source}"
    done
fi

# Prepare all fallible generated content outside the target root so validation
# and source filtering cannot leave a partially installed Guest tree.
mkdir -p "${REPO_ROOT}/build/tmp"
work_dir="$(mktemp -d "${REPO_ROOT}/build/tmp/stage-debugutils.XXXXXX")"
trap cleanup EXIT INT TERM

cat >"${work_dir}/README" <<'README'
cosim DPU debug utilities

The statically linked tools are installed at /usr/local/bin/pci_debug and
/usr/local/bin/reg_display.  Use pci_debug for PCIe configuration and BAR
access, and reg_display for device register inspection.

When the image was staged with --include-source, the sanitized utility source
is available at /opt/dpu-debugutils.  Source installation is optional.
README

if "${include_source}"; then
    mkdir -p "${work_dir}/source"
    cp -a "${source_dir}/." "${work_dir}/source/"
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

install -d -m 0755 \
    "${root}/usr/local/bin" \
    "${root}/usr/local/share/doc/cosim-dpu-debugutils"
install -m 0755 \
    "${bin_dir}/pci_debug" \
    "${root}/usr/local/bin/pci_debug"
install -m 0755 \
    "${bin_dir}/reg_display" \
    "${root}/usr/local/bin/reg_display"
install -m 0644 \
    "${work_dir}/README" \
    "${root}/usr/local/share/doc/cosim-dpu-debugutils/README"

if "${include_source}"; then
    install -d -m 0755 "${root}/opt"
    rm -rf -- "${root}/opt/dpu-debugutils"
    install -d -m 0755 "${root}/opt/dpu-debugutils"
    cp -a "${work_dir}/source/." "${root}/opt/dpu-debugutils/"
fi

echo "Staged DPU debug utilities under ${root}"
