# CoSim Table Backdoor Sideband Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional semantic table-write sideband that transfers complete Guest driver buffers through a QEMU-only PCIe control endpoint to VCS/SV table handlers while preserving the existing frontdoor path.

**Architecture:** A new standalone table protocol and transport carries route discovery, complete write payloads, 4B reads, and explicit completions without changing existing TLP ABI. One QEMU-only control endpoint per RC DMA-reads Guest slots and submits requests; VCS routes by logical target and invokes registered SV handlers. The reference `dpu_snd1` driver is delivered as tracked overlay files plus a reproducible patch because its release directory on host 53 is not a Git repository.

**Tech Stack:** C11, CMake/CTest, POSIX TCP/SHM, QEMU 9.2 PCI/QOM APIs, Linux PCI driver APIs, SystemVerilog/UVM 1.2, VCS DPI-C, Bash, VCS simulation on `10.11.10.53`.

---

## Implementation boundaries

The approved specification is
`docs/superpowers/specs/2026-08-14-cosim-table-backdoor-sideband-design.md`.
This plan does not revive the old AIP dependency or the passive BAR DWORD aggregator.

Use an isolated worktree when execution starts. The current checkout contains unrelated user changes; never stage them. Every commit below must name only the files listed in that task.

### File map

| Path | Responsibility |
|---|---|
| `bridge/table/cosim_table_protocol.h` | Versioned wire types, target identity, route, request, completion |
| `bridge/table/cosim_table_ctrl_uapi.h` | Shared Guest/QEMU control BAR and DMA-slot ABI |
| `bridge/table/cosim_table_route.[ch]` | INI parser, full-map validation, address matching and slicing |
| `bridge/table/cosim_table_transport.[ch]` | Standalone table transport interface/factory |
| `bridge/table/cosim_table_transport_tcp.c` | One-socket length-framed TCP implementation |
| `bridge/table/cosim_table_transport_shm.c` | Separate `/cosim-table-*` SHM implementation |
| `bridge/qemu/table_client.[ch]` | QEMU route cache and synchronous write/read RPC |
| `bridge/qemu/table_ctrl_core.[ch]` | QEMU-independent descriptor validation and completion ownership |
| `bridge/vcs/table_vcs_core.[ch]` | Simulator-independent per-RC request assembly and route activation |
| `bridge/vcs/table_vcs_dpi.[ch]` | Thin `svOpenArrayHandle` wrapper used only by VCS |
| `qemu-plugin/cosim_table_ctrl.[ch]` | QEMU-only PCIe endpoint and coherent DMA doorbell |
| `qemu-plugin/cosim_pcie_pf.[ch]` | PF/VF identity plus matched 4B read interception |
| `vcs-tb/cosim_table_*.sv` | Types, codecs, handler base, registry and service |
| `vcs-tb/tests/cosim_table_unit_test.sv` | Standalone mock-handler SV tests |
| `guest/dpu-table-sideband/*` | Tracked Guest controller source and driver integration patch |
| `scripts/apply_dpu_table_sideband.sh` | Idempotent application to a supplied `host-driver-net` tree |
| `tests/unit/test_table_*.c` | Protocol, route, transport and controller-core tests |
| `tests/integration/test_table_roundtrip.c` | QEMU/VCS semantic request loopback |

## Fixed ABI decisions

Use these constants consistently in every task:

```c
#define COSIM_TABLE_MAGIC              UINT32_C(0x4c425443) /* "CTBL" LE */
#define COSIM_TABLE_PROTOCOL_VERSION   1u
#define COSIM_TABLE_CTRL_VENDOR_ID     0x1af4
#define COSIM_TABLE_CTRL_DEVICE_ID     0x10f0
#define COSIM_TABLE_CTRL_BAR_BYTES     0x1000u
#define COSIM_TABLE_HANDLER_NAME_BYTES 64u
#define COSIM_TABLE_FRAME_DATA_BYTES   (64u * 1024u)
#define COSIM_TABLE_DEFAULT_PORT_BASE  10100
```

The table TCP port is `table_port_base + instance_id`. It is independent of existing
`port_base + instance_id * 3` TLP ports. SHM uses `/cosim-table-${instance_id}` and never changes
`cosim_shm_t`.

Status values are stable wire ABI:

```c
typedef enum {
    COSIM_TABLE_ST_SUCCESS      = 0,
    COSIM_TABLE_ST_NOT_READY    = 1,
    COSIM_TABLE_ST_NO_ROUTE     = 2,
    COSIM_TABLE_ST_UNSUPPORTED  = 3,
    COSIM_TABLE_ST_SLOT_BUSY    = 4,
    COSIM_TABLE_ST_EXEC_ERROR   = 5,
    COSIM_TABLE_ST_TIMEOUT      = 6,
    COSIM_TABLE_ST_UNKNOWN      = 7,
    COSIM_TABLE_ST_TARGET_GONE  = 8,
    COSIM_TABLE_ST_PROTOCOL     = 9,
} cosim_table_status_t;
```

Only `NOT_READY`, `NO_ROUTE`, `UNSUPPORTED`, and local `SLOT_BUSY` are safe frontdoor fallbacks.

### Task 1: Define the table wire protocol and control UAPI

**Files:**
- Create: `bridge/table/cosim_table_protocol.h`
- Create: `bridge/table/cosim_table_ctrl_uapi.h`
- Create: `tests/unit/test_table_protocol.c`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write the failing ABI test**

Create `test_table_protocol.c` with compile-time size assertions and runtime enum checks:

```c
#include "cosim_table_protocol.h"
#include "cosim_table_ctrl_uapi.h"
#include <assert.h>

int main(void)
{
    assert(COSIM_TABLE_PROTOCOL_VERSION == 1);
    assert(COSIM_TABLE_ST_NO_ROUTE == 2);
    assert(sizeof(cosim_table_frame_hdr_t) == 24);
    assert(sizeof(cosim_table_target_t) == 24);
    assert(sizeof(cosim_table_completion_t) == 32);
    assert(COSIM_TABLE_REG_DOORBELL == 0x20);
    assert(sizeof(cosim_table_slot_hdr_t) == 128);
    return 0;
}
```

