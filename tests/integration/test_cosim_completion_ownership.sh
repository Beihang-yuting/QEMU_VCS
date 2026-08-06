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


def function_body(source: str, declaration: str) -> str:
    match = re.search(declaration, source)
    if match is None:
        fail(f"missing function matching {declaration!r}")
    end = re.search(r"\bendfunction\b", source[match.end():])
    if end is None:
        fail("function has no endfunction")
    body = source[match.end():match.end() + end.start()]
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    return body


source = Path(sys.argv[1]).read_text(encoding="utf-8")

override = function_body(
    source,
    r"virtual\s+function\s+bit\s+handle_completion\s*\(\s*pcie_tl_cpl_tlp\s+cpl\s*\)\s*;",
)
override_contract = re.compile(
    r"^\s*if\s*\(\s*cosim_active\s*\)\s*"
    r"(?:begin\s*)?return\s+1\s*;\s*(?:end\s*)?"
    r"return\s+super\.handle_completion\s*\(\s*cpl\s*\)\s*;\s*$",
    flags=re.DOTALL,
)
if override_contract.fullmatch(override) is None:
    fail(
        "handle_completion must claim without consuming while cosim_active, "
        "and delegate to super before cosim activation"
    )
if override.count("super.handle_completion") != 1:
    fail("handle_completion override must contain exactly one pre-cosim super call")
for map_name in ("vip_tag_to_qemu_tag", "qemu_tag_to_vip_tag"):
    if map_name in override:
        fail(f"handle_completion override must not access {map_name}")

forward = function_body(
    source,
    r"protected\s+function\s+void\s+forward_completion_to_qemu\s*"
    r"\(\s*pcie_tl_cpl_tlp\s+cpl\s*\)\s*;",
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

print("[cosim-completion-ownership] PASS")
PY
