# Transaction-Scoped VCS Time Freeze Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep Guest virtual time normal while VCS is idle and exclude only host time spent in blocking QEMU-to-VCS bridge operations.

**Architecture:** The generic QEMU bridge gains optional begin/end wait hooks and balances them on every success and error path.  The QEMU PCIe device registers hooks only when iCount is active; the outermost wait disables CPU ticks under BQL and the matching end restores them.  Adaptive iCount uses `sleep=on`, so normal idle timers track wall time without catching up after a slow DUT transaction.

**Tech Stack:** C11, QEMU 9.2 TCG/iCount and timer APIs, pthreads, GNU Make, Bash, CMake/CTest, Synopsys VCS/UVM on `10.11.10.53`.

---

## File map

- `Makefile`: select the supported adaptive iCount arguments and document them.
- `bridge/qemu/bridge_qemu.h`: define the public optional wait-hook API and store hook state in `bridge_ctx_t`.
- `bridge/qemu/bridge_qemu.c`: balance wait scopes around blocking bridge operations.
- `qemu-plugin/cosim_pcie_rc.h`: store PF0 clock-gate depth, ownership, and timing state.
- `qemu-plugin/cosim_pcie_rc.c`: connect bridge wait hooks to QEMU tick disable/enable APIs.
- `tests/integration/test_qemu_time_mode.sh`: enforce launch-mode arguments.
- `tests/unit/test_bridge_wait_hooks.c`: test hook balance with a fake transport.
- `tests/integration/test_qemu_wait_gate_source.sh`: enforce QEMU-side registration and cleanup contract.
- `tests/unit/CMakeLists.txt`, `tests/integration/CMakeLists.txt`: register the new tests.

### Task 1: Make the launch-mode regression test fail on global `sleep=off`

**Files:**
- Modify: `tests/integration/test_qemu_time_mode.sh`
- Modify: `Makefile`

- [ ] **Step 1: Change the expected iCount command line before production code**

Replace the iCount assertion inside the console loop with:

```bash
assert_exactly_once '-accel tcg' "$icount"
assert_exactly_once '-icount shift=auto,align=off,sleep=on' "$icount"
if grep -Fq -- '-icount shift=auto,align=off,sleep=off' <<<"$icount"; then
    fail "legacy global sleep=off mode remains enabled for CONSOLE=$console"
fi
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
bash tests/integration/test_qemu_time_mode.sh
```

Expected: FAIL with `expected exactly one '-icount shift=auto,align=off,sleep=on', got 0`.

- [ ] **Step 3: Make the smallest launch change**

Change only the iCount branch and help text in `Makefile`:

```make
ifeq ($(QEMU_TIME_MODE),icount)
QEMU_TIME_ARGS := -accel tcg -icount shift=auto,align=off,sleep=on
else
QEMU_TIME_ARGS :=
endif
```

The help text must report the same exact string.  Do not change the default
`QEMU_TIME_MODE=realtime`, console commands, TCP ports, device properties, or
`MMIO_TIMEOUT_MS`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
bash tests/integration/test_qemu_time_mode.sh
```

Expected: `[qemu-time-mode] PASS`.

- [ ] **Step 5: Commit the launch correction**

```bash
git add Makefile tests/integration/test_qemu_time_mode.sh
git commit -m "fix(qemu): keep idle timers realtime in icount mode"
```

### Task 2: Add a failing bridge wait-hook balance test

**Files:**
- Create: `tests/unit/test_bridge_wait_hooks.c`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Register the test target**

Append:

```cmake
add_executable(test_bridge_wait_hooks test_bridge_wait_hooks.c)
target_link_libraries(test_bridge_wait_hooks cosim_bridge pthread)
add_test(NAME test_bridge_wait_hooks COMMAND test_bridge_wait_hooks)
set_tests_properties(test_bridge_wait_hooks PROPERTIES TIMEOUT 10)
```

- [ ] **Step 2: Write a fake-transport test against the desired public API**

Create `tests/unit/test_bridge_wait_hooks.c` with this complete test harness:

```c
#include "bridge_qemu.h"
#include "cosim_transport.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int send_tlp_rc;
    int send_sync_rc;
    int recv_sync_rc;
    int recv_timed_rc;
    int recv_cpl_rc;
    int match_tag;
    uint16_t last_tag;
} fake_state_t;

