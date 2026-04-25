#!/bin/bash
# build_guest_tools.sh -- static-compile custom C test tools for guest
# Usage: ./scripts/build_guest_tools.sh [output_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$(dirname "$SCRIPT_DIR")/build/guest_tools}"

mkdir -p "$OUTPUT_DIR"

TOOLS=(cfgspace_test virtio_reg_test devmem_test dma_test nic_tx_test)
PASS=0
FAIL=0

for tool in "${TOOLS[@]}"; do
    src="${SCRIPT_DIR}/${tool}.c"
    if [ ! -f "$src" ]; then
        echo "[SKIP] $tool -- source not found"
        continue
    fi
    echo -n "[BUILD] $tool ... "
    if gcc -static -O2 -o "${OUTPUT_DIR}/${tool}" "$src" 2>/dev/null; then
        echo "OK"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Built: $PASS  Failed: $FAIL  Output: $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
