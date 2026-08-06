#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/third_party/dpu-debugutils"
OUTPUT_DIR="${1:-${REPO_ROOT}/build/guest_tools/dpu-debugutils}"

for required_command in make gcc file install; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "Missing required command: ${required_command}" >&2
        exit 1
    fi
done

for makefile in pcie_debug/Makefile reg_display/Makefile; do
    if [[ ! -f "${SOURCE_DIR}/${makefile}" ]]; then
        echo "Missing required Makefile: ${SOURCE_DIR}/${makefile}" >&2
        exit 1
    fi
done

mkdir -p "${REPO_ROOT}/build/tmp"
WORK_DIR="$(mktemp -d "${REPO_ROOT}/build/tmp/dpu-debugutils.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

cp -a "${SOURCE_DIR}/." "${WORK_DIR}/"

make -C "${WORK_DIR}" clean
CC=gcc make -C "${WORK_DIR}" -j"$(nproc)" LDFLAGS=-static LIBS='-lreadline -ltinfo'

install -d "${OUTPUT_DIR}"
install -m 0755 "${WORK_DIR}/pcie_debug/bin/pci_debug" "${OUTPUT_DIR}/pci_debug"
install -m 0755 "${WORK_DIR}/reg_display/bin/reg_display" "${OUTPUT_DIR}/reg_display"

for utility in pci_debug reg_display; do
    if ! file "${OUTPUT_DIR}/${utility}" | grep -Fq 'statically linked'; then
        echo "Output is not statically linked: ${OUTPUT_DIR}/${utility}" >&2
        exit 1
    fi
done

echo "DPU debug utilities installed in ${OUTPUT_DIR}"
