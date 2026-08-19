#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [REFERENCE_HOST_DRIVER_NET_OR_ARCHIVE]" >&2
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
    reference_arg=$1
    if [[ -d "$reference_arg" ]]; then
        reference=$(cd "$reference_arg" && pwd)
    elif [[ -f "$reference_arg" ]]; then
        mkdir "$work/reference-extract"
        tar -xf "$reference_arg" -C "$work/reference-extract"
        mapfile -t common_headers < <(find "$work/reference-extract" \
            -type f -name common.h -print)
        [[ ${#common_headers[@]} -eq 1 ]] || {
            echo "reference archive must contain exactly one common.h" >&2
            exit 1
        }
        reference=$(dirname "${common_headers[0]}")
    else
        echo "reference driver tree/archive does not exist: $reference_arg" >&2
        exit 1
    fi

    read -r low_calls high_calls < <(python3 - "$reference" <<'PY'
from pathlib import Path
import re
import sys

def without_comments_and_literals(text):
    result = []
    index = 0
    state = "code"
    while index < len(text):
        char = text[index]
        following = text[index + 1] if index + 1 < len(text) else ""
        if state == "code":
            if char == "/" and following == "*":
                state = "block"
                result.extend("  ")
                index += 2
                continue
            if char == "/" and following == "/":
                state = "line"
                result.extend("  ")
                index += 2
                continue
            if char == '"':
                state = "string"
                result.append(" ")
            elif char == "'":
                state = "character"
                result.append(" ")
            else:
                result.append(char)
            index += 1
            continue
        if state == "block":
            if char == "*" and following == "/":
                state = "code"
                result.extend("  ")
                index += 2
            else:
                result.append("\n" if char == "\n" else " ")
                index += 1
            continue
        if state == "line":
            result.append("\n" if char == "\n" else " ")
            if char == "\n":
                state = "code"
            index += 1
            continue
        result.append("\n" if char == "\n" else " ")
        if char == "\\":
            if following:
                result.append("\n" if following == "\n" else " ")
                index += 2
            else:
                index += 1
        elif (state == "string" and char == '"') or \
             (state == "character" and char == "'"):
            state = "code"
            index += 1
        else:
            index += 1
    return "".join(result)

source = "\n".join(
    path.read_text(errors="ignore") for path in Path(sys.argv[1]).rglob("*.c")
)
source = without_comments_and_literals(source)
counts = []
for name in ("wr32_for_each", "wr32_for_high_order"):
    counts.append(len(re.findall(rf"(?<![A-Za-z0-9_]){name}\s*\(", source)))
print(*counts)
PY
    )
    [[ $low_calls -eq 70 && $high_calls -eq 8 ]] || {
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
