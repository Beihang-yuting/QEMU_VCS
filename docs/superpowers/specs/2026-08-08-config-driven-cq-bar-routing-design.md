# Config-driven PCIe CQ BAR routing design

Date: 2026-08-08

Status: approved for implementation planning

## 1. Problem statement

In real-DUT co-simulation, QEMU sends host memory requests to the VCS RC
driver and the Xilinx adapter converts them to CQ AXI-Stream traffic. The
adapter currently encodes every CQ descriptor with fixed routing sideband:

```systemverilog
encode_cq(tlp,
    .bar_id(3'h0),
    .bar_aperture(6'h0),
    .target_func(8'h0));
```

This loses the BAR and function selected by PCIe enumeration. For example,
the DPU driver writes `PF0 BAR2 + 0x2c = 1` and then polls the same register,
but the DUT receives every request as PF0/BAR0. The address bits alone do not
repair this because the Xilinx CQ interface supplies the selected BAR and
target function as explicit descriptor fields.

The fix must model the Root Complex BAR decode performed by real PCIe
hardware. QEMU continues to send the actual memory TLP address and its
intended target BDF. The shared VIP configuration model is authoritative for
BAR assignment and decides which PF or VF BAR owns the address.

## 2. Goals

- Generate correct Xilinx CQ `bar_id`, `bar_aperture`, and `target_func` for
  host-to-DUT MRd/MWr requests.
- Keep PCIe request identity semantics explicit on every QEMU-originated
  host-to-device request: `requester_id=16'h0000` for the RC and
  `target_bdf` equal to the PF/VF that the guest actually enumerated.
- Use current VIP configuration-space state, including firmware BAR
  assignments, Command.MSE, SR-IOV state, and runtime BDF binding.
- Support the current DPU profile with one to four PFs and up to sixteen VFs
  per PF on one downstream bus.
- Keep `+REAL_DUT +BYPASS_CONFIG=1`: configuration requests are answered by
  the VIP, while valid BAR memory requests continue to the real DUT.
- Preserve stand-in and legacy behavior unless config-driven routing is
  selected.
- Reject invalid or ambiguous routing instead of silently sending a request
  to PF0/BAR0.

## 3. Non-goals

- PCIe switch routing or BAR windows across multiple downstream buses.
- The previously discussed 16-PF/240-VF cross-bus topology.
- Sending configuration TLPs to the real DUT. Configuration bypass remains
  mandatory because the current request adapter only builds MRd/MWr TLPs.
- Changing QEMU's DMA, MSI-X, MPS/RCB, byte-enable, or tag-allocation logic.
- Translating the CQ address into a BAR-relative address. The CQ descriptor
  keeps the original PCIe system address.

## 4. Selected architecture

The routing path is:

```text
QEMU MRd/MWr
  -> sample the owning QEMU PCIDevice's current BDF at access time
  -> requester_id=0000, target_bdf=sampled PF/VF BDF
  -> cosim_xrc_driver
  -> pcie_tl_bar_decoder
       reads a generation-keyed snapshot from pcie_tl_func_manager
       independently resolves address to PF/VF/BAR
       validates QEMU target_bdf
  -> attach CQ route metadata to pcie_tl_tlp
  -> xilinx_pcie_if_adapter
  -> encode_cq(tlp, bar_id, bar_aperture, target_func)
  -> DUT CQ interface
```

The decoder is shared VIP functionality, not DPU-test code. The RC driver
owns policy decisions such as returning UR or dropping a posted write. The
Xilinx adapter only consumes already-validated route metadata and encodes the
descriptor.

Each `cosim_xrc_driver` owns one decoder bound to that driver's function
manager. Cache generation, BDF state, counters, and route results are isolated
per `rc_index`; no global BAR cache is shared between two DPU host interfaces.

The chosen design avoids two rejected alternatives:

1. Deriving BAR ID only from QEMU `target_bdf` would trust information that is
   not part of PCIe address routing and would not detect inconsistent BAR
   assignments.
2. Hard-coding the DPU BAR layout in `cosim_xrc_driver` would duplicate the
   configuration model and become stale after firmware reprograms a BAR or
   enables VFs.

### 4.1 Requester ID, target BDF, and runtime BDF ownership

`requester_id` and `target_bdf` describe different PCIe roles and must never
be copied from one another. For every request initiated by QEMU on behalf of
the host (CfgRd, CfgWr, MRd, MWr, and ATS invalidation), the requester is the
RC and is encoded as `16'h0000`. The target is the selected PF or VF. In the
opposite direction, a DUT-initiated DMA/ATS/MSI request keeps the originating
PF/VF BDF in `requester_id`; that device-requester path is not rewritten.

