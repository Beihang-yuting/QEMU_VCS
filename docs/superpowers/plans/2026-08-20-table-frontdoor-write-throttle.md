# Table Frontdoor Write Throttle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pace complete-table frontdoor fallback writes by issuing a synchronous read from the just-written DWORD after every 100 actual 4-byte writes, deliver a rebuilt Guest driver on host 53, document integration, and push the verified result to `origin/feature/qemu-vcs-isolated-tcp`.

**Architecture:** Keep generic `wr32()` and all non-table register paths unchanged. Add a small platform-neutral boundary predicate, per-`dpu_hw` atomic write sequence, and a table-frontdoor-only helper used solely by the fallback loops in `wr32_for_each()` and `wr32_for_high_order()`. A read-only module parameter defaults to 100 and accepts zero to restore the original unpaced loops.

**Tech Stack:** Linux kernel C, PCI/MMIO `writel()`/`readl()`, kernel atomics, Bash transactional overlay tooling, CMake/CTest, Git, QEMU/VCS validation on `ubuntu@10.11.10.53` through `bash -lic`.

---

## File structure

| Path | Responsibility |
|---|---|
| `guest/dpu-table-sideband/cosim_table_frontdoor_throttle_core.h` | Platform-neutral decision for whether a write sequence hits the configured interval |
| `tests/unit/test_dpu_table_frontdoor_throttle.c` | Boundary and independent-sequence unit coverage |
| `tests/unit/CMakeLists.txt` | Registers the new unit executable and CTest |
| `guest/dpu-table-sideband/cosim_table_ctrl.h` | Exposes the immutable interval getter to the patched driver wrappers |
| `guest/dpu-table-sideband/0004-dpu-table-frontdoor-throttle.patch` | Adds module parameter, per-`dpu_hw` state, initialization, logging, helper, and wrapper integration to the vendor driver |
| `tests/integration/test_dpu_table_frontdoor_throttle_patch.sh` | Applies patch 0004 to a minimal post-0003 driver fixture and executes the actual patched inline wrappers with mocked MMIO |
| `tests/integration/CMakeLists.txt` | Registers the new patch/runtime contract test |
| `scripts/apply_dpu_table_sideband.sh` | Transactionally copies the throttle core into generated driver trees |
| `tests/integration/test_dpu_table_overlay_apply.sh` | Verifies the enlarged managed source/patch set and idempotence |
| `guest/dpu-table-sideband/README.md` | Documents the driver option and frontdoor-only behavior |
| `docs/COSIM-C-BUILD.md` | Documents overlay/build/module-load commands |
| `docs/COSIM-MINIMAL-INTEGRATION.md` | Gives the minimal default, override, and disable flow |
| `docs/COSIM-VCS-INTEGRATION.md` | Explains interaction with table sideband fallback |
| `docs/VCS-INTEGRATION-GUIDE.md` | Adds full Guest/QEMU integration guidance and delivery paths |
| `docs/validation/2026-08-20-table-frontdoor-write-throttle-validation.md` | Records source, module hashes, test evidence, and remote revision |

## Execution constraints

- Work on the named branch `feature/qemu-vcs-isolated-tcp`, never `main`.
- Preserve all user changes outside the isolated `default-icount` worktree.
- Do not modify `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810`.
- Run VCS and Guest module validation on `10.11.10.53` as `ubuntu`, using credentials supplied out of band and `bash -lic`.
- Do not add the extracted driver, `dpu_snd1.ko`, QEMU dependency, build output, credentials, or proxy settings to Git.
- Do not force-push. Fetch immediately before publishing and require the remote branch to be an ancestor of local `HEAD`.

### Task 1: Add the platform-neutral throttle boundary

**Files:**
- Create: `tests/unit/test_dpu_table_frontdoor_throttle.c`
- Create: `guest/dpu-table-sideband/cosim_table_frontdoor_throttle_core.h`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Register a failing unit test**

Append this target to `tests/unit/CMakeLists.txt` and create the test before the header exists:

```cmake
add_executable(test_dpu_table_frontdoor_throttle
               test_dpu_table_frontdoor_throttle.c)
target_include_directories(test_dpu_table_frontdoor_throttle PRIVATE
    ${CMAKE_SOURCE_DIR}/guest/dpu-table-sideband
)
add_test(NAME test_dpu_table_frontdoor_throttle
         COMMAND test_dpu_table_frontdoor_throttle)
```

