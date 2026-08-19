#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)
apply_script="$repo/scripts/apply_dpu_table_sideband.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-table-overlay.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

fail()
{
    echo "[dpu-table-overlay] FAIL: $*" >&2
    exit 1
}

snapshot()
{
    local tree=$1

    (
        cd "$tree"
        {
            find -P . -printf '%y %P %m %l\n'
            find -P . -type f -print0 | sort -z | xargs -0 sha256sum
        } | sort
    )
}

make_driver()
{
    local tree=$1

    mkdir -p "$tree"
    cat >"$tree/Makefile" <<'EOF'
obj-y += bonding/
endif

# Put at last to save the `ccflags`.
DPU_BUILD_FLAGS := $(ccflags-y)
ccflags-y += -DDPU_BUILD_FLAGS="$(DPU_BUILD_FLAGS)"

obj-m += dpu_snd1.o

dpu_snd1-objs += main.o \
	adapter_ops.o \
	af_mng.o \
	interrupt.o \
	deinit_restore.o

endif
EOF
    cat >"$tree/main.c" <<'EOF'
#include "uart.h"
#include "tool_genl_com.h"
#include "deinit_restore.h"

static bool af_mode = true;
module_param(af_mode, bool, 0444);

static int __init dpu_module_init(void)
{
	err = dpu_workqueue_init();
	if (err) {
		pr_err("Failed to create workqueue, err = %d\n", err);
		goto workqueue_init_err;
	}

	err = pci_register_driver(&dpu_driver);
	if (err) {
		pr_err("Failed to register PCI driver, err = %d\n", err);
		goto pci_register_err;
	}

netevent_register_err:
	pci_unregister_driver(&dpu_driver);
pci_register_err:
	dpu_destroy_workqueue();
workqueue_init_err:
	dpu_debugfs_exit();

	return err;
}

static void __exit dpu_module_exit(void)
{
	dpu_arp_cache_cleanup();

	pci_unregister_driver(&dpu_driver);
	dpu_destroy_workqueue();
	dpu_uart_exit();
	dpu_debugfs_exit();
}
EOF
    cat >"$tree/common.h" <<'EOF'
#ifndef __DPU_COMMON_H
#define __DPU_COMMON_H
#include "hw.h"
#include "register.h"
#include "compat.h"


#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

#define wr32(hw, reg, value) writel((value), ((hw)->hw_addr + (reg)))
#define rd32(hw, reg) readl((hw)->hw_addr + (reg))

#define wr32_for_each(hw, reg, value, size)                                    \
	do {                                                                   \
		int __n;                                                       \
		for (__n = 0; __n < (size); __n += 4)                          \
			wr32((hw), (reg) + __n, ((u32 *)(value))[__n >> 2]);   \
	} while (0)
#define wr32_for_high_order(hw, reg, value, size)                              \
	do {                                                                   \
		int __n;                                                       \
		for (__n = (size - 4); __n >= 0; __n -= 4)                     \
			wr32((hw), (reg) + __n, ((u32 *)(value))[__n >> 2]);   \
	} while (0)
#define rd32_for_each(hw, reg, value, size)                                    \
	do {                                                                   \
		int __n;                                                       \
		for (__n = 0; __n < (size); __n += 4)                          \
			((u32 *)(value))[__n >> 2] = rd32((hw), (reg) + __n);  \
	} while (0)
#endif
EOF
    sed -i 's/$/\r/' "$tree/common.h"
    cp "$repo/tests/fixtures/dpu_qid_reference/af_mng.c" \
        "$repo/tests/fixtures/dpu_qid_reference/af_mng.h" \
        "$repo/tests/fixtures/dpu_qid_reference/deinit_restore.c" \
        "$repo/tests/fixtures/dpu_qid_reference/mailbox.c" \
        "$repo/tests/fixtures/dpu_qid_reference/mailbox.h" "$tree/"
    cat "$repo/tests/fixtures/dpu_qid_reference/main.c" >>"$tree/main.c"
    printf '%s\n' original-sentinel >"$tree/original.txt"
}

expect_failure_without_change()
{
    local label=$1
    local tree=$2
    shift 2
    local before after

    before=$(snapshot "$tree")
    if "$@"; then
        fail "$label unexpectedly succeeded"
    fi
    after=$(snapshot "$tree")
    [[ "$before" == "$after" ]] || fail "$label changed the live tree"
}

