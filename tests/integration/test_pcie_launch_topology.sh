#!/bin/bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
makefile="$project_dir/Makefile"
setup_script="$project_dir/setup.sh"
xrc_driver=${XRC_DRIVER:-"$project_dir/vcs-tb/cosim_xrc_driver.sv"}
qemu_rc="$project_dir/qemu-plugin/cosim_pcie_rc.c"
qemu_mmio_include='hw/net/cosim_mmio_be.h'
qemu_mmio_header_relative='qemu-plugin/cosim_mmio_be.h'
qemu_mmio_header="$project_dir/$qemu_mmio_header_relative"
make_mmio_sync_line=$'\t@cp "$(PROJECT_DIR)/qemu-plugin/cosim_mmio_be.h" "$(QEMU_SRC_DIR)/include/hw/net/cosim_mmio_be.h"'
setup_mmio_sync_line='        cp "${PROJECT_DIR}/qemu-plugin/cosim_mmio_be.h" "${QEMU_DIR}/include/hw/net/"'
fixture_parent="$project_dir/build/tmp"
mkdir -p "$fixture_parent"
fixture_root=$(mktemp -d "$fixture_parent/test-pcie-launch-topology.XXXXXX")
cleanup() {
    rm -rf -- "$fixture_root"
}
trap cleanup EXIT

has_exact_line() {
    local content=$1
    local expected=$2

    grep -Fxq -- "$expected" <<<"$content"
}

qemu_mmio_header_is_tracked() {
    local header_path=$1
    local tracked_path

    [[ -f "$header_path" ]] || return 1
    tracked_path=$(git -C "$project_dir" ls-files --error-unmatch -- \
        "$qemu_mmio_header_relative" 2>/dev/null) || return 1
    [[ "$tracked_path" == "$qemu_mmio_header_relative" ]] || return 1
    [[ "$header_path" == "$project_dir/$tracked_path" ]]
}

qemu_rc_depends_on_mmio_header() {
    local rc_path=$1
    local dependencies

    if ! dependencies=$(cpp -MM -MG "$rc_path"); then
        return 1
    fi
    awk -v expected="$qemu_mmio_include" '
        {
            for (field = 1; field <= NF; field++) {
                token = $field
                sub(/\\$/, "", token)
                if (token == expected)
                    found = 1
            }
        }
        END { exit !found }
    ' <<<"$dependencies"
}

qemu_device_executes_mmio_sync() {
    local make_body=$1
    local make_fixture make_output expected_output

    make_fixture=$(mktemp "$fixture_root/qemu-device.XXXXXX.mk")
    {
        printf 'PROJECT_DIR := %s\n' "$project_dir"
        printf 'QEMU_SRC_DIR := $(PROJECT_DIR)/third_party/qemu\n'
        printf 'QEMU_BUILD := $(QEMU_SRC_DIR)/build\n'
        printf '.PHONY: bridge qemu-device\n'
        printf 'bridge:\n\t@:\n'
        printf '%s\n' "$make_body"
    } >"$make_fixture"
    if ! make_output=$(make --no-print-directory -n -f "$make_fixture" \
            qemu-device 2>&1); then
        return 1
    fi
    expected_output="cp \"$qemu_mmio_header\" \"$project_dir/third_party/qemu/include/hw/net/cosim_mmio_be.h\""
    has_exact_line "$make_output" "$expected_output"
}

setup_injection_executes_mmio_sync() {
    local setup_body=$1
    local setup_fixture qemu_fixture target_header source_hash target_hash

    setup_fixture=$(mktemp -d "$fixture_root/setup-injection.XXXXXX")
    qemu_fixture="$setup_fixture/qemu"
    mkdir -p "$qemu_fixture/hw/net" "$qemu_fixture/include/hw/net"
    {
        printf '#!/bin/bash\nset -euo pipefail\n'
        printf 'info() { :; }\n'
        printf '%s\n' "$setup_body"
    } >"$setup_fixture/inject.sh"
    if ! PROJECT_DIR="$project_dir" QEMU_DIR="$qemu_fixture" \
            bash "$setup_fixture/inject.sh"; then
        return 1
    fi
    target_header="$qemu_fixture/include/hw/net/cosim_mmio_be.h"
    [[ -f "$target_header" ]] || return 1
    source_hash=$(sha256sum "$qemu_mmio_header") || return 1
    target_hash=$(sha256sum "$target_header") || return 1
    [[ "${source_hash%% *}" == "${target_hash%% *}" ]]
}

qemu_mmio_injection_contract_is_valid() {
    local make_body=$1
    local setup_body=$2
    local header_path=${3:-$qemu_mmio_header}
    local rc_path=${4:-$qemu_rc}

    qemu_mmio_header_is_tracked "$header_path" &&
        qemu_rc_depends_on_mmio_header "$rc_path" &&
        qemu_device_executes_mmio_sync "$make_body" &&
        setup_injection_executes_mmio_sync "$setup_body"
}

extract_unique_setup_qemu_injection_body() {
    awk '
        $0 == "    if [ \"$NEED_QEMU\" = true ] && [ -d \"$QEMU_DIR\" ]; then" {
            starts++
            active = 1
            next
        }
        active && $0 == "        MESON_FILE=\"${QEMU_DIR}/hw/net/meson.build\"" {
            ends++
            active = 0
            next
        }
        active { print }
        END {
            if (starts != 1 || ends != 1 || active)
                exit 1
        }
    ' "$setup_script"
}

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
if ! setup_qemu_injection_body=$(extract_unique_setup_qemu_injection_body); then
    echo "FAIL: setup.sh must contain exactly one initial QEMU injection block" >&2
    exit 1
