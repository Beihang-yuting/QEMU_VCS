#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)
fixture="$repo/tests/fixtures/dpu_qid_reference"
patch_file="$repo/guest/dpu-table-sideband/0003-dpu-qid-table-batch.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-qid-batch.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

[[ -f "$patch_file" ]] || {
    echo "missing QID batch patch: $patch_file" >&2
    exit 1
}
expected_paths=$'af_mng.c\naf_mng.h\ndeinit_restore.c\nmailbox.c\nmain.c'
[[ $(sed -n -e 's/^--- //p' -e 's/^+++ //p' "$patch_file" |
    sed '/^\/dev\/null$/d;s,^[ab]/,,' | sort -u) == "$expected_paths" ]] || {
    echo "QID batch patch must modify the complete QID error-return chain" >&2
    exit 1
}

cp "$fixture"/* "$work/"
patch --batch --binary --ignore-whitespace --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- -d "$work" -p1 \
    <"$patch_file" >/dev/null

python3 - "$work" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
af_mng = (root / "af_mng.c").read_text()

def function(text, name):
    prefixes = ("static int ", "int ", "static void ", "void ")
    start = next(text.index(prefix + name + "(") for prefix in prefixes
                 if prefix + name + "(" in text)
    brace = text.index("{", start)
    depth = 0
    for pos in range(brace, len(text)):
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0:
                return text[start:pos + 1]
    raise AssertionError(f"unterminated function: {name}")

for name in ("dpu_af_fill_qid_map_table", "dpu_af_remove_qid_map_table"):
    body = function(af_mng, name)
    assert body.startswith("static int "), name
    alloc = body.index("kmalloc(")
    lock = body.index("spin_lock_irqsave")
    stage = body.index("memcpy(staged_table, af_res->vio_notify_table,")
    call = body.index("result = dpu_table_submit_batch(")
    success = body.index("if (result == DPU_TABLE_SUCCESS)", call)
    error = body.index("if (result == DPU_TABLE_ERROR)", success)
    frontdoor = body.index("wr32_for_high_order(hw,", error)
    commit_label = body.index("qid_table_commit:", frontdoor)
    commit = body.index("memcpy(af_res->vio_notify_table, staged_table,", commit_label)
    ready = body.index("af_res->vio_notify_tbl_ready", commit)
    select = body.index("af_res->vio_notify_tbl_select =", ready)
    unlock = body.index("spin_unlock_irqrestore", select)
    free = body.index("kfree(staged_table)", unlock)
    returned = body.index("return err", free)
    assert alloc < lock < stage < call < success < error < frontdoor
    assert frontdoor < commit_label < commit < ready < select < unlock < free < returned
    assert "goto qid_table_commit;" in body[success:error]
    assert "err = -EIO;" in body[error:frontdoor]
    assert "goto qid_table_out;" in body[error:frontdoor]
    assert "return;" not in body
    before_commit = body[:commit]
    assert "memcpy(&af_res->vio_notify_table[" not in before_commit
    assert "af_res->vio_notify_table[i] =" not in before_commit
    assert "af_res->vio_notify_tbl_ready +=" not in before_commit
    assert "af_res->vio_notify_tbl_ready -=" not in before_commit
    assert "af_res->vio_notify_tbl_select =" not in before_commit
    segment = body[call:success]
    for token in ("DPU_MEMORY_BAR", "VIO_NOTIFY_TBL_E_ADDR(",
                  "staged_table",
                  "sizeof(struct dpu_vio_notify_tbl)",
                  "DPU_QID_MAP_TABLE_ENTRIES(hw)",
                  "DPU_TABLE_HIGH_TO_LOW"):
        assert token in segment, (name, token)
    assert "staged_table" in body[frontdoor:commit_label]

fill = function(af_mng, "dpu_af_fill_qid_map_table")
remove = function(af_mng, "dpu_af_remove_qid_map_table")
assert "memcpy(&staged_table[qid_map_base + i]" in fill
assert "staged_table[i] = invalid_qid_map;" in remove
guard = remove.index("qid_map_entries > af_res->vio_notify_tbl_ready")
submit = remove.index("result = dpu_table_submit_batch(")
subtract = remove.index("af_res->vio_notify_tbl_ready -= qid_map_entries")
assert guard < submit < subtract
assert "err = -EINVAL;" in remove[guard:submit]

configure = function(af_mng, "dpu_af_configure_qid_map")
fill_call = configure.index("err = dpu_af_fill_qid_map_table(")
fill_check = configure.index("if (err)", fill_call)
schedule = configure.index("dpu_add_vnet_2_qsch", fill_check)
rollback = configure.index("clear_bit(queue_index, af_res->txrx_queue_bitmap)", schedule)
free = configure.index("kfree(txrx_queues)", rollback)
assert fill_call < fill_check < schedule < rollback < free
assert "goto fill_qid_map_err;" in configure[fill_check:schedule]
assert "func_res->vio_notifiy_addr |= 1;" in configure[free:]

clear = function(af_mng, "dpu_af_clear_qid_map")
assert clear.startswith("int ")
remove_call = clear.index("err = dpu_af_remove_qid_map_table(")
remove_check = clear.index("if (err)", remove_call)
early_return = clear.index("return err;", remove_check)
teardown = clear.index("func_res->vio_notifiy_addr |= 1", early_return)
assert remove_call < remove_check < early_return < teardown
assert "return 0;" in clear[teardown:]

header = (root / "af_mng.h").read_text()
assert "int dpu_af_clear_qid_map(" in header

main = function((root / "main.c").read_text(), "dpu_clear_notify_addr")
assert "err = dpu_af_clear_qid_map(" in main
assert "Failed to clear qid map" in main

mailbox = function((root / "mailbox.c").read_text(),
                   "dpu_mailbox_resp_clear_qid_map")
assert "int err;" in mailbox
assert "err = dpu_af_clear_qid_map(" in mailbox
assert "srcid, err, req_msg_type" in mailbox

deinit = function((root / "deinit_restore.c").read_text(),
                  "af_rmmod_clear_notify_addr")
assert "err = dpu_af_clear_qid_map(" in deinit
assert "Failed to clear qid map" in deinit

assert af_mng.count("result = dpu_table_submit_batch(") == 2
assert af_mng.count("COSIM_TABLE_SIDEBAND_PATCH_0003") == 1
print("transactional QID insert/remove and error propagation contract passed")
PY

patch --batch --force --reverse --binary --ignore-whitespace --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- -d "$work" -p1 --dry-run \
    <"$patch_file" >/dev/null
