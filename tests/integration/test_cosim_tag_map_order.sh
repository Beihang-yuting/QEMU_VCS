#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
base="$repo/pcie_tl_vip/src/agent/pcie_tl_base_driver.sv"
xrc="$repo/vcs-tb/cosim_xrc_driver.sv"

fail() { echo "[cosim-tag-map-order] FAIL: $*" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "missing '$1' in ${2#$repo/}"; }

require 'virtual function void on_tag_assigned(pcie_tl_tlp tlp);' "$base"
require 'on_tag_assigned(tlp);' "$base"
require 'pending_qemu_tag_by_inst' "$xrc"
require 'virtual function void on_tag_assigned(pcie_tl_tlp tlp);' "$xrc"

hook_line=$(grep -nF 'on_tag_assigned(tlp);' "$base" | head -1 | cut -d: -f1)
send_line=$(grep -nF 'adapter.send(tlp);' "$base" | head -1 | cut -d: -f1)
if (( hook_line >= send_line )); then
    fail "tag-assigned hook must run before adapter.send"
fi

map_line=$(grep -nF "vip_tag_to_qemu_tag[int'(tlp.tag)] =" "$xrc" | head -1 | cut -d: -f1)
send_line=$(grep -nF 'send_tlp(vip_tlp);' "$xrc" | head -1 | cut -d: -f1)
if (( map_line >= send_line )); then
    fail "QEMU/VIP tag map is still created after send_tlp"
fi

echo "[cosim-tag-map-order] PASS"