Register `test_table_protocol` in `tests/unit/CMakeLists.txt`.

- [ ] **Step 2: Run the test to verify RED**

Run:

```bash
cmake -S . -B build/table-sideband -DCMAKE_BUILD_TYPE=Debug
cmake --build build/table-sideband --target test_table_protocol
```

Expected: compilation fails because `cosim_table_protocol.h` does not exist.

- [ ] **Step 3: Add the complete fixed-width ABI**

Define a 24-byte frame header with `magic/version/type/header_bytes/payload_bytes/transaction_id`;
define message types `HELLO`, `CAPABILITY`, `ROUTE_BEGIN`, `ROUTE_ENTRY`, `ROUTE_END`,
`WRITE_BEGIN`, `WRITE_DATA`, `WRITE_END`, `READ_DWORD`, `COMPLETION`, and `SHUTDOWN`.

Use this exact target contract:

```c
typedef struct {
    uint16_t rc_id;
    uint16_t device_instance;
    uint16_t pci_domain;
    uint16_t target_bdf;
    uint8_t  target_type;  /* 0=PF, 1=VF */
    uint8_t  pf_index;
    uint16_t vf_index;
    uint8_t  bar_index;
    uint8_t  _reserved0[3];
    uint32_t generation;
    uint32_t _reserved1;
} __attribute__((packed)) cosim_table_target_t;
```

Define route entries with `route_id`, target selector, operation mask, inclusive `start`, exclusive
`end`, `entry_bytes`, `stride_bytes`, `index_base`, and a 64-byte handler name. Define write/read
request metadata and the 32-byte completion containing status, failed index, committed count, handler
error and returned DWORD.

Define the control BAR register offsets exactly:

```c
enum {
    COSIM_TABLE_REG_MAGIC        = 0x00,
    COSIM_TABLE_REG_VERSION      = 0x04,
    COSIM_TABLE_REG_CAPS         = 0x08,
    COSIM_TABLE_REG_READY        = 0x0c,
    COSIM_TABLE_REG_DMA_ADDR_LO  = 0x10,
    COSIM_TABLE_REG_DMA_ADDR_HI  = 0x14,
    COSIM_TABLE_REG_DMA_BYTES    = 0x18,
    COSIM_TABLE_REG_SLOT_COUNT   = 0x1c,
    COSIM_TABLE_REG_DOORBELL     = 0x20,
    COSIM_TABLE_REG_LAST_ERROR   = 0x24,
};
```

Make `cosim_table_slot_hdr_t` exactly 128 bytes. It contains an atomic state, header version,
transaction ID, target, BAR offset, payload length/offset, result fields, and reserved bytes. Add
`_Static_assert` for every public structure. Both headers must compile in Linux kernel and userspace:
under `__KERNEL__` map private `cosim_u8/u16/u32/u64` aliases to `u8/u16/u32/u64`; otherwise map them
to `uint8_t/uint16_t/uint32_t/uint64_t`. Use a `COSIM_STATIC_ASSERT` macro that maps to the kernel
`static_assert` or C11 `_Static_assert`.

- [ ] **Step 4: Run GREEN and the existing ABI tests**

Run:

```bash
cmake --build build/table-sideband --target test_table_protocol test_transport_tcp
ctest --test-dir build/table-sideband -R 'test_table_protocol|test_transport_tcp' --output-on-failure
```

Expected: both tests pass; existing `tlp_entry_t` size assertions remain unchanged.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_protocol.h bridge/table/cosim_table_ctrl_uapi.h \
        tests/unit/test_table_protocol.c tests/unit/CMakeLists.txt
git commit -m "feat(table): define semantic sideband ABI"
```

### Task 2: Implement route parsing, validation and slicing

**Files:**
- Create: `bridge/table/cosim_table_route.h`
- Create: `bridge/table/cosim_table_route.c`
- Create: `tests/unit/test_table_route.c`
- Create: `tests/fixtures/table_routes_valid.ini`
- Create: `tests/fixtures/table_routes_overlap.ini`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write route parser and matcher tests**

The valid fixture must contain two routes, including a stride hole:

```ini
[route.qid_map]
rc=0
device=0
target=pf0
bar=0
start=0x1000
end=0x2000
entry_bytes=16
stride_bytes=16
index_base=0
handler=qid_map

[route.wide_table]
rc=0
device=0
target=pf0
bar=1
start=0x4000
end=0x6000
entry_bytes=32
stride_bytes=64
index_base=8
handler=wide_table
```

Test successful parsing, handler strings, overlap rejection, unaligned write rejection, a 48-byte
QID batch mapping to indices 2/3/4, and a `stride_bytes=64` batch whose packed entries map to indices
8/9 without payload holes.

- [ ] **Step 2: Verify RED**

Run:

```bash
cmake --build build/table-sideband --target test_table_route
```

Expected: build fails because `cosim_table_route_load()` is undefined.

- [ ] **Step 3: Implement the parser and validation API**

Expose this exact API:

```c
typedef struct {
    cosim_table_route_entry_t *entries;
    size_t count;
    uint64_t generation_hash;
} cosim_table_route_map_t;

int cosim_table_route_load(const char *path, cosim_table_route_map_t *map,
                           char *error, size_t error_bytes);
void cosim_table_route_free(cosim_table_route_map_t *map);
const cosim_table_route_entry_t *cosim_table_route_match(
    const cosim_table_route_map_t *map, const cosim_table_target_t *target,
    uint64_t bar_offset, uint8_t operation);
int cosim_table_route_slice(const cosim_table_route_entry_t *route,
                            uint64_t bar_offset, uint32_t byte_len,
                            uint64_t *first_index, uint32_t *entry_count);
