# DPU 20f9:501x PCIe Configuration Profile Design

## Goal

Add an opt-in VCS configuration-space profile for the real Shenzhen Silicon
Dynamic Networks DPU. The profile must model one to four PFs, sixteen VFs per
PF, the observed PF/VF BAR layout, the real capability chains, and a functional
PF MSI-X capability while preserving the existing default profile and its
single-PF/16-VF behavior.

## Scope

The profile is selected at VCS run time:

```text
+REAL_DUT +BYPASS_CONFIG=1
+CFG_PROFILE=DPU_20F9_501X
+NUM_PFS=<1..4> +MAX_VFS=16
```

`CFG_PROFILE` is a VCS-only selector. QEMU and the RTL DUT do not parse the
string. QEMU must receive the same `NUM_PFS` value through its existing
`cosim-pcie-rc,num_pfs=` property. The bridge transports the structured
topology generated from the profile.

The design remains a flat, single-bus endpoint topology. It does not add a
virtual PCIe switch or cross-bus VF routing.

## Profile Selection and Precedence

- No `CFG_PROFILE` plusarg selects the existing legacy behavior unchanged.
- `CFG_PROFILE=DPU_20F9_501X` selects this profile.
- Any unknown non-empty profile name is a fatal configuration error.
- The DPU profile accepts `NUM_PFS=1..4` and requires sixteen VFs per PF.
- If `MAX_VFS` is omitted, the DPU profile supplies `16`; an explicit value
  other than `16` is rejected.
- The profile owns Vendor, PF/VF Device, Subsystem, BAR, MSI-X, and capability
  values. Generic `VENDOR_ID`, `DEVICE_ID`, and `VF_DEVICE_ID` plusargs do not
  override it; conflicting explicit identity arguments produce a warning.
- In `REAL_DUT` mode VFs start disabled. `NUM_VFS` does not pre-enable them;
  guest SR-IOV writes control their lifecycle.

## Profile Contents

### Identity and Topology

| Field | Value |
|---|---|
| Vendor ID | `20f9` |
| PF0 Device ID | `5011` |
| PF1 Device ID | `5012` |
| PF2 Device ID | `5013` |
| PF3 Device ID | `5014` |
| VF Device ID | `8689` |
| Subsystem Vendor ID | `20f9` |
| Subsystem Device ID | `0000` |
| Revision ID | `00` |
| Class Code | `020000` (Ethernet controller) |
| VFs per enabled PF | `16` |
| VF stride | `1` |
| Function Dependency Link | PF index |

PFs are consecutive functions beginning at the runtime-bound PF0 BDF. For PF
index `p`, the profile computes:

```text
first_vf_offset(p) = NUM_PFS + p * 15
vf_rid(p, v)       = pf_rid(p) + first_vf_offset(p) + v
```

This reproduces the observed four-PF offsets `4, 19, 34, 49`. With two PFs the
offsets become `2, 17`. The resulting VF RIDs form disjoint contiguous blocks.

### PF BARs

| BAR | Size | Type |
|---|---:|---|
| BAR0/BAR1 | 32 MiB | 64-bit prefetchable memory |
| BAR2/BAR3 | 64 KiB | 64-bit prefetchable memory |
| BAR4/BAR5 | 64 KiB | 64-bit prefetchable memory |

The initial low DWORD contains only flags `0x0000000c`; assigned addresses from
the supplied dump are not reset values. Expected sizing responses are:

```text
PF BAR0 low/high: 0xfe00000c / 0xffffffff
PF BAR2 low/high: 0xffff000c / 0xffffffff
PF BAR4 low/high: 0xffff000c / 0xffffffff
```

### VF BARs

| BAR | Size | Type |
|---|---:|---|
| VF BAR0/BAR1 | 16 KiB | 64-bit prefetchable memory |
| VF BAR2/BAR3 | 16 KiB | 64-bit prefetchable memory |
| VF BAR4/BAR5 | 32 KiB | 64-bit prefetchable memory |

Expected SR-IOV VF BAR sizing responses are:

```text
VF BAR0 low/high: 0xffffc00c / 0xffffffff
VF BAR2 low/high: 0xffffc00c / 0xffffffff
VF BAR4 low/high: 0xffff800c / 0xffffffff
```

### Standard Capability Chain

The PF standard capability chain exactly follows the captured device layout:

```text
0x40 Power Management -> 0x60 MSI-X -> 0x70 PCI Express -> end
```

The profile stores the observed static capability values and assigns correct
field permissions. Host-programmed control/status values remain dynamic rather
than being frozen to the post-enumeration dump.

PF MSI-X is modeled at offset `0x60` with:

```text
vectors = 16
table   = BAR4 + 0x0000
PBA     = BAR4 + 0x4000
```

Table Size and Table/PBA descriptors are read-only. MSI-X Enable and Function
Mask remain writable. MSI-X table and PBA MMIO stay in BAR4 and flow to the real
DUT in `REAL_DUT` mode.

The PCI Express capability at `0x70` advertises the captured Endpoint v2 device
and link capabilities, including a maximum payload capability of 512 bytes and
an 8 GT/s x4 link. Device/Link control registers remain writable where required
by PCIe software.

### Extended Capability Chain

The PF extended capability chain is:

```text
0x100 AER
  -> 0x140 SR-IOV
  -> 0x180 ARI
  -> 0x1c0 Secondary PCI Express
  -> 0x400 ACS
  -> end
```

The AER masks and severity values come from the supplied dump, with status
registers retaining their write-one-to-clear behavior. SR-IOV contains sixteen
Initial/Total VFs, the per-PF Function Dependency Link and offset, stride one,
VF Device ID `8689`, page-size fields from the dump, and the VF BAR descriptors
above. ARI Next Function is generated from the active PF count instead of being
copied blindly from PF0.