typedef struct {
    int begin_count;
    int end_count;
    int depth;
    int max_depth;
} hook_state_t;

static int fake_send_tlp(cosim_transport_t *t, const tlp_entry_t *req)
{
    fake_state_t *s = t->priv;
    s->last_tag = req->tag;
    return s->send_tlp_rc;
}

static int fake_send_sync(cosim_transport_t *t, const sync_msg_t *msg)
{
    (void)msg;
    return ((fake_state_t *)t->priv)->send_sync_rc;
}

static int fake_recv_sync(cosim_transport_t *t, sync_msg_t *msg)
{
    fake_state_t *s = t->priv;
    if (s->recv_sync_rc == 0) {
        msg->type = SYNC_MSG_CPL_READY;
        msg->payload = 0;
    }
    return s->recv_sync_rc;
}

static int fake_recv_sync_timed(cosim_transport_t *t, sync_msg_t *msg,
                                int timeout_ms)
{
    fake_state_t *s = t->priv;
    (void)timeout_ms;
    if (s->recv_timed_rc == 0) {
        msg->type = SYNC_MSG_CPL_READY;
        msg->payload = 0;
    }
    return s->recv_timed_rc;
}

static int fake_recv_cpl(cosim_transport_t *t, cpl_entry_t *cpl)
{
    fake_state_t *s = t->priv;
    if (s->recv_cpl_rc == 0) {
        memset(cpl, 0, sizeof(*cpl));
        cpl->type = TLP_CPL;
        cpl->tag = s->match_tag ? s->last_tag : (uint16_t)(s->last_tag ^ 1u);
    }
    return s->recv_cpl_rc;
}

static void hook_begin(void *opaque)
{
    hook_state_t *s = opaque;
    s->begin_count++;
    s->depth++;
    if (s->depth > s->max_depth) s->max_depth = s->depth;
}

static void hook_end(void *opaque)
{
    hook_state_t *s = opaque;
    assert(s->depth > 0);
    s->end_count++;
    s->depth--;
}

static void init_ctx(bridge_ctx_t *ctx, cosim_transport_t *transport,
                     fake_state_t *fake, hook_state_t *hooks)
{
    memset(ctx, 0, sizeof(*ctx));
    memset(transport, 0, sizeof(*transport));
    memset(hooks, 0, sizeof(*hooks));
    fake->send_tlp_rc = 0;
    fake->send_sync_rc = 0;
    fake->recv_sync_rc = 0;
    fake->recv_timed_rc = 0;
    fake->recv_cpl_rc = 0;
    fake->match_tag = 1;
    transport->send_tlp = fake_send_tlp;
    transport->send_sync = fake_send_sync;
    transport->recv_sync = fake_recv_sync;
    transport->recv_sync_timed = fake_recv_sync_timed;
    transport->recv_cpl = fake_recv_cpl;
    transport->priv = fake;
    ctx->transport = transport;
    ctx->tag_mask = 0xff;
    pthread_mutex_init(&ctx->tlp_mutex, NULL);
    bridge_set_wait_hooks(ctx, hook_begin, hook_end, hooks);
}

static void assert_balanced(const hook_state_t *s, int expected)
{
    assert(s->begin_count == expected);
    assert(s->end_count == expected);
    assert(s->depth == 0);
    assert(s->max_depth == 1);
}

static void test_success_and_failures(void)
{
    bridge_ctx_t ctx;
    cosim_transport_t transport;
    fake_state_t fake = {0};
    hook_state_t hooks;
    tlp_entry_t req = { .type = TLP_MRD, .len = 4 };
    cpl_entry_t cpl;

    init_ctx(&ctx, &transport, &fake, &hooks);
    assert(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == 0);
    assert_balanced(&hooks, 1);

    fake.send_tlp_rc = -1;
    assert(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 2);

    fake.send_tlp_rc = 0;
    fake.recv_sync_rc = -1;
    assert(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 3);

    fake.recv_sync_rc = 0;
    fake.recv_timed_rc = 1;
    assert(bridge_send_tlp_and_wait_timed(&ctx, &req, &cpl, 10) == -2);
    assert_balanced(&hooks, 4);

    fake.recv_timed_rc = 0;
    assert(bridge_send_tlp_fire(&ctx, &req) == 0);
    assert_balanced(&hooks, 5);

    fake.recv_timed_rc = 1;
    bridge_drain_vf_pending(&ctx, 10);
    assert_balanced(&hooks, 6);

    pthread_mutex_destroy(&ctx.tlp_mutex);
}

