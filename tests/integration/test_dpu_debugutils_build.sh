#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/third_party/dpu-debugutils"
SOURCE_METADATA="${SOURCE_DIR}/SOURCE.md"
SOURCE_MANIFEST="${SOURCE_DIR}/SHA256SUMS"
EXPECTED_SHA256="1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab"
VENDOR_COMMIT="3dc8b60b2a2691fb47ba6aecf0ae873bc303b3aa"
VENDOR_COMMIT_SHORT="3dc8b60"

mkdir -p "${REPO_ROOT}/build/tmp"
OUTPUT_DIR="$(mktemp -d "${REPO_ROOT}/build/tmp/test-dpu-debugutils.XXXXXX")"
trap 'rm -rf "${OUTPUT_DIR}"' EXIT

test -f "${SOURCE_METADATA}"
grep -Fq "${EXPECTED_SHA256}" "${SOURCE_METADATA}"
grep -Fq "${VENDOR_COMMIT}" "${SOURCE_METADATA}"
test -f "${SOURCE_MANIFEST}"

excluded_path="$(find "${SOURCE_DIR}" \
    \( -name .git -o -name fpga -o -name contrib -o -name bin -o -name obj \
       -o -name '*.o' -o -name '*.ko' \) -print -quit)"
if [[ -n "${excluded_path}" ]]; then
    echo "Excluded vendor path is present: ${excluded_path}" >&2
    exit 1
fi

(
    cd "${SOURCE_DIR}"
    sha256sum -c SHA256SUMS
    test "$(wc -l < SHA256SUMS)" -eq 18
    find . -type f ! -name SOURCE.md ! -name SHA256SUMS -printf '%P\n' \
        | LC_ALL=C sort >"${OUTPUT_DIR}/vendor-files.actual"
    awk '{print $2}' SHA256SUMS \
        | LC_ALL=C sort >"${OUTPUT_DIR}/vendor-files.manifest"
    cmp "${OUTPUT_DIR}/vendor-files.actual" "${OUTPUT_DIR}/vendor-files.manifest"
)

CROSS_COMPILE=review-nonexistent- ARCH=arm64 \
    "${REPO_ROOT}/scripts/build_dpu_debugutils.sh" "${OUTPUT_DIR}"

for utility in pci_debug reg_display; do
    binary="${OUTPUT_DIR}/${utility}"
    test -x "${binary}"
    file "${binary}" | grep -Fq 'statically linked'

    ldd_output="$(ldd "${binary}" 2>&1 || true)"
    if grep -Fq -- '=>' <<<"${ldd_output}"; then
        echo "${utility} has shared-library dependencies:" >&2
        echo "${ldd_output}" >&2
        exit 1
    fi

    help_output="$("${binary}" -h 2>&1 || true)"
    grep -Fq 'Usage:' <<<"${help_output}"
done

if ! strings "${OUTPUT_DIR}/reg_display" \
    | grep -Fx "${VENDOR_COMMIT_SHORT}" >/dev/null; then
    echo "reg_display does not embed vendor commit ${VENDOR_COMMIT_SHORT}" >&2
    exit 1
fi
COSIM_HEAD_SHORT="$(git -C "${REPO_ROOT}" rev-parse --short HEAD)"
if [[ "${COSIM_HEAD_SHORT}" != "${VENDOR_COMMIT_SHORT}" ]] &&
   strings "${OUTPUT_DIR}/reg_display" | grep -Fx "${COSIM_HEAD_SHORT}" >/dev/null; then
    echo "reg_display embeds cosim-platform HEAD ${COSIM_HEAD_SHORT}" >&2
    exit 1
fi

echo '[dpu-debugutils-build] PASS'
