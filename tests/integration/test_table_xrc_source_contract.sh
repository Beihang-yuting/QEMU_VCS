#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$repo" <<'PY'
import re
import sys
from pathlib import Path


repo = Path(sys.argv[1])
xrc_pkg_path = repo / "vcs-tb/cosim_xrc_pkg.sv"
xrc_driver_path = repo / "vcs-tb/cosim_xrc_driver.sv"
table_pkg_path = repo / "vcs-tb/cosim_table_pkg.sv"


def fail(message: str) -> None:
    print(f"[table-xrc-source] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def strip_comments(source: str) -> str:
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def block(source: str, declaration: str, terminator: str) -> str:
    match = re.search(declaration, source)
    if match is None:
        fail(f"missing declaration matching {declaration!r}")
    end = re.search(rf"\b{terminator}\b", source[match.end():])
    if end is None:
        fail(f"declaration matching {declaration!r} has no {terminator}")
    return strip_comments(source[match.end():match.end() + end.start()])


xrc_pkg = xrc_pkg_path.read_text(encoding="utf-8")
xrc_driver = xrc_driver_path.read_text(encoding="utf-8")
table_pkg = table_pkg_path.read_text(encoding="utf-8")

include_pos = xrc_pkg.find('`include "cosim_table_pkg.sv"')
package_pos = xrc_pkg.find("package cosim_xrc_pkg;")
if include_pos < 0 or package_pos < 0 or include_pos >= package_pos:
    fail("cosim_table_pkg.sv must be included before cosim_xrc_pkg declaration")
if "import cosim_table_pkg::*;" not in xrc_pkg:
    fail("cosim_xrc_pkg must import the table package")
if '`include "cosim_xrc_test.sv"' in xrc_pkg or (repo / "vcs-tb/cosim_xrc_test.sv").exists():
    fail("the removed repository-owned cosim_xrc_test/top must not be restored")
if '`include "cosim_table_runtime.sv"' not in table_pkg:
    fail("cosim_table_pkg must export the runtime facade")

maybe_enable = block(
    xrc_pkg,
    r"function\s+automatic\s+void\s+cosim_maybe_enable\s*\([^;]*\)\s*;",
    "endfunction",
)
if '$test$plusargs("COSIM")' in maybe_enable:
    fail("prefix-matching $test$plusargs(\"COSIM\") is forbidden")
if "uvm_cmdline_processor" not in maybe_enable:
    fail("cosim_maybe_enable must use exact UVM command-line parsing")
if re.search(r'==\s*"\\?\+COSIM"', maybe_enable) is None and \
        re.search(r'\^\\?\+COSIM\$', maybe_enable) is None:
    fail("cosim_maybe_enable has no exact +COSIM comparison")

table_enable_pos = maybe_enable.find("COSIM_TABLE_ENABLE=%d")
fatal_pos = maybe_enable.find("$fatal")
return_match = re.search(r"if\s*\([^)]*cosim[^)]*\)\s*return\s*;", maybe_enable,
                         flags=re.IGNORECASE)
adapter_override_pos = maybe_enable.find(
    "pcie_tl_if_adapter::type_id::set_type_override")
driver_override_pos = maybe_enable.find(
    "pcie_tl_rc_driver::type_id::set_type_override")
if min(table_enable_pos, fatal_pos, adapter_override_pos, driver_override_pos) < 0:
    fail("cosim_maybe_enable is missing table guard or retained factory overrides")
if return_match is None:
    fail("cosim_maybe_enable must retain a default-off immediate return")
if not (table_enable_pos < fatal_pos < return_match.start() <
        adapter_override_pos < driver_override_pos):
    fail("table guard/default-off return/factory overrides are not safely ordered")

run_phase = block(
    xrc_driver,
    r"virtual\s+task\s+run_phase\s*\(\s*uvm_phase\s+phase\s*\)\s*;",
    "endtask",
)
ordered = (
    "self_init_bridge",
    "bridge_vcs_is_realized_rc",
    "cosim_table_runtime::start_rc",
    "request_loop",
    "cosim_table_runtime::stop_rc",
    "bridge_vcs_cleanup_ex_rc",
)
position = -1
for token in ordered:
    next_position = run_phase.find(token, position + 1)
    if next_position < 0:
        fail(f"run_phase is missing ordered lifecycle token {token}")
    position = next_position
if not re.search(r"for\s*\([^;]+;[^;]+<[^;]+;[^)]*\)", run_phase):
    fail("realization wait must be bounded")
if re.search(r"\bwhile\s*\([^)]*bridge_vcs_is_realized_rc", run_phase):
    fail("realization wait must not be unbounded")
poll_bound = re.search(r"table_ready_poll\s*<\s*(\d+)", run_phase)
if poll_bound is None or int(poll_bound.group(1)) > 100:
    fail("realization polling must not stall the main bridge for an excessive interval")

print("[table-xrc-source] PASS")
PY
