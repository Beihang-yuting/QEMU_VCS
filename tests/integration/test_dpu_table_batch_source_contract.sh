#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)

python3 - "$repo/guest/dpu-table-sideband/cosim_table_ctrl.c" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
start = text.index("enum dpu_table_submit_result dpu_table_submit_batch(")
body = text[start:text.index("\n}\n", start) + 2]

for token in (
    "struct dpu_table_batch_progress progress",
    "&progress",
    "if (result == DPU_TABLE_ERROR)",
    "table sideband batch error:",
    "committed=%u",
    "failed_index=%u",
    "failed_offset=%#llx",
    "original=%d",
    "final=%d",
    "progress.committed_entries",
    "progress.failed_index",
    "progress.failed_offset",
    "progress.original_result",
    "progress.final_result",
):
    assert token in body, token

error_check = body.index("if (result == DPU_TABLE_ERROR)")
adapter_lookup = body.index("adapter = (struct dpu_adapter *)hw->adapter")
assert error_check < adapter_lookup, "adapter lookup must remain on the ERROR path"

print("DPU batch error log contract passed")
PY