The current launch command already fixes a q35 Root Port and places PF0 at
raw devfn zero behind it. The QEMU configuration callbacks calculate the full
16-bit BDF from `pci_bus_num()` and the device's complete eight-bit `devfn` on
each access. The first PF0 Vendor-ID read carries that observed BDF to the VIP,
where `bind_runtime_pf_base()` atomically rekeys the prebuilt PF/VF model before
lookup. Thus `01:00.x` remains the common result, but it is no longer assumed
by the configuration model.

PF BAR callbacks must use the same access-time calculation. A BDF cached while
the QEMU device is realized is invalid because firmware has not necessarily
programmed the Root Port secondary bus number yet. VF aperture callbacks use
the runtime-bound `first_vf_bdf` supplied by the VIP and the VF stride; the VF
config stubs are created at those same BDFs. A focused source contract and a
QEMU-independent C unit test enforce the host-request fields and dynamic PF
BDF sampling.

The address decoder remains authoritative. `target_bdf` is only an independent
hint and consistency check after the address, live BAR state, and enable bits
have selected a function. A mismatch returns UR or drops the posted write; it
never changes the decoded function to satisfy the hint.

## 5. Route metadata

A common route record is added to the VIP types and carried as non-random
runtime metadata on `pcie_tl_tlp`:

```text
valid           route has passed all checks
target_bdf      BDF derived from the address hit
target_func     Xilinx CQ target function, target_bdf[7:0]
bar_id          owner of a 64-bit BAR: 0, 2, or 4
bar_aperture     log2(BAR size in bytes) - 12
bar_offset       debug/validation offset within the selected function BAR
is_vf            PF/VF identity
pf_index         owning PF index
vf_index         -1 for a PF, otherwise the VF index
```

`do_copy`, printing, and initialization of `pcie_tl_tlp` include this record.
It is not serialized across the C bridge because it is generated by the VCS
configuration model immediately before the adapter sends the TLP.

The adapter uses route metadata only on `XILINX_CH_CQ`. Other channels retain
their current encoding. In config-driven mode, a CQ request without valid
route metadata is an error and is not encoded with zero-valued defaults.

`target_func` retains all eight low BDF bits. It is not formed from
`pf_index[2:0]`; in an ARI layout PF8 therefore has target function `8'h08` and
cannot alias PF0. The current real-DUT acceptance matrix remains one to four
PFs with sixteen VFs per PF on one bus, but the shared BDF arithmetic retains
the existing no-alias regression through PF15. Cross-bus support remains out
of scope.

## 6. Configuration state and invalidation

`pcie_tl_func_manager` owns a monotonically increasing
`config_generation`. A helper marks routing state dirty and increments the
generation after each effective change to:

- a PF BAR low or high DWORD;
- Command.Memory Space Enable;
- SR-IOV Control.VF Enable or VF MSE;
- SR-IOV NumVFs;
- a VF BAR low or high DWORD;
- runtime PF BDF binding, including derived VF BDFs.

BAR sizing writes of all ones do not replace the active BAR base and therefore
do not create a new routable range. The following real assignment write clears
sizing state, updates the canonical 64-bit owner, and advances the generation.

The configuration proxy must mirror Command.MSE/BME and SR-IOV VF MSE into the
function manager. A Command write updates both fields, but advances the route
generation only when MSE changes because BME does not gate inbound BAR
requests. The existing `bar_enable[]`, `bus_master_en`, `vf_enable`, and
`vf_mse` state becomes maintained state rather than unused declarations.

Runtime BDF binding is also a routing-state change. A successful rebind
advances `config_generation` exactly once after all PF/VF contexts and LUT keys
have been updated, so the next memory request cannot use a cache built for the
bootstrap BDFs.

The decoder records the generation used to build its cache. Before each
memory request, it rebuilds only when the manager generation has changed. A
rebuild is atomic from the request's perspective: a request is decoded
entirely against either the old or new snapshot.

## 7. Decode cache and algorithm

### 7.1 PF entries

Each implemented 64-bit PF BAR owner contributes one range, including its
current enabled state:

```text
[bar_base, bar_base + bar_size)
```

Only owners BAR0, BAR2, and BAR4 are emitted. The high DWORD descriptors
BAR1, BAR3, and BAR5 never appear as `bar_id`.

A PF range is routable only when the function is enabled and Command.MSE is
set. Disabled entries remain in the snapshot so an address hit can be reported
as disabled rather than indistinguishable from an unknown address.
Command.BME does not gate host-to-BAR requests; it controls only DMA initiated
by the endpoint.

### 7.2 VF aperture entries

Each implemented VF BAR owner contributes one aperture range rather than one
cache entry per VF. The entry retains VF Enable/VF MSE state even while it is
not routable:

```text
aperture_start = vf_bar_base
aperture_size  = vf_bar_size * NumVFs
vf_index       = (address - aperture_start) / vf_bar_size
bar_offset     = (address - aperture_start) % vf_bar_size
vf_bdf         = first_vf_offset + vf_index * vf_stride, relative to its PF
```

The range is routable only when VF Enable and VF MSE are set, `NumVFs` is
nonzero, and the computed VF index is less than `NumVFs`. The decoded BDF is
looked up in the function manager and must identify the same enabled VF.

Range construction checks that every BAR size is a power of two of at least
4 KiB and that `base + size` and `vf_size * NumVFs` do not overflow 64 bits.
An invalid configuration is fatal because its CQ aperture cannot be encoded
unambiguously. Overlap is checked among routable hits when a request arrives;
a disabled BAR at the same temporary base does not create a false fatal during
firmware enumeration.

### 7.3 Request coverage

The decoder computes the effective first and last accessed byte using the TLP
address, length, first BE, and last BE. All enabled bytes must remain within
one function BAR. An all-zero or otherwise malformed BE layout is rejected.

The address selects the route. QEMU `target_bdf` is checked only after the
independent address decode; it never chooses the BAR or function. A mismatch
means QEMU and the VIP configuration model disagree and the request is not
sent to the DUT.

The VCS ingress path additionally requires QEMU-originated memory traffic to
carry `requester_id=16'h0000`, copies that value explicitly into the VIP TLP,
and rejects an inconsistent requester before tag-map allocation. This check is
directional: it does not apply to DUT-originated DMA, whose requester is a
PF/VF BDF.

Decode runs before the RC driver creates a QEMU-to-VIP tag-map entry. A failed
MRd is completed directly with the original QEMU tag; therefore it cannot
leave a stale map entry or later produce `completion with no qemu tag`.

The Xilinx CQ address field remains the complete PCIe system address.
`bar_offset` is retained for diagnostics and assertions only.

## 8. DPU profile values

The existing `DPU_20F9_501X` profile supplies these implemented BAR owners:

| Function | BAR | Size | CQ aperture |
|---|---:|---:|---:|
| PF | 0 | 32 MiB | 13 |
| PF | 2 | 64 KiB | 4 |
| PF | 4 | 64 KiB | 4 |
| VF | 0 | 16 KiB | 2 |
| VF | 2 | 16 KiB | 2 |
| VF | 4 | 32 KiB | 3 |

For the mailbox request at `PF0 BAR2 + 0x2c`, the required route is:

```text
bar_id       = 2
bar_aperture = 4
target_func  = 0
bar_offset   = 0x2c
```

PF1 through PF3 use their decoded BDF low byte as `target_func`; they must not
fall back to PF0.

## 9. Error behavior

The decoder returns a typed result: success, disabled range, no match,
cross-boundary/malformed request, BDF mismatch, or overlapping match. The RC
driver applies the following policy:

| Condition | MRd | Posted MWr |
|---|---|---|
| MSE/VF state disabled | UR Completion | Drop and rate-limited error |
| No BAR hit | UR Completion | Drop and rate-limited error |
| Crosses BAR boundary or malformed BE | UR Completion | Drop and rate-limited error |
| QEMU BDF differs from decoded BDF | UR Completion | Drop and rate-limited error |
| More than one BAR hit | `UVM_FATAL` | `UVM_FATAL` |

Overlapping BARs are fatal because continuing could write a real DUT through
the wrong function or BAR.

`cpl_entry_t.status` carries the PCIe Completion status. A status-aware scalar
Completion DPI entry point is added while the current scalar function remains
as an SC-compatible wrapper. The bridge uses the PCIe encodings SC=0, UR=1,
CRS=2, and CA=4. A rejected MRd returns a zero-payload UR. QEMU checks status
before consuming payload; any non-SC result is returned to the guest as all
ones. Transport timeout and transport failure retain their current all-ones
behavior.

To prevent a polling driver from flooding logs, each nonfatal decode reason is
counted per RC and logged for its first eight occurrences and every 1024th
occurrence thereafter. The final UVM report prints all counters. Overlap and
invalid-cache failures are always fatal and are never rate limited.

## 10. Configuration and compatibility

Config-driven decode is selected automatically when `+REAL_DUT` is present or
when a non-legacy configuration profile such as
`+CFG_PROFILE=DPU_20F9_501X` is selected. It adds no BAR-base plusargs.

The intended real-DUT command line remains:

```text
+REAL_DUT +BYPASS_CONFIG=1 +CFG_PROFILE=DPU_20F9_501X
+NUM_PFS=1..4 +MAX_VFS=16 +NUM_VFS=0 +TAG_BIT=8|10 +TOPO=0
```

`NUM_VFS=0` means no VF is pre-enabled at simulation start. Each PF still
advertises sixteen VFs; the guest can program NumVFs and VF Enable later.

