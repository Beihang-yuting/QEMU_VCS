#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
xrc=${XRC_DRIVER:-"$repo/vcs-tb/cosim_xrc_driver.sv"}
adapter=${XILINX_ADAPTER:-"$repo/third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv"}

python3 - "$xrc" "$adapter" <<'PY'
import re
import sys
from pathlib import Path


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


source = Path(sys.argv[1]).read_text(encoding="utf-8")
adapter_source = Path(sys.argv[2]).read_text(encoding="utf-8")
build_phase = compact(block(
    source,
    r"virtual\s+function\s+void\s+build_phase\s*\(",
    "endfunction",
))
request = compact(block(
    source,
    r"protected\s+task\s+request_loop\s*\(\s*uvm_phase\s+phase\s*\)\s*;",
    "endtask",
))
build = compact(block(
    source,
    r"protected\s+function\s+pcie_tl_tlp\s+build_mmio_tlp\s*\(",
    "endfunction",
))
forward = compact(block(
    source,
    r"protected\s+function\s+void\s+forward_completion_to_qemu\s*\(",
    "endfunction",
))
whole = compact(source)

for declaration in (
    "pcie_tl_bar_decoderbar_decoder;",
    "bitconfig_bar_decode_enable;",
    "longintunsignedbar_decode_error_count[int];",
    "longintunsignedhost_requester_error_count;",
    "intdpi_requester_id;",
):
    if declaration not in whole:
        fail(f"driver missing per-RC state {declaration}")

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

topology = request.find("bar_decoder.decode(")
tag_map = request.find("pending_qemu_tag_by_inst[request_inst_id]=")
if topology < 0:
    fail("request_loop does not call bar_decoder.decode")
if tag_map < 0 or topology >= tag_map:
    fail("BAR decode must occur before pending QEMU/VIP tag-map allocation")

build_call = request.find("vip_tlp=build_mmio_tlp(")
if build_call < 0 or build_call >= topology:
    fail("BAR decode must run after successful build_mmio_tlp")

decode_window = request[topology:tag_map]
if "vip_tlp.cq_route=route;" not in decode_window:
    fail("successful BAR decode must attach cq_route to the VIP TLP")
for result in ("PCIE_BAR_DECODE_OVERLAP", "PCIE_BAR_DECODE_INVALID_CONFIG"):
    fatal = re.search(
        rf"decode_result=={result}.*?`uvm_fatal\(",
        decode_window,
    )
    if fatal is None:
        fail(f"{result} must be fatal before tag allocation")

decode_ur = re.findall(
    r"if\(dpi_type==BV_TLP_MRD\)begin.*?"
    r"bridge_vcs_send_cpl_scalar_status_rc\(rc_index,dpi_tag,0,"
    r"int'\(CPL_STATUS_UR\)\)",
    decode_window,
)
if len(decode_ur) != 1:
    fail("MRd decode failure must return exactly one zero-payload UR")
if decode_window.count("bridge_vcs_send_cpl_scalar_status_rc(") != 1:
    fail("posted MWr decode failure must not send a Completion")
if "#1;continue;" not in decode_window[:decode_window.find("ep_vf_mmio_write(")]:
    fail("decode failure must continue before doorbell or tag-map allocation")

doorbell = decode_window.find("ep_vf_mmio_write(")
route_assign = decode_window.find("vip_tlp.cq_route=route;")
if doorbell < 0 or doorbell <= route_assign:
    fail("stand-in MWr doorbell must be reached only after successful decode")
if "route.target_bdf" not in decode_window or "route.is_vf" not in decode_window:
    fail("stand-in MWr doorbell function selection must use the decoded route")
if "lookup_by_bdf(" in decode_window or "bridge_vcs_get_tlp_target_bdf_rc(" in decode_window[topology + len("bar_decoder.decode("):]:
    fail("post-decode routing must not fall back to target_bdf function lookup")

getter = request.find("dpi_requester_id=bridge_vcs_get_tlp_requester_id_rc(rc_index);")
ats = request.find("if(dpi_type==BV_TLP_ATS_INVAL)")
if getter < 0 or ats < 0 or getter >= ats:
    fail("ingress must fetch requester_id before ATS/config bypass")
requester_check = request[getter:ats]
for tlp_type in (
    "BV_TLP_CFGRD0", "BV_TLP_CFGWR0", "BV_TLP_MRD", "BV_TLP_MWR",
    "BV_TLP_ATS_INVAL",
):
    if tlp_type not in requester_check:
        fail(f"host requester validation omits {tlp_type}")
if "dpi_requester_id!=0" not in requester_check:
    fail("QEMU-originated requests must reject non-zero requester_id")
if "host_requester_error_count++" not in requester_check or "`uvm_error(" not in requester_check:
    fail("host requester rejection must be counted and reported")
if requester_check.count("bridge_vcs_send_cpl_scalar_status_rc(") != 1:
    fail("requester rejection must have one Completion path")
for completion_type in ("BV_TLP_CFGRD0", "BV_TLP_MRD", "BV_TLP_ATS_INVAL"):
    if completion_type not in requester_check:
        fail(f"requester rejection Completion policy omits {completion_type}")
if "int'(CPL_STATUS_UR)" not in requester_check:
    fail("requester rejection Completion must carry UR")
if "total_tlp_count++;" not in requester_check or "continue;" not in requester_check:
    fail("requester rejection must account and continue before all bypasses")

signature = build.split(");", 1)[0]
if "inputbit[15:0]requester_id" not in signature:
    fail("build_mmio_tlp must take the ingress requester_id explicitly")
if build.count("m.requester_id=requester_id;") != 2:
    fail("build_mmio_tlp must set requester_id on both MRd and MWr")
if "dpi_requester_id[15:0]" not in request[build_call:topology]:
    fail("build_mmio_tlp call must pass the validated DPI requester_id")

status_send = (
    "bridge_vcs_send_cpl_scalar_status_rc(rc_index,qemu_tag,1,"
    "int'(cpl.cpl_status))"
)
if status_send not in forward:
    fail("DUT Completion forwarding must preserve cpl.cpl_status")
if "bridge_vcs_send_cpl_scalar_rc(" in forward:
    fail("DUT Completion forwarding must not force SC through the legacy wrapper")

for hardcoded in (
    ".bar_id(0)", ".bar_aperture(0)", ".target_func(0)",
    ".bar_id(3'h0)", ".bar_aperture(6'h0)", ".target_func(8'h0)",
):
    if hardcoded in compact(adapter_source):
        fail(f"Xilinx CQ adapter still hard-codes {hardcoded}")

if "bar_decode_error_count" not in compact(block(
    source,
    r"virtual\s+function\s+void\s+report_phase\s*\(",
    "endfunction",
)):
    fail("report_phase must print BAR decode error counters")

print("[cq-bar-routing-source] PASS")
PY
