# Target-Native Table Sideband Port Design

**Date:** 2026-08-18
**Target:** `origin/feature/qemu-vcs-isolated-tcp@bca79aaa6a54ecb881bb0fdff73245216492bc93`
**Source feature checkpoint:** `feature/table-backdoor-sideband@38858e202c59986b850b9ae76b4c3571052b9445`

## Goal

Port the optional semantic table backdoor onto the current
`feature/qemu-vcs-isolated-tcp` architecture without restoring files or device
models that the target branch intentionally removed.  The resulting QEMU,
CoSim library, Guest module, and SystemVerilog packages are built once.  Runtime
arguments select frontdoor or table-backdoor behavior.

The default-off path must retain the target branch's current dynamic PF/VF/BAR
model, Makefile launch commands, VCS integration-kit contract, and Guest MMIO
behavior.

## Non-goals

- Do not merge the old branch and resolve conflicts by choosing `ours`.
- Do not restore `cosim.sh`, `cosim_pcie_pf.[ch]`,
  `scripts/build_cosim_multirc.sh`, `scripts/launch_dual.py`,
  `scripts/run_cosim.sh`, `scripts/setup_cosim_qemu.sh`,
  `vcs-tb/cosim_xrc_test.sv`, or `vcs-tb/tb_cosim_multirc_top.sv`.
- Do not add a repository-owned production DUT top or hard-code a DUT RAM
  hierarchy.  The user compiles the production handler into their existing
  testbench.
- Do not infer or hard-code Guest-assigned BAR base addresses.
- Do not add route hot reload.  One validated route generation is installed at
  startup.
- Do not enable table access for PF1 or any VF in this increment.

## Target baseline

Before any source modification, the target checkpoint was synchronized to the
VCS host with Git metadata and tested through a Bash login shell.  The complete
CTest baseline passed 45/45 tests in 179.78 seconds.  This baseline, rather
than the older table feature branch, is the regression authority.

## Architecture

The feature uses a separate semantic sideband and never extends the existing
TLP wire ABI:

```text
Guest table-aware driver
  complete entry or packed batch
        |
        | coherent DMA slot + doorbell
        v
QEMU cosim-table-ctrl (one per QEMU/RC, TCP server)
        |
        | versioned table protocol, port TABLE_PORT_BASE + instance_id
        v
VCS table client and request assembler
        |
        | validated route, entry slicing, explicit RC/target identity
        v
SV cosim_table_runtime -> registered handler for that RC
        |
        | raw entry + protection selection + logical index
        v
User production handler -> DUT-specific deposit/read task
        |
        +---- SUCCESS / status + committed + failed_index ---->
```

Ordinary config, MMIO, DMA, MSI, topology, and VF lifecycle traffic remains on
the target branch's existing `cosim-pcie-rc` transport.

### Default-off invariant

The table code is compiled into artifacts but remains dormant unless both
sides opt in.  With `TABLE_BACKDOOR=off` and without
`+COSIM_TABLE_ENABLE=1`:

- the Makefile emits the exact existing `cosim-pcie-rc` QEMU command;
- QEMU does not realize `cosim-table-ctrl` or bind a table port;
- the Guest command line does not contain `dpu_snd1.table_backdoor=1`;
- `cosim_maybe_enable()` retains its existing no-`+COSIM` early return;
- no table route, worker, handler, DPI function, or transport is invoked; and
- the original driver, sequencer, config bypass, MMIO, DMA, MSI, PF/VF, and
  real-DUT paths remain authoritative.

## Components

### 1. Protocol, route map, and table transport

The fixed-width protocol and control UAPI are ported as isolated headers under
`bridge/table/`.  The route parser, standalone TCP transport, QEMU
controller/core, and VCS request assembler remain separate from
`cosim_transport_t` and `cosim_shm_t`.

Writes carry a complete entry or a contiguous packed batch.  Transport frames
fragment payloads larger than 64 KiB and reassemble them before exposing a
request to SV.  Route geometry, not Guest-provided geometry, is authoritative
for slicing:

```text
entry_count = payload_bytes / entry_bytes
first_index = index_base + (bar_offset - start) / stride_bytes
entry N     = payload[N * entry_bytes +: entry_bytes]
```