The test must include the missing header and exercise exact boundaries:

```c
#include <assert.h>
#include <stdint.h>

#include "cosim_table_frontdoor_throttle_core.h"

static void test_disabled_interval_never_flushes(void)
{
    uint64_t sequence;

    for (sequence = 1; sequence <= 1000; ++sequence)
        assert(!dpu_table_frontdoor_should_flush(sequence, 0));
}

static void test_interval_one_flushes_every_write(void)
{
    assert(dpu_table_frontdoor_should_flush(1, 1));
    assert(dpu_table_frontdoor_should_flush(2, 1));
}

static void test_default_boundary_is_exact(void)
{
    assert(!dpu_table_frontdoor_should_flush(0, 100));
    assert(!dpu_table_frontdoor_should_flush(99, 100));
    assert(dpu_table_frontdoor_should_flush(100, 100));
    assert(!dpu_table_frontdoor_should_flush(101, 100));
    assert(dpu_table_frontdoor_should_flush(200, 100));
}

static void test_sequences_remain_independent(void)
{
    uint64_t first = 99;
    uint64_t second = 0;

    assert(dpu_table_frontdoor_should_flush(++first, 100));
    assert(!dpu_table_frontdoor_should_flush(++second, 100));
    second = 99;
    assert(dpu_table_frontdoor_should_flush(++second, 100));
}

int main(void)
{
    test_disabled_interval_never_flushes();
    test_interval_one_flushes_every_write();
    test_default_boundary_is_exact();
    test_sequences_remain_independent();
    return 0;
}
```

- [ ] **Step 2: Run the new target and verify RED**

Run on host 53 after synchronizing the test/CMake change to the disposable source tree:

```bash
cmake -S /home/ubuntu/test_cosim/builds/table-sideband-target-src \
      -B /home/ubuntu/test_cosim/builds/table-sideband-target-build \
      -DCMAKE_BUILD_TYPE=Debug
cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
      --target test_dpu_table_frontdoor_throttle -j8
```

Expected: compilation fails because
`cosim_table_frontdoor_throttle_core.h` does not exist.

- [ ] **Step 3: Add the minimal portable predicate**

Create `guest/dpu-table-sideband/cosim_table_frontdoor_throttle_core.h`:

```c
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __DPU_COSIM_TABLE_FRONTDOOR_THROTTLE_CORE_H
#define __DPU_COSIM_TABLE_FRONTDOOR_THROTTLE_CORE_H

#ifdef __KERNEL__
#include <linux/types.h>
typedef u32 dpu_table_frontdoor_u32;
typedef u64 dpu_table_frontdoor_u64;
#else
#include <stdint.h>
typedef uint32_t dpu_table_frontdoor_u32;
typedef uint64_t dpu_table_frontdoor_u64;
#endif

static inline int dpu_table_frontdoor_should_flush(
    dpu_table_frontdoor_u64 sequence,
    dpu_table_frontdoor_u32 interval)
{
    return interval != 0 && sequence != 0 && sequence % interval == 0;
}

#endif /* __DPU_COSIM_TABLE_FRONTDOOR_THROTTLE_CORE_H */
```

- [ ] **Step 4: Build and run GREEN**

Run:

```bash
cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
      --target test_dpu_table_frontdoor_throttle -j8
/home/ubuntu/test_cosim/builds/table-sideband-target-build/tests/unit/test_dpu_table_frontdoor_throttle
```

Expected: build exits zero and the executable exits zero with no assertion.

- [ ] **Step 5: Commit the isolated core**

```bash
git add guest/dpu-table-sideband/cosim_table_frontdoor_throttle_core.h \
        tests/unit/test_dpu_table_frontdoor_throttle.c \
        tests/unit/CMakeLists.txt
git commit -m "test(driver): define table frontdoor throttle boundary"
```

### Task 2: Patch the real driver table wrappers

**Files:**
- Create: `tests/integration/test_dpu_table_frontdoor_throttle_patch.sh`
- Create: `guest/dpu-table-sideband/0004-dpu-table-frontdoor-throttle.patch`
- Modify: `guest/dpu-table-sideband/cosim_table_ctrl.h`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write the failing patched-wrapper test**

