#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="$repo/qemu-plugin/cosim_pcie_rc.c"
hdr="$repo/qemu-plugin/cosim_pcie_rc.h"

fail() { echo "[qemu-wait-gate] FAIL: $*" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "missing '$1' in ${2#$repo/}"; }

require '#include "sysemu/cpu-timers.h"' "$src"
require '#include "sysemu/runstate.h"' "$src"
require 'cpu_disable_ticks();' "$src"
require 'cpu_enable_ticks();' "$src"
require 'runstate_is_running()' "$src"
require 'icount_enabled()' "$src"
require 'bridge_set_wait_hooks(ctx,' "$src"
require 'vcs_wait_depth' "$hdr"
require 'vcs_wait_ticks_owned' "$hdr"

realize_body="$(sed -n '/static void cosim_pcie_rc_realize/,/^}/p' "$src")"
register_line="$(grep -nF 'bridge_set_wait_hooks(ctx,' <<<"$realize_body" | head -1 | cut -d: -f1)"
realized_line="$(grep -nF 'SYNC_MSG_REALIZED' <<<"$realize_body" | tail -1 | cut -d: -f1)"
[[ -n "$register_line" && -n "$realized_line" && "$register_line" -lt "$realized_line" ]] ||
    fail "wait hooks must be registered before the final REALIZED message"

exit_body="$(sed -n '/static void cosim_pcie_rc_exit(PCIDevice \*pci_dev)$/,/^}/p' "$src")"
[[ "$exit_body" == *'bridge_set_wait_hooks('*'NULL, NULL, NULL);'* ]] ||
    fail "PF0 exit must clear bridge wait hooks before bridge destruction"

echo "[qemu-wait-gate] PASS"
