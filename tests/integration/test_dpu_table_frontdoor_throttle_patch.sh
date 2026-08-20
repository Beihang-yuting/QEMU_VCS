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
#include <pthread.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdint.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef struct {
    _Atomic uint64_t value;
} atomic64_t;
typedef struct {
    pthread_mutex_t mutex;
} spinlock_t;

#define __iomem
#define unlikely(condition) (condition)

static inline void atomic64_set(atomic64_t *counter, uint64_t value)
{
    atomic_store_explicit(&counter->value, value, memory_order_relaxed);
}

static inline uint64_t atomic64_read(const atomic64_t *counter)
{
    return atomic_load_explicit(&counter->value, memory_order_relaxed);
}

static inline uint64_t atomic64_inc_return(atomic64_t *counter)
{
    return atomic_fetch_add_explicit(&counter->value, 1,
                                     memory_order_relaxed) + 1;
}

void test_spin_lock_pre_acquire(spinlock_t *lock);

static inline void test_spin_lock_init(spinlock_t *lock)
{
    if (pthread_mutex_init(&lock->mutex, NULL) != 0)
        abort();
}

static inline void test_spin_lock_acquire(spinlock_t *lock)
{
    test_spin_lock_pre_acquire(lock);
    if (pthread_mutex_lock(&lock->mutex) != 0)
        abort();
}

static inline void test_spin_lock_release(spinlock_t *lock)
{
    if (pthread_mutex_unlock(&lock->mutex) != 0)
        abort();
}

#define spin_lock_init(lock) test_spin_lock_init((lock))
#define spin_lock_irqsave(lock, flags)                                         \
    do {                                                                       \
        (flags) = 0;                                                           \
        test_spin_lock_acquire((lock));                                        \
    } while (0)
#define spin_unlock_irqrestore(lock, flags)                                    \
    do {                                                                       \
        (void)(flags);                                                         \
        test_spin_lock_release((lock));                                        \
    } while (0)

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
lock_init_token = "spin_lock_init(&hw->table_frontdoor_write_lock);"
assert lock_init_token in probe, "probe does not initialize the pacing spinlock"
lock_init = probe.index(lock_init_token)
assert adapter < counter < lock_init
assert probe.count("atomic64_set(&hw->table_frontdoor_write_sequence, 0);") == 1
assert probe.count("spin_lock_init(&hw->table_frontdoor_write_lock);") == 1

assert '#include "cosim_table_frontdoor_throttle_core.h"' in common
struct = common[common.index("struct dpu_hw {"):common.index("};", common.index("struct dpu_hw {"))]
assert struct.count("atomic64_t table_frontdoor_write_sequence;") == 1
assert struct.count("spinlock_t table_frontdoor_write_lock;") == 1
assert "#define wr32(hw, reg, value) writel((value), ((hw)->hw_addr + (reg)))" in common

helper = function(common, "static inline void dpu_table_frontdoor_wr32(")
interval = helper.index("interval = dpu_table_frontdoor_flush_interval_get();")
disabled = helper.index("if (!interval)", interval)
unpaced_write = helper.index("wr32(hw, reg, value);", disabled)
unpaced_return = helper.index("return;", unpaced_write)
lock = helper.index(
    "spin_lock_irqsave(&hw->table_frontdoor_write_lock, flags);",
    unpaced_return)
paced_write = helper.index("wr32(hw, reg, value);", lock)
increment = helper.index("atomic64_inc_return(", paced_write)
assert "&hw->table_frontdoor_write_sequence" in helper[increment:]
decision = helper.index("dpu_table_frontdoor_should_flush(sequence, interval)", increment)
readback = helper.index("(void)rd32(hw, reg);", decision)
unlock = helper.index(
    "spin_unlock_irqrestore(&hw->table_frontdoor_write_lock, flags);",
    readback)
assert interval < disabled < unpaced_write < unpaced_return < lock
assert lock < paced_write < increment < decision < readback < unlock
assert "spin_lock" not in helper[disabled:unpaced_return]
assert "atomic64_" not in helper[disabled:unpaced_return]
assert helper.count("wr32(hw, reg, value);") == 2
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
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