static void test_stale_completion_guard_restores_hook(void)
{
    bridge_ctx_t ctx;
    cosim_transport_t transport;
    fake_state_t fake = {0};
    hook_state_t hooks;
    tlp_entry_t req = { .type = TLP_MRD, .len = 4 };
    cpl_entry_t cpl;

    init_ctx(&ctx, &transport, &fake, &hooks);
    fake.match_tag = 0;
    assert(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 1);
    pthread_mutex_destroy(&ctx.tlp_mutex);
}

int main(void)
{
    test_success_and_failures();
    test_stale_completion_guard_restores_hook();
    puts("bridge wait-hook tests: PASS");
    return 0;
}
```

- [ ] **Step 3: Configure and build to verify RED**

Run:

```bash
cmake -S . -B build-time-freeze -DCMAKE_BUILD_TYPE=Debug
cmake --build build-time-freeze --target test_bridge_wait_hooks -j"$(nproc)"
```

Expected: link or compile failure because `bridge_set_wait_hooks` does not yet
exist.

### Task 3: Implement balanced bridge wait hooks

**Files:**
- Modify: `bridge/qemu/bridge_qemu.h`
- Modify: `bridge/qemu/bridge_qemu.c`
- Test: `tests/unit/test_bridge_wait_hooks.c`

- [ ] **Step 1: Add the callback type, context fields, and registration API**

Before `bridge_ctx_t`, add:

```c
typedef void (*bridge_wait_hook_fn)(void *opaque);
```

Add these fields to `bridge_ctx_t`:

```c
bridge_wait_hook_fn wait_begin;
bridge_wait_hook_fn wait_end;
void               *wait_hook_opaque;
```

Declare:

```c
void bridge_set_wait_hooks(bridge_ctx_t *ctx,
                           bridge_wait_hook_fn begin,
                           bridge_wait_hook_fn end,
                           void *opaque);
```

- [ ] **Step 2: Add null-safe internal helpers**

Near the top of `bridge_qemu.c`, implement:

```c
static void bridge_wait_begin(bridge_ctx_t *ctx)
{
    if (ctx && ctx->wait_begin) ctx->wait_begin(ctx->wait_hook_opaque);
}

static void bridge_wait_end(bridge_ctx_t *ctx)
{
    if (ctx && ctx->wait_end) ctx->wait_end(ctx->wait_hook_opaque);
}

void bridge_set_wait_hooks(bridge_ctx_t *ctx,
                           bridge_wait_hook_fn begin,
                           bridge_wait_hook_fn end,
                           void *opaque)
{
    if (!ctx) return;
    ctx->wait_begin = begin;
    ctx->wait_end = end;
    ctx->wait_hook_opaque = opaque;
}
```

- [ ] **Step 3: Balance scopes in synchronous and posted-send paths**

For `bridge_send_tlp_and_wait()` and its timed variant, enter after taking
`tlp_mutex`, perform send and optional wait, then leave exactly once before
unlocking.  Use this shape:

```c
pthread_mutex_lock(&ctx->tlp_mutex);
bridge_wait_begin(ctx);
int ret = bridge_send_tlp(ctx, req);
if (ret >= 0) ret = bridge_wait_completion(ctx, req->tag, cpl);
bridge_wait_end(ctx);
pthread_mutex_unlock(&ctx->tlp_mutex);
return ret;
```

Use `bridge_wait_completion_timed()` in the timed variant.  Wrap
`bridge_send_tlp_fire()` from immediately before `bridge_send_tlp()` through
its return.  Refactor `bridge_drain_vf_pending()` to one `out:` label and wrap
the receive loop with one begin/end pair; preserve its existing 64-message
guard and message handling.

- [ ] **Step 4: Build and verify GREEN**

Run:

```bash
cmake --build build-time-freeze --target test_bridge_wait_hooks -j"$(nproc)"
ctest --test-dir build-time-freeze -R '^test_bridge_wait_hooks$' --output-on-failure
```

Expected: one test passes; the stale-Completion test still prints the existing
guard diagnostic but leaves the hook balanced.

- [ ] **Step 5: Run existing bridge/TCP regressions**

```bash
ctest --test-dir build-time-freeze \
  -R 'test_(bridge_loopback|sock_sync|tcp_roundtrip|transport_tcp)$' \
  --output-on-failure
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the bridge API**