Create an executable Bash test that builds a temporary post-0003 fixture with
`main.c` and `common.h`, applies patch 0004 with `--binary --fuzz=0`, and then
compiles a C harness against the resulting `common.h`. The harness supplies
mock `writel()`, `readl()`, `atomic64_inc_return()`, and
`dpu_table_submit()` functions and verifies:

```c
/* Required assertions in the generated harness. */
interval = 100;
submit_result = DPU_TABLE_FRONTDOOR;
for (unsigned int index = 0; index < 99; ++index)
    wr32_for_each(&first_hw, 0x1000 + index * 4, &value, sizeof(value));
assert(write_count == 99);
assert(read_count == 0);
wr32_for_each(&first_hw, 0x2000, &value, sizeof(value));
assert(write_count == 100);
assert(read_count == 1);
assert(last_read_offset == 0x2000);

/* HIGH_TO_LOW must read the address of the triggering DWORD. */
first_hw.table_frontdoor_write_sequence.counter = 99;
wr32_for_high_order(&first_hw, 0x3000, two_dwords, sizeof(two_dwords));
assert(first_new_read_offset == 0x3004);

/* Zero disables pacing. */
interval = 0;
for (unsigned int index = 0; index < 200; ++index)
    wr32_for_each(&first_hw, 0x4000, &value, sizeof(value));
assert(read_count == reads_before_disabled_loop);

/* Backdoor success/error never reaches MMIO or the sequence. */
submit_result = DPU_TABLE_SUCCESS;
wr32_for_each(&first_hw, 0x5000, &value, sizeof(value));
submit_result = DPU_TABLE_ERROR;
wr32_for_high_order(&first_hw, 0x5000, &value, sizeof(value));
assert(write_count == writes_before_terminal_results);

/* Separate dpu_hw objects each trigger at their own 100th write. */
first_hw.table_frontdoor_write_sequence.counter = 99;
second_hw.table_frontdoor_write_sequence.counter = 99;
submit_result = DPU_TABLE_FRONTDOOR;
interval = 100;
wr32_for_each(&first_hw, 0x6000, &value, sizeof(value));
wr32_for_each(&second_hw, 0x7000, &value, sizeof(value));
assert(read_count == reads_before_independent_writes + 2);
```

The Bash test must also use Python source assertions to prove:

```text
table_frontdoor_flush_interval = 100
module_param(table_frontdoor_flush_interval, uint, 0444)
MODULE_PARM_DESC(table_frontdoor_flush_interval,
                 "Flush table frontdoor writes after this many DWORDs (0 disables)")
atomic64_set(&hw->table_frontdoor_write_sequence, 0)
```

Register it in `tests/integration/CMakeLists.txt`:

```cmake
add_test(NAME test_dpu_table_frontdoor_throttle_patch
         COMMAND bash
                 ${CMAKE_CURRENT_SOURCE_DIR}/test_dpu_table_frontdoor_throttle_patch.sh)
set_tests_properties(test_dpu_table_frontdoor_throttle_patch
                     PROPERTIES TIMEOUT 20)
```

- [ ] **Step 2: Run the patch test and verify RED**

Run:

```bash
bash tests/integration/test_dpu_table_frontdoor_throttle_patch.sh
```

Expected: exit nonzero with `missing throttle patch` because
`0004-dpu-table-frontdoor-throttle.patch` is absent.

- [ ] **Step 3: Expose the immutable interval getter**

Add this declaration inside the existing `#ifdef __KERNEL__` section of
`guest/dpu-table-sideband/cosim_table_ctrl.h`, immediately before
`dpu_table_backdoor_enabled()`:

```c
u32 dpu_table_frontdoor_flush_interval_get(void);
```

The definition is supplied by the vendor-driver `main.c` hunk in patch 0004,
not by a second module.

- [ ] **Step 4: Create patch 0004 from an exact clean driver copy**

In a temporary directory on host 53, extract the clean reference archive,
apply patches 0001 through 0003, copy that tree as `before`, edit a second copy
as `after`, and generate a binary-safe unified patch. The `main.c` result must
contain:

```c
static unsigned int table_frontdoor_flush_interval = 100;
module_param(table_frontdoor_flush_interval, uint, 0444);
MODULE_PARM_DESC(table_frontdoor_flush_interval,
                 "Flush table frontdoor writes after this many DWORDs (0 disables)");

u32 dpu_table_frontdoor_flush_interval_get(void)
{
    return table_frontdoor_flush_interval;
}
```

