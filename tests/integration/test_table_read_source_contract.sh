#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$repo" <<'PY'
from pathlib import Path
import re
import sys

repo = Path(sys.argv[1])
rc_source = (repo / "qemu-plugin/cosim_pcie_rc.c").read_text()
ctrl_source = (repo / "qemu-plugin/cosim_table_ctrl.c").read_text()
ctrl_header = (repo / "qemu-plugin/cosim_table_ctrl.h").read_text()


def fail(message):
    raise SystemExit(f"[table-read-source] FAIL: {message}")


def function_body(source, name):
    match = re.search(r"\b" + re.escape(name) + r"\s*\([^;]*?\)\s*\{", source,
                      re.S)
    if match is None:
        fail(f"cannot find function {name}")
    opening = source.find("{", match.start())
    depth = 1
    state = "code"
    index = opening + 1
    while index < len(source) and depth:
        char = source[index]
        nxt = source[index:index + 2]
        if state == "code":
            if nxt == "//":
                state = "line_comment"
                index += 2
                continue
            if nxt == "/*":
                state = "block_comment"
                index += 2
                continue
            if char == '"':
                state = "string"
            elif char == "'":
                state = "char"
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
        elif state == "line_comment":
            if char == "\n":
                state = "code"
        elif state == "block_comment":
            if nxt == "*/":
                state = "code"
                index += 2
                continue
        elif state in ("string", "char"):
            if char == "\\":
                index += 2
                continue
            if (state == "string" and char == '"') or (
                    state == "char" and char == "'"):
                state = "code"
        index += 1
    if depth:
        fail(f"unterminated function {name}")
    return source[opening + 1:index - 1]


def require(text, needle, context):
    if needle not in text:
        fail(f"{context} must contain {needle}")


def compact(text):
    return re.sub(r"\s+", "", text)


header = compact(ctrl_header)
require(header,
        "cosim_table_status_tcosim_table_ctrl_try_read(uint16_trc_id,"
        "uint16_tdevice_instance,constcosim_table_target_t*target,"
        "uint64_taligned_bar_offset,uint32_t*returned_dword);",
        "controller public header")

read = function_body(rc_source, "cosim_mmio_read")
for token in ("cosim_pcie_rc_get_table_target", "cosim_table_decode_read",
              "cosim_table_ctrl_try_read", "cosim_table_extract_read"):
    require(read, token, "cosim_mmio_read")
lookup = read.find("cosim_table_ctrl_try_read")
frontdoor = read.find("cosim_mmio_do_read")
if lookup < 0 or frontdoor < 0 or lookup >= frontdoor:
    fail("cosim_mmio_read must try the table path before frontdoor forwarding")
for status in ("COSIM_TABLE_ST_SUCCESS", "COSIM_TABLE_ST_NOT_READY",
               "COSIM_TABLE_ST_NO_ROUTE", "COSIM_TABLE_ST_UNSUPPORTED",
               "COSIM_TABLE_ST_TIMEOUT", "COSIM_TABLE_ST_TARGET_GONE",
               "COSIM_TABLE_ST_PROTOCOL", "COSIM_TABLE_ST_UNKNOWN",
               "COSIM_TABLE_ST_EXEC_ERROR"):
    require(read, status, "cosim_mmio_read")
if "size == 8" not in read and "size != 8" not in read:
    fail("cosim_mmio_read must explicitly bypass table lookup for 8-byte reads")

write = function_body(rc_source, "cosim_mmio_write")
require(write, "cosim_mmio_do_write(s, pcie_addr, target_bdf, val, size);",
        "cosim_mmio_write")
if re.search(r"(?:cosim_)?table", write, re.I):
    fail("cosim_mmio_write must contain zero table references")

try_read = function_body(ctrl_source, "cosim_table_ctrl_try_read")
for token in ("cosim_pcie_rc_get_table_target", "cosim_table_target_matches",
              "COSIM_TABLE_OP_READ_DWORD", "COSIM_TABLE_OP_WRITE",
              "cosim_table_client_read_dword",
              "cosim_table_ctrl_lifecycle_complete_rpc"):
    require(try_read, token, "cosim_table_ctrl_try_read")
require(try_read, "COSIM_TABLE_ST_NOT_READY", "cosim_table_ctrl_try_read")
require(try_read, "COSIM_TABLE_ST_TARGET_GONE", "cosim_table_ctrl_try_read")
require(try_read, "COSIM_TABLE_ST_NO_ROUTE", "cosim_table_ctrl_try_read")
require(try_read, "COSIM_TABLE_ST_UNSUPPORTED", "cosim_table_ctrl_try_read")

realize = function_body(ctrl_source, "cosim_table_ctrl_realize")
exit_body = function_body(ctrl_source, "cosim_table_ctrl_exit")
require(realize, "cosim_table_ctrl_registry_add", "controller realize")
require(exit_body, "cosim_table_ctrl_registry_remove", "controller exit")

print("PASS: eligible PF0 table read source contract")
PY