Every route section contains:

```ini
[route.<name>]
rc=<number>
device=<number>
target=pf0
bar=0|1
start=<inclusive offset>
end=<exclusive offset>
entry_bytes=<positive bytes>
stride_bytes=<bytes, at least entry_bytes>
index_base=<logical first index>
handler=<case-sensitive handler name>
operations=write|write,read
```

`operations` is optional.  Omission means `write`, as does the explicit value
`operations=write`.  Only `operations=write,read` publishes read capability.
Unknown tokens, duplicates, empty values, reversed order, or any other
combination are rejected.  Existing route fixtures are updated to state read
capability only where their handler implements it.

Routes are validated as one atomic generation.  Invalid ranges, overlap,
stride holes addressed as data, index overflow, missing handlers, or capability
mismatch prevent the complete generation from being published.

### 2. QEMU integration with `cosim-pcie-rc`

`cosim-table-ctrl` remains a distinct QOM PCI endpoint.  The QEMU binary always
contains its type, while the Makefile adds the device only when
`TABLE_BACKDOOR=on`.  The controller is placed at
`bus=pcie.0,addr=0x6`; it is not a function of the DUT PF and does not consume
a DUT BAR.

The target branch's `CosimPCIeRC` remains the sole model for live PF/VF and BAR
topology.  A small table-target adapter exposes a read-only PF0 snapshot to the
controller:

- RC identity is the QEMU `instance_id`;
- device identity is zero in this increment;
- target type is PF, `pf_index=0`, and `vf_index=0`;
- domain and BDF come from the live QEMU PCI object;
- BAR index and aperture come from `CosimBarContext`; and
- generation changes whenever the live PF0 target is replaced, reset, or
  removed.

No table code duplicates PF/VF discovery or maintains a second BAR topology.

Table TCP follows the target branch's normal connection direction: QEMU is the
server and VCS is the client.  QEMU listens on
`table_port_base + instance_id`, so VCS reuses its existing `+REMOTE_HOST`
value and needs no second remote-host option.

Matched table reads are intercepted at the beginning of the target branch's
PF BAR read callback, before `cosim_mmio_do_read()`.  Only PF0, BAR0/BAR1,
1/2/4-byte CPU reads, a live controller, and a route containing read capability
are eligible.  VCS returns one aligned DWORD and QEMU extracts the requested
bytes.  An 8-byte read, PF1/VF access, route miss, write-only route, or
unsupported read continues through the exact existing frontdoor path.

The existing QEMU BAR write callback is not changed to aggregate or intercept
writes.  Semantic writes enter only through the Guest's complete-buffer API.

### 3. VCS C/DPI integration

Table C sources are added to CMake and to the target branch's retained
`scripts/build_cosim_lib.sh` source closure.  The existing bridge symbols and
message routing remain intact.  Table DPI functions use a separate per-RC
state array and separate TCP socket.

For each enabled RC, VCS connects to QEMU at
`TABLE_PORT_BASE + instance_id`, validates and publishes the full route
generation, reassembles one request at a time, and requires exactly one
completion for every accepted request.  Cleanup interrupts blocking receive
operations before joining workers.

### 4. SystemVerilog integration-kit contract

The target branch remains a kit for a user-owned top and test.  It does not
regain a repository-owned multi-RC top.  `cosim_table_pkg` supplies:

- request context and result types;
- handler and codec base classes;
- handler registry;
- per-RC table service;
- per-RC runtime/registration facade; and
- common none, even parity, odd parity, and SECDED codecs.

The retained `cosim_xrc_pkg.sv` makes the table package available alongside
the existing `cosim_maybe_enable()` API.  The user registers concrete handler
objects in their test `build_phase`, before the environment creates the RC
drivers:

```systemverilog
cosim_xrc_pkg::cosim_maybe_enable();
handler[0] = new();
if (!cosim_table_runtime::register_handler(
        0, handler[0], COSIM_TABLE_PROTECTION_NONE))
  `uvm_fatal("TABLE", "RC0 table handler registration failed")