```bash
git add bridge/qemu/bridge_qemu.h bridge/qemu/bridge_qemu.c \
        tests/unit/CMakeLists.txt tests/unit/test_bridge_wait_hooks.c
git commit -m "feat(bridge): bracket blocking VCS operations with wait hooks"
```

### Task 4: Add a failing QEMU clock-gate contract test

**Files:**
- Create: `tests/integration/test_qemu_wait_gate_source.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write the source contract**

Create:

```bash
#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
src="$repo/qemu-plugin/cosim_pcie_rc.c"
hdr="$repo/qemu-plugin/cosim_pcie_rc.h"

fail() { echo "[qemu-wait-gate] FAIL: $*" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "missing '$1' in ${2#$repo/}"; }

require '#include "sysemu/cpu-timers.h"' "$src"
require '#include "sysemu/runstate.h"' "$src"
require 'cpu_disable_ticks();' "$src"
require 'cpu_enable_ticks();' "$src"
require 'runstate_is_running()' "$src"
require 'icount_enabled()' "$src"
require 'bridge_set_wait_hooks(ctx,' "$src"
require 'vcs_wait_depth' "$hdr"
require 'vcs_wait_ticks_owned' "$hdr"

echo "[qemu-wait-gate] PASS"
```

Register it in `tests/integration/CMakeLists.txt`:

```cmake
add_test(NAME test_qemu_wait_gate_source
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_qemu_wait_gate_source.sh)
set_tests_properties(test_qemu_wait_gate_source PROPERTIES TIMEOUT 10)
```

- [ ] **Step 2: Run and verify RED**

```bash
bash tests/integration/test_qemu_wait_gate_source.sh
```

Expected: FAIL because the QEMU timer includes and gate callbacks are absent.

### Task 5: Implement the QEMU-side transaction clock gate

**Files:**
- Modify: `qemu-plugin/cosim_pcie_rc.h`
- Modify: `qemu-plugin/cosim_pcie_rc.c`
- Test: `tests/integration/test_qemu_wait_gate_source.sh`

- [ ] **Step 1: Add PF0 gate state**

Add to `CosimPCIeRC` next to `bridge_ctx`:

```c
uint32_t vcs_wait_depth;
bool     vcs_wait_ticks_owned;
int64_t  vcs_wait_started_ns;
```

- [ ] **Step 2: Include the QEMU timer and runstate APIs**

Add to `cosim_pcie_rc.c`:

```c
#include "sysemu/cpu-timers.h"
#include "sysemu/runstate.h"
#include "qemu/timer.h"
```

- [ ] **Step 3: Implement outermost begin/end callbacks**

Add before the MMIO helpers:

```c
static void cosim_vcs_wait_begin(void *opaque)
{
    CosimPCIeRC *s = opaque;
    if (s->vcs_wait_depth++ != 0) return;

    s->vcs_wait_ticks_owned = false;
    if (!runstate_is_running()) return;

    s->vcs_wait_started_ns = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
    cpu_disable_ticks();
    s->vcs_wait_ticks_owned = true;
    COSIM_DPRINTF(s, "VCS wait: virtual ticks frozen\n");
}

