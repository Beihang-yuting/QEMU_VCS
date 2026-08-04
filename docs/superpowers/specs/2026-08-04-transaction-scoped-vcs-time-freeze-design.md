# Transaction-Scoped VCS Time Freeze Design

## Context

The existing opt-in command line uses:

```text
-accel tcg -icount shift=auto,align=off,sleep=off
```

This globally changes Guest timer behavior.  After a long host-side VCS/DUT
wait, adaptive iCount can catch virtual time up to host time.  A controlled
test on the VCS host reproduced the resulting serial-login failure: after a
62-second host pause, the Guest's 60-second password timeout expired about
4.6 wall-clock seconds after the password prompt.  The same global mode can
also distort `sleep`, systemd timers, and driver `msleep()` behavior while no
VCS transaction is active.

The required behavior is narrower: host time spent sending a co-simulation
request or waiting for its response must not consume Guest virtual time, but
Guest time must run normally whenever no bridge operation is blocking the
vCPU.

This design supersedes the global-time assumptions in
`2026-07-31-qemu-icount-time-mode-design.md` while preserving its public
`QEMU_TIME_MODE` interface.

## Goals

- Freeze Guest virtual time only around a blocking QEMU-to-VCS bridge
  operation.
- Resume Guest time on success, host timeout, transport error, and unexpected
  Completion paths.
- Keep Guest time normal while VCS is idle, including interactive login,
  driver loading, `sleep`, `lspci`, and `pci-debug` use.
- Keep `MMIO_TIMEOUT_MS` as a host-time safety bound even while Guest time is
  frozen.
- Preserve the existing default `QEMU_TIME_MODE=realtime` behavior.
- Preserve the current single-vCPU and single-outstanding-control-channel
  ordering guarantees.

## Non-goals

- The clock gate is not a general PCIe bandwidth limiter.
- Posted Memory Writes do not wait for a PCIe Completion.  The bridge only
  excludes time spent blocking in their transport send; it does not hold time
  frozen until the DUT consumes the write.
- A driver that receives valid but permanently incorrect DUT status can still
  reach its own logical timeout or polling limit.
- Multi-vCPU clock coordination is not added.  All supported launch variants
  currently use `-smp 1`.
- DMA and MSI arriving asynchronously from VCS do not freeze Guest time because
  they do not block a Guest CPU request.

## User interface

The accepted values remain:

```text
QEMU_TIME_MODE=realtime
QEMU_TIME_MODE=icount
```

`realtime` remains the default and does not register an active clock gate.

`icount` changes its QEMU arguments to the supported adaptive form:

```text
-accel tcg -icount shift=auto,align=off,sleep=on
```

`sleep=on` keeps idle Guest timers tied to normal elapsed time.  Transaction
hooks remove VCS/DUT wait latency from the adaptive clock correlation, so the
old `sleep=off` global fast-forward behavior is no longer needed.

No rootfs authentication setting is changed.  `/etc/login.defs` keeps its
normal 60-second password timeout, which must now correspond to approximately
60 wall-clock seconds while the console is idle.

## Architecture

### Bridge wait-hook API

`bridge/qemu/bridge_qemu.h` exposes an optional callback registration API:

```c
typedef void (*bridge_wait_hook_fn)(void *opaque);

void bridge_set_wait_hooks(bridge_ctx_t *ctx,
                           bridge_wait_hook_fn begin,
                           bridge_wait_hook_fn end,
                           void *opaque);
```

The bridge stores the callbacks and opaque pointer but does not include QEMU
headers or call QEMU APIs directly.  With no callbacks registered, every path
retains its current behavior.

Internal helpers enter and leave the wait scope.  The helpers are used around:

- `bridge_send_tlp_and_wait()`;
- `bridge_send_tlp_and_wait_timed()`;
- the blocking transport-send portion of `bridge_send_tlp_fire()`; and
- `bridge_drain_vf_pending()` while it performs a bounded receive.

The scope begins before the potentially blocking send and ends after the final
receive or timeout.  Each function uses one cleanup path so every successful
begin has exactly one end, including send failure, receive failure, host
timeout, stale-Completion exhaustion, and unexpected-message returns.

