#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
guest_doc="$repo/docs/GUEST-MANAGEMENT-SCP.md"
vcs_doc="$repo/docs/COSIM-VCS-INTEGRATION.md"
filelist="$repo/pcie_tl_vip/sim/filelist_cosim.f"
plan="$repo/docs/superpowers/plans/2026-08-06-ubuntu-server-debugutils.md"
spec="$repo/docs/superpowers/specs/2026-08-06-ubuntu-server-debugutils-design.md"
failures=0

fail() {
    echo "FAIL: $*" >&2
    failures=$((failures + 1))
}

require_literal() {
    local file=$1
    local literal=$2
    local description=$3

    grep -Fq -- "$literal" "$file" || fail "$description"
}

forbid_literal() {
    local file=$1
    local literal=$2
    local description=$3

    if grep -Fq -- "$literal" "$file"; then
        fail "$description"
    fi
}

require_text_literal() {
    local content=$1
    local literal=$2
    local description=$3

    grep -Fq -- "$literal" <<<"$content" || fail "$description"
}

forbid_text_literal() {
    local content=$1
    local literal=$2
    local description=$3

    if grep -Fq -- "$literal" <<<"$content"; then
        fail "$description"
    fi
}

extract_section() {
    local file=$1
    local start=$2
    local end=$3

    awk -v start="$start" -v end="$end" '
        $0 == start { active = 1 }
        active && $0 == end { exit }
        active { print }
    ' "$file"
}

driver_cmd='make KERNELDIR=/lib/modules/$(uname -r)/build CFLAGS=-UDPU_LACP'
bare_driver_cmd='make KERNELDIR=/lib/modules/$(uname -r)/build'

for file in "$guest_doc" "$spec"; do
    require_literal "$file" "$driver_cmd" \
        "$(basename "$file") must disable the incompatible bundled LACP sources"
    require_literal "$file" 'bundled LACP' \
        "$(basename "$file") must explain the bundled LACP compatibility exception"
    require_literal "$file" 'system bonding' \
        "$(basename "$file") must explain that the build uses system bonding"
    if grep -Fxq -- "$bare_driver_cmd" "$file"; then
        fail "$(basename "$file") still documents the failing bare driver build"
    fi
done

plan_task7=$(extract_section \
    "$plan" \
    '## Task 7: Document workflows and run the fast suite' \
    '## Task 8: Build and inspect both real images on 53')
plan_task9=$(extract_section \
    "$plan" \
    '## Task 9: Boot validation, native driver build, and VCS BAR read' \
    '## Task 10: Produce and relocate-test the offline archive')

for task in "$plan_task7" "$plan_task9"; do
    require_text_literal "$task" "$driver_cmd" \
        'the current plan task must use the compatible Ubuntu Server driver build command'
    require_text_literal "$task" 'bundled LACP' \
        'the current plan task must explain the bundled LACP compatibility exception'
    require_text_literal "$task" 'system bonding' \
        'the current plan task must explain that the build uses system bonding'
    if grep -Fxq -- "$bare_driver_cmd" <<<"$task"; then
        fail 'the current plan task still documents the failing bare driver build'
    fi
done

absolute_bridge_arg='-Wl,--whole-archive $PWD/build/lib/libcosim_bridge.a'
relative_bridge_arg='-Wl,--whole-archive build/lib/libcosim_bridge.a'
require_literal "$filelist" "$absolute_bridge_arg" \
    'filelist_cosim.f must pass an absolute bridge archive path to the VCS csrc link'
forbid_literal "$filelist" "$relative_bridge_arg" \
    'filelist_cosim.f still passes a csrc-relative bridge archive path'
require_text_literal "$plan_task9" "$absolute_bridge_arg" \
    'the Task 9 VCS command must pass an absolute bridge archive path to the csrc link'
forbid_text_literal "$plan_task9" "$relative_bridge_arg" \
    'the Task 9 VCS command still passes a csrc-relative bridge archive path'

require_literal "$filelist" \
    '// Batch run: ./simv_cosim +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART +REMOTE_HOST=<QEMU> +PORT_BASE=9100' \
    'the filelist batch run command must opt in to COSIM autostart'
require_text_literal "$plan_task9" \
    '  +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART' \
    'the Task 9 batch run command must opt in to COSIM autostart'

vcs_section8=$(extract_section \
    "$vcs_doc" \
    '## 8. DPU_20F9_501X 多 PF 启动' \
    '## 9. QEMU iCount 时间模式')
require_text_literal "$vcs_section8" '批处理运行应加 `+COSIM_AUTOSTART`' \
    'the VCS guide must describe the batch autostart mode'
require_text_literal "$vcs_section8" \
    '需要先运行 VIP 再切换的分阶段交互模式则省略该 plusarg，并在 UCLI 中执行' \
    'the VCS guide must retain the staged UCLI mode'
require_text_literal "$vcs_section8" '`start_cosim`。两种启动方式二选一' \
    'the VCS guide must name the staged UCLI transition command'
require_text_literal "$vcs_section8" '`+COSIM_AUTOSTART` 不是全局默认' \
    'the VCS guide must state that autostart is not a global default'

require_text_literal "$vcs_section8" '**TLM stand-in** 测试，不包含用户的 RTL DUT' \
    'the VCS guide must state that the standalone TLM test has no user RTL DUT'
require_text_literal "$vcs_section8" \
    '仅在命令行加 `+REAL_DUT` 不能把它变成真实 DUT 测试' \
    'the VCS guide must state that +REAL_DUT cannot create a real RTL DUT'
require_text_literal "$vcs_section8" \
    '当前 completion ownership 已保证每种模式只选择一条消费路径' \
    'the VCS guide must describe the repaired completion ownership'
require_text_literal "$vcs_section8" '用户自己的 top' \
    'the VCS guide must require a user real-DUT top'
require_text_literal "$vcs_section8" 'Completion 的唯一来源' \
    'the VCS guide must require one DUT completion source'
forbid_text_literal "$vcs_section8" 'Unexpected Completion' \
    'the VCS guide still claims the repaired direct/monitor path must duplicate completions'
forbid_text_literal "$vcs_section8" 'no QEMU tag map' \
    'the VCS guide still claims the repaired ownership path must lose the QEMU tag map'

if ((failures != 0)); then
    echo "[workflow-command-contracts] $failures contract check(s) failed" >&2
    exit 1
fi

echo '[workflow-command-contracts] PASS'
