#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)
fixture="$repo/tests/fixtures/dpu_qid_reference/af_mng.c"
patch_file="$repo/guest/dpu-table-sideband/0003-dpu-qid-table-batch.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-qid-batch.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

[[ -f "$patch_file" ]] || {
    echo "missing QID batch patch: $patch_file" >&2
    exit 1
}
[[ $(sed -n -e 's/^--- //p' -e 's/^+++ //p' "$patch_file" |
    sed '/^\/dev\/null$/d;s,^[ab]/,,' | sort -u) == af_mng.c ]] || {
    echo "QID batch patch must modify only af_mng.c" >&2
    exit 1
}

cp "$fixture" "$work/af_mng.c"
patch --batch --binary --ignore-whitespace --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- -d "$work" -p1 \
    <"$patch_file" >/dev/null

python3 - "$fixture" "$work/af_mng.c" <<'PY'
from pathlib import Path
import sys

before_text = Path(sys.argv[1]).read_text()
after_text = Path(sys.argv[2]).read_text()

def function(text, name):
    start = text.index(f"static void {name}(")
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

def fallback(body):
    write = body.index("wr32_for_high_order(hw,")
    start = body.rfind("\tfor (i = 0; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++) {", 0, write)
    end_mark = "\n\t\tif (j == DPU_REG_WRITE_MAX_TRY_TIMES)"
    last = body.index(end_mark, start)
    end = body.index("\n\t}", last) + len("\n\t}")
    return body[start:end]

for name in ("dpu_af_fill_qid_map_table", "dpu_af_remove_qid_map_table"):
    before = function(before_text, name)
    after = function(after_text, name)
    assert fallback(before) == fallback(after), name
    call = after.index("result = dpu_table_submit_batch(")
    success = after.index("if (result == DPU_TABLE_SUCCESS)", call)
    jump = after.index("goto qid_table_done;", success)
    error = after.index("if (result == DPU_TABLE_ERROR)", jump)
    unlock = after.index("spin_unlock_irqrestore", error)
    hard_return = after.index("return;", unlock)
    frontdoor = after.index("\tfor (i = 0; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++) {", hard_return)
    label = after.index("qid_table_done:", frontdoor)
    assert call < success < jump < error < unlock < hard_return < frontdoor < label
    segment = after[call:success]
    for token in ("DPU_MEMORY_BAR", "VIO_NOTIFY_TBL_E_ADDR(",
                  "af_res->vio_notify_table",
                  "sizeof(struct dpu_vio_notify_tbl)",
                  "DPU_QID_MAP_TABLE_ENTRIES(hw)",
                  "DPU_TABLE_HIGH_TO_LOW"):
        assert token in segment, (name, token)

fill = function(after_text, "dpu_af_fill_qid_map_table")
remove = function(after_text, "dpu_af_remove_qid_map_table")
assert fill.index("memcpy(&af_res->vio_notify_table[qid_map_base + i]") < \
       fill.index("result = dpu_table_submit_batch(")
assert remove.index("af_res->vio_notify_table[i] = invalid_qid_map;") < \
       remove.index("result = dpu_table_submit_batch(")
assert after_text.count("result = dpu_table_submit_batch(") == 2
assert after_text.count("COSIM_TABLE_SIDEBAND_PATCH_0003") == 1
print("QID insert/remove batch contract passed")
PY

patch --batch --force --reverse --binary --ignore-whitespace --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- -d "$work" -p1 --dry-run \
    <"$patch_file" >/dev/null
