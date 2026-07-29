# Single-Bus 16 PF + 240 VF Design

## Goal

Support one DPU host-facing PCIe endpoint with 16 PFs and 240 VFs on one
downstream PCIe bus. Configuration space remains owned by the VIP when VCS is
started with `+REAL_DUT +BYPASS_CONFIG=1`; MMIO, DMA, interrupts, and other
data-plane traffic continue to reach the real DUT.

Cross-bus VF routing, a virtual PCIe switch, and uneven VF allocation are out
of scope for this change.

## Alternatives Considered

Three layouts were considered:

1. A fixed single-bus ARI layout uses all 256 devfns and keeps one stable
   topology. This is selected because the real device has exactly 15 VFs per
   PF, so it fits without overflow.
2. Two downstream buses behind a virtual switch leave spare RID capacity but
   add a bridge hierarchy and change the guest-visible topology unnecessarily.
3. Switching automatically between one and two buses based on VF count saves
   a bus in small configurations but makes BDFs and firmware behavior depend on
   runtime parameters.

## Fixed Topology

Each host uses one QEMU process, one fixed QEMU Root Port, one downstream bus,
and one shared three-channel cosim TCP transport:

```text
QEMU PCIe Root Complex
└── pcie-root-port (ARI forwarding capable)
    └── one downstream bus
        └── cosim endpoint: 16 PF + 240 VF
```

The 240 VFs are distributed uniformly: 15 VFs per PF.

For a firmware-assigned PF0 base RID `B`, the routing-ID layout is:

```text
PF(i)       = B + i                              i = 0..15
VF(i, j)    = B + i + 16 + j * 16              j = 0..14
```

Consequently every PF advertises:

```text
TotalVFs       = 15
InitialVFs     = 15
FirstVFOffset  = 16
VFStride       = 16
```

PF0 must be placed at devfn 0 on its downstream bus. The occupied devfn range
is then exactly 0 through 255, and no RID crosses into the next bus. If `B` is
bus `bb`, device 0, function 0, Linux displays:

```text
PF0..PF7     bb:00.0 .. bb:00.7
PF8..PF15   bb:01.0 .. bb:01.7
VF region   bb:02.0 .. bb:1f.7
```

The apparent device-number changes are the conventional rendering of the
single eight-bit ARI function number. They do not represent separate physical
devices or additional buses.

## QEMU Model

The primary `cosim-pcie-rc` remains the owner of the bridge transport and IRQ
poller. It creates 15 sibling PF objects on the same downstream bus. All PFs
share the transport but retain independent config BDFs, BAR state, VF
apertures, DMA requester identity, and interrupt identity.

PF objects are placed at raw bus devfn values 0 through 15. `PCI_DEVFN(slot,
function)` must not be used with logical PF numbers above 7 because it masks
the function to three bits. The model carries an explicit logical PF index
0 through 15 instead of deriving it with `PCI_FUNC(devfn)`.

The local QEMU shadow config advertises an ARI extended capability so QEMU's
own PCIe link checks recognize PFs whose traditional display has a non-zero
device number. Guest-visible config reads continue to be answered by the VIP.
The existing Root Port advertises ARI Forwarding Supported; firmware/Linux can
enable ARI forwarding through Device Control 2.

The Root Port reserves 64 MiB of non-prefetchable MMIO space. The default VIP
profile needs 16 MiB for 16 PF BAR0s and 240 64-KiB VF BAR0s; the larger fixed
reservation covers alignment and firmware allocation overhead. No additional
bus-number reservation is needed.

The QEMU PF registry and shared topology limit increase from 8 to 16. The
topology response grows from 900 to 1796 bytes and still fits in both the TCP
framing and the 4 KiB shared-memory control region.

## VCS/VIP Model

The function manager accepts `NUM_PFS=16`. Bootstrap and runtime-bound PF BDFs
use `base_bdf + pf_index`, preserving all eight devfn bits; they must not use
`pf[2:0]`.

The ARI Next Function Number chain is:

```text
PF0 -> PF1 -> ... -> PF15 -> 0
```

Each PF owns 15 preallocated VF contexts. `first_vf_offset` and `vf_stride`
are both the configured PF count, which is 16 for this topology. Runtime BDF
binding atomically rekeys all 16 PF contexts and all VF contexts from the BDF
observed on the first PF0 Vendor ID read.

With `+REAL_DUT +BYPASS_CONFIG=1`, the VIP answers PF and VF enumeration,
SR-IOV, BAR sizing, ARI, and related config transactions. The real DUT is not
required to answer configuration requests. Memory requests, completions, DMA,
and interrupt traffic retain their existing real-DUT path.

## Runtime Interface and Validation

The supported launch contract is:

```text
QEMU: NUM_PFS=16
VCS:  +REAL_DUT +BYPASS_CONFIG=1 +NUM_PFS=16 +MAX_VFS=15
```

`NUM_PFS` outside 1 through 16 is rejected at launch. `MAX_VFS` greater than
15 is rejected for the single-bus 16-PF profile instead of silently creating
cross-bus RIDs. Existing 1 through 8 PF configurations remain supported.
The launch also rejects a PF0 placement whose downstream devfn is not zero,
because adding the full 0-through-255 ARI range would otherwise overflow into
the next bus.

Validation proceeds in increasing scope:

1. Unit tests verify the full PF/VF RID map, uniqueness of all 256 RIDs, and
   that the maximum RID remains on PF0's bus.
2. Source/launch tests verify the 16-PF range and matching QEMU/VCS arguments.
3. QEMU and bridge builds verify the enlarged topology ABI on both peers.
4. A VCS config-bypass run verifies all 16 PFs enumerate without duplicate
   BDFs or UVM errors.
5. Enabling 15 VFs on every PF verifies exactly 16 PFs and 240 VFs, all on one
   bus, with ARI enabled and no `cross-bus config stub` messages.
6. A representative PF and VF MMIO/DMA transaction verifies that config stays
   in the VIP while the real-DUT data plane remains connected.

A failure to enable ARI forwarding, a duplicate RID, a PF/VF count mismatch,
or a computed RID outside the PF bus is a hard validation failure.

## Compatibility Boundaries

This change keeps the TLP, completion, DMA, MSI, VF-event, and VF-config wire
structures unchanged. The topology response size changes because its fixed PF
array grows to 16, so the QEMU and VCS bridge libraries must be rebuilt and
deployed together. Mixed old/new bridge binaries are unsupported and will be
rejected by the existing TCP payload-size check.

Each DPU host-facing port uses an independent QEMU/VCS instance and therefore
an independent BDF namespace and transport. Dual-host UPS/DSP or EP/EP policy
does not alter this per-host single-bus layout.