static void cosim_vcs_wait_end(void *opaque)
{
    CosimPCIeRC *s = opaque;
    if (s->vcs_wait_depth == 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: unbalanced VCS wait end\n");
        return;
    }
    if (--s->vcs_wait_depth != 0) return;

    if (s->vcs_wait_ticks_owned) {
        int64_t elapsed = qemu_clock_get_ns(QEMU_CLOCK_REALTIME) -
                          s->vcs_wait_started_ns;
        cpu_enable_ticks();
        s->vcs_wait_ticks_owned = false;
        COSIM_DPRINTF(s, "VCS wait: virtual ticks resumed after %.3f ms\n",
                      (double)elapsed / 1000000.0);
    }
}
```

- [ ] **Step 4: Register only for active iCount after realization work**

Initialize the three state fields to zero/false in PF0 realization.  After
topology/capability setup, sibling creation, and IRQ poller startup, but before
the final `SYNC_MSG_REALIZED`, add:

```c
if (icount_enabled()) {
    bridge_set_wait_hooks(ctx, cosim_vcs_wait_begin,
                          cosim_vcs_wait_end, s);
}
```

Do not register hooks for sibling PFs or realtime mode.

- [ ] **Step 5: Clear hooks before PF0 bridge destruction**

In PF0 exit, before `bridge_destroy()`, clear callbacks:

```c
bridge_set_wait_hooks((bridge_ctx_t *)s->bridge_ctx, NULL, NULL, NULL);
```

Defensively restore ticks only when `vcs_wait_ticks_owned` is true and the VM
is still running, then clear depth/ownership.  A stopped VM must remain
stopped; its normal `vm_start()` path owns tick re-enablement.

- [ ] **Step 6: Verify the source contract turns GREEN**

```bash
bash tests/integration/test_qemu_wait_gate_source.sh
```

Expected: `[qemu-wait-gate] PASS`.

- [ ] **Step 7: Commit the QEMU gate**

```bash
git add qemu-plugin/cosim_pcie_rc.c qemu-plugin/cosim_pcie_rc.h \
        tests/integration/CMakeLists.txt \
        tests/integration/test_qemu_wait_gate_source.sh
git commit -m "feat(qemu): freeze virtual ticks only during VCS waits"
```

### Task 6: Run local regression and build the patched QEMU on 53

**Files:**
- Verify: all files changed in Tasks 1–5
- Remote build host: `ubuntu@10.11.10.53`

- [ ] **Step 1: Run local source and bridge tests**

```bash
bash tests/integration/test_qemu_time_mode.sh
bash tests/integration/test_qemu_wait_gate_source.sh
cmake --build build-time-freeze -j"$(nproc)"
ctest --test-dir build-time-freeze --output-on-failure
```

Expected: all enabled local tests pass.  If a pre-existing unrelated test is
unavailable, record its exact name and reason; do not hide a changed-path
failure.

- [ ] **Step 2: Synchronize the changed source files to the 53 validation checkout**

Use the existing target checkout:

```text
/home/ubuntu/test_cosim/QEMU_VCS-feature-qemu-vcs-isolated-tcp
```

Before copying, record `git status --short` and preserve unrelated remote
changes.  Synchronize only the changed Makefile, bridge, QEMU-plugin, and test
files from this branch.

- [ ] **Step 3: Build bridge tests in a separate directory on 53**

In a login shell:

```bash
source ~/.bashrc
cd /home/ubuntu/test_cosim/QEMU_VCS-feature-qemu-vcs-isolated-tcp
cmake -S . -B build-time-freeze -DCMAKE_BUILD_TYPE=Debug
cmake --build build-time-freeze -j"$(nproc)"
ctest --test-dir build-time-freeze --output-on-failure
```

Expected: changed-path tests and the existing bridge suite pass.

- [ ] **Step 4: Rebuild the QEMU device model**

```bash
source ~/.bashrc
cd /home/ubuntu/test_cosim/QEMU_VCS-feature-qemu-vcs-isolated-tcp
make qemu-device
```

Expected: `third_party/qemu/build/qemu-system-x86_64` links successfully with
the updated `libcosim_bridge` symbols.  Run QEMU option parsing with:

```bash
timeout 3 third_party/qemu/build/qemu-system-x86_64 \
  -machine none -display none -nodefaults -accel tcg \
  -icount shift=auto,align=off,sleep=on -S
```

Exit 124 from `timeout` is acceptable; an option or symbol error is not.

### Task 7: Validate time semantics and Guest operations with VCS on 53

**Files:**
- Runtime logs under: `logs/time-freeze-20260804/`
- Driver bundle: `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/`

- [ ] **Step 1: Start the one-PF smoke configuration**

Start QEMU first:

```bash
make run-qemu QEMU_TIME_MODE=icount CONSOLE=login PORT_BASE=28100 \
  NUM_PFS=1 TAG_BIT=8
```

Start the external VCS image from its existing simulation directory with:

```bash
./simv +transport=tcp +REMOTE_HOST=127.0.0.1 +PORT_BASE=28100 \
  +INSTANCE_ID=0 +REAL_DUT +BYPASS_CONFIG=1 \
  +CFG_PROFILE=DPU_20F9_501X +NUM_PFS=1 +MAX_VFS=16 \
  +NUM_VFS=0 +TOPO=0 +TAG_BIT=8