```

Parse line-by-line without adding an external INI library. Trim whitespace, reject duplicate keys and
unknown keys, parse integers with `strtoull(..., 0)`, and reject trailing characters. Sort a copy by
`rc/device/target/pf/vf/bar/start` to detect overlap. Hash the validated fixed-width entries with FNV-1a
64 so QEMU can log the route generation.

- [ ] **Step 4: Run GREEN**

```bash
cmake --build build/table-sideband --target test_table_route
ctest --test-dir build/table-sideband -R test_table_route --output-on-failure
```

Expected: valid and stride tests pass; overlap fixture reports both conflicting route names.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_route.c bridge/table/cosim_table_route.h bridge/CMakeLists.txt \
        tests/unit/test_table_route.c tests/unit/CMakeLists.txt tests/fixtures/table_routes_*.ini
git commit -m "feat(table): parse and validate table routes"
```

### Task 3: Add the standalone TCP table transport

**Files:**
- Create: `bridge/table/cosim_table_transport.h`
- Create: `bridge/table/cosim_table_transport.c`
- Create: `bridge/table/cosim_table_transport_tcp.c`
- Create: `tests/unit/test_table_transport_tcp.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write a failing fragmented-frame loopback test**

Fork a server and client on `127.0.0.1:20100`. Send HELLO, two ROUTE_ENTRY frames, a 150000-byte
write split into 65536/65536/18928-byte `WRITE_DATA` frames, then a completion. Assert transaction ID,
fragment offsets, byte-exact payload and timeout return `1`.

- [ ] **Step 2: Verify RED**

```bash
cmake --build build/table-sideband --target test_table_transport_tcp
```

Expected: undefined `cosim_table_transport_create()`.

- [ ] **Step 3: Implement the transport interface and TCP backend**

Use this interface:

```c
typedef struct cosim_table_transport cosim_table_transport_t;
typedef struct {
    const char *kind;          /* tcp or shm */
    const char *remote_host;
    const char *listen_addr;
    const char *shm_name;
    int table_port_base;
    int instance_id;
    int is_server;
} cosim_table_transport_cfg_t;

int cosim_table_send(cosim_table_transport_t *, const cosim_table_frame_hdr_t *,
                     const void *header, const void *payload);
int cosim_table_recv(cosim_table_transport_t *, cosim_table_frame_hdr_t *,
                     void *header, size_t header_cap, void *payload, size_t payload_cap,
                     int timeout_ms);
cosim_table_transport_t *cosim_table_transport_create(
    const cosim_table_transport_cfg_t *cfg);
void cosim_table_transport_close(cosim_table_transport_t *);
```

TCP uses one socket, `TCP_NODELAY`, an explicit handshake containing magic/version/RC, exact-length
send/recv loops, `poll()` timeout, and rejects frame lengths above the supplied capacities before
reading payload. Do not edit `transport_tcp.c` or `cosim_transport_t`.

- [ ] **Step 4: Run GREEN and normal TCP regression**

```bash
cmake --build build/table-sideband --target test_table_transport_tcp test_transport_tcp
ctest --test-dir build/table-sideband -R 'test_table_transport_tcp|test_transport_tcp' --output-on-failure
```

Expected: both table and existing TCP tests pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_transport.h bridge/table/cosim_table_transport.c \
        bridge/table/cosim_table_transport_tcp.c bridge/CMakeLists.txt \
        tests/unit/test_table_transport_tcp.c tests/unit/CMakeLists.txt
git commit -m "feat(table): add independent TCP transport"
```

### Task 4: Add the standalone SHM table transport

**Files:**
- Create: `bridge/table/cosim_table_transport_shm.c`
- Create: `tests/unit/test_table_transport_shm.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write a failing two-process SHM test**

Use a unique name containing `getpid()`. Parent creates, child opens, child sends a 1024-byte write,
parent verifies it and returns SUCCESS. Close and unlink only the exact generated object.

- [ ] **Step 2: Verify RED**

```bash
cmake --build build/table-sideband --target test_table_transport_shm
```

Expected: factory reports unsupported kind `shm`.

- [ ] **Step 3: Implement separate SHM queues**

Create one SHM object containing magic/version, ready flags, and two fixed-frame rings. Reuse
`ring_buffer.c` but give each ring `COSIM_TABLE_FRAME_DATA_BYTES + header` element capacity. Use
release/acquire atomics around enqueue/dequeue, 1ms bounded polling for timed receive, and unlink only
on creator close. Never add fields to `cosim_shm_t`.

- [ ] **Step 4: Run GREEN and existing SHM regression**

```bash
cmake --build build/table-sideband --target test_table_transport_shm test_shm_layout
ctest --test-dir build/table-sideband -R 'test_table_transport_shm|test_shm_layout' --output-on-failure
```

Expected: both pass and `test_shm_layout` reports unchanged offsets.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_transport_shm.c bridge/CMakeLists.txt \
        tests/unit/test_table_transport_shm.c tests/unit/CMakeLists.txt
git commit -m "feat(table): add isolated SHM transport"
```

### Task 5: Build the QEMU-side route client and descriptor core

**Files:**
- Create: `bridge/qemu/table_client.h`
- Create: `bridge/qemu/table_client.c`
- Create: `bridge/qemu/table_ctrl_core.h`
- Create: `bridge/qemu/table_ctrl_core.c`
- Create: `tests/unit/test_table_ctrl_core.c`
- Create: `tests/integration/test_table_roundtrip.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write RED tests for ownership and fallback boundaries**

The core test injects callbacks for DMA read/write and table RPC. Cover READY false, invalid slot,
NO_ROUTE, 3-entry SUCCESS, EXEC_ERROR after one commit, TIMEOUT, bad target generation and payload
bounds. Assert only safe statuses set `may_frontdoor=1`.

The integration test starts a mock VCS client, sends two routes, submits a 48-byte write, verifies
index slicing, returns SUCCESS, then services one 4B read.

- [ ] **Step 2: Verify RED**

```bash
cmake --build build/table-sideband --target test_table_ctrl_core test_table_roundtrip
```

Expected: undefined table client/core symbols.

- [ ] **Step 3: Implement exact client APIs**

```c
cosim_table_client_t *cosim_table_client_create(
    const cosim_table_transport_cfg_t *cfg, uint16_t rc_id);