expect_symlink_rejection()
{
    local label=$1
    local tree=$2
    local external=$3
    shift 3
    local tree_before tree_after external_before external_after status

    tree_before=$(snapshot "$tree")
    external_before=$(snapshot "$external")
    set +e
    "$@" >/dev/null 2>&1
    status=$?
    set -e
    tree_after=$(snapshot "$tree")
    external_after=$(snapshot "$external")
    [[ "$external_before" == "$external_after" ]] ||
        fail "$label modified an external target"
    [[ "$tree_before" == "$tree_after" ]] ||
        fail "$label changed the live tree"
    ((status != 0)) || fail "$label unexpectedly accepted a symlink"
    [[ -z $(find "$(dirname "$tree")" -maxdepth 1 -type d \
        -name '.cosim-table-transaction.*' -print -quit) ]] ||
        fail "$label left a transaction directory"
}

make_unsafe_overlay()
{
    local test_repo=$1 patch_path=$2

    mkdir -p "$test_repo/scripts" "$test_repo/guest/dpu-table-sideband" \
        "$test_repo/bridge/table"
    cp "$apply_script" "$test_repo/scripts/apply_dpu_table_sideband.sh"
    cp "$repo/guest/dpu-table-sideband/cosim_table_ctrl.c" \
        "$repo/guest/dpu-table-sideband/cosim_table_ctrl.h" \
        "$repo/guest/dpu-table-sideband/cosim_table_batch_core.h" \
        "$test_repo/guest/dpu-table-sideband/"
    cp "$repo/bridge/table/cosim_table_ctrl_uapi.h" \
        "$repo/bridge/table/cosim_table_protocol.h" \
        "$test_repo/bridge/table/"
    {
        printf '%s\n' "--- $patch_path"
        printf '%s\n' '+++ b/Makefile'
        printf '%s\n' '@@ -1 +1 @@' '-old' '+new'
    } >"$test_repo/guest/dpu-table-sideband/0001-unsafe-path.patch"
}

expect_unsafe_patch_rejection()
{
    local label=$1 patch_path=$2
    local case_dir="$work/$label" test_repo tree before after output status

    test_repo="$case_dir/repo"
    tree="$case_dir/host-driver-net"
    make_unsafe_overlay "$test_repo" "$patch_path"
    make_driver "$tree"
    before=$(snapshot "$tree")
    set +e
    output=$("$test_repo/scripts/apply_dpu_table_sideband.sh" "$tree" 2>&1)
    status=$?
    set -e
    after=$(snapshot "$tree")
    ((status != 0)) || fail "$label unexpectedly accepted an unsafe path"
    [[ "$output" == *"error: unsafe path in overlay patch: $patch_path"* ]] ||
        fail "$label was not rejected by path validation"
    [[ "$before" == "$after" ]] || fail "$label changed the live tree"
    [[ $(<"$tree/original.txt") == original-sentinel ]] ||
        fail "$label changed the live sentinel"
    [[ -z $(find "$case_dir" -maxdepth 1 -type d \
        -name '.cosim-table-transaction.*' -print -quit) ]] ||
        fail "$label left a transaction directory"
}

[[ -x "$apply_script" ]] || fail "apply script is absent"

expect_unsafe_patch_rejection "trailing-empty-path-component" \
    'a/Makefile/'
expect_unsafe_patch_rejection "doubled-path-separator" \
    'a//Makefile'

missing="$work/missing-anchor/host-driver-net"
make_driver "$missing"
sed -i 's/goto workqueue_init_err;/goto missing_anchor;/' "$missing/main.c"
expect_failure_without_change "missing anchor" "$missing" \
    "$apply_script" "$missing"

valid="$work/valid/host-driver-net"
make_driver "$valid"
"$apply_script" "$valid"
for copied in cosim_table_ctrl.c cosim_table_ctrl.h cosim_table_batch_core.h \
              cosim_table_ctrl_uapi.h cosim_table_protocol.h; do
    [[ -f "$valid/$copied" ]] || fail "valid apply omitted $copied"
done
cmp "$valid/cosim_table_ctrl.c" \
    "$repo/guest/dpu-table-sideband/cosim_table_ctrl.c" ||
    fail "controller source was not copied byte-for-byte"
cmp "$valid/cosim_table_ctrl.h" \
    "$repo/guest/dpu-table-sideband/cosim_table_ctrl.h" ||
    fail "controller header was not copied byte-for-byte"
cmp "$valid/cosim_table_batch_core.h" \
    "$repo/guest/dpu-table-sideband/cosim_table_batch_core.h" ||
    fail "batch core header was not copied byte-for-byte"