```

Expected: `0000:01:00.0` enumerates as `20f9:5011` and the login prompt remains
usable.

- [ ] **Step 2: Verify normal time while VCS is idle**

After logging in as `root/123`, run:

```bash
python3 - <<'PY'
import time
s = time.monotonic()
time.sleep(5)
print(f"guest_sleep_delta={time.monotonic()-s:.3f}")
PY
```

Expected: both Guest and host observe approximately five seconds; accepting
4.5–6.5 seconds accounts for TCG load.

- [ ] **Step 3: Verify a blocked VCS read does not spend Guest time**

Resolve PF0 BAR0 from `lspci -s 01:00.0 -vv`, stop `simv`, then launch a Guest
read at BAR0+0x1010.  Hold VCS stopped for 15 wall seconds and resume it:

```bash
kill -STOP "$SIMV_PID"
sleep 15
kill -CONT "$SIMV_PID"
```

The Guest command records `/proc/uptime` immediately before and after the
`pci-debug` or `devmem` read.  Expected: host delta is at least 15 seconds,
while Guest delta excludes the stopped interval and remains below five
seconds.  The returned data must still match the VCS/DUT value.

- [ ] **Step 4: Verify delayed interactive login**

Restart the Guest, wait ten wall seconds after `Password:`, then enter `123`.
Expected: root shell opens and no `Login timed out after 60 seconds` appears.

- [ ] **Step 5: Load the fixed-128-QID driver and exercise tools after VCS idle**

Transfer the newest `.ko` from the named bundle through the host-only
management port, then run inside the Guest:

```bash
insmod /root/dpu_snd1.ko
dmesg | tail -100
lspci -s 01:00.0 -vv
```

After at least ten wall seconds with no target-device request, run the existing
`pci-debug` BAR read/write/read sequence.  Expected: traffic restarts, VCS sees
the new TLPs, the driver does not report a Guest-time timeout caused solely by
VCS latency, and QEMU debug logs show balanced freeze/resume pairs.

- [ ] **Step 6: Verify timeout and disconnect recovery**

Run once with a short `MMIO_TIMEOUT_MS`, suppress the VCS Completion, and check
that the read returns the existing all-ones/error behavior.  Then run `sleep 5`
inside the Guest.  Repeat with the VCS control connection closed.  Expected:
both failure paths resume normal Guest time; no later command remains frozen.

- [ ] **Step 7: Repeat topology smoke with four PFs**

Use matching QEMU/VCS arguments:

```text
QEMU: NUM_PFS=4 TAG_BIT=8
VCS:  +NUM_PFS=4 +MAX_VFS=16 +NUM_VFS=0 +TAG_BIT=8
```

Expected: `01:00.0` through `01:00.3` enumerate as `20f9:5011` through
`20f9:5014`; all PFs share PF0's bridge gate without unbalanced-depth logs.

### Task 8: Final regression, documentation, and commit audit

**Files:**
- Modify if needed: `docs/COSIM-VCS-INTEGRATION.md`
- Verify: `docs/superpowers/specs/2026-08-04-transaction-scoped-vcs-time-freeze-design.md`

- [ ] **Step 1: Document the corrected time semantics**

State that VCS-idle time advances normally, only blocking bridge operations
exclude host latency, posted writes resume after transport send, and
`MMIO_TIMEOUT_MS` remains host-time based.  Remove any statement claiming
global `sleep=off` behavior is required.

- [ ] **Step 2: Run the complete relevant regression set on 53**

Run CTest plus the existing DPU profile, runtime-BDF, tag-bit, management-NIC,
DMA byte-enable, MPS, and RCB tests.  Preserve command lines and pass/fail
counts in `logs/time-freeze-20260804/final-regression.log`.

- [ ] **Step 3: Review the final diff and commits**

```bash
git diff --check origin/feature/qemu-vcs-isolated-tcp...HEAD
git status --short
git log --oneline origin/feature/qemu-vcs-isolated-tcp..HEAD
```

Expected: no whitespace errors, no unexpected generated files, and every
production change has a corresponding failed-then-passing test recorded in
the task log.

- [ ] **Step 4: Commit documentation and validation evidence references**

```bash
git add docs/COSIM-VCS-INTEGRATION.md
git commit -m "docs: explain transaction-scoped VCS time freeze"
```

Do not push or rebuild an offline archive until explicitly requested after the
53 validation result is reviewed.