int cosim_table_client_wait_routes(cosim_table_client_t *, int timeout_ms);
const cosim_table_route_entry_t *cosim_table_client_match(
    cosim_table_client_t *, const cosim_table_target_t *, uint64_t offset, uint8_t op);
cosim_table_status_t cosim_table_client_write(
    cosim_table_client_t *, const cosim_table_write_req_t *, const uint8_t *,
    cosim_table_completion_t *, int timeout_ms);
cosim_table_status_t cosim_table_client_read_dword(
    cosim_table_client_t *, const cosim_table_read_req_t *,
    cosim_table_completion_t *, int timeout_ms);
```

Install route generations only after complete ROUTE_BEGIN/ENTRY/END validation. Serialize requests per
client with a pthread mutex. Fragment writes at 64KiB. Treat transport errors and timeout as UNKNOWN;
never translate them to NO_ROUTE. Maintain per-client route-hit, route-miss, write, read, timeout,
fallback-eligible and byte counters, with a read-only snapshot API for QEMU logs.

`table_ctrl_core` validates the slot header and target before copying payload, invokes the client, writes
completion fields back through callbacks, and exposes `cosim_table_status_may_frontdoor()`.

- [ ] **Step 4: Run GREEN**

```bash
cmake --build build/table-sideband --target test_table_ctrl_core test_table_roundtrip
ctest --test-dir build/table-sideband -R 'test_table_ctrl_core|test_table_roundtrip' --output-on-failure
```

Expected: all status and fragmented roundtrip cases pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/qemu/table_client.c bridge/qemu/table_client.h \
        bridge/qemu/table_ctrl_core.c bridge/qemu/table_ctrl_core.h bridge/CMakeLists.txt \
        tests/unit/test_table_ctrl_core.c tests/unit/CMakeLists.txt \
        tests/integration/test_table_roundtrip.c tests/integration/CMakeLists.txt
git commit -m "feat(table): add QEMU semantic table client"
```

### Task 6: Add VCS C-side route activation and DPI request queue

**Files:**
- Create: `bridge/vcs/table_vcs_core.h`
- Create: `bridge/vcs/table_vcs_core.c`
- Create: `bridge/vcs/table_vcs_dpi.h`
- Create: `bridge/vcs/table_vcs_dpi.c`
- Create: `tests/unit/test_table_vcs_dpi.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write a failing C-only VCS DPI state test**

Load the valid fixture, register handler names `qid_map` and `wide_table`, activate routes through a mock
transport, enqueue a fragmented write, poll it, copy the payload, and send a completion. Repeat with a
missing handler and assert activation fails without sending ROUTE_BEGIN.

- [ ] **Step 2: Verify RED**

```bash
cmake --build build/table-sideband --target test_table_vcs_dpi
```

Expected: missing `table_vcs_init_rc()`.

- [ ] **Step 3: Implement per-RC DPI-compatible state**

Expose simulator-independent core functions plus thin DPI wrappers. The core API includes:

```c
int table_vcs_init_rc(int rc, const char *kind, const char *remote_host,
                      int table_port_base, int instance_id, const char *shm_name);
int table_vcs_load_routes_rc(int rc, const char *path);
int table_vcs_get_route_count_rc(int rc);
const char *table_vcs_get_route_handler_rc(int rc, int route);
int table_vcs_activate_routes_rc(int rc);
int table_vcs_poll_request_rc(int rc);
int table_vcs_get_request_kind_rc(int rc);
int table_vcs_copy_request_payload_core(int rc, unsigned char *out, int capacity);
int table_vcs_complete_rc(int rc, int status, unsigned long long failed_index,
                          unsigned int committed, int handler_error,
                          unsigned int read_data);
void table_vcs_cleanup_rc(int rc);
```

Maintain one state object per `COSIM_MAX_RCS`. Reassemble all fragments before exposing a write to SV.
Reject a second request while the current request lacks a completion. Keep route parsing and transport
threading out of `bridge_vcs.c`. `table_vcs_dpi.c` includes `svdpi.h` and maps an SV open byte array to
the core copy function with `svGetArrayPtr()` and `svSize()`. CMake unit tests compile only the core;
the VCS filelist compiles the wrapper with the simulator headers.

- [ ] **Step 4: Run GREEN**

```bash
cmake --build build/table-sideband --target test_table_vcs_dpi
ctest --test-dir build/table-sideband -R test_table_vcs_dpi --output-on-failure
```

Expected: activation, request ownership and missing-handler tests pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/vcs/table_vcs_core.c bridge/vcs/table_vcs_core.h \
        bridge/vcs/table_vcs_dpi.c bridge/vcs/table_vcs_dpi.h bridge/CMakeLists.txt \
        tests/unit/test_table_vcs_dpi.c tests/unit/CMakeLists.txt
git commit -m "feat(table): add VCS route and request DPI state"
```

### Task 7: Add the SV handler, codec and registry package

**Files:**
- Create: `vcs-tb/cosim_table_types.sv`
- Create: `vcs-tb/cosim_table_codec.sv`
- Create: `vcs-tb/cosim_table_handler.sv`
- Create: `vcs-tb/cosim_table_registry.sv`
- Create: `vcs-tb/cosim_table_pkg.sv`
- Create: `vcs-tb/tests/cosim_table_unit_test.sv`
- Create: `vcs-tb/tests/run_cosim_table_unit.sh`

- [ ] **Step 1: Write a standalone failing SV test**

The test must register two mock handlers, reject a duplicate name, write indices 2/3/4, verify byte
packing `packed[8*b +: 8]`, and test codecs:

```systemverilog
byte unsigned zero8[] = '{8'h00};
byte unsigned one8[]  = '{8'h01};
// Generic even SECDED convention: p1,p2,p4,p8,overall.
// 0x00 -> 5'b00000; 0x01 -> 5'b10011.
```

Also verify parity for `8'hff` is 0 in even mode and 1 in odd mode.

- [ ] **Step 2: Verify RED on the required simulation host**

Sync the worktree and run through a bash login shell:

```bash
sshpass -p 123 rsync -az --exclude .git ./ \
  ubuntu@10.11.10.53:/home/ubuntu/test_cosim/builds/cosim-table-sideband-20260814/
sshpass -p 123 ssh ubuntu@10.11.10.53 \
  "bash -lc 'cd /home/ubuntu/test_cosim/builds/cosim-table-sideband-20260814 && \
   vcs-tb/tests/run_cosim_table_unit.sh'"
```

Expected: VCS fails because `cosim_table_pkg` is missing.

- [ ] **Step 3: Implement the package**

Define `cosim_table_context`, result class, protection enum, and these virtual contracts:

```systemverilog
virtual class cosim_table_handler;
  pure virtual task write_entry(cosim_table_context ctx,
                                longint unsigned index,
                                byte unsigned raw_data[],
                                output cosim_table_result result);
  virtual task read_dword(cosim_table_context ctx,
                          longint unsigned index,
                          int unsigned byte_offset,
                          output bit [31:0] data,
                          output cosim_table_result result);
  virtual function bit supports_read(); return 0; endfunction
endclass
```

Registry lookup is by exact case-sensitive handler name. Implement group-wise XOR parity and generic
even SECDED with LSB-first data placed in non-power-of-two Hamming positions and overall parity last.
Expose a virtual codec callback so DUT-specific packing can replace the common codec.

- [ ] **Step 4: Run GREEN on host 53**

Repeat the rsync and script command. Expected log contains:

```text
COSIM_TABLE_UNIT: PASS registry
COSIM_TABLE_UNIT: PASS packing
COSIM_TABLE_UNIT: PASS parity
COSIM_TABLE_UNIT: PASS secded
COSIM_TABLE_UNIT: ALL PASS
```

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/cosim_table_types.sv vcs-tb/cosim_table_codec.sv \
        vcs-tb/cosim_table_handler.sv vcs-tb/cosim_table_registry.sv \
        vcs-tb/cosim_table_pkg.sv vcs-tb/tests/cosim_table_unit_test.sv \
        vcs-tb/tests/run_cosim_table_unit.sh
git commit -m "feat(table): add SV handler and codec framework"
```

### Task 8: Integrate the VCS table service into the per-RC test

**Files:**
- Create: `vcs-tb/cosim_table_service.sv`
- Create: `vcs-tb/tests/cosim_table_service_test.sv`
- Create: `vcs-tb/tests/run_cosim_table_service_test.sh`
- Modify: `bridge/vcs/bridge_vcs.sv`
- Modify: `vcs-tb/cosim_table_pkg.sv`
- Modify: `vcs-tb/cosim_xrc_pkg.sv`
- Modify: `vcs-tb/cosim_xrc_test.sv`
- Modify: `scripts/build_cosim_multirc.sh`

- [ ] **Step 1: Write a failing mock-service test**

Use DPI test doubles to deliver a 48-byte request at route start + 2*stride. Assert the service calls
the mock handler with indices 2/3/4 in order, stops at index 3 on injected failure, and sends completion
with `committed=1, failed_index=3`.

- [ ] **Step 2: Verify RED on host 53**

Compile the service test with `-ntb_opts uvm-1.2`. Expected: missing `cosim_table_service`.

- [ ] **Step 3: Implement the UVM service and DPI imports**

The service must:

1. parse `+COSIM_TABLE_ENABLE`, `+COSIM_TABLE_MAP`, `+TABLE_PORT_BASE`, and per-handler protection
   overrides;
2. call virtual `register_table_handlers(rc, service)` before route activation;
3. keep the endpoint not-ready if any handler is absent;
4. poll one fully assembled request at a time in `run_phase`;
5. apply the approved slice equations and byte packing;
6. call `write_entry()` sequentially or `read_dword()` once;
7. complete every accepted request exactly once;
8. maintain accepted, batch-entry, read-hit, write-success, exec-error and byte counters by
   RC/route/handler, complementing QEMU's miss/fallback/timeout counters;
9. print HIGH logs with a configurable dump limit.

Add `cosim_table_pkg.sv` after `bridge_vcs.sv` and before `cosim_xrc_pkg.sv` in the generated filelist.
Always add `table_vcs_dpi.c`, route and table transport sources to `CSRCS` so DPI symbols resolve in
the default binary. With no `+COSIM_TABLE_ENABLE`, no table transport is created and no behavior changes.

- [ ] **Step 4: Run GREEN and default compile regression on 53**

```bash
sshpass -p 123 ssh ubuntu@10.11.10.53 \
  "bash -lc 'cd /home/ubuntu/test_cosim/builds/cosim-table-sideband-20260814 && \
   vcs-tb/tests/run_cosim_table_service_test.sh && \
   scripts/build_cosim_multirc.sh build'"
```

Expected: service test passes; default multi-RC `simv_cosim_mrc` builds without table plusargs.

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/cosim_table_service.sv vcs-tb/tests/cosim_table_service_test.sv \
        vcs-tb/tests/run_cosim_table_service_test.sh bridge/vcs/bridge_vcs.sv \
        vcs-tb/cosim_table_pkg.sv vcs-tb/cosim_xrc_pkg.sv vcs-tb/cosim_xrc_test.sv \
        scripts/build_cosim_multirc.sh
git commit -m "feat(table): run registered handlers from VCS"
```

### Task 9: Add the QEMU-only PCIe table controller

