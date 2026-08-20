#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$script_dir/../.." && pwd)
patch_file="$repo/guest/dpu-table-sideband/0004-dpu-table-frontdoor-throttle.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-frontdoor-throttle.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

[[ -f "$patch_file" ]] || {
    echo "missing throttle patch: $patch_file" >&2
    exit 1
}
[[ $(sed -n -e 's/^--- //p' -e 's/^+++ //p' "$patch_file" |
    sed '/^\/dev\/null$/d;s,^[ab]/,,' | sort -u) == $'common.h\nmain.c' ]] || {
    echo "throttle patch must modify only common.h and main.c" >&2
    exit 1
}

cat >"$work/hw.h" <<'EOF'
#ifndef TEST_HW_H
#define TEST_HW_H
#include <stddef.h>
#include <stdint.h>

typedef uint8_t u8;
/* Keep the minimal fixture warning-clean for the vendor wrapper's int index. */
typedef int32_t u32;
typedef uint64_t u64;
typedef struct {
    uint64_t value;
} atomic64_t;

#define __iomem
#define unlikely(condition) (condition)

static inline void atomic64_set(atomic64_t *counter, uint64_t value)
{
    counter->value = value;
}

static inline uint64_t atomic64_read(const atomic64_t *counter)
{
    return counter->value;
}

static inline uint64_t atomic64_inc_return(atomic64_t *counter)
{
    return ++counter->value;
}

void test_writel(u32 value, u8 *address);
u32 test_readl(u8 *address);
#define writel(value, address) test_writel((value), (address))
#define readl(address) test_readl((address))
#endif
EOF

: >"$work/register.h"
: >"$work/compat.h"
cat >"$work/cosim_table_ctrl.h" <<'EOF'
#ifndef TEST_COSIM_TABLE_CTRL_H
#define TEST_COSIM_TABLE_CTRL_H
enum dpu_table_submit_result {
    DPU_TABLE_FRONTDOOR = 0,
    DPU_TABLE_SUCCESS = 1,
    DPU_TABLE_ERROR = 2,
};
enum dpu_table_write_order {
    DPU_TABLE_LOW_TO_HIGH = 0,
    DPU_TABLE_HIGH_TO_LOW = 1,
};
struct dpu_hw;
enum dpu_table_submit_result dpu_table_submit(
    struct dpu_hw *hw, unsigned int logical_bar, u64 offset,
    const void *data, u32 bytes, enum dpu_table_write_order order);
u32 dpu_table_frontdoor_flush_interval_get(void);
#define DPU_MEMORY_BAR 0
#endif
EOF

cat >"$work/common.h" <<'EOF'
#ifndef __DPU_COMMON_H
#define __DPU_COMMON_H
#include "hw.h"
#include "register.h"
#include "compat.h"
#include "cosim_table_ctrl.h"


#define __FILENAME__ (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)

struct dpu_hw {
	void *adapter;

	u8 __iomem *hw_addr;
	u8 __iomem *msix_bar_hw_addr;
	u8 __iomem *mailbox_bar_hw_addr;
};

#define wr32(hw, reg, value) writel((value), ((hw)->hw_addr + (reg)))
#define rd32(hw, reg) readl((hw)->hw_addr + (reg))

/* COSIM_TABLE_SIDEBAND_PATCH_0002 */
static inline void wr32_for_each(struct dpu_hw *hw, u64 reg,
				 const void *value, u32 size)
{
	enum dpu_table_submit_result result;
	int __n;

	result = dpu_table_submit(hw, DPU_MEMORY_BAR, reg, value, size,
				  DPU_TABLE_LOW_TO_HIGH);
	if (result == DPU_TABLE_SUCCESS)
		return;
	if (result == DPU_TABLE_ERROR)
		return;
	for (__n = 0; __n < size; __n += 4)
		wr32(hw, reg + __n, ((const u32 *)value)[__n >> 2]);
}

