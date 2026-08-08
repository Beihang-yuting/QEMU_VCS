#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
xrc=${XRC_DRIVER:-"$repo/vcs-tb/cosim_xrc_driver.sv"}
adapter=${XILINX_ADAPTER:-"$repo/third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv"}

python3 - "$xrc" "$adapter" <<'PY'
import re
import sys
from pathlib import Path
from typing import Set, Tuple


def fail(message: str) -> None:
    print(f"[cq-bar-routing-source] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def without_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


def compact(text: str) -> str:
    return re.sub(r"\s+", "", without_comments(text))


def block(source: str, declaration: str, terminator: str) -> str:
    start = re.search(declaration, source)
    if start is None:
        fail(f"missing block matching {declaration!r}")
    end = re.search(rf"\b{terminator}\b", source[start.end():])
    if end is None:
        fail(f"block matching {declaration!r} has no {terminator}")
    return source[start.end():start.end() + end.start()]


def parsed_if(source: str, search_from: int = 0) -> Tuple[str, str, int, int]:
    match = re.search(r"\bif\s*\(", source[search_from:])
    if match is None:
        fail("expected if statement was not found")
    if_start = search_from + match.start()
    open_paren = source.find("(", if_start)
    depth = 0
    close_paren = -1
    for pos in range(open_paren, len(source)):
        if source[pos] == "(":
            depth += 1
        elif source[pos] == ")":
            depth -= 1
            if depth == 0:
                close_paren = pos
                break
    if close_paren < 0:
        fail("if condition has unbalanced parentheses")
    begin = re.match(r"\s*begin\b", source[close_paren + 1:])
    if begin is None:
        fail("contract if statement must use begin/end")
    body_start = close_paren + 1 + begin.end()
    depth = 1
    body_end = -1
    end_pos = -1
    for token in re.finditer(r"\b(begin|end)\b", source[body_start:]):
        if token.group(1) == "begin":
            depth += 1
        else:
            depth -= 1
            if depth == 0:
                body_end = body_start + token.start()
                end_pos = body_start + token.end()
                break
    if body_end < 0:
        fail("if statement has unbalanced begin/end")
    return source[open_paren + 1:close_paren], source[body_start:body_end], if_start, end_pos


def predicate_types(condition: str) -> Set[str]:
    return set(re.findall(r"dpi_type\s*==\s*(BV_TLP_[A-Z0-9_]+)", condition))


source = Path(sys.argv[1]).read_text(encoding="utf-8")
adapter_source = Path(sys.argv[2]).read_text(encoding="utf-8")
clean_source = without_comments(source)
build_phase_raw = block(
    source,
    r"virtual\s+function\s+void\s+build_phase\s*\(",
    "endfunction",
)
request_raw = block(
    source,
    r"protected\s+task\s+request_loop\s*\(\s*uvm_phase\s+phase\s*\)\s*;",
    "endtask",
)
build_raw = block(
    source,
    r"protected\s+function\s+pcie_tl_tlp\s+build_mmio_tlp\s*\(",
    "endfunction",
)
forward_raw = block(
    source,
    r"protected\s+function\s+void\s+forward_completion_to_qemu\s*\(",
    "endfunction",
)
report_raw = block(
    source,
    r"virtual\s+function\s+void\s+report_phase\s*\(",
    "endfunction",
)
build_phase = compact(build_phase_raw)
request = compact(request_raw)
build = compact(build_raw)
forward = compact(forward_raw)
report = compact(report_raw)
adapter = compact(adapter_source)

# These members belong to one cosim_xrc_driver instance (one RC). A static
# mutation silently shares decoder policy, counters, or DPI scratch across RCs.
per_rc_declarations = (
    (r"pcie_tl_bar_decoder\s+bar_decoder\s*;", "bar_decoder"),
    (r"bit\s+config_bar_decode_enable\s*;", "config_bar_decode_enable"),
    (r"longint\s+unsigned\s+bar_decode_error_count\s*\[\s*int\s*\]\s*;", "bar_decode_error_count"),
    (r"longint\s+unsigned\s+host_requester_error_count\s*;", "host_requester_error_count"),
    (r"int\s+dpi_requester_id\s*;", "dpi_requester_id"),
)
for declaration, name in per_rc_declarations:
    matches = list(re.finditer(
        rf"(?m)^[ \t]*(?P<mods>(?:(?:static|local|protected)\s+)*){declaration}",
        clean_source,
    ))
    if len(matches) != 1:
        fail(f"driver must declare exactly one per-RC {name}")
    if "static" in matches[0].group("mods").split():
        fail(f"per-RC field {name} must not be static")

topology_build = build_phase.find("func_mgr.build_topology(")
decoder_create = build_phase.find(
    'bar_decoder=pcie_tl_bar_decoder::type_id::create("bar_decoder");'
)
decoder_bind = build_phase.find("bar_decoder.func_mgr=func_mgr;")
if topology_build < 0 or decoder_create <= topology_build or decoder_bind <= decoder_create:
    fail("each RC must create and bind its BAR decoder after build_topology")
enable = (
    "config_bar_decode_enable=real_dut||cfg_profile!="
    "pcie_tl_device_profile_pkg::PCIE_CFG_PROFILE_LEGACY;"
)
if enable not in build_phase:
    fail("BAR decode enable policy must cover REAL_DUT and non-legacy profiles")

build_call = request.find("vip_tlp=build_mmio_tlp(")
decode_call = request.find("bar_decoder.decode(")
tag_map = request.find("pending_qemu_tag_by_inst[request_inst_id]=")
if build_call < 0 or decode_call < 0 or tag_map < 0:
    fail("request_loop is missing build, decode, or tag-map stages")
if not build_call < decode_call < tag_map:
    fail("request path must be build -> decode -> tag-map")

# LEGACY is a separate stand-in compatibility path. It must be impossible to
# reach from an enabled decode failure, which continues before this block.
legacy_guard = "if(!config_bar_decode_enable&&!real_dut&&dpi_type==BV_TLP_MWR)begin"
legacy = request.find(legacy_guard)
if legacy < 0 or not decode_call < legacy < tag_map:
    fail("LEGACY VF doorbell fallback must be guarded after decode and before tag-map")
legacy_window = request[legacy:tag_map]
for required in (
    "bridge_vcs_get_tlp_target_bdf_rc(rc_index)",
    "func_mgr.lookup_by_bdf(",
    "legacy_ctx.is_vf",
    "ep_vf_mmio_write(",
):
    if required not in legacy_window:
        fail(f"LEGACY VF doorbell fallback missing {required}")
if "route.target_bdf" in legacy_window or "route.is_vf" in legacy_window:
    fail("LEGACY fallback must use target_bdf lookup, not a decoded route")

pre_decode = request[build_call:decode_call]
if "lookup_by_bdf(" in pre_decode or "bridge_vcs_get_tlp_target_bdf_rc(" in pre_decode:
    fail("build-to-decode path must not pre-route with lookup or target hint")
decode_end = request.find(");", decode_call)
if decode_end < 0:
    fail("BAR decoder call has no terminator")
decode_invocation = request[decode_call:decode_end]
if "bridge_vcs_get_tlp_target_bdf_rc(rc_index)" not in decode_invocation:
    fail("BAR decoder must receive the target BDF cross-check inline")
if request[decode_call:legacy].count("lookup_by_bdf(") != 0:
    fail("config-driven routing must not use BDF lookup")
if request[decode_call:tag_map].count("lookup_by_bdf(") != 1:
    fail("only the guarded LEGACY path may use lookup_by_bdf")
if request[decode_call:tag_map].count("bridge_vcs_get_tlp_target_bdf_rc(rc_index)") != 2:
    fail("target BDF hint must appear only in decode and guarded LEGACY fallback")

decode_assignment = request_raw.find("decode_result = bar_decoder.decode(")
if decode_assignment < 0:
    fail("missing BAR decode assignment")
decode_condition, _, _, _ = parsed_if(request_raw, decode_assignment)
if compact(decode_condition) != "decode_result==PCIE_BAR_DECODE_OK":
    fail("decode success must be exactly PCIE_BAR_DECODE_OK")

decode_window = request[decode_call:tag_map]
if "vip_tlp.cq_route=route;" not in decode_window:
    fail("successful BAR decode must attach cq_route to the VIP TLP")
for result in ("PCIE_BAR_DECODE_OVERLAP", "PCIE_BAR_DECODE_INVALID_CONFIG"):
    if re.search(rf"decode_result=={result}.*?`uvm_fatal\(", decode_window) is None:
        fail(f"{result} must be fatal before tag allocation")
decode_ur = re.findall(
    r"if\(dpi_type==BV_TLP_MRD\)begin.*?"
    r"bridge_vcs_send_cpl_scalar_status_rc\(rc_index,dpi_tag,0,"
    r"int'\(CPL_STATUS_UR\)\)",
    decode_window,
)
if len(decode_ur) != 1 or decode_window.count("bridge_vcs_send_cpl_scalar_status_rc(") != 1:
    fail("decode failure must send exactly one MRd UR and no posted-MWr Completion")

decoded_doorbell = request.find(
    "if(!real_dut&&dpi_type==BV_TLP_MWR&&route.valid&&route.is_vf)begin",
    decode_call,
)
failure_continue = request.find("#1;continue;", decode_call)
route_assign = request.find("vip_tlp.cq_route=route;", decode_call)
if decoded_doorbell < 0 or not route_assign < decoded_doorbell < legacy:
    fail("config-driven VF doorbell must use the valid decoded route")
if failure_continue < 0 or not failure_continue < decoded_doorbell < legacy:
    fail("decode failure must continue before decoded or LEGACY doorbells")
decoded_window = request[decoded_doorbell:legacy]
if "route.target_bdf" not in decoded_window or "ep_vf_mmio_write(" not in decoded_window:
    fail("decoded doorbell must select its function from route.target_bdf")

# Parse the host rejection predicate and its nested UR predicate independently.
getter = re.search(
    r"dpi_requester_id\s*=\s*bridge_vcs_get_tlp_requester_id_rc\s*\(\s*rc_index\s*\)\s*;",
    request_raw,
)
if getter is None:
    fail("ingress does not fetch requester_id")
outer_condition, outer_body, _, _ = parsed_if(request_raw, getter.end())
outer_expected = {
    "BV_TLP_CFGRD0", "BV_TLP_CFGWR0", "BV_TLP_MRD", "BV_TLP_MWR",
    "BV_TLP_ATS_INVAL",
}
if predicate_types(outer_condition) != outer_expected or "dpi_requester_id!=0" not in compact(outer_condition):
    fail("outer requester rejection predicate has the wrong exact TLP set")
inner_condition, _, _, _ = parsed_if(outer_body)
inner_expected = {"BV_TLP_CFGRD0", "BV_TLP_MRD", "BV_TLP_ATS_INVAL"}
if predicate_types(inner_condition) != inner_expected:
    fail("inner requester UR predicate must be exactly CFGRD0/MRD/ATS")
outer_compact = compact(outer_body)
if "host_requester_error_count++;" not in outer_compact or "`uvm_error(" not in outer_compact:
    fail("host requester rejection must be counted and reported")
if outer_compact.count("bridge_vcs_send_cpl_scalar_status_rc(") != 1:
    fail("requester rejection must have exactly one Completion path")
if "int'(CPL_STATUS_UR)" not in outer_compact:
    fail("requester rejection Completion must carry UR")
if "total_tlp_count++;" not in outer_compact or "continue;" not in outer_compact:
    fail("requester rejection must account and continue before bypasses")

signature = build.split(");", 1)[0]
if "inputbit[15:0]requester_id" not in signature:
    fail("build_mmio_tlp must take requester_id explicitly")
if build.count("m.requester_id=requester_id;") != 2:
    fail("build_mmio_tlp must set requester_id on both MRd and MWr")
if "dpi_requester_id[15:0]" not in request[build_call:decode_call]:
    fail("build_mmio_tlp call must pass the validated requester_id")

status_send = (
    "bridge_vcs_send_cpl_scalar_status_rc(rc_index,qemu_tag,1,"
    "int'(cpl.cpl_status))"
)
if status_send not in forward or "bridge_vcs_send_cpl_scalar_rc(" in forward:
    fail("DUT Completion forwarding must preserve cpl.cpl_status")

for field, width in (
    ("bar_id", "3'h0"),
    ("bar_aperture", "6'h0"),
    ("target_func", "8'h0"),
):
    exact = f".{field}(route.valid?route.{field}:{width})"
    if exact not in adapter:
        fail(f"Xilinx CQ adapter valid branch must use route.{field}")

if "host_requester_error_count" not in report:
    fail("report_phase must print host requester errors")
if "bar_decode_error_count" not in report:
    fail("report_phase must print BAR decode error counters")

print("[cq-bar-routing-source] PASS")
PY