The topology handshake occurs before the Guest runs and before hooks are
registered, so it does not manipulate VM ticks during device realization.

### QEMU clock gate

`qemu-plugin/cosim_pcie_rc.c` provides the hook implementation.  When
`QEMU_TIME_MODE=icount` is active, PF0 registers the hooks at the end of device
realization, after topology discovery and before Guest execution begins.
Sibling PFs share PF0's bridge context and therefore share the same gate.

The begin hook runs under the Big QEMU Lock on the vCPU/device path.  On the
outermost begin, if the VM runstate is running, it calls
`cpu_disable_ticks()` and records that this scope owns the disabled state.  The
matching outermost end calls `cpu_enable_ticks()`.  A depth counter makes the
pair safe for nested bridge helpers, and an underflow is logged as a Guest
error rather than enabling ticks blindly.

If the VM was not running at begin time, the scope does not disable ticks and
must not enable them at end.  This prevents a realization, monitor-stop, or
shutdown path from starting VM time accidentally.

While the bridge waits, the current single vCPU executes no Guest
instructions, `QEMU_CLOCK_VIRTUAL_RT` is stopped, and adaptive iCount cannot
accumulate a host-versus-virtual backlog.  On return, the tick offset excludes
the VCS wait and normal Guest execution resumes.

### Request behavior

- CFG Reads and MMIO Reads remain synchronous and serialized by `tlp_mutex`.
  At most one such control request waits for a Completion per bridge context.
- CFG/MMIO transport send latency is excluded from Guest time.
- Posted MMIO Writes resume Guest time as soon as the transport send returns.
- Extended-config writes keep their bounded VF-event drain; only the drain's
  actual host wait is excluded.
- `MMIO_TIMEOUT_MS` continues to use the transport's host clock, so a lost DUT
  response still returns an error rather than freezing the VM forever.
- DMA and MSI callbacks are unchanged and never invoke the wait hooks.

## Failure handling and diagnostics

All exit paths restore ticks through a single cleanup section.  Hook state is
cleared before PF0 destroys the bridge context.  Debug mode logs outermost
freeze/resume events and host wait duration; normal mode does not print per-TLP
clock messages.

A Completion or transport failure is returned to the existing caller after
time is resumed.  The design does not convert protocol failures into success
and does not suppress `MMIO_TIMEOUT_MS` diagnostics.

## Verification

### Automated tests

1. Update the Makefile dry-run integration test to require
   `shift=auto,align=off,sleep=on` exactly once in all console variants and to
   reject the former `sleep=off` string.
2. Add bridge tests with counting hooks that cover successful Completion,
   send failure, receive failure, timed host timeout, stale-Completion guard
   exhaustion, fire-and-forget send, and VF pending-drain timeout.  Every case
   must finish with equal begin/end counts and zero active depth.
3. Keep `QEMU_TIME_MODE=realtime` free of iCount arguments and with inactive
   clock hooks.
4. Run the existing launch, topology, management-network, tag-width, DMA,
   MPS/RCB, and byte-enable regression suites.

### VCS validation on 10.11.10.53

Use a bash login shell so the VCS environment is loaded.  Run QEMU and VCS with
the DPU profile, config bypass, one PF/16 VF smoke configuration first, then
the requested four-PF/16-VF-per-PF configuration.

After the Guest reaches a shell:

1. Stop the VCS process while a Guest MMIO read is waiting, hold it for a known
   wall interval, resume VCS, and verify the Guest monotonic-clock delta does
   not include that interval.
2. With no VCS request outstanding, run `sleep 5` and verify both Guest and wall
   time advance by approximately five seconds.
3. Wait at the password prompt for ten seconds and log in with `root/123`.
4. Load the fixed-128-QID DPU driver and confirm slow status reads do not spend
   the driver's Guest-time deadline while the host waits for VCS.
5. Run `lspci` and `pci-debug` reads/writes after a VCS-idle period and confirm
   requests restart normally.
6. Exercise an MMIO host timeout and a forced transport disconnect; both must
   restore Guest time before returning the existing error.

The change passes only if VCS wait latency is invisible to Guest time, idle
Guest time remains normal, and no failure path leaves the clock disabled.
