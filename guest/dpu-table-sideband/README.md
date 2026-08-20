# DPU table sideband Guest overlay

This overlay adds the CoSim table controller to the existing `dpu_snd1.ko`.
It does not create or install a second kernel module. The normal frontdoor BAR
path remains the default because the `table_backdoor` module parameter is off
unless explicitly enabled.

Apply the overlay to a disposable `host-driver-net` tree:

```sh
./scripts/apply_dpu_table_sideband.sh /path/to/host-driver-net
```

The script copies the driver to a same-filesystem staging directory, validates
and applies every contiguous numbered patch there, copies the controller and
shared UAPI sources, and publishes the complete tree with directory renames.
The supplied tree is unchanged if validation or staging fails. Reapplying the
same overlay is a checksum-preserving no-op.

For the 2026-08-10 reference release, extract
`source/host-driver-net-skipeth.tar.gz` into a temporary build directory. Do
not apply the overlay in the release directory itself.

Enable the path with `table_backdoor=1` when loading `dpu_snd1.ko`. Disabled
mode returns to the frontdoor before controller lookup or MMIO. Enabled mode
supports physical PF0 and logical BAR0/BAR1. Missing/not-ready routing and slot
contention fall back before publication; execution, timeout, target-loss and
other hard errors are not replayed through the frontdoor.

The same overlay adds the read-only `table_frontdoor_flush_interval` module
parameter. It defaults to 100, so the first command below enables pacing at
100 even though it does not pass the parameter explicitly:

```bash
insmod dpu_snd1.ko
insmod dpu_snd1.ko table_backdoor=1 table_frontdoor_flush_interval=100
insmod dpu_snd1.ko table_frontdoor_flush_interval=0
```

Only actual 4-byte MMIO writes in the `wr32_for_each` and
`wr32_for_high_order` frontdoor fallback loops advance the counter. With the
default interval, immediately after the 100th write (and every 100 writes
thereafter), the driver performs `readl` on the DWORD address it just wrote.
The return value is discarded: this is a posted-write pacing readback, not
data validation. A value of 0 restores the original unthrottled loops. A
successful backdoor submission and a hard backdoor error both return before
the fallback loops and therefore do not count. Each `dpu_hw` has an
independent counter and IRQ-safe pacing lock. For a nonzero interval, that
per-device lock serializes the complete write/count/boundary-read sequence, so
the next write on the same device cannot pass its pacing read; different
`dpu_hw` instances can still progress independently. A value of 0 bypasses
both the counter and the lock.

The equivalent kernel command-line settings are:

```text
dpu_snd1.table_frontdoor_flush_interval=100
dpu_snd1.table_frontdoor_flush_interval=0
```

The numbered patch stack routes complete table buffers through the semantic
sideband before executing the original DWORD loops. Patch 0002 wraps the
central low-to-high and high-to-low writers: success skips the MMIO loop, a
hard error returns without replay, and an unavailable route executes the
original loop in its original order. The route map, rather than guest address
constants, decides whether a buffer is a semantic table write.

Patch 0003 batches the complete 128-entry VIO notification table after insert
or remove/compaction. Entries are packed contiguously in each DMA payload;
the table stride advances logical BAR offsets only. Requests split only
between entries when the complete payload exceeds one controller slot. A
frontdoor result is replayable only before the first successful request;
partial completion or a hard error stops the batch without MMIO replay.