cmp "$valid/cosim_table_ctrl_uapi.h" \
    "$repo/bridge/table/cosim_table_ctrl_uapi.h" ||
    fail "controller UAPI was not copied byte-for-byte"
cmp "$valid/cosim_table_protocol.h" \
    "$repo/bridge/table/cosim_table_protocol.h" ||
    fail "table protocol was not copied byte-for-byte"
grep -Fq COSIM_TABLE_SIDEBAND_PATCH_0001 "$valid/Makefile" ||
    fail "Makefile patch marker is absent"
grep -Fq 'module_param(table_backdoor, bool, 0444)' "$valid/main.c" ||
    fail "module parameter patch is absent"
grep -Fq 'dpu_table_ctrl_register()' "$valid/main.c" ||
    fail "controller registration patch is absent"
[[ -f "$valid/.cosim-table-sideband-applied/0001-dpu-table-sideband-core.patch.applied" ]] ||
    fail "patch application marker is absent"

before_second=$(snapshot "$valid")
"$apply_script" "$valid"
after_second=$(snapshot "$valid")
[[ "$before_second" == "$after_second" ]] ||
    fail "second apply changed file checksums"

injected="$work/injected/host-driver-net"
make_driver "$injected"
expect_failure_without_change "injected first-stage failure" "$injected" \
    env COSIM_TABLE_FAIL_AFTER_STAGE_FILE=1 "$apply_script" "$injected"

managed_link="$work/managed-link/host-driver-net"
managed_external="$work/managed-link/external"
make_driver "$managed_link"
mkdir -p "$managed_external"
printf '%s\n' managed-sentinel >"$managed_external/controller.c"
ln -s "$managed_external/controller.c" "$managed_link/cosim_table_ctrl.c"
expect_symlink_rejection "managed-file symlink" "$managed_link" \
    "$managed_external" "$apply_script" "$managed_link"

patch_link="$work/patch-link/host-driver-net"
patch_external="$work/patch-link/external"
make_driver "$patch_link"
mkdir -p "$patch_external"
mv "$patch_link/Makefile" "$patch_external/Makefile"
ln -s "$patch_external/Makefile" "$patch_link/Makefile"
expect_symlink_rejection "patch-target symlink" "$patch_link" \
    "$patch_external" "$apply_script" "$patch_link"

marker_dir_link="$work/marker-dir-link/host-driver-net"
marker_dir_external="$work/marker-dir-link/external"
make_driver "$marker_dir_link"
mkdir -p "$marker_dir_external"
printf '%s\n' marker-dir-sentinel >"$marker_dir_external/sentinel"
ln -s "$marker_dir_external" \
    "$marker_dir_link/.cosim-table-sideband-applied"
expect_symlink_rejection "marker-directory symlink" "$marker_dir_link" \
    "$marker_dir_external" "$apply_script" "$marker_dir_link"

marker_file_link="$work/marker-file-link/host-driver-net"
marker_file_external="$work/marker-file-link/external"
make_driver "$marker_file_link"
"$apply_script" "$marker_file_link"
mkdir -p "$marker_file_external"
printf '%s\n' marker-file-sentinel >"$marker_file_external/marker"
marker_file="$marker_file_link/.cosim-table-sideband-applied/0001-dpu-table-sideband-core.patch.applied"
rm -f "$marker_file"
ln -s "$marker_file_external/marker" "$marker_file"
expect_symlink_rejection "marker-file symlink" "$marker_file_link" \
    "$marker_file_external" "$apply_script" "$marker_file_link"

rename_driver="$work/rename-failure/host-driver-net"
rename_wrapper="$work/rename-failure/rename-wrapper"
rename_count="$work/rename-failure/rename-count"
make_driver "$rename_driver"
cat >"$rename_wrapper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$COSIM_TABLE_RENAME_COUNT" ]]; then
    read -r count <"$COSIM_TABLE_RENAME_COUNT"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$COSIM_TABLE_RENAME_COUNT"
if [[ $count -eq 2 ]]; then
    exit 99
fi
exec "$COSIM_TABLE_REAL_MV" "$@"
EOF
chmod +x "$rename_wrapper"
expect_failure_without_change "injected second-rename failure" "$rename_driver" \
    env COSIM_TABLE_RENAME_BIN="$rename_wrapper" \
        COSIM_TABLE_RENAME_COUNT="$rename_count" \
        COSIM_TABLE_REAL_MV="$(command -v mv)" \
        "$apply_script" "$rename_driver"
[[ $(<"$rename_count") -eq 3 ]] ||
    fail "second-rename rollback did not restore through the rename hook"

echo "PASS: transactional DPU table overlay application"