**Files:**
- Create: `qemu-plugin/cosim_table_ctrl.h`
- Create: `qemu-plugin/cosim_table_ctrl.c`
- Create: `tests/integration/test_qemu_table_setup_smoke.sh`
- Modify: `setup.sh`
- Modify: `scripts/setup_cosim_qemu.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Add a QEMU build smoke check that fails**

Create `test_qemu_table_setup_smoke.sh`. It builds a temporary fake QEMU tree and requires
`cosim_table_ctrl.c` copied into `hw/net`, its header copied into `include/hw/net`, and exactly one
`system_ss.add(files('cosim_table_ctrl.c'))` line after two setup runs. Expected RED is the missing
source copy.

- [ ] **Step 2: Implement the endpoint**

Define QOM type `cosim-table-ctrl`, PCI class `PCI_CLASS_OTHERS`, vendor/device IDs from the shared
UAPI, one 4KiB memory BAR, and QOM properties:

```text
transport, remote_host, listen_addr, table_port_base,
instance_id, rc_id, device_instance, shm_name, timeout_ms, debug
```

The BAR returns magic/version/caps/ready. Register writes validate DMA address, bytes and slot count.
Doorbell validates `slot < slot_count`, uses `pci_dma_read()` for the 128-byte slot and payload, calls
`table_ctrl_core`, then uses `pci_dma_write()` for the completion before the MMIO callback returns.
Expose a registry lookup by `(rc_id, device_instance)` for PF read interception. On reset/remove, mark
not-ready before closing transport.

- [ ] **Step 3: Update both QEMU injection paths idempotently**

Copy the new files and shared table headers. Ensure repeated setup runs do not duplicate the meson line.
The legacy setup path must still copy RC/PF/VF files.

- [ ] **Step 4: Build QEMU and run device help smoke test**

On host 53, use the project setup-generated QEMU tree and run:

```bash
ninja -C third_party/qemu/build qemu-system-x86_64
third_party/qemu/build/qemu-system-x86_64 -device cosim-table-ctrl,help
```

Expected: build succeeds; help lists `rc_id`, `device_instance`, `table_port_base`, and `timeout_ms`.

- [ ] **Step 5: Commit**

```bash
git add qemu-plugin/cosim_table_ctrl.c qemu-plugin/cosim_table_ctrl.h \
        setup.sh scripts/setup_cosim_qemu.sh tests/integration/test_qemu_table_setup_smoke.sh \
        tests/integration/CMakeLists.txt
git commit -m "feat(table): add QEMU control endpoint"
```

### Task 10: Intercept matched PF table reads without changing writes

**Files:**
- Modify: `qemu-plugin/cosim_pcie_pf.h`
- Modify: `qemu-plugin/cosim_pcie_pf.c`
- Create: `tests/unit/test_table_read_decode.c`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write address-decode tests**

Cover 1/2/4B CPU reads, aligned DWORD calculation, byte extraction, BAR0 versus BAR1, stride holes,
end boundary, PF0 match, and VF/non-PF0 miss. Keep decode logic in QEMU-independent
`table_client` helpers so CTest can run it.

- [ ] **Step 2: Verify RED**

Expected: undefined `cosim_table_decode_read()`.

- [ ] **Step 3: Implement and integrate read interception**

Add `device_instance` QOM property to `CosimPCIePF`, default 0. At the start of
`cosim_pf_mmio_read()`, build target identity from the current `PCIDevice`, `pf_index`, BAR context and
generation. Call `cosim_table_ctrl_try_read()` only for active route hits. Handle statuses:

```text
SUCCESS       return requested bytes from completion.read_data
NO_ROUTE      execute the existing bridge_send_tlp_and_wait path
UNSUPPORTED   execute the existing bridge_send_tlp_and_wait path
other error   log and return all ones for the requested size
```

Do not alter `cosim_pf_mmio_write()`; semantic writes arrive through the controller.

- [ ] **Step 4: Run C tests and QEMU build**

```bash
cmake --build build/table-sideband --target test_table_read_decode
ctest --test-dir build/table-sideband -R test_table_read_decode --output-on-failure
```

Then rebuild QEMU on 53. Expected: CTest passes and QEMU links.

- [ ] **Step 5: Commit**

```bash
git add qemu-plugin/cosim_pcie_pf.c qemu-plugin/cosim_pcie_pf.h \
        tests/unit/test_table_read_decode.c tests/unit/CMakeLists.txt
git commit -m "feat(table): route matched PF reads to VCS"
```

### Task 11: Add one user-facing launch switch

**Files:**
- Modify: `cosim.sh`
- Modify: `scripts/run_cosim.sh`
- Modify: `scripts/launch_dual.py`
- Modify: `scripts/build_cosim_multirc.sh`
- Modify: `tests/integration/test_cli_smoke.sh`
- Modify: `tests/integration/test_launch_smoke.sh`
- Modify: `docs/VCS-INTEGRATION-GUIDE.md`

- [ ] **Step 1: Extend smoke tests first**

Assert default command lines contain neither `cosim-table-ctrl` nor `COSIM_TABLE_ENABLE`. Assert:

```text
--table-backdoor=on --table-map=/tmp/routes.ini --table-port-base=10100
```

adds one controller per RC and VCS plusargs:

```text
+COSIM_TABLE_ENABLE=1 +COSIM_TABLE_MAP=/tmp/routes.ini +TABLE_PORT_BASE=10100
```

- [ ] **Step 2: Verify RED**

```bash
bash tests/integration/test_cli_smoke.sh
bash tests/integration/test_launch_smoke.sh
```

Expected: unknown table options or missing generated arguments.

- [ ] **Step 3: Implement propagation**

Default `table_backdoor=off`. Reject `on` without an absolute readable map path. Add the controller as a
separate endpoint on the same root-port bus with a different PCI address from the DUT. Pass `rc_id`,
`device_instance`, transport, instance ID and table port base. Set Guest module parameter
`table_backdoor=1` through the existing module-load configuration; never hardcode a BAR base.

- [ ] **Step 4: Run GREEN**

Run both smoke scripts and `ctest -R 'test_cli_smoke|test_launch_smoke'`. Expected: default-off and
enabled cases pass.

- [ ] **Step 5: Commit**

```bash
git add cosim.sh scripts/run_cosim.sh scripts/launch_dual.py scripts/build_cosim_multirc.sh \
        tests/integration/test_cli_smoke.sh tests/integration/test_launch_smoke.sh \
        docs/VCS-INTEGRATION-GUIDE.md