```

Registration is explicitly per RC.  A handler's `get_name()` is the route key,
so the caller cannot register one object under a conflicting string.  The
runtime starts a service only when `+COSIM_TABLE_ENABLE=1` is present.  If that
plusarg is present without `+COSIM`, `cosim_maybe_enable()` reports a fatal
configuration error before any table connection or worker is started.  Driver
startup notifies the runtime after the existing bridge and live topology are
ready; driver shutdown stops and joins the corresponding service before bridge
cleanup.

A write-only route does not require `supports_read()`.  A route with
`operations=write,read` activates only when its handler returns true from
`supports_read()` and implements `read_dword()`.

### 5. Protection and DUT-specific deposits

Protection is selected per handler.  The registration call provides a compiled
default, and a runtime plusarg may override it:

```text
+COSIM_TABLE_PROTECT_<handler>=none
+COSIM_TABLE_PROTECT_<handler>=parity_even
+COSIM_TABLE_PROTECT_<handler>=parity_odd
+COSIM_TABLE_PROTECT_<handler>=ecc
+COSIM_TABLE_PROTECT_<handler>=secded
+COSIM_TABLE_PROTECT_<handler>=custom
```

`none` preserves the raw bytes and produces no protection bits.  Parity is
group-wise and LSB-first.  `ecc` and `secded` select the common SECDED codec.
`custom` dispatches to a user-provided codec implementation.  The option does
not enable the backdoor, change routes, or select read versus write.

The production handler owns physical packing and DUT hierarchy.  The retained
multi-RAM reference demonstrates index-dependent L3/L2/L1 bank and physical
index selection.  A user subclass overrides only the backend deposit/read task
to call the DUT's macros or simulator backdoor API.  Entry width and depth are
route data, not compiled constants.

### 6. Guest driver overlay

The table controller remains an overlay for a supplied `host-driver-net` tree
and builds into `dpu_snd1.ko`; it is not a second Guest module.  The apply
script is transactional, validates its patch series before mutation, and is an
idempotent no-op when already current.

The module parameter defaults to false.  With it disabled, table wrappers
return the original frontdoor decision before controller lookup, DMA slot
claim, or MMIO.  With it enabled, the QID insertion and remove/compaction paths
that own the full table call the packed batch API.  Other complete-buffer call
sites may use the same API; single-command call sites retain the single-entry
API or their original ordered writes.

The driver supports PF0 BAR0/BAR1.  PF1 and all VFs are rejected before lookup
and retain the original path.  The controller BAR supplies RC/device identity
and live generation; PCI enumeration supplies target BDF and all BAR bases.

## Runtime interface

### QEMU

The target Makefile gains dormant defaults:

```make
TABLE_BACKDOOR ?= off
TABLE_PORT_BASE ?= 10100
```

Enabled launch:

```bash
TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 make run-qemu
```

For QEMU instance `r`, the controller listens at
`TABLE_PORT_BASE + r`.  The enabled command adds one controller and appends
`dpu_snd1.table_backdoor=1` to the Guest command line.  Disabled command text
must remain equivalent to the target baseline.  The connection descriptor may
contain table fields only in enabled mode.

The route map is not a QEMU input because QEMU receives the validated route
generation from VCS.

### VCS

The user compiles the CoSim packages and their production handler once, then
selects behavior at simulation runtime:

```bash
./simv \
  +COSIM \
  +REMOTE_HOST=<QEMU host> \
  +PORT_BASE=9100 \
  +COSIM_TABLE_ENABLE=1 \
  +COSIM_TABLE_MAP=/absolute/path/routes.ini \
  +TABLE_PORT_BASE=10100 \
  +COSIM_TABLE_LOG=high \
  +COSIM_TABLE_PROTECT_vio_notify=none