static inline void wr32_for_high_order(struct dpu_hw *hw, u64 reg,
				       const void *value, u32 size)
{
	enum dpu_table_submit_result result;
	int __n;

	result = dpu_table_submit(hw, DPU_MEMORY_BAR, reg, value, size,
				  DPU_TABLE_HIGH_TO_LOW);
	if (result == DPU_TABLE_SUCCESS)
		return;
	if (result == DPU_TABLE_ERROR)
		return;
	for (__n = size - 4; __n >= 0; __n -= 4)
		wr32(hw, reg + __n, ((const u32 *)value)[__n >> 2]);
}
#define rd32_for_each(hw, reg, value, size)                                    \
	do {                                                                   \
		int __n;                                                       \
		for (__n = 0; __n < (size); __n += 4)                          \
			((u32 *)(value))[__n >> 2] = rd32((hw), (reg) + __n);  \
	} while (0)

#define wr32_zero_for_each(hw, reg, size) do { wr32((hw), (reg), 0); } while (0)
#define wr64mix(hw, reg, value) do { wr32((hw), (reg), (value)); } while (0)
#define wr32_mailbox(hw, reg, value) writel((value), ((hw)->mailbox_bar_hw_addr + (reg)))
#define wr32_msix(hw, reg, value) writel((value), ((hw)->msix_bar_hw_addr + (reg)))
#endif
EOF
sed -i 's/$/\r/' "$work/common.h"

cat >"$work/main.c" <<'EOF'
#include "uart.h"
#include "tool_genl_com.h"
#include "deinit_restore.h"
#include "cosim_table_ctrl.h"

static bool table_backdoor;
module_param(table_backdoor, bool, 0444);
MODULE_PARM_DESC(table_backdoor, "Enable CoSim semantic table sideband");

bool dpu_table_backdoor_enabled(void)
{
	return table_backdoor;
}

static bool af_mode = true;
module_param(af_mode, bool, 0444);
MODULE_PARM_DESC(af_mode, "Pf acts as af or not");

static int dpu_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct dpu_adapter *adapter;
    struct dpu_hw *hw;

	mutex_init(&adapter->stats.lock);
	hw = &adapter->hw;
	hw->adapter = adapter;

	set_bit(DPU_DOWN, adapter->state);

    return 0;
}

static int __init dpu_module_init(void)
{
	int err;
	int i;

	for (i = 0; i < DEV_HASH_SIZE; i++)
		INIT_HLIST_HEAD(&dev_hash_table[i]);

    return err;
}
EOF

patch --batch --binary --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- \
    -d "$work" -p1 <"$patch_file"

python3 - "$work" "$repo" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
repo = Path(sys.argv[2])
common = (root / "common.h").read_text()
main = (root / "main.c").read_text()
ctrl = (repo / "guest/dpu-table-sideband/cosim_table_ctrl.h").read_text()

def function(text, signature):
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for pos in range(brace, len(text)):
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0:
                return text[start:pos + 1]
    raise AssertionError(f"unterminated function: {signature}")

assert re.search(
    r"static\s+unsigned\s+int\s+table_frontdoor_flush_interval\s*=\s*100\s*;",
    main)
assert re.search(
    r"module_param\s*\(\s*table_frontdoor_flush_interval\s*,\s*uint\s*,\s*0444\s*\)\s*;",
    main)
assert re.search(
    r'MODULE_PARM_DESC\s*\(\s*table_frontdoor_flush_interval\s*,\s*'
    r'"Flush table frontdoor writes after this many DWORDs \(0 disables\)"\s*\)\s*;',
    main)
declaration = "u32 dpu_table_frontdoor_flush_interval_get(void);"
assert ctrl.count(declaration) == 1
assert ctrl.index(declaration) < ctrl.index("bool dpu_table_backdoor_enabled(void);")
getter = function(main, "u32 dpu_table_frontdoor_flush_interval_get(")
assert "return table_frontdoor_flush_interval;" in getter

init = function(main, "static int __init dpu_module_init(")
assert ('pr_info("table frontdoor flush interval: %u DWORD writes\\n",'
        in init)
interval_logs = re.findall(
    r"pr_(?:info|notice)\s*\([^;]*table_frontdoor_flush_interval[^;]*;",
    init, re.DOTALL)
assert len(interval_logs) == 1, interval_logs

probe = function(main, "static int dpu_probe(")
adapter = probe.index("hw->adapter = adapter;")
counter = probe.index("atomic64_set(&hw->table_frontdoor_write_sequence, 0);")
assert adapter < counter
assert probe.count("atomic64_set(&hw->table_frontdoor_write_sequence, 0);") == 1