git commit -m "feat(table): expose optional sideband launch switch"
```

### Task 12: Add the tracked Guest control driver overlay

**Files:**
- Create: `guest/dpu-table-sideband/cosim_table_ctrl.h`
- Create: `guest/dpu-table-sideband/cosim_table_ctrl.c`
- Create: `guest/dpu-table-sideband/README.md`
- Create: `scripts/apply_dpu_table_sideband.sh`
- Create: `guest/dpu-table-sideband/0001-dpu-table-sideband-core.patch`

- [ ] **Step 1: Create a dry-run test against the reference release**

The apply script accepts exactly one `host-driver-net` directory, checks for `common.h`, `main.c`, and
`Makefile`, copies the two controller files plus `cosim_table_protocol.h` and
`cosim_table_ctrl_uapi.h`, and applies each numbered patch only if its marker is absent.
It runs `patch --dry-run` before each mutation. Re-running an already applied version is a successful
no-op; adding patch 0002 later applies only 0002. First run before patch 0001 exists must fail.

- [ ] **Step 2: Implement the controller source**

Register a second `pci_driver` in the same `dpu_snd1.ko` for `1af4:10f0`. Probe must enable the device,
request/map BAR0, set 64-bit then 32-bit DMA masks, allocate four coherent slots, program DMA base/size,
and add the controller to an RC/root-port registry. Remove reverses those operations.

Expose:

```c
enum dpu_table_submit_result {
    DPU_TABLE_FRONTDOOR = 0,
    DPU_TABLE_SUCCESS   = 1,
    DPU_TABLE_ERROR     = 2,
};

enum dpu_table_submit_result dpu_table_submit(
    struct dpu_hw *hw, unsigned int bar, u64 offset,
    const void *data, u32 bytes, enum dpu_table_write_order order);
```

Claim a slot with `cmpxchg`, copy payload, execute `dma_wmb()`, ring the doorbell, execute `dma_rmb()`,
and release the slot. Map only the four safe statuses to `DPU_TABLE_FRONTDOOR`. Log EXEC_ERROR with
failed index and committed count. Calls made while the module parameter is off return FRONTDOOR without
touching the controller.

- [ ] **Step 3: Add core integration patch**

The patch must:

- add `cosim_table_ctrl.o` to `dpu_snd1-objs`;
- add `static bool table_backdoor` and `module_param(table_backdoor, bool, 0444)` in `main.c`;
- register the controller PCI driver before `dpu_driver` and unwind it on every failure/exit path;
- add the exact target `struct pci_dev *` lookup through `((struct dpu_adapter *)hw->adapter)->pdev`;
- replace macro loops with inline functions that call `dpu_table_submit()` and perform the original
  low-to-high or high-to-low `writel()` loop only on FRONTDOOR;
- preserve `wr32`, `rd32`, mailbox and MSI macros byte-for-byte.

- [ ] **Step 4: Apply and build on host 53**

```bash
sshpass -p 123 rsync -az guest/dpu-table-sideband/ bridge/table/cosim_table_protocol.h \
  bridge/table/cosim_table_ctrl_uapi.h scripts/apply_dpu_table_sideband.sh \
  ubuntu@10.11.10.53:/home/ubuntu/test_cosim/builds/dpu-table-sideband-overlay/
sshpass -p 123 ssh ubuntu@10.11.10.53 \
  "bash -lc 'test -d /home/ubuntu/test_cosim/builds/dpu-table-sideband-driver-baseline || \
   cp -a /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net \
         /home/ubuntu/test_cosim/builds/dpu-table-sideband-driver-baseline; \
   /home/ubuntu/test_cosim/builds/dpu-table-sideband-overlay/apply_dpu_table_sideband.sh \
   /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net && \
   cd /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net && \
   make modules'"
```

Expected: `dpu_snd1.ko` builds and `modinfo` lists `table_backdoor`.

- [ ] **Step 5: Commit**

```bash
git add guest/dpu-table-sideband scripts/apply_dpu_table_sideband.sh
git commit -m "feat(guest): add DPU table sideband controller overlay"
```

### Task 13: Add QID batch submission and skip redundant readback

**Files:**
- Create: `guest/dpu-table-sideband/0002-dpu-qid-table-batch.patch`
- Modify: `scripts/apply_dpu_table_sideband.sh`
- Modify: `guest/dpu-table-sideband/README.md`

- [ ] **Step 1: Capture the existing behavior with source assertions**

The patch test must assert the reference source contains both QID loops with
`wr32_for_high_order()`, `udelay(5)`, `rd32_for_each()`, and
`DPU_REG_WRITE_MAX_TRY_TIMES`. This prevents silently patching a different driver release.

- [ ] **Step 2: Add a batch API and modify only complete-buffer paths**

Expose `dpu_table_submit_batch()` with start offset, entry bytes, stride bytes and entry count. For the
QID/vio-notify path, submit `af_res->vio_notify_table` starting at
`VIO_NOTIFY_TBL_E_ADDR(select, 0)` with `sizeof(struct dpu_vio_notify_tbl)` and
`DPU_QID_MAP_TABLE_ENTRIES(hw)`.

Behavior must be:

```c
result = dpu_table_submit_batch(...);
if (result == DPU_TABLE_SUCCESS)
    goto qid_table_done;
if (result == DPU_TABLE_ERROR)
    return; /* already logged; never frontdoor replay */
/* FRONTDOOR: execute the original per-entry write/read/retry loop unchanged */
```

Apply the same structure to the remove/compaction path that owns the complete array. Do not batch call
sites that only own a single register command structure.

- [ ] **Step 3: Reapply from a fresh reference copy and build**

Sync the updated overlay to host 53. Run the script once on the already patched release so marker 0001
is skipped and 0002 is applied. Copy the saved baseline to
`/home/ubuntu/test_cosim/builds/dpu-table-sideband-driver-test`, apply both patches, run `make modules`,
and use `objdump -t dpu_snd1.ko` to verify both submit symbols are present. Both the requested reference
release and the clean replay copy must build.

- [ ] **Step 4: Commit**

```bash
git add guest/dpu-table-sideband/0002-dpu-qid-table-batch.patch \
        guest/dpu-table-sideband/README.md scripts/apply_dpu_table_sideband.sh
