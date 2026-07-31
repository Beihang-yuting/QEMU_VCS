#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
makefile="$project_dir/Makefile"
xrc_driver=${XRC_DRIVER:-"$project_dir/vcs-tb/cosim_xrc_driver.sv"}
qemu_rc="$project_dir/qemu-plugin/cosim_pcie_rc.c"

require_profile_pattern() {
    local description=$1
    local pattern=$2

    if ! [[ "$profile_build_phase" =~ $pattern ]]; then
        echo "FAIL: VCS profile build_phase lacks executable $description" >&2
        exit 1
    fi
}

require_dpu_profile_pattern() {
    local description=$1
    local pattern=$2

    if ! [[ "$dpu_profile_block" =~ $pattern ]]; then
        echo "FAIL: VCS DPU profile branch lacks executable $description" >&2
        exit 1
    fi
}

verify_pcie_pkg_filelist() {
    local filelist=$1

    # Filelists treat whole-line // and # entries as comments. Count only
    # active source lines, with exact package basenames, before checking order.
    if ! awk '
        /^[[:space:]]*($|\/\/|#)/ { next }
        /(^|\/)pcie_tl_bdf_utils_pkg\.sv[[:space:]]*$/ {
            bdf_count++; bdf_line = NR
        }
        /(^|\/)pcie_tl_device_profile_pkg\.sv[[:space:]]*$/ {
            profile_count++; profile_line = NR
        }
        /(^|\/)pcie_tl_pkg\.sv[[:space:]]*$/ {
            pkg_count++; pkg_line = NR
        }
        END {
            if (bdf_count != 1 || profile_count != 1 || pkg_count != 1)
                exit 1
            if (bdf_line >= profile_line || profile_line >= pkg_line)
                exit 2
        }
    ' "$filelist" >/dev/null 2>&1; then
        echo "FAIL: $filelist must contain each pcie_tl helper and pcie_tl_pkg exactly once" >&2
        exit 1
    fi
}

verify_pref64_reserve_dry_run() {
    local console=$1
    local dry_run_output
    local root_port_lines

    if ! dry_run_output=$(make -C "$project_dir" --no-print-directory -n run-qemu \
            "CONSOLE=$console" NUM_RC=2 PCIE_PREF64_RESERVE=512M 2>&1); then
        echo "FAIL: $console dry run with PCIE_PREF64_RESERVE=512M failed" >&2
        exit 1
    fi

    root_port_lines=$(printf '%s\n' "$dry_run_output" |
        grep -F -- '-device "pcie-root-port' || true)
    if [[ $(printf '%s\n' "$root_port_lines" | sed '/^$/d' | wc -l) -ne 1 ]]; then
        echo "FAIL: $console dry run does not emit exactly one cosim Root Port" >&2
        exit 1
    fi
    if [[ "$root_port_lines" != *'mem-reserve=64M,pref64-reserve=$PCIE_PREF64_RESERVE"'* ]]; then
        echo "FAIL: $console dry run does not use the exported pref64 reserve in its Root Port" >&2
        exit 1
    fi
}

cosim_count=$(grep -c -- '-device "cosim-pcie-rc' "$makefile")
root_port_count=$(grep -c -- '-device "pcie-root-port' "$makefile" || true)

if [[ "$cosim_count" -eq 0 ]]; then
    echo "FAIL: no cosim-pcie-rc launch found in Makefile" >&2
    exit 1
fi

if [[ "$root_port_count" -ne "$cosim_count" ]]; then
    echo "FAIL: expected one Root Port per cosim launch ($cosim_count), found $root_port_count" >&2
    exit 1
fi

previous=""
while IFS= read -r line; do
    if [[ "$line" == *'-device "cosim-pcie-rc'* ]]; then
        if [[ "$previous" != *'-device "pcie-root-port'* ]]; then
            echo "FAIL: cosim endpoint is not immediately preceded by its Root Port" >&2
            exit 1
        fi
        root_id=${previous#*id=}
        root_id=${root_id%%,*}
        endpoint_bus=${line#*bus=}
        endpoint_bus=${endpoint_bus%%,*}
        if [[ "$root_id" != "$endpoint_bus" ]]; then
            echo "FAIL: Root Port id '$root_id' does not match endpoint bus '$endpoint_bus'" >&2
            exit 1
        fi
    fi
    previous=$line
done < "$makefile"

if grep -- '-device "cosim-pcie-rc' "$makefile" |
        grep -Ev 'bus=cosim_rp([^,]*),addr=0x0,.*num_pfs=\$\(NUM_PFS\)' >/dev/null; then
    echo "FAIL: a cosim-pcie-rc launch is not on cosim_rp at addr 0 with NUM_PFS" >&2
    exit 1
fi

if ! grep -q 'NUM_PFS.*?=.*1' "$makefile"; then
    echo "FAIL: Makefile has no NUM_PFS default" >&2
    exit 1
fi

if ! grep -Eq '^[[:space:]]*PCIE_PREF64_RESERVE[[:space:]]*\?=[[:space:]]*256M[[:space:]]*$' "$makefile"; then
    echo "FAIL: Makefile has no PCIE_PREF64_RESERVE=256M default" >&2
    exit 1
fi

if ! grep -Eq '^[[:space:]]*export[[:space:]]+PCIE_PREF64_RESERVE[[:space:]]*$' "$makefile"; then
    echo "FAIL: Makefile does not export PCIE_PREF64_RESERVE to QEMU recipes" >&2
    exit 1
fi

if ! grep -Eq '^run-qemu:[[:space:]]+validate-pcie-pref64-reserve([[:space:]]|$)' "$makefile"; then
    echo "FAIL: run-qemu does not validate PCIE_PREF64_RESERVE before launch" >&2
    exit 1
fi

qemu_device_body=$(sed -n '/^qemu-device:/,/^# host_mem/p' "$makefile")
for sync_cmd in \
    'cp "$(PROJECT_DIR)/qemu-plugin/cosim_pcie_rc.c" "$(QEMU_SRC_DIR)/hw/net/cosim_pcie_rc.c"' \
    'cp "$(PROJECT_DIR)/qemu-plugin/cosim_pcie_rc.h" "$(QEMU_SRC_DIR)/include/hw/net/cosim_pcie_rc.h"' \
    'cp "$(PROJECT_DIR)/bridge/common/cosim_topology.h" "$(QEMU_SRC_DIR)/include/hw/net/cosim_topology.h"'; do
    if [[ "$qemu_device_body" != *"$sync_cmd"* ]]; then
        echo "FAIL: qemu-device does not sync: $sync_cmd" >&2
        exit 1
    fi
done

if [[ -n "${PCIE_PKG_FILELIST_OVERRIDE:-}" ]]; then
    pcie_pkg_filelists=("$PCIE_PKG_FILELIST_OVERRIDE")
else
    pcie_pkg_filelists=(
        "$project_dir/pcie_tl_vip/sim/filelist.f"
        "$project_dir/pcie_tl_vip/sim/filelist_local.f"
        "$project_dir/pcie_tl_vip/sim/filelist_cosim.f"
        "$project_dir/third_party/xilinx_pcie/sim/filelist_adapter_local.f"
        "$project_dir/third_party/xilinx_pcie/sim/filelist_adapter.f"
        "$project_dir/third_party/xilinx_pcie/sim/filelist_multirc.f"
        "$project_dir/third_party/xilinx_pcie/sim/filelist_multiep.f"
    )
fi
for filelist in "${pcie_pkg_filelists[@]}"; do
    verify_pcie_pkg_filelist "$filelist"
done

if ! grep -q 'cosim_effective_config_bypass' "$xrc_driver"; then
    echo "FAIL: cosim_xrc_driver does not use the tested config-bypass policy" >&2
    exit 1
fi

if ! grep -q 'NUM_PFS must be in range 1..16' "$xrc_driver"; then
    echo "FAIL: VCS does not reject an invalid NUM_PFS" >&2
    exit 1
fi

# Check executable policy only within build_phase. Remove SV/C comments while
# preserving quoted literals, then normalize whitespace so comments or line
# layout cannot satisfy a rule.
profile_build_phase_source=$(sed -n \
    '/virtual function void build_phase/,/func_mgr\.build_topology/p' "$xrc_driver" |
    perl -0777 -pe 's{("(?:\\.|[^"\\])*")|/\*.*?\*/|//[^\n]*}{defined $1 ? $1 : ""}gsex')
profile_build_phase=$(printf '%s' "$profile_build_phase_source" |
    tr '\n\t\r' ' ' |
    sed 's/[[:space:]][[:space:]]*/ /g')
dpu_profile_block=$(printf '%s' "$profile_build_phase_source" |
    perl -0777 -ne '
        if (!/if\s*\(\s*cfg_profile\s*==\s*pcie_tl_device_profile_pkg::PCIE_CFG_PROFILE_DPU_20F9_501X\s*\)\s*begin/g) {
            exit 1;
        }
        my $start = $-[0];
        my $depth = 1;
        while (/(?:\b(begin|end)\b)|(?:"(?:\\.|[^"\\])*")/g) {
            next if !defined $1;
            $depth += $1 eq "begin" ? 1 : -1;
            if ($depth == 0) {
                print substr($_, $start, pos() - $start);
                exit 0;
            }
        }
        exit 1;
    ' || true)

require_profile_pattern 'CFG_PROFILE plusarg parsing' \
    '\$value\$plusargs[[:space:]]*\([[:space:]]*"CFG_PROFILE=%s"[[:space:]]*,[[:space:]]*cfg_profile_name[[:space:]]*\)'
require_profile_pattern 'CFG_PROFILE validity parsing' \
    'pcie_cfg_profile_parse[[:space:]]*\([[:space:]]*cfg_profile_name[[:space:]]*\)'
require_profile_pattern 'unknown CFG_PROFILE fatal path' \
    'if[[:space:]]*\([[:space:]]*!pcie_tl_device_profile_pkg::pcie_cfg_profile_parse[[:space:]]*\([[:space:]]*cfg_profile_name[[:space:]]*\)[[:space:]]*\)[[:space:]]*`uvm_fatal'
require_profile_pattern 'CFG_PROFILE enum resolution' \
    'pcie_cfg_profile_value[[:space:]]*\([[:space:]]*cfg_profile_name[[:space:]]*\)'
require_profile_pattern 'MAX_VFS explicit-presence tracking' \
    'max_vfs_explicit[[:space:]]*=[[:space:]]*\$value\$plusargs[[:space:]]*\([[:space:]]*"MAX_VFS=%d"[[:space:]]*,[[:space:]]*max_vfs[[:space:]]*\)'
require_profile_pattern 'DPU profile selection condition' \
    'if[[:space:]]*\([[:space:]]*cfg_profile[[:space:]]*==[[:space:]]*pcie_tl_device_profile_pkg::PCIE_CFG_PROFILE_DPU_20F9_501X[[:space:]]*\)[[:space:]]*begin'
require_profile_pattern 'DPU omitted-MAX_VFS default' \
    'PCIE_CFG_PROFILE_DPU_20F9_501X[[:space:]]*\)[[:space:]]*begin[[:space:]]*if[[:space:]]*\([[:space:]]*!max_vfs_explicit[[:space:]]*\)[[:space:]]*max_vfs[[:space:]]*=[[:space:]]*16[[:space:]]*;'
require_profile_pattern 'DPU NUM_PFS range condition' \
    'PCIE_CFG_PROFILE_DPU_20F9_501X[[:space:]]*\)[[:space:]]*begin.*if[[:space:]]*\([[:space:]]*n_pfs[[:space:]]*<[[:space:]]*1[[:space:]]*\|\|[[:space:]]*n_pfs[[:space:]]*>[[:space:]]*4[[:space:]]*\)'
require_profile_pattern 'DPU MAX_VFS value condition' \
    'PCIE_CFG_PROFILE_DPU_20F9_501X[[:space:]]*\)[[:space:]]*begin.*if[[:space:]]*\([[:space:]]*max_vfs[[:space:]]*!=[[:space:]]*16[[:space:]]*\)'
require_dpu_profile_pattern 'vendor identity default' \
    "ven[[:space:]]*=[[:space:]]*16'h20f9[[:space:]]*;"
require_dpu_profile_pattern 'PF device identity default' \
    "dev[[:space:]]*=[[:space:]]*16'h5011[[:space:]]*;"
require_dpu_profile_pattern 'VF device identity default' \
    "vfdev[[:space:]]*=[[:space:]]*16'h8689[[:space:]]*;"
require_profile_pattern 'profile propagation before topology build' \
    'func_mgr[[:space:]]*\.[[:space:]]*cfg_profile[[:space:]]*=[[:space:]]*cfg_profile[[:space:]]*;[[:space:]]*func_mgr[[:space:]]*\.[[:space:]]*build_topology[[:space:]]*\('

if ! grep -Fq '$test$plusargs("AUTO_START_COSIM")' "$xrc_driver"; then
    echo 'FAIL: VCS has no AUTO_START_COSIM alias for automated TCP startup' >&2
    exit 1
fi

if ! grep -Fq '[CFG_PROFILE] resolved' "$xrc_driver"; then
    echo 'FAIL: VCS does not log resolved profile identity after topology build' >&2
    exit 1
fi

if grep -- '-device "pcie-root-port' "$makefile" |
        grep -v 'mem-reserve=64M' >/dev/null; then
    echo "FAIL: a cosim Root Port does not reserve 64M MMIO space" >&2
    exit 1
fi

if grep -- '-device "pcie-root-port' "$makefile" |
        grep -Fv 'mem-reserve=64M,pref64-reserve=$$PCIE_PREF64_RESERVE"' >/dev/null; then
    echo "FAIL: a cosim Root Port does not quote the exported pref64 reserve" >&2
    exit 1
fi

if grep -- '-device "pcie-root-port' "$makefile" |
        grep -F '$(PCIE_PREF64_RESERVE)' >/dev/null; then
    echo "FAIL: a cosim Root Port interpolates PCIE_PREF64_RESERVE before the shell" >&2
    exit 1
fi

for console in login login-multi file; do
    verify_pref64_reserve_dry_run "$console"
done

if ! make -C "$project_dir" --no-print-directory validate-pcie-pref64-reserve >/dev/null; then
    echo "FAIL: default PCIE_PREF64_RESERVE did not pass validation" >&2
    exit 1
fi
if ! make -C "$project_dir" --no-print-directory \
        validate-pcie-pref64-reserve PCIE_PREF64_RESERVE=512M >/dev/null; then
    echo "FAIL: command-line PCIE_PREF64_RESERVE=512M did not pass validation" >&2
    exit 1
fi
if ! env PCIE_PREF64_RESERVE=512M make -C "$project_dir" --no-print-directory \
        validate-pcie-pref64-reserve >/dev/null; then
    echo "FAIL: environment PCIE_PREF64_RESERVE=512M did not pass validation" >&2
    exit 1
fi

if invalid_reserve_output=$(make -C "$project_dir" --no-print-directory \
        validate-pcie-pref64-reserve 'PCIE_PREF64_RESERVE=512M; echo INJECTED' 2>&1); then
    echo "FAIL: invalid PCIE_PREF64_RESERVE passed validation" >&2
    exit 1
fi
if [[ "$invalid_reserve_output" == *INJECTED* ]]; then
    echo "FAIL: invalid PCIE_PREF64_RESERVE executed injected shell content" >&2
    exit 1
fi

if make_function_output=$(make -C "$project_dir" --no-print-directory \
        validate-pcie-pref64-reserve \
        'PCIE_PREF64_RESERVE=$(shell printf MAKE_FUNCTION_INJECTED >&2)' 2>&1); then
    echo "FAIL: Make-function PCIE_PREF64_RESERVE passed validation" >&2
    exit 1
fi
if [[ "$make_function_output" == *MAKE_FUNCTION_INJECTED* ]]; then
    echo "FAIL: Make-function PCIE_PREF64_RESERVE executed before validation" >&2
    exit 1
fi

if grep -q 'pci_new(PCI_DEVFN(slot, i)' "$qemu_rc"; then
    echo "FAIL: QEMU still truncates logical PF indices to three function bits" >&2
    exit 1
fi

if ! grep -q 'sib->pf_index[[:space:]]*=[[:space:]]*i' "$qemu_rc"; then
    echo "FAIL: QEMU sibling PFs have no explicit logical PF index" >&2
    exit 1
fi

pf_create_body=$(sed -n \
    '/if (s->num_pfs > 1)/,/Signal VCS that device realize completed/p' \
    "$qemu_rc")
if [[ "$pf_create_body" != *'error_propagate(errp, e)'* ||
      "$pf_create_body" != *'object_unparent(OBJECT(g_rc_pfs[j]))'* ||
      "$pf_create_body" != *'cosim_pcie_rc_exit(pci_dev)'* ]]; then
    echo "FAIL: a sibling PF realize failure does not fail and unwind PF0 realize" >&2
    exit 1
fi

vf_apply_prefix=$(sed -n \
    '/static void cosim_vf_config_apply/,/cosim_vf_teardown(s, true);/p' \
    "$qemu_rc")
if [[ "$vf_apply_prefix" != *'!g_rc_pfs[cfg->pf_index]'* ||
      "$vf_apply_prefix" != *'return;'* ]]; then
    echo "FAIL: VF_CONFIG with an unknown PF index can fall back to PF0" >&2
    exit 1
fi

vf_realize_body=$(sed -n \
    '/static void cosim_rc_vf_realize/,/static void cosim_rc_vf_class_init/p' \
    "$qemu_rc")
if [[ "$vf_realize_body" != *'pcie_ari_init(dev, 0x100)'* ]]; then
    echo "FAIL: QEMU VF config stubs have no local ARI marker" >&2
    exit 1
fi

# The VCS topology response is the authoritative PF/BAR profile.  PF0 must
# query and retain it before creating sibling PFs; every PF then uses the same
# registration helper rather than the former fixed 64KiB sibling BAR window.
if ! grep -q 'bridge_query_topology(ctx, &s->topology)' "$qemu_rc"; then
    echo "FAIL: QEMU PF0 does not query the VCS topology" >&2
    exit 1
fi

if ! grep -Eq 's->topology\.header\.num_pfs[[:space:]]*!=[[:space:]]*s->num_pfs' \
        "$qemu_rc"; then
    echo "FAIL: QEMU does not reject a VCS/QEMU PF-count mismatch" >&2
    exit 1
fi

if ! grep -q 'cosim_register_pf_bars' "$qemu_rc"; then
    echo "FAIL: QEMU has no shared topology-driven PF BAR registration helper" >&2
    exit 1
fi

if ! grep -q 'PCI_BASE_ADDRESS_MEM_TYPE_64 | PCI_BASE_ADDRESS_MEM_PREFETCH' \
        "$qemu_rc"; then
    echo "FAIL: QEMU does not preserve 64-bit prefetchable PF BAR flags" >&2
    exit 1
fi

bar_registration_body=$(sed -n \
    '/static bool cosim_register_pf_bars/,/^}/p' "$qemu_rc")
if [[ "$bar_registration_body" != *'!is_power_of_2(size)'* ||
      "$bar_registration_body" != *'has non-power-of-two size'* ]]; then
    echo "FAIL: QEMU does not reject a non-power-of-two topology BAR size" >&2
    exit 1
fi
if [[ "$bar_registration_body" != *'s->num_bars == 0'* ||
      "$bar_registration_body" != *'has no owner BAR'* ]]; then
    echo "FAIL: QEMU accepts a PF topology with no owner BAR" >&2
    exit 1
fi
if [[ "$bar_registration_body" != *'memory_type != 0'* ||
      "$bar_registration_body" != *'PCI_BASE_ADDRESS_MEM_TYPE_64'* ||
      "$bar_registration_body" != *'reserved memory type'* ]]; then
    echo "FAIL: QEMU does not reject reserved PCI memory BAR types" >&2
    exit 1
fi

rc_exit_body=$(sed -n '/static void cosim_pcie_rc_exit/,/^}/p' "$qemu_rc")
if [[ "$rc_exit_body" != *'for (uint32_t i = 1; i < COSIM_RC_MAX_PF; i++)'* ||
      "$rc_exit_body" != *'g_rc_pfs[i] = NULL'* ||
      "$rc_exit_body" != *'object_unparent(OBJECT(sibling))'* ]]; then
    echo "FAIL: PF0 exit does not tear down and clear auto-created siblings" >&2
    exit 1
fi

sibling_realize_body=$(sed -n \
    '/if (s->pf_index != 0)/,/if (s->num_pfs < 1/p' "$qemu_rc")
if [[ "$sibling_realize_body" == *'64 * 1024'* ]]; then
    echo "FAIL: QEMU sibling PFs still register a fixed 64KiB BAR" >&2
    exit 1
fi
if [[ "$sibling_realize_body" != *'cosim_register_pf_bars'* ]]; then
    echo "FAIL: QEMU sibling PFs do not use the topology BAR helper" >&2
    exit 1
fi

if ! grep -q 'REAL_DUT config passthrough is not implemented' "$xrc_driver"; then
    echo "FAIL: unsupported REAL_DUT config passthrough is not rejected" >&2
    exit 1
fi

echo "PASS: fixed Root Port, PF/BAR reservations, NUM_PFS propagation, and explicit config-bypass policy"