```

`+COSIM_TABLE_MAP` must be an absolute readable file on the VCS host.  HIGH
logging prints request identity, raw entry bytes, protection choice, handler
result, committed count, failed index, completion, and bounded payload dumps.

### Guest

If kmod consumes the kernel command line, `dpu_snd1.table_backdoor=1` enables
the compiled module option.  A direct load uses:

```bash
insmod dpu_snd1.ko table_backdoor=1
```

Omitting the option preserves the original driver behavior.

## Completion and fallback policy

Only statuses that prove no remote entry was committed may replay through the
frontdoor:

| Status | Guest action |
|---|---|
| `SUCCESS` | skip original BAR writes/readback loop |
| `NOT_READY` | original frontdoor path |
| `NO_ROUTE` | original frontdoor path |
| `UNSUPPORTED` | original frontdoor path |
| local `SLOT_BUSY` | original frontdoor path |
| `EXEC_ERROR` | hard error; report `committed` and `failed_index`; no replay |
| `TIMEOUT` | hard error; no replay |
| `TARGET_GONE` | hard error; no replay |
| `PROTOCOL` or `UNKNOWN` | hard error; no replay |

Route parse, route overlap, missing handler, or read-capability mismatch keeps
the complete endpoint not-ready.  A target-generation mismatch is checked
again at doorbell execution and returns `TARGET_GONE`.

## Testing strategy

All behavior changes follow test-first red/green cycles.  Generated QEMU,
kernel, VCS, logs, and build products remain untracked.

### Core and route tests

- fixed ABI sizes, byte order, malformed and fragmented frames;
- route default operation is write;
- explicit `write` and `write,read` parsing;
- rejection of unknown, duplicate, empty, and reversed operation tokens;
- multi-table range, overlap, stride, boundary, and index-overflow cases;
- packed batches across 128/256/1024-bit example entry widths;
- TCP server/client direction used by target integration;
- exact completion ownership, timeout, and cleanup.

### Default-off tests

- compare target-baseline and post-port Makefile QEMU commands;
- assert no table device, table port, Guest module parameter, table plusarg, or
  connection-descriptor field appears while off;
- run the complete target CTest suite;
- compile and run retained target VCS source tests without table plusargs; and
- verify the original PF/VF/BAR and request-routing source contracts.

### QEMU tests

- QEMU-independent target snapshot and read-decode tests for PF0 BAR0/BAR1;
- PF1, VF, route miss, write-only route, 8-byte read, and inactive controller
  continue through the existing read path;
- injection/setup closure includes table sources idempotently;
- build QEMU 9.2 on host 53;
- verify both `cosim-pcie-rc,help` and `cosim-table-ctrl,help`; and
- verify the enabled command places `cosim-table-ctrl` at
  `bus=pcie.0,addr=0x6`; and
- verify enabled Makefile commands allocate distinct bridge and table ports for
  every QEMU instance.

### VCS tests on host 53

- standalone registry, codec, service, lifecycle, and multi-RAM tests;
- minimal-integration harness using the retained `cosim_xrc_pkg` contract;
- `+COSIM_TABLE_ENABLE=1` without `+COSIM` fails before any table connection or
  worker starts;
- write-only route activation with a handler that has no read callback;
- explicit read route activation and 4-byte returned data;
- raw/protected data, maximum index, bank/physical-index routing, and HIGH logs;
- one-RC success, safe fallback, partial execution error, and timeout mocks;
- two-RC route, handler, port, and value isolation; and
- full target PCIe TL/Xilinx filelist compilation without a repository-owned
  DUT top.

### Guest tests

- transactional overlay application, rollback, and idempotence;
- module build against the reference driver headers;
- `modinfo` includes `table_backdoor`;
- single-entry and packed-batch symbols remain present;
- disabled mode exits before controller access; and
- safe fallback versus no-replay status mapping.

## Completion criteria

The port is complete only when:

1. the target branch's complete CTest suite passes after the port;
2. default-off command and behavioral gates match the target baseline;
3. QEMU builds and both device help queries pass;
4. target VCS source tests and the table SV runners pass on host 53 with zero
   UVM errors or fatals;
5. the Guest overlay and module artifact build pass;
6. SUCCESS, safe fallback, partial EXEC_ERROR, TIMEOUT, and two-RC isolation
   are demonstrated by deterministic integration tests; and
7. an independent specification review and code-quality review find no open
   critical or important issue.

Real DUT hierarchy deposits require the user's production handler and matching
Guest image.  Mock results are never presented as real DUT semantic evidence.