git commit -m "feat(guest): batch complete QID table writes"
```

### Task 14: Add a reference route and mock multi-RAM handler

**Files:**
- Create: `vcs-tb/examples/qid_table_routes.ini`
- Create: `vcs-tb/examples/vio_notify_mock_handler.sv`
- Create: `vcs-tb/tests/cosim_vio_notify_handler_test.sv`
- Create: `vcs-tb/tests/run_vio_notify_handler_test.sh`

- [ ] **Step 1: Write the multi-level routing test**

Use indices 0, 15, and 255. Assert every index writes one L3 bank selected by `idx % 4`; index 15 also
writes L2; index 255 writes L3, L2 and L1. Verify physical indices:

```text
l3_mod_idx = idx / 4
l2_mod     = ((idx + 1) / 16 - 1) % 4
l2_mod_idx = ((idx - 15) / 16) / 4
l1_mod     = ((idx + 1) / 256 - 1) % 4
l1_mod_idx = ((idx - 255) / 256) / 4
```

Use mock arrays instead of real DUT paths so the test compiles in this repository.

The route file uses the reference driver's evaluated BAR0 offsets and two selected banks:

```ini
[route.vio_notify_bank0]
rc=0
device=0
target=pf0
bar=0
start=0xA0000
end=0xA0800
entry_bytes=16
stride_bytes=16
index_base=0
handler=vio_notify

[route.vio_notify_bank1]
rc=0
device=0
target=pf0
bar=0
start=0xB0000
end=0xB0800
entry_bytes=16
stride_bytes=16
index_base=0
handler=vio_notify
```

- [ ] **Step 2: Verify RED on host 53**

Expected: handler class missing.

- [ ] **Step 3: Implement the reference handler**

Mirror the supplied example semantics: L3 uses four banks, every 16th entry mirrors to one of four L2
banks, and every 256th entry mirrors to one of four L1 banks. The mock handler records the exact raw and
protected values and emits HIGH messages. Document that the user's real subclass replaces mock array
writes with these existing macros:

```text
ST_WRITE_DEPOSIT_RAM(..., `PCMP_3LL_VIONTY_TABLE_RAM)
ST_WRITE_DEPOSIT_RAM(..., `PCMP_3HL_VIONTY_TABLE_RAM)
ST_WRITE_DEPOSIT_RAM(..., `PCMP_3LH_VIONTY_TABLE_RAM)
ST_WRITE_DEPOSIT_RAM(..., `PCMP_3HH_VIONTY_TABLE_RAM)
```

and the corresponding `PCMP_2*` and `PCMP_1*` macros.

- [ ] **Step 4: Run GREEN on host 53**

Expected log contains one/ two/ three deposits for indices 0/15/255 and `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/examples/qid_table_routes.ini vcs-tb/examples/vio_notify_mock_handler.sv \
        vcs-tb/tests/cosim_vio_notify_handler_test.sv \
        vcs-tb/tests/run_vio_notify_handler_test.sh
git commit -m "test(table): cover index-routed multi-RAM handler"
```

### Task 15: Run complete local and host-53 verification

**Files:**
- Create: `docs/validation/2026-08-14-table-sideband-validation.md`
- Modify only if a verified test exposes a defect in files from Tasks 1-14.

- [ ] **Step 1: Run the full local C suite**

```bash
cmake -S . -B build/table-sideband -DCMAKE_BUILD_TYPE=Debug
cmake --build build/table-sideband -j"$(nproc)"
ctest --test-dir build/table-sideband --output-on-failure
```

Expected: zero failed tests.

- [ ] **Step 2: Verify default-off launch equivalence**

Run CLI/launch smoke tests and compare the generated QEMU and VCS argument lists with a baseline after
removing timestamps and temporary paths. Expected: no table device, table port or table plusarg appears.

- [ ] **Step 3: Run all standalone SV tests on 53**

Through `bash -lc`, run the handler, service and multi-RAM scripts. Expected: each prints `ALL PASS` and
VCS reports zero UVM errors/fatals.

- [ ] **Step 4: Build QEMU, VCS and Guest driver on 53**

Build QEMU with the injected endpoint, `scripts/build_cosim_multirc.sh build`, and the patched
`dpu_snd1.ko`. Expected: all three exit 0; `qemu-system-x86_64 -device cosim-table-ctrl,help` works;
`modinfo dpu_snd1.ko` lists `table_backdoor`.

- [ ] **Step 5: Run semantic sideband integration**

Start one RC with table mode enabled and the reference route. In the Guest load:

```bash
modprobe dpu_snd1 table_backdoor=1
```

Exercise QID setup. Verify logs and counters show:

```text
QEMU: one accepted batch, zero target PF MWr for the route
VCS: expected first index/count and SUCCESS completion
SV: expected raw data, protection mode, physical data and RAM targets
Guest: no udelay/readback retry on SUCCESS
```

Repeat with an empty map and verify the original high-to-low frontdoor sequence reaches CQ. Inject
EXEC_ERROR at index 3 and verify `committed=3`, an error log, and no frontdoor MWr replay.

- [ ] **Step 6: Run two-RC isolation smoke**

Start two control endpoints and two table channels. Submit the same BAR offset with different RC/device
identity and values. Verify each VCS service and mock RAM receives only its own value.

- [ ] **Step 7: Record evidence and commit only necessary fixes**

Save command lines and concise pass/fail summaries under
`docs/validation/2026-08-14-table-sideband-validation.md`. Do not commit generated `simv`, QEMU build,
kernel objects, logs containing environment secrets, or the modified non-Git release directory.

```bash
git add docs/validation/2026-08-14-table-sideband-validation.md
git commit -m "test(table): record sideband integration validation"
```

## Final review gate

Before merging or pushing:

1. run `git diff f48270b...HEAD --check`;
2. confirm `git status --short` contains no build products or unrelated user files;
3. rerun full CTest and all host-53 SV tests;
4. verify default-off and NO_ROUTE frontdoor paths with captured CQ evidence;
5. verify SUCCESS, EXEC_ERROR and TIMEOUT each follow the specified replay boundary;
6. use `superpowers:requesting-code-review` for an independent spec and code review;
7. use `superpowers:finishing-a-development-branch` only after every required test passes.