fi
if ! grep -Eq '^qemu-device:[[:space:]]+bridge([[:space:]]|$)' "$makefile"; then
    echo "FAIL: qemu-device does not rebuild its bridge library dependency" >&2
    exit 1
fi
for sync_cmd in \
    'cp "$(PROJECT_DIR)/qemu-plugin/cosim_pcie_rc.c" "$(QEMU_SRC_DIR)/hw/net/cosim_pcie_rc.c"' \
    'cp "$(PROJECT_DIR)/qemu-plugin/cosim_pcie_rc.h" "$(QEMU_SRC_DIR)/include/hw/net/cosim_pcie_rc.h"' \
    'cp "$(PROJECT_DIR)/bridge/common/cosim_topology.h" "$(QEMU_SRC_DIR)/include/hw/net/cosim_topology.h"'; do
    if [[ "$qemu_device_body" != *"$sync_cmd"* ]]; then
        echo "FAIL: qemu-device does not sync: $sync_cmd" >&2
        exit 1
    fi
done
if ! qemu_mmio_injection_contract_is_valid \
        "$qemu_device_body" "$setup_qemu_injection_body"; then
    if ! qemu_mmio_header_is_tracked "$qemu_mmio_header"; then
        echo "FAIL: qemu-plugin/cosim_mmio_be.h is not the tracked source header" >&2
    elif ! qemu_rc_depends_on_mmio_header "$qemu_rc"; then
        echo "FAIL: cpp dependencies do not contain active hw/net/cosim_mmio_be.h" >&2
    elif ! qemu_device_executes_mmio_sync "$qemu_device_body"; then
        echo "FAIL: qemu-device dry run does not execute the cosim_mmio_be.h sync" >&2
    else
        echo "FAIL: setup QEMU injection does not copy matching cosim_mmio_be.h bytes" >&2
    fi
    exit 1
fi
setup_without_mmio=${setup_qemu_injection_body/"$setup_mmio_sync_line"/}
if [[ "$setup_without_mmio" == "$setup_qemu_injection_body" ]]; then
    echo "FAIL: setup cosim_mmio_be.h deletion mutation could not be constructed" >&2
    exit 1
fi
if qemu_mmio_injection_contract_is_valid \
        "$qemu_device_body" "$setup_without_mmio"; then
    echo "FAIL: setup cosim_mmio_be.h deletion mutation was incorrectly accepted" >&2
    exit 1
fi
untracked_header="$fixture_root/untracked-cosim_mmio_be.h"
commented_rc="$fixture_root/cosim_pcie_rc-block-comment.c"
cp "$qemu_mmio_header" "$untracked_header"
awk '
    $0 == "#include \"hw/net/cosim_mmio_be.h\"" {
        print "/*"
        print
        print "*/"
        next
    }
    { print }
' "$qemu_rc" >"$commented_rc"
make_with_disabled_mmio=${qemu_device_body/"$make_mmio_sync_line"/$'ifeq (1,0)\n'"$make_mmio_sync_line"$'\nendif'}
setup_with_disabled_mmio=${setup_qemu_injection_body/"$setup_mmio_sync_line"/$'        if false; then\n'"$setup_mmio_sync_line"$'\n        fi'}
contract_false_greens=0
if qemu_mmio_injection_contract_is_valid \
        "$qemu_device_body" "$setup_qemu_injection_body" \
        "$untracked_header" "$qemu_rc"; then
    echo "FAIL: MMIO injection contract accepted an untracked header fixture" >&2
    contract_false_greens=$((contract_false_greens + 1))
fi
if qemu_mmio_injection_contract_is_valid \
        "$qemu_device_body" "$setup_qemu_injection_body" \
        "$qemu_mmio_header" "$commented_rc"; then
    echo "FAIL: MMIO injection contract accepted a block-comment include fixture" >&2
    contract_false_greens=$((contract_false_greens + 1))
fi
if qemu_mmio_injection_contract_is_valid \
        "$make_with_disabled_mmio" "$setup_qemu_injection_body"; then
    echo "FAIL: MMIO injection contract accepted an ifeq-disabled Make recipe" >&2
    contract_false_greens=$((contract_false_greens + 1))
fi
if qemu_mmio_injection_contract_is_valid \
        "$qemu_device_body" "$setup_with_disabled_mmio"; then
    echo "FAIL: MMIO injection contract accepted an if-false setup copy" >&2
    contract_false_greens=$((contract_false_greens + 1))
fi
if ((contract_false_greens != 0)); then
    echo "FAIL: MMIO injection contract false greens: $contract_false_greens/4" >&2
    exit 1
fi

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
require_profile_pattern 'profile and tag-bit propagation before topology build' \
    'func_mgr[[:space:]]*\.[[:space:]]*cfg_profile[[:space:]]*=[[:space:]]*cfg_profile[[:space:]]*;.*func_mgr[[:space:]]*\.[[:space:]]*set_tag_bit[[:space:]]*\([[:space:]]*tag_bit[[:space:]]*\)[[:space:]]*;.*func_mgr[[:space:]]*\.[[:space:]]*build_topology[[:space:]]*\('

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
