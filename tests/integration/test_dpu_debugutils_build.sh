#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/third_party/dpu-debugutils"
SOURCE_METADATA="${SOURCE_DIR}/SOURCE.md"
EXPECTED_SHA256="1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab"

mkdir -p "${REPO_ROOT}/build/tmp"
OUTPUT_DIR="$(mktemp -d "${REPO_ROOT}/build/tmp/test-dpu-debugutils.XXXXXX")"
trap 'rm -rf "${OUTPUT_DIR}"' EXIT

test -f "${SOURCE_METADATA}"
grep -Fq "${EXPECTED_SHA256}" "${SOURCE_METADATA}"
test ! -e "${SOURCE_DIR}/.git"

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

echo '[dpu-debugutils-build] PASS'