At the beginning of `dpu_module_init()` log exactly once:

```c
pr_info("table frontdoor flush interval: %u DWORD writes\n",
        table_frontdoor_flush_interval);
```

Add this field to `struct dpu_hw`:

```c
atomic64_t table_frontdoor_write_sequence;
spinlock_t table_frontdoor_write_lock;
```

Immediately after `hw->adapter = adapter;` in probe, initialize it:

```c
atomic64_set(&hw->table_frontdoor_write_sequence, 0);
spin_lock_init(&hw->table_frontdoor_write_lock);
```

Include the portable core and add this helper next to the existing wrappers:

```c
#include "cosim_table_frontdoor_throttle_core.h"

static inline void dpu_table_frontdoor_wr32(struct dpu_hw *hw, u64 reg,
                                             u32 value)
{
    unsigned long flags;
    u32 interval;
    u64 sequence;

    interval = dpu_table_frontdoor_flush_interval_get();
    if (!interval) {
        wr32(hw, reg, value);
        return;
    }
    spin_lock_irqsave(&hw->table_frontdoor_write_lock, flags);
    wr32(hw, reg, value);
    sequence = (u64)atomic64_inc_return(
        &hw->table_frontdoor_write_sequence);
    if (unlikely(dpu_table_frontdoor_should_flush(sequence, interval)))
        (void)rd32(hw, reg);
    spin_unlock_irqrestore(&hw->table_frontdoor_write_lock, flags);
}
```

Replace only the two fallback-loop calls:

```c
dpu_table_frontdoor_wr32(hw, reg + __n,
                         ((const u32 *)value)[__n >> 2]);
```

Do not replace the global `wr32` macro or any other wrapper. Generate the
repository patch with paths `a/common.h`, `b/common.h`, `a/main.c`, and
`b/main.c`, preserving CRLF where present:

```bash
git diff --no-index --binary -- before/common.h after/common.h > common.patch || test $? -eq 1
git diff --no-index --binary -- before/main.c after/main.c > main.patch || test $? -eq 1
```

Normalize only the diff path prefixes, concatenate the two diffs, and save the
result as `guest/dpu-table-sideband/0004-dpu-table-frontdoor-throttle.patch`.

- [ ] **Step 5: Run GREEN and retained wrapper tests**

Run:

```bash
bash tests/integration/test_dpu_table_frontdoor_throttle_patch.sh
bash tests/integration/test_dpu_complete_buffer_patch.sh
bash tests/integration/test_dpu_qid_batch_patch.sh
```

Expected: the new runtime harness prints `PASS`, the complete-buffer contract
passes, and the QID batch contract passes.

- [ ] **Step 6: Commit the real-driver behavior**

```bash
git add guest/dpu-table-sideband/cosim_table_ctrl.h \
        guest/dpu-table-sideband/0004-dpu-table-frontdoor-throttle.patch \
        tests/integration/test_dpu_table_frontdoor_throttle_patch.sh \
        tests/integration/CMakeLists.txt
git commit -m "feat(driver): pace table frontdoor writes"
```

### Task 3: Extend the transactional overlay and integration documentation

**Files:**
- Modify: `scripts/apply_dpu_table_sideband.sh`
- Modify: `tests/integration/test_dpu_table_overlay_apply.sh`
- Modify: `guest/dpu-table-sideband/README.md`
- Modify: `docs/COSIM-C-BUILD.md`
- Modify: `docs/COSIM-MINIMAL-INTEGRATION.md`
- Modify: `docs/COSIM-VCS-INTEGRATION.md`
- Modify: `docs/VCS-INTEGRATION-GUIDE.md`

- [ ] **Step 1: Make overlay tests fail for the missing managed core**

Update `test_dpu_table_overlay_apply.sh` before the installer:

```bash
for copied in cosim_table_ctrl.c cosim_table_ctrl.h \
              cosim_table_batch_core.h \
              cosim_table_frontdoor_throttle_core.h \
              cosim_table_ctrl_uapi.h cosim_table_protocol.h; do
    [[ -f "$valid/$copied" ]] || fail "overlay omitted $copied"
done

cmp "$valid/cosim_table_frontdoor_throttle_core.h" \
    "$repo/guest/dpu-table-sideband/cosim_table_frontdoor_throttle_core.h" ||
    fail "throttle core differs from overlay source"

[[ -f "$valid/.cosim-table-sideband-applied/0004-dpu-table-frontdoor-throttle.patch.applied" ]] ||
    fail "throttle patch marker is absent"
```

Retain the existing first/second-application whole-tree hashes and symlink
escape tests.

- [ ] **Step 2: Run overlay test and verify RED**

Run:

```bash
bash tests/integration/test_dpu_table_overlay_apply.sh
```

Expected: failure because the apply script does not yet copy
`cosim_table_frontdoor_throttle_core.h`.

- [ ] **Step 3: Add the core to the managed transactional source list**

In `scripts/apply_dpu_table_sideband.sh`, extend `sources`:

```bash
sources=(
    "$overlay_dir/cosim_table_ctrl.c"
    "$overlay_dir/cosim_table_ctrl.h"
    "$overlay_dir/cosim_table_batch_core.h"
    "$overlay_dir/cosim_table_frontdoor_throttle_core.h"
    "$repo/bridge/table/cosim_table_ctrl_uapi.h"
    "$repo/bridge/table/cosim_table_protocol.h"
)
```

Do not weaken path, symlink, rollback, or contiguous-patch validation.

- [ ] **Step 4: Document exact runtime and fallback behavior**

Add the following facts consistently to all four integration guides and the
overlay README:

```text
table_frontdoor_flush_interval defaults to 100.
Only actual 4-byte writes in wr32_for_each/wr32_for_high_order frontdoor
fallback count toward the interval.
The 100th write is followed by readl() of that just-written DWORD; the value is
discarded and is not data verification.
table_frontdoor_flush_interval=0 restores the original unpaced loops.
For a nonzero interval, each dpu_hw serializes its complete write/count/read
sequence with an IRQ-safe spinlock; interval 0 bypasses that lock.
Successful backdoor requests and hard errors never increment the frontdoor
counter.
Each dpu_hw has an independent counter.
```

Include these exact commands:

```bash
insmod dpu_snd1.ko
insmod dpu_snd1.ko table_backdoor=1 table_frontdoor_flush_interval=100
insmod dpu_snd1.ko table_frontdoor_flush_interval=0
```

Include kernel-command-line forms:

```text
dpu_snd1.table_frontdoor_flush_interval=100
dpu_snd1.table_frontdoor_flush_interval=0
```

State that the default is already 100, so the first command enables pacing
without an explicit option.

- [ ] **Step 5: Run overlay and documentation contracts GREEN**

Run:

```bash
bash tests/integration/test_dpu_table_overlay_apply.sh
bash tests/integration/test_dpu_table_frontdoor_throttle_patch.sh
bash tests/integration/test_dpu_table_batch_source_contract.sh
git diff --check
```

Expected: all scripts exit zero and `git diff --check` emits no diagnostics for
the changed production/documentation files. CRLF/unified-patch payload warnings
are assessed separately with the known-artifact exclusion used by the existing
validation report.

- [ ] **Step 6: Commit installer and documentation**

```bash
git add scripts/apply_dpu_table_sideband.sh \
        tests/integration/test_dpu_table_overlay_apply.sh \
        guest/dpu-table-sideband/README.md \
        docs/COSIM-C-BUILD.md docs/COSIM-MINIMAL-INTEGRATION.md \
        docs/COSIM-VCS-INTEGRATION.md docs/VCS-INTEGRATION-GUIDE.md
git commit -m "docs(driver): integrate frontdoor write pacing"
```

### Task 4: Generate and build the deliverable driver on host 53

**Files:**
- Create remotely only: `/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net`
- Create remotely only: `/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net/dpu_snd1.ko`
- Create remotely only: `/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/evidence`

- [ ] **Step 1: Synchronize the tracked implementation to the disposable source tree**

Use checksum-preserving rsync with relative paths from the local worktree. Do
not copy `.git`, build products, or credentials:

```bash
rsync -aR --checksum \
  ./guest/dpu-table-sideband \
  ./bridge/table/cosim_table_ctrl_uapi.h \
  ./bridge/table/cosim_table_protocol.h \
  ./scripts/apply_dpu_table_sideband.sh \
  ./tests ./docs ./CMakeLists.txt ./bridge/CMakeLists.txt \
  ubuntu@10.11.10.53:/home/ubuntu/test_cosim/builds/table-sideband-target-src/
```

Expected: SHA-256 hashes for every changed tracked file match locally and on
host 53.

- [ ] **Step 2: Extract the clean driver into a new build-only location**

Run on host 53 through `bash -lic`:

```bash
delivery=/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
archive="$release/source/host-driver-net-skipeth.tar.gz"
test ! -e "$delivery"
mkdir -p "$delivery/evidence" "$delivery/extract"
tar -xf "$archive" -C "$delivery/extract"
driver=$(find "$delivery/extract" -type f -name main.c -printf '%h\n' | head -1)
test -n "$driver"
mv "$driver" "$delivery/host-driver-net"
rmdir "$delivery/extract"
sha256sum "$archive" >"$delivery/evidence/reference-archive.sha256"
```

Expected: the release tree remains byte-for-byte unchanged and the delivery
tree is outside the release directory.

- [ ] **Step 3: Apply twice and prove idempotence**

Run:

```bash
src=/home/ubuntu/test_cosim/builds/table-sideband-target-src
delivery=/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820
driver="$delivery/host-driver-net"
"$src/scripts/apply_dpu_table_sideband.sh" "$driver" \
  | tee "$delivery/evidence/apply-first.log"
find "$driver" -type f -print0 | sort -z | xargs -0 sha256sum \
  >"$delivery/evidence/tree-first.sha256"
"$src/scripts/apply_dpu_table_sideband.sh" "$driver" \
  | tee "$delivery/evidence/apply-second.log"
find "$driver" -type f -print0 | sort -z | xargs -0 sha256sum \
  >"$delivery/evidence/tree-second.sha256"
cmp "$delivery/evidence/tree-first.sha256" \
    "$delivery/evidence/tree-second.sha256"
```

Expected: both applications exit zero and the manifests compare equal.

- [ ] **Step 4: Build and inspect the module**

Run:

```bash
delivery=/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820
driver="$delivery/host-driver-net"
make -C "$driver" CFLAGS=-UDPU_LACP modules \
  2>&1 | tee "$delivery/evidence/module-build.log"
test -f "$driver/dpu_snd1.ko"
modinfo "$driver/dpu_snd1.ko" \
  | tee "$delivery/evidence/modinfo.txt"
grep -F 'parm:' "$delivery/evidence/modinfo.txt" \
  | grep -F 'table_frontdoor_flush_interval'
grep -F 'table_frontdoor_flush_interval = 100' "$driver/main.c"
sha256sum "$driver/dpu_snd1.ko" \
  | tee "$delivery/evidence/dpu_snd1.ko.sha256"
```

Expected: build exits zero, the module exists, `modinfo` publishes the option,
and source inspection proves the numeric default is 100.

- [ ] **Step 5: Record deliverable paths and hashes**

Create `evidence/summary.txt` containing:

```text
DRIVER_SOURCE=/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net
DRIVER_MODULE=/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net/dpu_snd1.ko
DEFAULT_INTERVAL=100
DISABLE_VALUE=0
BUILD_FLAGS=CFLAGS=-UDPU_LACP
```

Append the repository HEAD, archive hash, module hash, patched-tree manifest
hash, build exit code, and overlay idempotence result.

### Task 5: Run complete validation and record evidence

**Files:**
- Create: `docs/validation/2026-08-20-table-frontdoor-write-throttle-validation.md`

- [ ] **Step 1: Run focused tests on host 53**

Run through `bash -lic`:

```bash
src=/home/ubuntu/test_cosim/builds/table-sideband-target-src
build=/home/ubuntu/test_cosim/builds/table-sideband-target-build
cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Debug \
  -DDPU_TABLE_REFERENCE_ARCHIVE=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net-skipeth.tar.gz
cmake --build "$build" -j8
ctest --test-dir "$build" --output-on-failure \
  -R 'dpu_table_frontdoor_throttle|dpu_table_overlay|dpu_complete_buffer|dpu_qid|table_launch|workflow_command|pcie_launch'
```

If the host CTest version ignores `--test-dir`, run `cd "$build"` followed by
the same `ctest` expression. Expected: every selected test passes.