/* The unchanged vendor loops compare their signed index with a u32 size. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare"
#include "common.h"
#pragma GCC diagnostic pop

#define MAX_EVENTS 1024
#define BAR_BYTES 0x10000u
struct event {
    char kind;
    u8 *address;
};

static u8 bar_a[BAR_BYTES];
static u8 bar_b[BAR_BYTES];
static struct event events[MAX_EVENTS];
static size_t event_count;
static size_t write_count;
static size_t read_count;
static pthread_mutex_t event_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned int writers_ready;
static _Atomic unsigned int writers_start;
static _Atomic unsigned int spin_lock_attempts;
static _Atomic unsigned int boundary_write_seen;
static _Atomic unsigned int boundary_write_release;
static _Atomic unsigned int follower_lock_attempted;
static _Atomic unsigned int boundary_gate_enabled;
static spinlock_t *boundary_lock;
static u8 *boundary_write_address;
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
    expect(pthread_mutex_lock(&event_lock) == 0, "event mutex lock failed");
    event_count = 0;
    write_count = 0;
    read_count = 0;
    expect(pthread_mutex_unlock(&event_lock) == 0,
           "event mutex unlock failed");
}

void test_spin_lock_pre_acquire(spinlock_t *lock)
{
    atomic_fetch_add_explicit(&spin_lock_attempts, 1, memory_order_relaxed);
    if (lock == boundary_lock &&
        atomic_load_explicit(&boundary_write_seen, memory_order_acquire) &&
        !atomic_load_explicit(&boundary_write_release,
                              memory_order_acquire))
        atomic_store_explicit(&follower_lock_attempted, 1,
                              memory_order_release);
}

void test_writel(u32 value, u8 *address)
{
    (void)value;
    expect(pthread_mutex_lock(&event_lock) == 0, "event mutex lock failed");
    expect(event_count < MAX_EVENTS, "event log overflow");
    events[event_count++] = (struct event){ .kind = 'W', .address = address };
    write_count++;
    expect(pthread_mutex_unlock(&event_lock) == 0,
           "event mutex unlock failed");
    if (atomic_load_explicit(&boundary_gate_enabled, memory_order_acquire) &&
        address == boundary_write_address) {
        atomic_store_explicit(&boundary_write_seen, 1, memory_order_release);
        while (!atomic_load_explicit(&boundary_write_release,
                                     memory_order_acquire))
            sched_yield();
    }
}

u32 test_readl(u8 *address)
{
    expect(pthread_mutex_lock(&event_lock) == 0, "event mutex lock failed");
    expect(event_count < MAX_EVENTS, "event log overflow");
    events[event_count++] = (struct event){ .kind = 'R', .address = address };
    read_count++;
    expect(pthread_mutex_unlock(&event_lock) == 0,
           "event mutex unlock failed");
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

struct writer_context {
    struct dpu_hw *hw;
    u64 first_reg;
};

struct single_writer_context {
    struct dpu_hw *hw;
    u64 reg;
    _Atomic unsigned int done;
};

static void *write_100_dwords(void *opaque)
{
    struct writer_context *context = opaque;
    unsigned int index;

    atomic_fetch_add_explicit(&writers_ready, 1, memory_order_release);
    while (!atomic_load_explicit(&writers_start, memory_order_acquire))
        sched_yield();
    for (index = 0; index < 100; index++)
        write_one(context->hw, context->first_reg + index * 4u);
    return NULL;
}

static void *write_single_dword(void *opaque)
{
    struct single_writer_context *context = opaque;

    write_one(context->hw, context->reg);
    atomic_store_explicit(&context->done, 1, memory_order_release);
    return NULL;
}

static void expect_device_events(u8 *base, u64 final_reg)
{
    size_t device_reads = 0;
    size_t device_writes = 0;
    u8 *last_write = NULL;
    size_t index;

    for (index = 0; index < event_count; index++) {
        uintptr_t address = (uintptr_t)events[index].address;
        uintptr_t first = (uintptr_t)base;

        if (address < first || address >= first + BAR_BYTES)
            continue;
        if (events[index].kind == 'W') {
            device_writes++;
            last_write = events[index].address;
            continue;
        }
        device_reads++;
        expect(device_writes == 100,
               "device readback did not follow its 100th write");
        expect(last_write == events[index].address,
               "device readback did not use its just-written address");
    }
    expect(device_writes == 100, "device did not issue exactly 100 writes");
    expect(device_reads == 1, "device did not issue exactly one readback");
    expect(last_write == base + final_reg,
           "device 100th write used an unexpected address");
}

int main(void)
{
    u8 *const base_a = bar_a;
    u8 *const base_b = bar_b;
    struct dpu_hw first = { .hw_addr = base_a };
    struct dpu_hw second = { .hw_addr = base_b };
    const u32 pair[2] = { 0x11111111u, 0x22222222u };
    struct writer_context first_writer = { .hw = &first, .first_reg = 0xc000u };
    struct writer_context second_writer = { .hw = &second, .first_reg = 0xd000u };
    struct single_writer_context boundary_writer = {
        .hw = &first, .reg = 0xe000u
    };
    struct single_writer_context follower_writer = {
        .hw = &first, .reg = 0xe004u
    };
    pthread_t first_thread;
    pthread_t second_thread;
    pthread_t boundary_thread;
    pthread_t follower_thread;
    unsigned int index;

    spin_lock_init(&first.table_frontdoor_write_lock);
    spin_lock_init(&second.table_frontdoor_write_lock);
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
    atomic_store_explicit(&spin_lock_attempts, 0, memory_order_relaxed);
    for (index = 0; index < 200; index++)
        write_one(&first, 0x5000u + index * 4u);
    expect(write_count == 200 && read_count == 0,
           "disabled throttling generated a readback");
    expect(atomic64_read(&first.table_frontdoor_write_sequence) == 0,
           "disabled throttling incremented the write sequence");
    expect(atomic_load_explicit(&spin_lock_attempts, memory_order_relaxed) == 0,
           "disabled throttling acquired the pacing lock");

    flush_interval = 100;
    for (submit_result = DPU_TABLE_SUCCESS;
         submit_result <= DPU_TABLE_ERROR; submit_result++) {
        reset_events();
        atomic64_set(&first.table_frontdoor_write_sequence, 0);
        atomic_store_explicit(&spin_lock_attempts, 0, memory_order_relaxed);
        wr32_for_each(&first, 0x6000u, pair, sizeof(pair));
        wr32_for_high_order(&first, 0x7000u, pair, sizeof(pair));
        expect(write_count == 0 && read_count == 0,
               "SUCCESS/ERROR path accessed MMIO");
        expect(atomic64_read(&first.table_frontdoor_write_sequence) == 0,
               "SUCCESS/ERROR path incremented the write sequence");
        expect(atomic_load_explicit(&spin_lock_attempts,
                                    memory_order_relaxed) == 0,
               "SUCCESS/ERROR path acquired the pacing lock");
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

    reset_events();
    atomic64_set(&first.table_frontdoor_write_sequence, 0);
    atomic64_set(&second.table_frontdoor_write_sequence, 0);
    atomic_store_explicit(&writers_ready, 0, memory_order_relaxed);
    atomic_store_explicit(&writers_start, 0, memory_order_relaxed);
    expect(pthread_create(&first_thread, NULL, write_100_dwords,
                          &first_writer) == 0,
           "failed to create first writer thread");
    expect(pthread_create(&second_thread, NULL, write_100_dwords,
                          &second_writer) == 0,
           "failed to create second writer thread");
    while (atomic_load_explicit(&writers_ready, memory_order_acquire) != 2u)
        sched_yield();
    atomic_store_explicit(&writers_start, 1, memory_order_release);
    expect(pthread_join(first_thread, NULL) == 0,
           "failed to join first writer thread");
    expect(pthread_join(second_thread, NULL) == 0,
           "failed to join second writer thread");
    expect(atomic64_read(&first.table_frontdoor_write_sequence) == 100,
           "first concurrent device sequence is not 100");
    expect(atomic64_read(&second.table_frontdoor_write_sequence) == 100,
           "second concurrent device sequence is not 100");
    expect(write_count == 200, "concurrent writers did not issue 200 writes");
    expect(read_count == 2, "concurrent writers did not issue two readbacks");
    expect_device_events(base_a, first_writer.first_reg + 99u * 4u);
    expect_device_events(base_b, second_writer.first_reg + 99u * 4u);

    reset_events();
    atomic64_set(&first.table_frontdoor_write_sequence, 99);
    atomic_store_explicit(&boundary_writer.done, 0, memory_order_relaxed);
    atomic_store_explicit(&follower_writer.done, 0, memory_order_relaxed);
    atomic_store_explicit(&boundary_write_seen, 0, memory_order_relaxed);
    atomic_store_explicit(&boundary_write_release, 0, memory_order_relaxed);
    atomic_store_explicit(&follower_lock_attempted, 0, memory_order_relaxed);
    boundary_lock = &first.table_frontdoor_write_lock;
    boundary_write_address = base_a + boundary_writer.reg;
    atomic_store_explicit(&boundary_gate_enabled, 1, memory_order_release);
    expect(pthread_create(&boundary_thread, NULL, write_single_dword,
                          &boundary_writer) == 0,
           "failed to create boundary writer thread");
    while (!atomic_load_explicit(&boundary_write_seen, memory_order_acquire))
        sched_yield();
    expect(pthread_create(&follower_thread, NULL, write_single_dword,
                          &follower_writer) == 0,
           "failed to create follower writer thread");
    while (!atomic_load_explicit(&follower_lock_attempted,
                                 memory_order_acquire))
        sched_yield();
    expect(!atomic_load_explicit(&follower_writer.done,
                                 memory_order_acquire),
           "follower write crossed the held pacing lock");
    expect(event_count == 1 && write_count == 1 && read_count == 0 &&
           events[0].kind == 'W' &&
           events[0].address == base_a + boundary_writer.reg,
           "unexpected MMIO occurred while the boundary write was held");
    atomic_store_explicit(&boundary_write_release, 1, memory_order_release);
    expect(pthread_join(boundary_thread, NULL) == 0,
           "failed to join boundary writer thread");
    expect(pthread_join(follower_thread, NULL) == 0,
           "failed to join follower writer thread");
    atomic_store_explicit(&boundary_gate_enabled, 0, memory_order_release);
    boundary_lock = NULL;
    expect(event_count == 3 && write_count == 2 && read_count == 1,
           "serialized boundary test produced unexpected MMIO counts");
    expect(events[0].kind == 'W' &&
           events[0].address == base_a + boundary_writer.reg &&
           events[1].kind == 'R' &&
           events[1].address == base_a + boundary_writer.reg &&
           events[2].kind == 'W' &&
           events[2].address == base_a + follower_writer.reg,
           "same-device MMIO order was not boundary-W, boundary-R, follower-W");
    expect(atomic64_read(&first.table_frontdoor_write_sequence) == 101,
           "same-device serialized sequence is not 101");

    puts("frontdoor throttle runtime contract passed");
    return 0;
}
EOF

python3 - "$work/hw.h" "$work/throttle_test.c" <<'PY'
from pathlib import Path
import sys

mock = Path(sys.argv[1]).read_text()
harness = Path(sys.argv[2]).read_text()
assert "#include <stdatomic.h>" in mock, "mock atomic64 must use C11 atomics"
assert "_Atomic uint64_t value;" in mock, "atomic64_t storage is not atomic"
assert "atomic_fetch_add_explicit" in mock, "atomic64 increment is not atomic"
assert "pthread_create(" in harness, "separate dpu_hw callers are not concurrent"
assert "atomic_load_explicit(&writers_ready" in harness, "writer barrier is absent"
assert "atomic_load_explicit(&writers_start" in harness, "writer start gate is absent"
assert "pthread_mutex_lock(&event_lock)" in harness, "MMIO log is not synchronized"
assert "test_spin_lock_pre_acquire" in mock, "spinlock mock hook is absent"
assert "follower_lock_attempted" in harness, "same-device lock race is absent"
print("concurrent harness source contract passed")
PY

cc -std=c11 -Wall -Wextra -Werror -pthread -I"$work" \
   -I"$repo/guest/dpu-table-sideband" \
   "$work/throttle_test.c" -o "$work/throttle_test"
"$work/throttle_test"

patch --batch --force --reverse --binary --fuzz=0 \
    --no-backup-if-mismatch --reject-file=- -d "$work" -p1 --dry-run \
    <"$patch_file" >/dev/null
