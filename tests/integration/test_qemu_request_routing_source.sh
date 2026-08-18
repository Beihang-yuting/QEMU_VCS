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

# The table adapter must publish one read-only PF0 snapshot namespace keyed by
# the configured RC instance.  It may project the authoritative PF BAR
# contexts, but it must not grow a second PF/VF topology array beside g_rc_pfs.
if '#include "table_target.h"' not in header:
    fail("CosimPCIeRC must use the QEMU-independent table target snapshot type")
if not re.search(
    r"bool\s+cosim_pcie_rc_get_table_target\s*\(\s*uint32_t\s+instance_id\s*,"
    r"\s*cosim_table_target_snapshot_t\s*\*\s*snapshot\s*\)\s*;",
    header,
    flags=re.S,
):
    fail("cosim_pcie_rc.h must export the read-only instance-keyed snapshot API")

pf_arrays = re.findall(
    r"static\s+CosimPCIeRC\s*\*\s*[A-Za-z_][A-Za-z0-9_]*\s*\["
    r"[^\]]*(?:PF|PFS)[^\]]*\]",
    source,
)
if len(pf_arrays) != 1 or "g_rc_pfs" not in pf_arrays[0]:
    fail("g_rc_pfs must remain the only PF/VF topology pointer array")
if not re.search(
    r"static\s+CosimPCIeRC\s*\*\s*g_table_target_registry\s*;", source
):
    fail("table snapshots must use one PF0 linked registry, not another topology array")

getter = function_body("cosim_pcie_rc_get_table_target")
require(getter, "instance_id", "cosim_pcie_rc_get_table_target")
require(getter, "instance_id > UINT16_MAX", "cosim_pcie_rc_get_table_target")
require(getter, "entry->instance_id == instance_id",
        "cosim_pcie_rc_get_table_target")
require(getter, "*snapshot", "cosim_pcie_rc_get_table_target")
require(getter, "table_target_snapshot", "cosim_pcie_rc_get_table_target")

publish = function_body("cosim_table_target_publish")
require(publish, "s->pf_index != 0", "cosim_table_target_publish")
require(publish, "s->instance_id > UINT16_MAX", "cosim_table_target_publish")
require(publish, "s->instance_id", "cosim_table_target_publish")
require(publish, "snapshot.rc_id = (uint16_t)s->instance_id",
        "cosim_table_target_publish")
require(publish, "snapshot.device_instance = 0",
        "cosim_table_target_publish")
require(publish, "existing->instance_id == s->instance_id",
        "cosim_table_target_publish")
domain = function_body("cosim_current_pci_domain")
require(domain, "pci_root_bus_path(pci_dev)", "cosim_current_pci_domain")
require(publish, "cosim_current_pci_domain(pci_dev)",
        "cosim_table_target_publish")
require(publish, "cosim_current_bdf(pci_dev)", "cosim_table_target_publish")
require(publish, "physical_bar", "cosim_table_target_publish")
require(publish, "s->bar_ctx[physical_bar].dev != s", "cosim_table_target_publish")
require(publish, "memory_region_size(&s->bars[physical_bar])",
        "cosim_table_target_publish")
require(publish, "bar_sizes[physical_bar]",
        "cosim_table_target_publish")

require(realize, "cosim_table_target_publish(s, pci_dev);",
        "cosim_pcie_rc_realize")
reset = function_body("cosim_pcie_rc_reset")
require(reset, "cosim_table_target_publish(s, pci_dev);", "cosim_pcie_rc_reset")

device_exit = function_body("cosim_pcie_rc_exit")
require(device_exit, "cosim_table_target_remove(s);", "cosim_pcie_rc_exit")
if device_exit.find("cosim_table_target_remove(s);") > device_exit.find(
    "bridge_destroy(ctx);"
):
    fail("PF0 table snapshot must be removed before its bridge is destroyed")

class_init = function_body("cosim_pcie_rc_class_init")
require(class_init,
        "device_class_set_legacy_reset(dc, cosim_pcie_rc_reset);",
        "cosim_pcie_rc_class_init")
forbid(class_init, "dc->legacy_reset = cosim_pcie_rc_reset;",
       "cosim_pcie_rc_class_init")

print("[qemu-request-routing] PASS")
PY
