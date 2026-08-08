#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="$repo/qemu-plugin/cosim_pcie_rc.c"
hdr="$repo/qemu-plugin/cosim_pcie_rc.h"

python3 - "$src" "$hdr" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
header = Path(sys.argv[2]).read_text()


def fail(message):
    print(f"[qemu-request-routing] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def skip_space_and_comments(pos):
    while pos < len(source):
        if source[pos].isspace():
            pos += 1
        elif source.startswith("//", pos):
            newline = source.find("\n", pos + 2)
            pos = len(source) if newline < 0 else newline + 1
        elif source.startswith("/*", pos):
            end = source.find("*/", pos + 2)
            if end < 0:
                fail("unterminated block comment")
            pos = end + 2
        else:
            break
    return pos


def matching_delimiter(pos, opener, closer):
    depth = 0
    state = "code"
    i = pos
    while i < len(source):
        ch = source[i]
        nxt = source[i:i + 2]
        if state == "code":
            if nxt == "//":
                state = "line_comment"
                i += 2
                continue
            if nxt == "/*":
                state = "block_comment"
                i += 2
                continue
            if ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == opener:
                depth += 1
            elif ch == closer:
                depth -= 1
                if depth == 0:
                    return i
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
        elif state == "block_comment":
            if nxt == "*/":
                state = "code"
                i += 2
                continue
        elif state in ("string", "char"):
            if ch == "\\":
                i += 2
                continue
            if (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "code"
        i += 1
    fail(f"unmatched {opener} starting at byte {pos}")


def function_parts(name):
    for match in re.finditer(rf"\b{re.escape(name)}\s*\(", source):
        open_paren = source.find("(", match.start())
        close_paren = matching_delimiter(open_paren, "(", ")")
        body_open = skip_space_and_comments(close_paren + 1)
        if body_open < len(source) and source[body_open] == "{":
            body_close = matching_delimiter(body_open, "{", "}")
            return (source[match.start():body_open],
                    source[body_open + 1:body_close])
    fail(f"cannot locate function body for {name}")


def function_body(name):
    return function_parts(name)[1]


def require(body, needle, where):
    if needle not in body:
        fail(f"{where} missing {needle!r}")


def forbid(body, needle, where):
    if needle in body:
        fail(f"{where} must not contain {needle!r}")


def compact_code(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r"\s+", "", text)


def brace_depth_at(text, stop):
    depth = 0
    state = "code"
    i = 0
    while i < stop:
        ch = text[i]
        nxt = text[i:i + 2]
        if state == "code":
            if nxt == "//":
                state = "line_comment"
                i += 2
                continue
            if nxt == "/*":
                state = "block_comment"
                i += 2
                continue
            if ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
        elif state == "block_comment":
            if nxt == "*/":
                state = "code"
                i += 2
                continue
        elif state in ("string", "char"):
            if ch == "\\":
                i += 2
                continue
            if (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "code"
        i += 1
    return depth


current_bdf = compact_code(function_body("cosim_current_bdf"))
expected_bdf = (
    "returncosim_pcie_bdf((uint8_t)pci_bus_num(pci_get_bus(dev)),"
    "dev->devfn);"
)
if current_bdf != expected_bdf:
    fail("cosim_current_bdf must pass the live bus and full 8-bit devfn "
         "directly to the tested cosim_pcie_bdf helper")


for callback in ("cosim_mmio_read", "cosim_mmio_write"):
    body = function_body(callback)
    require(body, "cosim_current_bdf(PCI_DEVICE(bc->dev))", callback)
    forbid(body, "bc->target_bdf", callback)

for forwarder in ("cosim_mmio_do_read", "cosim_mmio_do_write"):
    body = function_body(forwarder)
    require(body, "cosim_route_host_to_device(&req, target_bdf);", forwarder)

config_read = function_body("cosim_config_read")
if config_read.count("cosim_route_host_to_device(") != 2:
    fail("cosim_config_read must route both the first probe and normal CfgRd")
require(config_read,
        "cosim_route_host_to_device(&probe_req, cosim_current_bdf(pci_dev));",
        "cosim_config_read")
require(config_read,
        "cosim_route_host_to_device(&req, cosim_current_bdf(pci_dev));",
        "cosim_config_read")

config_write = function_body("cosim_config_write")
require(config_write,
        "cosim_route_host_to_device(&req, cosim_current_bdf(pci_dev));",
        "cosim_config_write")

for legacy in ("cosim_cfgrd", "cosim_cfgwr"):
    signature, body = function_parts(legacy)
    require(signature, "uint16_t target_bdf", legacy)
    require(body, "cosim_route_host_to_device(&req, target_bdf);", legacy)

for vf_fn in ("cosim_rc_vf_config_read", "cosim_rc_vf_config_write"):
    body = function_body(vf_fn)
    require(body, "cosim_route_host_to_device(&req, vf->vf_bdf);", vf_fn)

invalidate = function_body("cosim_vf_invalidate_atc")
require(invalidate,
        "cosim_route_host_to_device(&req, ima[i].vf_bdf);",
        "cosim_vf_invalidate_atc")

aliases = re.findall(
    r"requester_id\s*=\s*(?:req\.)?(?:target_bdf|vf_bdf|pf_bdf|vf->vf_bdf)",
    source,
)
if aliases:
    fail(f"host requester/target alias remains: {aliases[0]}")

dma = function_body("cosim_dma_cb")
require(dma, "req->requester_id", "cosim_dma_cb")
forbid(dma, "cosim_route_host_to_device", "cosim_dma_cb")

mmio_read = function_body("cosim_mmio_do_read")
decode_call = "cosim_cpl_value_decode(cpl.status, cpl.data, size, &val)"
if mmio_read.count(decode_call) != 1:
    fail("cosim_mmio_do_read must call cosim_cpl_value_decode exactly once")
decode_pos = mmio_read.find(decode_call)
if brace_depth_at(mmio_read, decode_pos) != 0:
    fail("cosim_mmio_do_read completion decode must be unconditional, not nested")
require(
        compact_code(mmio_read),
        "uint64_tval;"
        "boolcpl_success=cosim_cpl_value_decode(cpl.status,cpl.data,size,&val);"
        "if(!cpl_success){",
        "cosim_mmio_do_read")
forbid(mmio_read, "cosim_cpl_status_is_success", "cosim_mmio_do_read")
forbid(mmio_read, "cpl.data[", "cosim_mmio_do_read")
require(mmio_read, "++s->mmio_cpl_error_count", "cosim_mmio_do_read")
require(mmio_read, "error_count <= 8", "cosim_mmio_do_read")
require(mmio_read, "error_count % 1024 == 0", "cosim_mmio_do_read")
require(mmio_read, "return val;", "cosim_mmio_do_read")

if "uint64_t mmio_cpl_error_count;" not in header:
    fail("CosimPCIeRC must track MMIO completion errors")

query_bar = function_body("cosim_query_bar_size")
if query_bar.count("target_bdf") != 4:
    fail("cosim_query_bar_size must pass its live PF target to every legacy CfgRd/CfgWr")

discover = function_body("cosim_discover_caps")
if discover.count("target_bdf") != 3:
    fail("cosim_discover_caps must pass its live PF target to every legacy CfgRd")

realize = function_body("cosim_pcie_rc_realize")
require(realize, "cosim_current_bdf(pci_dev)", "cosim_pcie_rc_realize")

print("[qemu-request-routing] PASS")
PY
