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
        find . -type f -print0 | sort -z | xargs -0 sha256sum
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

[[ -x "$apply_script" ]] || fail "apply script is absent"

missing="$work/missing-anchor/host-driver-net"
make_driver "$missing"
sed -i 's/goto workqueue_init_err;/goto missing_anchor;/' "$missing/main.c"
expect_failure_without_change "missing anchor" "$missing" \
    "$apply_script" "$missing"

valid="$work/valid/host-driver-net"
make_driver "$valid"
"$apply_script" "$valid"
for copied in cosim_table_ctrl.c cosim_table_ctrl.h \
              cosim_table_ctrl_uapi.h cosim_table_protocol.h; do
    [[ -f "$valid/$copied" ]] || fail "valid apply omitted $copied"
done
cmp "$valid/cosim_table_ctrl.c" \
    "$repo/guest/dpu-table-sideband/cosim_table_ctrl.c" ||
    fail "controller source was not copied byte-for-byte"
cmp "$valid/cosim_table_ctrl.h" \
    "$repo/guest/dpu-table-sideband/cosim_table_ctrl.h" ||
    fail "controller header was not copied byte-for-byte"
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