assert '#include "cosim_table_frontdoor_throttle_core.h"' in common
struct = common[common.index("struct dpu_hw {"):common.index("};", common.index("struct dpu_hw {"))]
assert struct.count("atomic64_t table_frontdoor_write_sequence;") == 1
assert "#define wr32(hw, reg, value) writel((value), ((hw)->hw_addr + (reg)))" in common

helper = function(common, "static inline void dpu_table_frontdoor_wr32(")
write = helper.index("wr32(hw, reg, value);")
interval = helper.index("interval = dpu_table_frontdoor_flush_interval_get();")
disabled = helper.index("if (!interval)", interval)
increment = helper.index("atomic64_inc_return(", disabled)
assert "&hw->table_frontdoor_write_sequence" in helper[increment:]
decision = helper.index("dpu_table_frontdoor_should_flush(sequence, interval)", increment)
readback = helper.index("(void)rd32(hw, reg);", decision)
assert write < interval < disabled < increment < decision < readback
assert "unlikely(dpu_table_frontdoor_should_flush(sequence, interval))" in helper

low = function(common, "static inline void wr32_for_each(")
high = function(common, "static inline void wr32_for_high_order(")
for body in (low, high):
    assert len(re.findall(
        r"dpu_table_frontdoor_wr32\s*\(\s*hw\s*,\s*reg\s*\+\s*__n\s*,",
        body)) == 1
    assert "wr32(hw, reg + __n," not in body
assert low.index("if (result == DPU_TABLE_ERROR)") < low.index(
    "dpu_table_frontdoor_wr32(")
assert high.index("if (result == DPU_TABLE_ERROR)") < high.index(
    "dpu_table_frontdoor_wr32(")
assert common.count("dpu_table_frontdoor_wr32(") == 3
for unchanged in (
    "#define wr32_zero_for_each(hw, reg, size) do { wr32((hw), (reg), 0); } while (0)",
    "#define wr64mix(hw, reg, value) do { wr32((hw), (reg), (value)); } while (0)",
    "#define wr32_mailbox(hw, reg, value) writel((value), ((hw)->mailbox_bar_hw_addr + (reg)))",
    "#define wr32_msix(hw, reg, value) writel((value), ((hw)->msix_bar_hw_addr + (reg)))",
):
    assert unchanged in common
print("frontdoor throttle source contract passed")
PY

cat >"$work/throttle_test.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>

#include "common.h"

#define MAX_EVENTS 1024
struct event {
    char kind;
    u8 *address;
};

static struct event events[MAX_EVENTS];
static size_t event_count;
static size_t write_count;
static size_t read_count;
static unsigned int flush_interval = 100;
static enum dpu_table_submit_result submit_result = DPU_TABLE_FRONTDOOR;

static void fail(const char *message)
{
    fprintf(stderr, "FAIL: %s\n", message);
    exit(1);
}

static void expect(int condition, const char *message)
{
    if (!condition)
        fail(message);
}

static void reset_events(void)
{
    event_count = 0;
    write_count = 0;
    read_count = 0;
}

void test_writel(u32 value, u8 *address)
{
    (void)value;
    expect(event_count < MAX_EVENTS, "event log overflow");
    events[event_count++] = (struct event){ .kind = 'W', .address = address };
    write_count++;
}

u32 test_readl(u8 *address)
{
    expect(event_count < MAX_EVENTS, "event log overflow");
    events[event_count++] = (struct event){ .kind = 'R', .address = address };
    read_count++;
    return 0;
}

u32 dpu_table_frontdoor_flush_interval_get(void)
{
    return flush_interval;
}

enum dpu_table_submit_result dpu_table_submit(
    struct dpu_hw *hw, unsigned int logical_bar, u64 offset,
    const void *data, u32 bytes, enum dpu_table_write_order order)
{
    (void)hw;
    (void)logical_bar;
    (void)offset;
    (void)data;
    (void)bytes;
    (void)order;
    return submit_result;
}

static void write_one(struct dpu_hw *hw, u64 reg)
{
    const u32 value = (u32)reg;
    wr32_for_each(hw, reg, &value, sizeof(value));
}

