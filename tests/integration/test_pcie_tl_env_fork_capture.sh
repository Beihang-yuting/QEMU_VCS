#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
env_source="$repo/pcie_tl_vip/src/env/pcie_tl_env.sv"

python3 - "$env_source" <<'PY'
import re
import sys
from pathlib import Path


EXPECTED_CALLS = {
    "tlm_loopback_rc_to_ep": ("handle_request",),
    "tlm_loopback_ep_to_rc": ("handle_request", "rc_auto_respond"),
    "tlm_loopback_rc_to_ep_pair": ("handle_request",),
    "tlm_loopback_ep_to_rc_pair": ("handle_request",),
    "switch_to_rc_loopback": ("handle_request",),
    "switch_to_ep_loopback": ("handle_request",),
}
CALL = re.compile(
    r"\b(?P<callee>handle_request|rc_auto_respond)\s*"
    r"\(\s*(?P<argument>[A-Za-z_]\w*)\s*\)\s*;"
)


def without_comments(source: str) -> str:
    def preserve_lines(match) -> str:
        text = match.group(0)
        return "\n" * text.count("\n")

    source = re.sub(r"/\*.*?\*/", preserve_lines, source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", source)


def line_number(source: str, offset: int) -> int:
    return source.count("\n", 0, offset) + 1


def task_span(source: str, task_name: str):
    declaration = re.search(
        rf"\bprotected\s+task\s+{re.escape(task_name)}\s*\([^;]*\)\s*;",
        source,
    )
    if declaration is None:
        raise AssertionError(f"missing protected task {task_name}")
    terminator = re.search(r"\bendtask\b", source[declaration.end():])
    if terminator is None:
        raise AssertionError(f"task {task_name} has no endtask")
    return declaration.end(), declaration.end() + terminator.start()


source_path = Path(sys.argv[1])
source = without_comments(source_path.read_text(encoding="utf-8"))
errors = []
covered_calls = []

for task_name, expected in EXPECTED_CALLS.items():
    try:
        start, end = task_span(source, task_name)
    except AssertionError as error:
        errors.append(str(error))
        continue

    calls = list(CALL.finditer(source, start, end))
    found = tuple(call.group("callee") for call in calls)
    if found != expected:
        errors.append(
            f"{task_name}: expected async calls {expected}, found {found}"
        )
    covered_calls.extend(calls)

all_calls = list(CALL.finditer(source))
if len(all_calls) != 7:
    errors.append(
        "pcie_tl_env.sv must contain exactly seven handle_request/"
        f"rc_auto_respond call sites, found {len(all_calls)}"
    )
if {call.start() for call in covered_calls} != {call.start() for call in all_calls}:
    errors.append("not every production response call site is covered by the task map")

for call in covered_calls:
    callee = call.group("callee")
    argument = call.group("argument")
    line = line_number(source, call.start())
    prefix = source[:call.start()]
    forks = list(re.finditer(r"\bfork\b", prefix))
    if not forks:
        errors.append(f"line {line} {callee}: call is not inside a fork")
        continue
    fork = forks[-1]

    intervening_join = re.search(
        r"\b(?:join|join_any|join_none)\b", source[fork.end():call.start()]
    )
    next_join = re.search(
        r"\b(?P<kind>join|join_any|join_none)\b", source[call.end():]
    )
    if intervening_join is not None or next_join is None:
        errors.append(f"line {line} {callee}: call is not inside the nearest fork")
        continue
    if next_join.group("kind") != "join_none":
        errors.append(f"line {line} {callee}: response fork must use join_none")

    capture = re.search(
        r"\bautomatic\s+pcie_tl_tlp\s+(?P<name>[A-Za-z_]\w*)\s*"
        r"=\s*tlp\s*;\s*$",
        source[:fork.start()],
    )
    if capture is None:
        errors.append(
            f"line {line} {callee}: missing automatic TLP capture immediately "
            "before fork"
        )
    elif capture.group("name") != argument:
        errors.append(
            f"line {line} {callee}: fork captures {capture.group('name')}, "
            f"but child uses {argument}"
        )

    child_prefix = source[fork.end():call.start()]
    if re.search(
        rf"\b(?:automatic\s+)?pcie_tl_tlp\s+{re.escape(argument)}\s*=",
        child_prefix,
    ):
        errors.append(
            f"line {line} {callee}: TLP capture remains inside fork child"
        )

if errors:
    for error in errors:
        print(f"[pcie-env-fork-capture] FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)

print("[pcie-env-fork-capture] PASS: all 7 async response calls capture before fork")
PY