ATS, PRI, and PASID are not advertised by this profile because they are absent
from the captured extended-capability chain. They remain available in the
legacy profile.

All unimplemented/reserved bytes are zero, including the observed empty range
between the Secondary PCI Express and ACS capabilities.

### Dynamic State

The following captured values are treated as host/runtime state rather than
hard-coded reset values:

- Command Memory Space and Bus Master Enable bits;
- BIOS-assigned PF and VF BAR base addresses;
- PCIe Device/Link control fields written by firmware or Linux;
- MSI-X Enable and Function Mask;
- SR-IOV NumVFs, VF Enable, VF MSE, and ARI hierarchy control;
- AER status fields.

Writes update the VIP configuration image and invoke existing topology/VF
lifecycle callbacks. Configuration TLPs remain bypassed and are not forwarded
to the RTL DUT. Any DUT-internal side effects required later must use explicit
sideband synchronization rather than config-TLP passthrough.

## Component Responsibilities

| Component | Uses profile? | Responsibility |
|---|---|---|
| `vcs-tb/cosim_xrc_driver.sv` | Directly | Parse `CFG_PROFILE`, select/validate the profile, apply profile defaults, and pass it to each RC function manager. |
| New shared device-profile model | Directly | Own immutable identity, BAR, MSI-X, capability, and per-PF SR-IOV rules. Return a resolved PF profile for a PF index and active PF count. |
| `pcie_tl_func_manager.sv` | Directly | Create PF/VF contexts from resolved data, compute collision-free RIDs, register capabilities, and export distinct per-PF identities/topology. |
| `pcie_tl_cfg_space_manager.sv` | Indirectly | Store the 4 KiB image, field permissions, capability links, and writable runtime state. It does not parse plusargs. |
| `pcie_tl_config_proxy.sv` | Indirectly | Answer BDF config reads/writes, implement correct paired 64-bit PF/VF BAR sizing and address writes, and process SR-IOV controls. |
| VCS bridge/topology | No string parsing | Transport resolved IDs, BDFs, BAR sizes, MSI-X counts, and VF layout to QEMU. |
| QEMU `cosim-pcie-rc` | No string parsing | Use `num_pfs`, query the resolved VCS topology, register every non-empty PF BAR with its 64-bit/prefetch flags, expose matching QEMU functions, and receive VF lifecycle events. |
| Real RTL DUT | No | Receive MMIO/DMA/data-plane traffic as before. It never sees `CFG_PROFILE`. |
| Guest BIOS/Linux | No | Discover the profile through normal configuration reads and program BAR/MSI-X/SR-IOV state. |

For multiple RC agents, the same global profile applies to every RC. This is
appropriate when both DPU host-facing ports expose the same PF/VF profile.

## Environment Integration

VCS example:

```text
./simv +REAL_DUT +BYPASS_CONFIG=1 \
  +CFG_PROFILE=DPU_20F9_501X +NUM_PFS=4 +MAX_VFS=16 \
  +REMOTE_HOST=10.11.10.53 +PORT_BASE=9100
```

QEMU example:

```text
make run-qemu NUM_PFS=4
```

Changing from four PFs to two requires only changing `NUM_PFS` on both sides;
it does not require recompiling VCS or QEMU after profile support is built.

The QEMU root port needs a 64-bit prefetchable reserve large enough for PFs and
runtime-created VFs. The Makefile will expose a reserve variable with a 256 MiB
default for this profile and apply it to the root-port prefetchable window. Four
PFs consume approximately 128.5 MiB of PF BAR space, and all 64 VFs consume
another 4 MiB before alignment overhead.

## Failure Handling and Diagnostics

The VCS build phase reports the selected profile and a resolved line for every
PF. It terminates with `uvm_fatal` for an unknown profile, more than four PFs,
or a non-sixteen explicit `MAX_VFS` value. The resolved log includes each PF
Device ID, BDF, VF offset/range, BAR sizes, and MSI-X count.

The topology handshake must reject a QEMU/VCS PF-count mismatch instead of
silently enumerating a partial topology.

QEMU currently realizes only PF BAR0 and gives sibling PFs a fixed 64 KiB
BAR0. The implementation must replace that fallback for a valid topology with
topology-driven registration of BAR0/BAR2/BAR4 for PF0 and every sibling PF.
The shared topology payload must carry BAR flags as well as sizes so QEMU does
not infer 32/64-bit or prefetchability from a profile name.

## Verification

Implementation follows test-driven development. Tests first assert failure for
the missing DPU behavior, then cover:

1. PF0 through PF3 identity, subsystem identity, and class/revision fields;
2. two-PF and four-PF VF offsets, ranges, and absence of RID collisions;
3. exact standard and extended capability offsets and next pointers;
4. PF MSI-X count, BAR4 Table/PBA descriptors, and writable enable/mask bits;
5. paired 64-bit PF and VF BAR sizing masks and address programming;
6. SR-IOV Total/Initial/NumVFs and enable/disable lifecycle;
7. absence of ATS/PRI/PASID in the DPU profile;
8. preservation of the legacy single-PF/16-VF profile;
9. QEMU topology-driven PF BAR0/BAR2/BAR4 registration and PF-count mismatch
   rejection;
10. QEMU launch/topology regression for `NUM_PFS=2` and `NUM_PFS=4`;
11. remote VCS regression and guest `lspci -nnvvxxxx` comparison against the
    supplied profile.

No commit or push is part of this work unless separately requested.