int main(void)
{
    u8 *const base_a = (u8 *)(uintptr_t)0x10000000u;
    u8 *const base_b = (u8 *)(uintptr_t)0x20000000u;
    struct dpu_hw first = { .hw_addr = base_a };
    struct dpu_hw second = { .hw_addr = base_b };
    const u32 pair[2] = { 0x11111111u, 0x22222222u };
    unsigned int index;

    flush_interval = 100;
    submit_result = DPU_TABLE_FRONTDOOR;
    reset_events();
    for (index = 0; index < 99; index++)
        write_one(&first, 0x1000u + index * 4u);
    expect(write_count == 99, "first 99 DWORD writes missing");
    expect(read_count == 0, "readback happened before the 100th DWORD");
    write_one(&first, 0x3000u);
    expect(write_count == 100, "100th DWORD was not written");
    expect(read_count == 1, "100th DWORD did not trigger one readback");
    expect(event_count == 101 && events[99].kind == 'W' &&
           events[100].kind == 'R', "100th write was not immediately followed by readback");
    expect(events[99].address == base_a + 0x3000u &&
           events[100].address == base_a + 0x3000u,
           "readback did not use the just-written 100th address");

    reset_events();
    atomic64_set(&first.table_frontdoor_write_sequence, 99);
    wr32_for_high_order(&first, 0x4000u, pair, sizeof(pair));
    expect(write_count == 2 && read_count == 1,
           "high-order fallback did not write two DWORDs and read once");
    expect(event_count == 3 && events[0].kind == 'W' &&
           events[0].address == base_a + 0x4004u &&
           events[1].kind == 'R' && events[1].address == base_a + 0x4004u &&
           events[2].kind == 'W' && events[2].address == base_a + 0x4000u,
           "high-order fallback did not flush its first high DWORD address");

    reset_events();
    flush_interval = 0;
    atomic64_set(&first.table_frontdoor_write_sequence, 0);
    for (index = 0; index < 200; index++)
        write_one(&first, 0x5000u + index * 4u);
    expect(write_count == 200 && read_count == 0,
           "disabled throttling generated a readback");
    expect(atomic64_read(&first.table_frontdoor_write_sequence) == 0,
           "disabled throttling incremented the write sequence");

    flush_interval = 100;
    for (submit_result = DPU_TABLE_SUCCESS;
         submit_result <= DPU_TABLE_ERROR; submit_result++) {
        reset_events();
        atomic64_set(&first.table_frontdoor_write_sequence, 0);
        wr32_for_each(&first, 0x6000u, pair, sizeof(pair));
        wr32_for_high_order(&first, 0x7000u, pair, sizeof(pair));
        expect(write_count == 0 && read_count == 0,
               "SUCCESS/ERROR path accessed MMIO");
        expect(atomic64_read(&first.table_frontdoor_write_sequence) == 0,
               "SUCCESS/ERROR path incremented the write sequence");
    }

    submit_result = DPU_TABLE_FRONTDOOR;
    reset_events();
    atomic64_set(&first.table_frontdoor_write_sequence, 0);
    atomic64_set(&second.table_frontdoor_write_sequence, 0);
    for (index = 0; index < 99; index++) {
        write_one(&first, 0x8000u + index * 4u);
        write_one(&second, 0x9000u + index * 4u);
    }
    expect(read_count == 0, "per-device counters flushed before 100 writes");
    write_one(&first, 0xa000u);
    expect(read_count == 1 && events[event_count - 1].address == base_a + 0xa000u,
           "first device did not independently flush at 100 writes");
    write_one(&second, 0xb000u);
    expect(read_count == 2 && events[event_count - 1].address == base_b + 0xb000u,
           "second device did not independently flush at 100 writes");

    puts("frontdoor throttle runtime contract passed");
    return 0;
}
EOF

cc -std=c11 -Wall -Wextra -Werror -I"$work" \
   -I"$repo/guest/dpu-table-sideband" \
   "$work/throttle_test.c" -o "$work/throttle_test"
"$work/throttle_test"

patch --batch --force --reverse --binary --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- -d "$work" -p1 --dry-run \
    <"$patch_file" >/dev/null
