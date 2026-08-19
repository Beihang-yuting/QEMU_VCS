#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [REFERENCE_HOST_DRIVER_NET]" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)
patch_file="$repo/guest/dpu-table-sideband/0002-dpu-table-complete-buffers.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-complete-buffer.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

[[ -f "$patch_file" ]] || {
    echo "missing complete-buffer patch: $patch_file" >&2
    exit 1
}
[[ $(sed -n -e 's/^--- //p' -e 's/^+++ //p' "$patch_file" |
    sed '/^\/dev\/null$/d;s,^[ab]/,,' | sort -u) == common.h ]] || {
    echo "complete-buffer patch must modify only common.h" >&2
    exit 1
}

if [[ $# -eq 1 ]]; then
    reference=$(cd "$1" && pwd)
    low_calls=$(grep -R --include='*.c' -h -E \
        '(^|[^[:alnum:]_])wr32_for_each\(' "$reference" | wc -l)
    high_calls=$(grep -R --include='*.c' -h -E \
        '(^|[^[:alnum:]_])wr32_for_high_order\(' "$reference" | wc -l)
    [[ $low_calls -eq 75 && $high_calls -eq 8 ]] || {
        echo "reference DWORD wrapper call-site count changed: $low_calls/$high_calls" >&2
        exit 1
    }
fi

if [[ $# -eq 1 ]]; then
    cp "$reference/common.h" "$work/common.h"
else
    cat >"$work/common.h" <<'EOF'
#ifndef __DPU_COMMON_H
#define __DPU_COMMON_H
#include "hw.h"
#include "register.h"
#include "compat.h"


#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

#define wr32(hw, reg, value) writel((value), ((hw)->hw_addr + (reg)))
#define rd32(hw, reg) readl((hw)->hw_addr + (reg))

#define wr32_for_each(hw, reg, value, size)                                    \
	do {                                                                   \
		int __n;                                                       \
		for (__n = 0; __n < (size); __n += 4)                          \
			wr32((hw), (reg) + __n, ((u32 *)(value))[__n >> 2]);   \
	} while (0)
#define wr32_for_high_order(hw, reg, value, size)                              \
	do {                                                                   \
		int __n;                                                       \
		for (__n = (size - 4); __n >= 0; __n -= 4)                     \
			wr32((hw), (reg) + __n, ((u32 *)(value))[__n >> 2]);   \
	} while (0)
#define rd32_for_each(hw, reg, value, size)                                    \
	do {                                                                   \
		int __n;                                                       \
		for (__n = 0; __n < (size); __n += 4)                          \
			((u32 *)(value))[__n >> 2] = rd32((hw), (reg) + __n);  \
	} while (0)
#endif
EOF
    sed -i 's/$/\r/' "$work/common.h"
fi

patch --batch --binary --fuzz=0 --no-backup-if-mismatch --reject-file=- \
    -d "$work" -p1 <"$patch_file" >/dev/null

python3 - "$work/common.h" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()

def function(name):
    start = text.index(f"static inline void {name}(")
    brace = text.index("{", start)
    depth = 0
    for pos in range(brace, len(text)):
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0:
                return text[start:pos + 1]
    raise AssertionError(name)

checks = (
    ("wr32_for_each", "DPU_TABLE_LOW_TO_HIGH", "for (__n = 0;", "+= 4"),
    ("wr32_for_high_order", "DPU_TABLE_HIGH_TO_LOW",
     "for (__n = size - 4;", "-= 4"),
)
for name, order, loop, step in checks:
    body = function(name)
    submit = body.index("dpu_table_submit(")
    success = body.index("if (result == DPU_TABLE_SUCCESS)", submit)
    success_return = body.index("return;", success)
    error = body.index("if (result == DPU_TABLE_ERROR)", success_return)
    error_return = body.index("return;", error)
    fallback = body.index(loop, error_return)
    assert submit < success < success_return < error < error_return < fallback
    for token in ("hw", "DPU_MEMORY_BAR", "reg", "value", "size", order):
        assert token in body[submit:success], (name, token)
    assert step in body[fallback:]
    assert "wr32(" in body[fallback:]
assert text.count("COSIM_TABLE_SIDEBAND_PATCH_0002") == 1
print("complete-buffer wrapper contract passed")
PY

patch --batch --force --reverse --binary --fuzz=0 --no-backup-if-mismatch \
    --reject-file=- -d "$work" -p1 --dry-run <"$patch_file" >/dev/null
