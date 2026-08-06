#!/usr/bin/env bash
set -euo pipefail

if (($# > 1)); then
    echo "usage: $0 [repo-root]" >&2
    exit 2
fi

if (($# == 1)); then
    repo=$(cd "$1" && pwd)
else
    repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fi

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

get_section() {
    local result_name=$1
    local file=$2
    local start=$3
    local end=$4
    local description=$5
    local section

    if ! section=$(awk -v start="$start" -v end="$end" '
        $0 == start {
            starts++
            active = 1
            next
        }
        active && $0 == end {
            ends++
            active = 0
            next
        }
        active { print }
        END {
            if (starts != 1 || ends != 1 || active)
                exit 1
        }
    ' "$file"); then
        fail "$description must occur exactly once"
        section=
    fi
    printf -v "$result_name" '%s' "$section"
}

get_fenced_block() {
    local result_name=$1
    local section=$2
    local opening_fence=$3
    local anchor=$4
    local description=$5
    local block

    if ! block=$(awk -v opening="$opening_fence" -v anchor="$anchor" '
        $0 == opening {
            inside = 1
            current = ""
            next
        }
        inside && $0 == "```" {
            if (index(current, anchor) != 0) {
                matches++
                selected = current
            }
            inside = 0
            next
        }
        inside { current = current $0 ORS }
        END {
            if (matches != 1)
                exit 1
            printf "%s", selected
        }
    ' <<<"$section"); then
        fail "$description must identify exactly one fenced command block"
        block=
    fi
    printf -v "$result_name" '%s' "$block"
}

has_exact_line() {
    local content=$1
    local expected=$2

    grep -Fxq -- "$expected" <<<"$content"
}

require_exact_line() {
    local content=$1
    local expected=$2
    local description=$3

    has_exact_line "$content" "$expected" || fail "$description"
}

forbid_exact_line() {
    local content=$1
    local forbidden=$2
    local description=$3

    if has_exact_line "$content" "$forbidden"; then
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

driver_cmd='make KERNELDIR=/lib/modules/$(uname -r)/build CFLAGS=-UDPU_LACP'
bare_driver_cmd='make KERNELDIR=/lib/modules/$(uname -r)/build'
absolute_bridge_line='  -LDFLAGS "-Wl,--whole-archive $PWD/build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \'
relative_bridge_line='  -LDFLAGS "-Wl,--whole-archive build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \'
autostart_line='  +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART \'
no_autostart_line='  +UVM_TESTNAME=pcie_tl_cosim_test +COSIM \'

task10_archive_assignment='archive="$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip"'
task10_import_line='./setup.sh --import "$archive" --import-only'
task10_old_extract_line='unzip -q "$archive" setup.sh'
task10_quoted_extract_line='unzip -q "$archive" "setup.sh"'
task10_project_tar_assignment='project_tar="$verify/project-$source_commit.tar"'
task10_git_archive_line='git archive --format=tar --output="$project_tar" "$source_commit" || exit 1'
task10_tar_extract_line='tar -xf "$project_tar" -C "$project" || exit 1'
task10_fresh_project_check='if [ -e "$project" ]; then
  echo "relocated project path already exists: $project" >&2
  exit 1
fi'
task10_absolute_path_check='if [[ "$archive" != /* || "$verify" != /* ]]; then
  echo "archive and relocated project paths must be absolute" >&2
  exit 1
fi'
task10_data_only_check='if unzip -Z1 "$archive" | grep -Fxq setup.sh; then
  echo "data-only archive unexpectedly contains setup.sh" >&2
  exit 1
fi'

driver_block_is_valid() {
    local block=$1

    has_exact_line "$block" "$driver_cmd" &&
        ! has_exact_line "$block" "$bare_driver_cmd"
}

task9_compile_block_is_valid() {
    local block=$1

    has_exact_line "$block" "$absolute_bridge_line" &&
        ! has_exact_line "$block" "$relative_bridge_line"
}

task9_run_block_is_valid() {
    local block=$1

    has_exact_line "$block" 'build/ubuntu-server-vcs/simv_cosim \' &&
        has_exact_line "$block" "$autostart_line" &&
        ! has_exact_line "$block" "$no_autostart_line"
}

task10_relocated_import_block_is_valid() {
    local block=$1

    has_exact_line "$block" 'verify="$out/import-check"' &&
        has_exact_line "$block" 'project="$verify/project"' &&
        has_exact_line "$block" "$task10_archive_assignment" &&
        grep -Fq -- "$task10_absolute_path_check" <<<"$block" &&
        grep -Fq -- "$task10_data_only_check" <<<"$block" &&
        has_exact_line "$block" 'source_commit=$(git rev-parse HEAD)' &&
        has_exact_line "$block" "$task10_project_tar_assignment" &&
        grep -Fq -- "$task10_fresh_project_check" <<<"$block" &&
        has_exact_line "$block" 'mkdir -p "$project" || exit 1' &&
        has_exact_line "$block" "$task10_git_archive_line" &&
        has_exact_line "$block" "$task10_tar_extract_line" &&
        has_exact_line "$block" 'cd "$project" || exit 1' &&
        has_exact_line "$block" "$task10_import_line" &&
        ! grep -Eq '^[[:space:]]*unzip[[:space:]].*setup\.sh' <<<"$block"
}

require_driver_block() {
    local label=$1
    local block=$2

    if ! driver_block_is_valid "$block"; then
        fail "$label driver fenced block must use CFLAGS=-UDPU_LACP and forbid the bare command"
    fi
}

expect_mutation_rejected() {
    local checker=$1
    local original=$2
    local expected=$3
    local replacement=$4
    local description=$5
    local mutated=${original/"$expected"/"$replacement"}

    # An already-invalid fixture is reported by its real contract check above;
    # mutation probes only exercise validators from a valid starting block.
    if [[ "$mutated" == "$original" ]]; then
        return 0
    elif "$checker" "$mutated"; then
        fail "$description mutation probe was incorrectly accepted"
    fi
}

expect_insertion_rejected() {
    local checker=$1
    local original=$2
    local anchor=$3
    local insertion=$4
    local description=$5
    local mutated

    if ! grep -Fq -- "$anchor" <<<"$original"; then
        # The primary contract reports an invalid starting block. Mutation
        # probes become meaningful only after every required line is present.
        return 0
    fi
    mutated=${original/"$anchor"/"$anchor"$'\n'"$insertion"}
    if "$checker" "$mutated"; then
        fail "$description insertion mutation was incorrectly accepted"
    fi
}

get_section guest_driver_section \
    "$guest_doc" \
    '## 在 Ubuntu Server 内编译并手工加载 DPU 驱动' \
    '## setup、离线导入与 relocated archive' \
    'the Guest management driver section'
get_fenced_block guest_driver_block \
    "$guest_driver_section" '```bash' 'cd host-driver-net' \
    'the Guest management driver build'
require_driver_block 'Guest management' "$guest_driver_block"
require_text_literal "$guest_driver_section" 'bundled LACP' \
    'the Guest management driver section must explain the bundled LACP exception'
require_text_literal "$guest_driver_section" 'system bonding' \
    'the Guest management driver section must explain system bonding'

get_section spec_driver_section \
    "$spec" \
    '### Driver build workflows' \
    '## Setup and offline packaging' \
    'the design driver workflow section'
get_fenced_block spec_driver_block \
    "$spec_driver_section" '```bash' 'cd host-driver-net' \
    'the design driver build'
require_driver_block 'Design workflow' "$spec_driver_block"
require_text_literal "$spec_driver_section" 'bundled LACP' \
    'the design driver section must explain the bundled LACP exception'
require_text_literal "$spec_driver_section" 'system bonding' \
    'the design driver section must explain system bonding'

get_section plan_task7 \
    "$plan" \
    '## Task 7: Document workflows and run the fast suite' \
    '## Task 8: Build and inspect both real images on 53' \
    'Task 7 in the current Ubuntu Server plan'
get_fenced_block task7_driver_block \
    "$plan_task7" '```bash' 'cd host-driver-net' \
    'the Task 7 documented driver workflow'
require_driver_block 'Task 7' "$task7_driver_block"
require_text_literal "$plan_task7" 'bundled LACP' \
    'Task 7 must explain the bundled LACP exception'
require_text_literal "$plan_task7" 'system bonding' \
    'Task 7 must explain system bonding'

get_section plan_task9 \
    "$plan" \
    '## Task 9: Boot validation, native driver build, and VCS BAR read' \
    '## Task 10: Produce and relocate-test the offline archive' \
    'Task 9 in the current Ubuntu Server plan'
get_fenced_block task9_driver_block \
    "$plan_task9" '```bash' "modinfo ./dpu_snd1.ko | grep -F 'pci:v000020F9d00005011'" \
    'the Task 9 native driver build'
require_driver_block 'Task 9' "$task9_driver_block"
require_text_literal "$plan_task9" 'bundled LACP' \
    'Task 9 must explain the bundled LACP exception'
require_text_literal "$plan_task9" 'system bonding' \
    'Task 9 must explain system bonding'

get_fenced_block task9_compile_block \
    "$plan_task9" '```bash' 'vcs -sverilog' \
    'the Task 9 VCS compile command'
if ! task9_compile_block_is_valid "$task9_compile_block"; then
    fail 'Task 9 VCS compile fenced block must use the absolute bridge archive and forbid the relative path'
fi

get_fenced_block task9_run_block \
    "$plan_task9" '```bash' '+REMOTE_HOST=127.0.0.1 +PORT_BASE=28100' \
    'the Task 9 VCS batch run command'
if ! task9_run_block_is_valid "$task9_run_block"; then
    fail 'Task 9 VCS run fenced block must execute simv_cosim with +COSIM_AUTOSTART and forbid the staged command'
fi

get_section plan_task10 \
    "$plan" \
    '## Task 10: Produce and relocate-test the offline archive' \
    '## Task 11: Final regression review and publication' \
    'Task 10 in the current Ubuntu Server plan'
get_fenced_block task10_relocated_import_block \
    "$plan_task10" '```bash' 'verify="$out/import-check"' \
    'the Task 10 Step 3 relocated-import command'
if ! task10_relocated_import_block_is_valid "$task10_relocated_import_block"; then
    fail 'Task 10 Step 3 fenced block must import the absolute data-only archive from a complete exact-commit relocated project tree and forbid extracting setup.sh from the zip'
fi

filelist_content=$(<"$filelist")
require_exact_line "$filelist_content" \
    '//       -LDFLAGS "-Wl,--whole-archive $PWD/build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \' \
    'the filelist compile recipe must use the absolute bridge archive'
forbid_exact_line "$filelist_content" \
    '//       -LDFLAGS "-Wl,--whole-archive build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \' \
    'the filelist compile recipe must forbid the relative bridge archive'
require_exact_line "$filelist_content" \
    '//       -f pcie_tl_vip/sim/filelist_cosim.f -o pcie_tl_vip/sim/simv_cosim' \
    'the filelist compile recipe must name the repository-relative simv output'
require_exact_line "$filelist_content" \
    '// Batch run: ./pcie_tl_vip/sim/simv_cosim +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART +REMOTE_HOST=<QEMU> +PORT_BASE=9100' \
    'the filelist batch recipe must execute the simv path produced from the repository root'
forbid_exact_line "$filelist_content" \
    '// Batch run: ./simv_cosim +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART +REMOTE_HOST=<QEMU> +PORT_BASE=9100' \
    'the filelist batch recipe must forbid the nonexistent repository-root simv path'

get_section vcs_section8 \
    "$vcs_doc" \
    '## 8. DPU_20F9_501X 多 PF 启动' \
    '## 9. QEMU iCount 时间模式' \
    'section 8 in the VCS integration guide'
get_fenced_block vcs_qemu_block \
    "$vcs_section8" '```bash' 'PCIE_PREF64_RESERVE=256M' \
    'the section 8 QEMU launch command'
require_exact_line "$vcs_qemu_block" \
    'make run-qemu NUM_PFS=4 PCIE_PREF64_RESERVE=256M' \
    'section 8 must retain the matching four-PF QEMU command'
get_fenced_block vcs_real_dut_block \
    "$vcs_section8" '```text' '+CFG_PROFILE=DPU_20F9_501X' \
    'the section 8 real-DUT plusargs'
require_exact_line "$vcs_real_dut_block" \
    '+REAL_DUT +BYPASS_CONFIG=1 +CFG_PROFILE=DPU_20F9_501X +NUM_PFS=4 +MAX_VFS=16' \
    'section 8 must retain the real-DUT plusarg command'

require_text_literal "$vcs_section8" '批处理运行应加 `+COSIM_AUTOSTART`' \
    'section 8 must describe the batch autostart mode'
require_text_literal "$vcs_section8" \
    '需要先运行 VIP 再切换的分阶段交互模式则省略该 plusarg，并在 UCLI 中执行' \
    'section 8 must retain the staged UCLI mode'
require_text_literal "$vcs_section8" '`start_cosim`。两种启动方式二选一' \
    'section 8 must name the staged UCLI transition command'
require_text_literal "$vcs_section8" '`+COSIM_AUTOSTART` 不是全局默认' \
    'section 8 must state that autostart is not a global default'
require_text_literal "$vcs_section8" '**TLM stand-in** 测试，不包含用户的 RTL DUT' \
    'section 8 must state that the standalone TLM test has no user RTL DUT'
require_text_literal "$vcs_section8" \
    '仅在命令行加 `+REAL_DUT` 不能把它变成真实 DUT 测试' \
    'section 8 must state that +REAL_DUT cannot create a real RTL DUT'
require_text_literal "$vcs_section8" \
    '当前 completion ownership 已保证每种模式只选择一条消费路径' \
    'section 8 must describe the repaired completion ownership'
require_text_literal "$vcs_section8" '用户自己的 top' \
    'section 8 must require a user real-DUT top'
require_text_literal "$vcs_section8" 'Completion 的唯一来源' \
    'section 8 must require one DUT completion source'
forbid_text_literal "$vcs_section8" 'Unexpected Completion' \
    'section 8 still claims the repaired direct/monitor path must duplicate completions'
forbid_text_literal "$vcs_section8" 'no QEMU tag map' \
    'section 8 still claims the repaired ownership path must lose the QEMU tag map'

expect_mutation_rejected driver_block_is_valid \
    "$task7_driver_block" "$driver_cmd" "$bare_driver_cmd" \
    'Task 7 bare-driver command'
expect_mutation_rejected driver_block_is_valid \
    "$task9_driver_block" "$driver_cmd" "$bare_driver_cmd" \
    'Task 9 bare-driver command'
expect_mutation_rejected task9_compile_block_is_valid \
    "$task9_compile_block" "$absolute_bridge_line" "$relative_bridge_line" \
    'Task 9 relative-archive command'
expect_mutation_rejected task9_run_block_is_valid \
    "$task9_run_block" "$autostart_line" "$no_autostart_line" \
    'Task 9 no-autostart command'
expect_insertion_rejected task10_relocated_import_block_is_valid \
    "$task10_relocated_import_block" "$task10_git_archive_line" \
    "$task10_old_extract_line" \
    'Task 10 setup-from-data-archive command'
expect_insertion_rejected task10_relocated_import_block_is_valid \
    "$task10_relocated_import_block" "$task10_git_archive_line" \
    "$task10_quoted_extract_line" \
    'Task 10 quoted-setup-from-data-archive command'

if ((failures != 0)); then
    echo "[workflow-command-contracts] $failures contract check(s) failed" >&2
    exit 1
fi

echo '[workflow-command-contracts] PASS'
