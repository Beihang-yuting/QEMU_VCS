#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
xrc="$repo/vcs-tb/cosim_xrc_driver.sv"

python3 - "$xrc" <<'PY'
import re
import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"[cosim-completion-ownership] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def block_body(source: str, declaration: str, terminator: str) -> str:
    match = re.search(declaration, source)
    if match is None:
        fail(f"missing block matching {declaration!r}")
    end = re.search(rf"\b{terminator}\b", source[match.end():])
    if end is None:
        fail(f"block has no {terminator}")
    body = source[match.end():match.end() + end.start()]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    return body


source = Path(sys.argv[1]).read_text(encoding="utf-8")

override = block_body(
    source,
    r"virtual\s+function\s+bit\s+handle_completion\s*\(\s*pcie_tl_cpl_tlp\s+cpl\s*\)\s*;",
    "endfunction",
)
if re.fullmatch(r"\s*return\s+1\s*;\s*", override) is None:
    fail(
        "handle_completion must unconditionally defer ownership to rx_loop "
        "and return claimed"
    )
for forbidden in (
    "super.handle_completion",
    "cosim_active",
    "vip_tag_to_qemu_tag",
    "qemu_tag_to_vip_tag",
):
    if forbidden in override:
        fail(f"handle_completion override must not access {forbidden}")

rx_loop = block_body(
    source,
    r"protected\s+task\s+rx_loop\s*\(\s*uvm_phase\s+phase\s*\)\s*;",
    "endtask",
)
phase_owners = re.compile(
    r"else\s+if\s*\(\s*cosim_active\s*\)\s*"
    r"forward_completion_to_qemu\s*\(\s*cpl\s*\)\s*;\s*"
    r"else\s+void\s*'\s*\(\s*super\.handle_completion\s*\(\s*cpl\s*\)\s*\)\s*;",
    flags=re.DOTALL,
)
if phase_owners.search(rx_loop) is None:
    fail("rx_loop must own both pre-cosim and cosim completion consumption")
if rx_loop.count("super.handle_completion") != 1:
    fail("rx_loop must explicitly consume pre-cosim completions via super exactly once")

forward = block_body(
    source,
    r"protected\s+function\s+void\s+forward_completion_to_qemu\s*"
    r"\(\s*pcie_tl_cpl_tlp\s+cpl\s*\)\s*;",
    "endfunction",
)
required_in_order = (
    "super.handle_completion(cpl)",
    "vip_tag_to_qemu_tag.exists(vip_tag_int)",
    "qemu_tag = int'(vip_tag_to_qemu_tag[vip_tag_int])",
    "vip_tag_to_qemu_tag.delete(vip_tag_int)",
    "qemu_tag_to_vip_tag.delete(qemu_tag[9:0])",
)
compact_forward = re.sub(r"\s+", "", forward)
position = -1
for expression in required_in_order:
    compact_expression = re.sub(r"\s+", "", expression)
    next_position = compact_forward.find(compact_expression, position + 1)
    if next_position < 0:
        fail(f"forward_completion_to_qemu missing ordered expression: {expression}")
    position = next_position
if forward.count("super.handle_completion") != 1:
    fail("forward_completion_to_qemu must explicitly consume via super exactly once")

run_phase = block_body(
    source,
    r"virtual\s+task\s+run_phase\s*\(\s*uvm_phase\s+phase\s*\)\s*;",
    "endtask",
)
if re.search(r"\bwait\s*\(\s*get_pending_count\s*\(", run_phase):
    fail("drain must not wait on a no-argument function expression")
drain = re.search(
    r"while\s*\(\s*get_pending_count\s*\(\s*\)\s*!=\s*0\s*\)\s*"
    r"#\s*\(\s*polling_interval_ns\s*\*\s*1ns\s*\)\s*;",
    run_phase,
)
if drain is None:
    fail("drain must poll pending completions with explicit time progress")
activate = re.search(r"cosim_active\s*=\s*1\s*;", run_phase)
if activate is None or drain.start() >= activate.start():
    fail("completion drain must finish before cosim activation")

print("[cosim-completion-ownership] PASS")
PY
