# Table Frontdoor Write Throttle Design

**Date:** 2026-08-20
**Target:** `feature/qemu-vcs-isolated-tcp@a1ed632f513d38a9feff6f073a200979e6635693`

## Goal

Prevent software from issuing an unbounded stream of table frontdoor MMIO
writes faster than the DUT can consume them. After every 100 actual 4-byte
table frontdoor writes, the driver performs a synchronous 4-byte read from the
address just written. The read completion drains the preceding posted writes
before the driver continues.

The throttle applies only to the frontdoor fallback loops used by
`wr32_for_each()` and `wr32_for_high_order()`. It does not change ordinary
register `wr32()` calls, successful table-sideband writes, hard-error handling,
or any read path.

## Runtime interface

The `dpu_snd1` module gains a read-only unsigned parameter:

```text
table_frontdoor_flush_interval=100
```

- The default is `100`, so the throttle is active without an extra argument.
- A value of `0` disables the throttle and restores the original unpaced
  frontdoor loops.
- A positive value `N` performs one synchronous read after every `N` actual
  4-byte table frontdoor writes.
- The parameter is sampled while the module is loaded and cannot be changed at
  runtime (`0444`), matching the existing immutable module options.

Direct module-load examples:

```bash
# Default: flush after every 100 writes
insmod dpu_snd1.ko

# Explicitly select the default
insmod dpu_snd1.ko table_frontdoor_flush_interval=100

# Restore the original unpaced frontdoor behavior
insmod dpu_snd1.ko table_frontdoor_flush_interval=0
```

When the Guest consumes the kernel command line, the equivalent argument is:

```text
dpu_snd1.table_frontdoor_flush_interval=100
```

This option is independent of `table_backdoor`. It also protects table writes
when the semantic backdoor is disabled, not ready, unsupported, or has no
matching route and the existing policy selects frontdoor fallback.

## Driver architecture

### Per-DUT state

`struct dpu_hw` gains an `atomic64_t` table-frontdoor write sequence. Probe
initializes it to zero immediately after associating the `dpu_hw` with its
adapter. State is therefore independent for each probed DUT/PF and safe when
multiple driver contexts write tables concurrently.

The sequence is monotonic for the lifetime of that `dpu_hw`. A write whose
sequence is an exact multiple of the configured interval triggers the
synchronous read. An atomic sequence avoids a lock around MMIO and ensures
that concurrent callers collectively receive one pacing read per interval.

### Write helper

A table-frontdoor-only helper performs this operation:

```text
writel(value, hw->hw_addr + offset)
sequence = atomic64_inc_return(&hw->table_frontdoor_write_sequence)
if interval != 0 and sequence % interval == 0:
    readl(hw->hw_addr + offset)    // result intentionally discarded
```

The read uses the exact DWORD address written by the triggering operation. No
fixed DUT register address or additional address parameter is required. The
table address is already valid for the frontdoor path, and the user has
confirmed that reading the just-written table DWORD is acceptable.

The helper does not sleep, retry, compare data, or report a data mismatch. Its
only purpose is to wait for a PCIe/MMIO read completion and thereby bound the
number of outstanding posted writes.

### Integration with existing wrappers

The two complete-buffer wrappers retain their existing decision order:

1. Submit the complete entry through `dpu_table_submit()`.
2. On `DPU_TABLE_SUCCESS`, return without a frontdoor write or throttle count.
3. On `DPU_TABLE_ERROR`, return without replay or throttle count.
4. On `DPU_TABLE_FRONTDOOR`, retain the original low-to-high or high-to-low
   DWORD order, but issue each DWORD through the throttle helper.

The count carries across calls and across the two wrappers. For example, a
128-bit entry contributes four writes and a 1024-bit entry contributes 32. The
100th actual frontdoor DWORD write triggers the read even when it falls in the
middle of a wide entry; the wrapper then resumes in its original order.

`wr32_zero_for_each()`, `wr64mix32_for_each()`, mailbox BAR helpers, MSI-X BAR
helpers, and the generic `wr32()` macro are outside this change. This keeps the
scope limited to the table paths already covered by the semantic complete-entry
integration.

## Logging and errors

The module reports the configured interval once during initialization. It does
not log every pacing read because that would materially slow simulation and
obscure the existing HIGH table-sideband diagnostics.

Linux `readl()` has no status return separate from its data. The driver
intentionally discards the value. Existing QEMU/VCS completion and timeout
handling remains authoritative if the read cannot complete. No new retry or
frontdoor replay policy is introduced.

## Guest overlay and generated driver

The repository remains the source of truth through
`guest/dpu-table-sideband/`. The patch stack and transactional apply script are
updated so applying the overlay once or repeatedly produces the same driver
tree.

Validation must never edit the supplied release directory. On host
`10.11.10.53`, a clean copy is extracted and patched under:

```text
/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net
```

The built module is delivered at:

```text
/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net/dpu_snd1.ko
```

If the retained release still requires the documented LACP workaround, the
module is built with `CFLAGS=-UDPU_LACP`; that build detail is recorded in the
integration instructions and module evidence.

## Documentation

The integration guide records:

- the default interval and the `0` disable value;
- direct `insmod` and kernel-command-line forms;
- interaction with `table_backdoor` and frontdoor fallback;
- the generated source and module paths on host 53;
- the fact that the read value is discarded and is not a table-data
  verification step; and
- performance guidance for changing the interval when DUT capacity differs.

## Testing

All behavior changes are test-first.

### Source and unit contracts

- Prove the parameter exists, defaults to 100, uses mode `0444`, and accepts
  zero as disabled.
- Prove the per-`dpu_hw` atomic sequence is initialized.
- Prove only the two table wrapper fallback loops call the throttle helper.
- Prove low-to-high and high-to-low write order remains unchanged.
- Prove sideband success and hard-error paths do not reach the helper.
- Exercise intervals 0, 1, 100, and a boundary spanning multiple entries.
- Exercise concurrent callers against separate `dpu_hw` instances and confirm
  independent sequences.
- Confirm the pacing read uses the address of the triggering write and ignores
  its value.

### Guest validation on host 53

- Extract a clean copy of the specified release without modifying it.
- Apply the overlay twice and prove idempotence.
- Build `dpu_snd1.ko` using the documented release-compatible flags.
- Confirm `modinfo` reports the `table_frontdoor_flush_interval` parameter and
  description; confirm the default value from the compiled source because
  standard `modinfo` output does not expose numeric parameter defaults.
- Confirm the source and module delivery paths exist and record hashes.

### Project regression

- Run the complete host-53 CTest suite, including retained target tests and all
  table tests.
- Re-run default-off launch, Guest overlay, batch source, table read, and QEMU
  routing contracts.
- Confirm no common TLP/transport ABI header changes and no generated driver,
  module, build product, credential, or production DUT hierarchy is tracked.

## Delivery

After implementation, review, and successful host-53 verification:

1. Commit the overlay, tests, and integration documentation to
   `feature/qemu-vcs-isolated-tcp`.
2. Push that branch to `origin/feature/qemu-vcs-isolated-tcp` without
   force-pushing.
3. Report the remote commit, modified files, generated driver source path,
   module path, hashes, build command, test results, and enable/disable examples.
