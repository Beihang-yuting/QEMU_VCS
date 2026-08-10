#!/usr/bin/env bash
set -euo pipefail

src=${1:-}
if [ -z "$src" ] || [ ! -d "$src" ]; then
    echo "Usage: $0 DRIVER_SOURCE_DIR" >&2
    exit 2
fi

main="$src/main.c"
af_c="$src/af_mng.c"
af_h="$src/af_mng.h"
common="$src/common.h"
for file in "$main" "$af_c" "$af_h" "$common"; do
    [ -f "$file" ] || {
        echo "FAIL: missing driver source file: $file" >&2
        exit 1
    }
done

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local signature=$1
    local file=$2
    sed -n "/$signature/,/^}/p" "$file"
}

grep -Eq '^static bool skip_eth_scan;$' "$main" || \
    fail 'skip_eth_scan must be a default-false static bool'
grep -Fq 'module_param(skip_eth_scan, bool, 0444);' "$main" || \
    fail 'skip_eth_scan must be a read-only bool module parameter'
grep -Fq 'MODULE_PARM_DESC(skip_eth_scan,' "$main" || \
    fail 'skip_eth_scan parameter description is missing'

task1=$(extract_function 'static void dpu_service_task1(' "$main")
grep -Fq 'dpu_purge_mailbox_event(adapter);' <<<"$task1" || \
    fail 'service task1 lost mailbox purge'
grep -Fq 'if (!skip_eth_scan)' <<<"$task1" || \
    fail 'service task1 does not gate the optical scan'
grep -Fq 'dpu_optical_link_subtask(adapter);' <<<"$task1" || \
    fail 'service task1 lost the default optical scan'

task2=$(extract_function 'static void dpu_service_task2(' "$main")
grep -Fq 'dpu_notify_backend_virtqueue_subtask(adapter);' <<<"$task2" || \
    fail 'service task2 lost virtqueue notification'
grep -Fq 'dpu_reset_subtask(adapter);' <<<"$task2" || \
    fail 'service task2 lost reset handling'
grep -Fq 'if (skip_eth_scan)' <<<"$task2" || \
    fail 'service task2 does not select bypass mode'
grep -Fq 'dpu_force_eth_link_up_subtask(&adapter->hw);' <<<"$task2" || \
    fail 'service task2 does not invoke forced Link Up'
grep -Fq 'dpu_process_eth_status_subtask(&adapter->hw);' <<<"$task2" || \
    fail 'service task2 lost the default status path'

grep -Fq 'void dpu_force_eth_link_up_subtask(struct dpu_hw *hw);' "$af_h" || \
    fail 'forced Link Up declaration is missing'
force_body=$(extract_function 'void dpu_force_eth_link_up_subtask(' "$af_c")
[ -n "$force_body" ] || fail 'forced Link Up implementation is missing'
grep -Fq 'spin_lock_irqsave(&adapter->eth_status_lock, flags);' <<<"$force_body" || \
    fail 'forced Link Up does not use the ETH status lock'
grep -Fq 'DPU_ADD_ETH_2_BC' <<<"$force_body" || \
    fail 'forced Link Up does not add offline ports'
grep -Fq 'DPU_ETH_ACTION_BUILD' <<<"$force_body" || \
    fail 'forced Link Up does not make online ports idempotent'
grep -Fq 'dpu_cfg_eth_2_bc(hw, &action_mng);' <<<"$force_body" || \
    fail 'AF carrier/VLAN action path is not reused'
grep -Fq 'dpu_cfg_host_eth_stats(hw, &action_mng);' <<<"$force_body" || \
    fail 'host ETH carrier action path is not reused'
if grep -Fq 'rd32(' <<<"$force_body"; then
    fail 'forced Link Up must not read DUT registers'
fi

grep -Fq '#define DPU_QID_MAP_TABLE_ENTRIES(hw) (128)' "$common" || \
    fail '128-QID baseline was not preserved'
grep -A10 'static inline u16 dpu_get_vnet_num' "$common" | \
    grep -Fq 'static u16 queue_num = 0;' || \
    fail 'VNET queue-count cache was not preserved'
if grep -Fq 'DPU_DEVICE_ID_PF1' "$main"; then
    fail 'PF1 binding must remain disabled'
fi

echo 'PASS: DPU skip_eth_scan source contract'