- [ ] **Step 2: Run the complete suite**

Run:

```bash
cd /home/ubuntu/test_cosim/builds/table-sideband-target-build
ctest --output-on-failure -j1
```

Expected: all retained 73 tests plus the new unit and integration tests pass,
for a total of 75/75 with zero failures.

- [ ] **Step 3: Run hygiene checks**

Run locally:

```bash
git status --short
git diff origin/feature/qemu-vcs-isolated-tcp...HEAD --name-status
git diff --check HEAD~3..HEAD
git diff origin/feature/qemu-vcs-isolated-tcp...HEAD -- \
    bridge/common/cosim_protocol.h \
    bridge/common/cosim_transport.h \
    bridge/common/cosim_shm.h
```

Expected: no uncommitted files before the validation report, no common
TLP/transport ABI changes, and no tracked generated driver/module/build path.
Whole-range `diff --check` warnings are permitted only inside pre-existing
nested Guest patch payloads or the retained CRLF driver fixture and must be
listed explicitly in the validation report.

- [ ] **Step 4: Write the validation report**

Record:

- base and implementation commits;
- RED and GREEN commands/results;
- exact 75-test count and elapsed time;
- source, module, archive, and manifest SHA-256 hashes;
- module parameter name, default 100, and disable value 0;
- proof that only the two table fallback wrappers call the helper;
- proof that success/error paths do not count;
- exact host-53 source and module delivery paths;
- `CFLAGS=-UDPU_LACP` as the reference-release build requirement;
- overlay two-pass idempotence;
- retained default/off, QEMU, VCS, Guest, and multi-RAM results;
- known limitation that the pacing read discards data and real DUT capacity
  still requires user workload validation.

- [ ] **Step 5: Request independent specification and quality reviews**

Review range: the target commit from immediately before Task 1 through current
`HEAD`. Specification review must compare the code to
`docs/superpowers/specs/2026-08-20-table-frontdoor-write-throttle-design.md`.
Quality review must inspect atomic lifetime, exact modulo behavior, per-device
isolation, MMIO ordering, wrapper scope, interval zero, patch idempotence,
kernel build compatibility, documentation, and generated-artifact hygiene.

Expected: no open Critical or Important finding. Fix any such finding with a
new failing test and rerun all affected verification before proceeding.

- [ ] **Step 6: Commit validation evidence**

```bash
git add docs/validation/2026-08-20-table-frontdoor-write-throttle-validation.md
git commit -m "test(driver): record frontdoor throttle validation"
```

### Task 6: Publish the verified branch and hand off integration

**Files:**
- No source changes expected.

- [ ] **Step 1: Perform final verification-before-completion checks**

Run:

```bash
git status --porcelain
git branch --show-current
git log -5 --oneline
git diff --check HEAD^..HEAD
```

Expected: clean worktree, branch `feature/qemu-vcs-isolated-tcp`, validation
commit at HEAD, and no diagnostics in the last commit.

- [ ] **Step 2: Fetch and prove a fast-forward publication**

Run:

```bash
git fetch origin feature/qemu-vcs-isolated-tcp
git merge-base --is-ancestor origin/feature/qemu-vcs-isolated-tcp HEAD
```

Expected: both commands exit zero. If the ancestry check fails, stop without
pushing and inspect the newly fetched remote changes; do not rebase, merge, or
force-push without reporting the divergence.

- [ ] **Step 3: Push without force**

Run:

```bash
git push origin \
  feature/qemu-vcs-isolated-tcp:feature/qemu-vcs-isolated-tcp
```

Expected: a normal fast-forward update. Confirm:

```bash
git ls-remote origin refs/heads/feature/qemu-vcs-isolated-tcp
```

The returned SHA must equal local `HEAD`.

- [ ] **Step 4: Report the final integration handoff**

Provide:

```text
Remote branch and SHA
Modified/added repository files
Host-53 driver source path
Host-53 dpu_snd1.ko path and SHA-256
Default behavior: interval 100
Disable command: table_frontdoor_flush_interval=0
Backdoor-enabled command with explicit interval
Kernel-command-line equivalents
Focused and full regression counts
Mock/read-discard limitation and real-DUT validation note
```

Also remind the user to revoke any GitHub token previously exposed in chat;
never store or echo that token during publication.
