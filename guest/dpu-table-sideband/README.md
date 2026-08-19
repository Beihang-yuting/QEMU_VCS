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