Compatibility rules are:

- LEGACY profile without `+REAL_DUT` keeps the present zero-sideband/stand-in
  behavior.
- The stand-in VF doorbell interception remains before CQ routing and is not
  changed.
- Config-driven mode never falls back to PF0/BAR0 after a decode failure.
- `+BYPASS_CONFIG=1` continues to answer CfgRd/CfgWr entirely in the VIP. Its
  writes update the same state consumed by the BAR decoder.
- Configuration bypass does not alter PCIe header roles: QEMU CfgRd/CfgWr use
  requester `0000` and the runtime PF/VF BDF as the target.
- `TAG_BIT`, DMA, ATS, MSI-X, MPS/RCB, and first/last-BE behavior are not
  reinterpreted by the decoder.

## 11. Verification

### 11.1 Focused VIP tests

Focused tests exercise:

- PF0 BAR0/BAR2/BAR4 routing and exact DPU aperture encodings;
- PF1 through PF3 function separation;
- QEMU host-request field separation for PF and VF targets, access-time PF BDF
  sampling, and rejection of a nonzero host requester;
- PF8 maps to full devfn/ARI function `8'h08` and never aliases PF0, while the
  real-DUT topology exercised here remains limited to PF0-PF3;
- first and last valid bytes of every BAR;
- an access ending exactly at the range end;
- an access crossing the end by one enabled byte;
- Command.MSE disable and re-enable;
- BAR low/high programming, all-ones sizing, and cache rebuild generation;
- SR-IOV NumVFs, VF Enable, VF MSE, and disable transitions;
- all sixteen VFs for each of four PFs, including first and last VF in each
  aperture;
- wrong target BDF, no hit, malformed BE, and overlap fatal paths;
- route metadata copy and Xilinx CQ descriptor encode/decode round trips.

### 11.2 VCS integration on 10.11.10.53

All simulation validation runs in a bash login shell on `10.11.10.53` so the
VCS and license environment from `~/.bashrc` is active. The integration
matrix is:

1. LEGACY single-PF stand-in smoke test.
2. DPU single-PF, no-VF boot and enumeration.
3. DPU four-PF boot, confirming `01:00.0` through `01:00.3`.
4. Boot with `NUM_VFS=0`, then enable sixteen VFs on each PF and verify the
   computed BDF and BAR route for every VF.
5. Reproduce PF0 `BAR2+0x2c` write-one/read polling and assert
   `bar_id=2`, `bar_aperture=4`, `target_func=0`, and `bar_offset=0x2c`.
6. Repeat the mailbox access through PF1, PF2, and PF3 and prove no request is
   mislabeled as PF0.
7. Trace a PF and a VF request across QEMU, the bridge, the decoder, and CQ;
   require requester `0000`, matching runtime target BDF, and independently
   decoded function/BAR metadata at every boundary.
8. Exercise runtime BAR reassignment and MSE/VF state changes without
   restarting simulation.
9. Re-run 8-bit and 10-bit tag tests, QEMU-to-VCS and VCS-to-QEMU random DMA,
   odd lengths, the complete first/last-BE matrix, long packets at MPS
   boundaries, and RCB split coverage.

The implementation is accepted when the focused tests pass, the mailbox
waveform carries the expected CQ sideband, four PFs plus enabled VFs route
without aliases, and the existing LEGACY/data-plane regressions remain green.

## 12. Expected implementation surface

Existing package compilation order determines where the new shared type and
decoder are included. The design limits changes to these responsibilities:

- `pcie_tl_vip/src/types/pcie_tl_types.sv`: route result and metadata types.
- `pcie_tl_vip/src/types/pcie_tl_tlp.sv`: runtime CQ route metadata handling.
- `pcie_tl_vip/src/shared/pcie_tl_bar_decoder.sv`: shared cache and decode
  algorithm.
- `pcie_tl_vip/src/shared/pcie_tl_func_manager.sv`: generation and maintained
  command/BAR/function state.
- `pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv`: update all route-affecting
  state after bypassed configuration writes.
- `vcs-tb/cosim_xrc_driver.sv`: invoke decode, enforce error policy, and attach
  metadata before sending CQ traffic.
- `third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv`: encode CQ
  from validated metadata.
- `bridge/vcs/bridge_vcs.sv`, `bridge/vcs/bridge_vcs.c`, and bridge headers:
  status-aware scalar Completion with compatibility wrapper.
- `qemu-plugin/cosim_pcie_request.h`: pure host-request BDF/field helpers used
  by all QEMU-originated request constructors.
- `qemu-plugin/cosim_pcie_rc.c`: sample live PF BDFs, route host requests with
  distinct requester/target fields, and honor non-success Completion status.
- Focused VIP tests and existing VCS regression scripts: assertions and
  integration coverage described above.
