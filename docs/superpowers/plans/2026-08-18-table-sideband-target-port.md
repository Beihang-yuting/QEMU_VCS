# Target-Native Table Sideband Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the optional complete-buffer table backdoor onto `feature/qemu-vcs-isolated-tcp` while preserving the target branch's default PF/VF/BAR, QEMU, VCS, and Guest behavior.

**Architecture:** Keep `cosim-pcie-rc` as the only DUT topology model and add an independent `cosim-table-ctrl` endpoint at `pcie.0:00:06.0`. QEMU serves a separate table TCP channel, VCS connects as the client, validates a VCS-only route generation, and dispatches complete entries to per-RC SystemVerilog handlers. Guest writes use coherent DMA slots; eligible PF0 logical BAR0/BAR1 reads use a 4-byte callback; every other access stays on the existing frontdoor.

**Tech Stack:** C11, CMake/CTest, POSIX TCP and pthreads, QEMU 9.2 PCI/QOM APIs, Linux PCI driver APIs, SystemVerilog/UVM 1.2, VCS DPI-C, Bash, and VCS simulation on `10.11.10.53`.

---

## Implementation boundaries

The approved specification is
`docs/superpowers/specs/2026-08-18-table-sideband-target-port-design.md`.
The implementation starts from
`origin/feature/qemu-vcs-isolated-tcp@bca79aaa6a54ecb881bb0fdff73245216492bc93`.
The checkpoint
`feature/table-backdoor-sideband@38858e202c59986b850b9ae76b4c3571052b9445`
is a code reference, not a merge source.

Do not restore or edit the target-deleted `cosim.sh`, `cosim_pcie_pf.[ch]`, old
multi-RC launch/build scripts, `vcs-tb/cosim_xrc_test.sv`, or a repository-owned
top. Do not change the existing TLP ABI, `cosim_transport_t`, `cosim_shm_t`, PF/VF
discovery, or Guest-assigned BAR bases. TCP is the only table transport in this
increment; adding table SHM would not serve the approved cross-host runtime.

All VCS compilation and simulation checks run on `ubuntu@10.11.10.53` through a
Bash login shell (`bash -lic`). Use these fixed remote paths so source and build
products stay separate:

```text
/home/ubuntu/test_cosim/builds/table-sideband-target-src
/home/ubuntu/test_cosim/builds/table-sideband-target-build
```

Before a host-53 check, synchronize the current worktree without persisting the
password or a token:

```bash
read -rsp 'VCS host password: ' SSHPASS; export SSHPASS; echo
sshpass -e rsync -az --delete --exclude .git ./ \
  ubuntu@10.11.10.53:/home/ubuntu/test_cosim/builds/table-sideband-target-src/
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   git init -q && git add -A'"
```

The temporary Git index is required because retained source-contract tests call
`git ls-files` and `git rev-parse`. Never copy the local worktree's `.git` file to
the simulation host. Keep `SSHPASS` only for the immediately following task
command and run `unset SSHPASS` as soon as that command finishes.

## File map

| Path | Responsibility |
|---|---|
| `bridge/table/cosim_table_protocol.h` | Stable little-endian table wire ABI |
| `bridge/table/cosim_table_ctrl_uapi.h` | Guest/QEMU control BAR and coherent-slot ABI |
| `bridge/table/cosim_table_route.[ch]` | INI parsing, operation policy, atomic validation, match and slicing |
| `bridge/table/cosim_table_transport.[ch]` | Table-only transport interface and lifecycle |
| `bridge/table/cosim_table_transport_tcp.c` | QEMU-server/VCS-client framed TCP channel |
| `bridge/qemu/table_client.[ch]` | Semantic route cache and synchronous write/read RPC; “client” describes the RPC role, while its socket is a server |
| `bridge/qemu/table_ctrl_core.[ch]` | QEMU-independent slot validation, logical BAR decode and completion ownership |
| `bridge/qemu/table_ctrl_lifecycle.h` | QEMU-independent worker start/stop state transitions |
| `bridge/qemu/table_target.[ch]` | QEMU-independent PF0 target snapshot and generation checks |
| `bridge/vcs/table_vcs_core.[ch]` | Per-RC VCS client, route publication and request assembly |
| `qemu-plugin/cosim_table_ctrl.[ch]` | Separate QOM PCI controller and background server lifecycle |
| `qemu-plugin/cosim_pcie_rc.[ch]` | Existing topology owner plus read-only PF0 snapshot and optional read interception |
| `vcs-tb/cosim_table_*.sv` | Types, codecs, handler registry, service and per-RC runtime facade |
| `guest/dpu-table-sideband/*` | Transactional overlay for the supplied `host-driver-net` tree |
| `scripts/apply_dpu_table_sideband.sh` | Validate and apply the numbered Guest patch stack |
| `tests/unit/test_table_*.c` | Protocol, route, transport, controller, target and VCS core tests |
| `tests/sv/test_cosim_table_*.sv` | Standalone handler, codec, runtime and service tests |
| `tests/integration/test_table_*.{c,sh}` | Roundtrip, default-off, injection and Guest overlay contracts |

## Fixed contracts used by every task

```c
#define COSIM_TABLE_MAGIC              UINT32_C(0x4c425443)
#define COSIM_TABLE_PROTOCOL_VERSION   1u
#define COSIM_TABLE_CTRL_VENDOR_ID     0x1af4
#define COSIM_TABLE_CTRL_DEVICE_ID     0x10f0
#define COSIM_TABLE_CTRL_BAR_BYTES     0x1000u
#define COSIM_TABLE_HANDLER_NAME_BYTES 64u
#define COSIM_TABLE_FRAME_DATA_BYTES   (64u * 1024u)
#define COSIM_TABLE_DEFAULT_PORT_BASE  10100u

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

Only `NOT_READY`, `NO_ROUTE`, `UNSUPPORTED`, and a locally detected
`SLOT_BUSY` permit a Guest write to replay through the frontdoor. `SUCCESS`
skips frontdoor writes. Every other accepted or ambiguous result is a hard
error with no replay.

Route `bar=0` and `bar=1` name the first two populated PF BAR owner regions in
dense order. For a DPU profile with physical owners BAR0/BAR2/BAR4, logical
BAR0 maps to physical BAR0 and logical BAR1 maps to physical BAR2. A 64-bit BAR
upper DWORD is never treated as a separate region.

### Task 1: Define the table wire protocol and control UAPI

**Files:**
- Create: `bridge/table/cosim_table_protocol.h`
- Create: `bridge/table/cosim_table_ctrl_uapi.h`
- Create: `tests/unit/test_table_protocol.c`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write the failing ABI test**

Create `tests/unit/test_table_protocol.c` with exact size and status checks:

```c
#include "cosim_table_ctrl_uapi.h"
#include <assert.h>

int main(void)
{
    assert(COSIM_TABLE_PROTOCOL_VERSION == 1);
    assert(COSIM_TABLE_ST_NO_ROUTE == 2);
    assert(COSIM_TABLE_ST_PROTOCOL == 9);
    assert(sizeof(cosim_table_frame_hdr_t) == 24);
    assert(sizeof(cosim_table_target_t) == 24);
    assert(sizeof(cosim_table_route_entry_t) == 128);
    assert(sizeof(cosim_table_completion_t) == 32);
    assert(COSIM_TABLE_REG_DOORBELL == 0x20);
    assert(COSIM_TABLE_REG_TARGET_GENERATION == 0x30);
    assert(sizeof(cosim_table_slot_hdr_t) == 128);
    assert(cosim_table_status_may_frontdoor(COSIM_TABLE_ST_NO_ROUTE));
    assert(!cosim_table_status_may_frontdoor(COSIM_TABLE_ST_TIMEOUT));
    return 0;
}
```

Register the executable with include path `bridge/table` in
`tests/unit/CMakeLists.txt`.

- [ ] **Step 2: Run the test on host 53 and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake -S /home/ubuntu/test_cosim/builds/table-sideband-target-src \
   -B /home/ubuntu/test_cosim/builds/table-sideband-target-build -DCMAKE_BUILD_TYPE=Debug && \
   cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_protocol'"
```

Expected: compilation fails because `cosim_table_ctrl_uapi.h` is absent.

- [ ] **Step 3: Add the fixed-width ABI**

Implement little-endian conversion helpers that compile in both Linux kernel
and userspace, followed by these public wire records:

```c
typedef struct __attribute__((packed)) {
    cosim_u32 magic;
    cosim_u16 version;
    cosim_u16 type;
    cosim_u32 header_bytes;
    cosim_u32 payload_bytes;
    cosim_u64 transaction_id;
} cosim_table_frame_hdr_t;

typedef struct __attribute__((packed)) {
    cosim_u16 rc_id;
    cosim_u16 device_instance;
    cosim_u16 pci_domain;
    cosim_u16 target_bdf;
    cosim_u8 target_type;
    cosim_u8 pf_index;
    cosim_u16 vf_index;
    cosim_u8 bar_index;
    cosim_u8 reserved0[3];
    cosim_u32 generation;
    cosim_u32 reserved1;
} cosim_table_target_t;

typedef struct __attribute__((packed)) {
    cosim_u32 status;
    cosim_u32 failed_index;
    cosim_u32 committed_count;
    cosim_u32 handler_error;
    cosim_u32 returned_dword;
    cosim_u32 reserved[3];
} cosim_table_completion_t;
```

Define message types `HELLO`, `CAPABILITY`, `ROUTE_BEGIN`, `ROUTE_ENTRY`,
`ROUTE_END`, `WRITE_BEGIN`, `WRITE_DATA`, `WRITE_END`, `READ_DWORD`,
`COMPLETION`, and `SHUTDOWN`. Define operation bits `WRITE` and `READ_DWORD`.
The route record contains target, operation mask, `[start,end)`, entry bytes,
stride bytes, index base and a 64-byte handler name.

Use these BAR registers and slot ownership states:

```c
enum {
    COSIM_TABLE_REG_MAGIC = 0x00, COSIM_TABLE_REG_VERSION = 0x04,
    COSIM_TABLE_REG_CAPS = 0x08, COSIM_TABLE_REG_READY = 0x0c,
    COSIM_TABLE_REG_DMA_ADDR_LO = 0x10, COSIM_TABLE_REG_DMA_ADDR_HI = 0x14,
    COSIM_TABLE_REG_DMA_BYTES = 0x18, COSIM_TABLE_REG_SLOT_COUNT = 0x1c,
    COSIM_TABLE_REG_DOORBELL = 0x20, COSIM_TABLE_REG_LAST_ERROR = 0x24,
    COSIM_TABLE_REG_RC_ID = 0x28, COSIM_TABLE_REG_DEVICE_INSTANCE = 0x2c,
    COSIM_TABLE_REG_TARGET_GENERATION = 0x30,
};
enum {
    COSIM_TABLE_SLOT_FREE, COSIM_TABLE_SLOT_READY,
    COSIM_TABLE_SLOT_BUSY, COSIM_TABLE_SLOT_COMPLETE,
};
```

Make `cosim_table_slot_hdr_t` exactly 128 bytes and 8-byte aligned. Add
`cosim_table_status_may_frontdoor()` with the four approved safe statuses.
Static-assert every public record size.

- [ ] **Step 4: Run GREEN plus the retained transport ABI test**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_protocol test_transport_tcp && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R \"test_table_protocol|test_transport_tcp\" --output-on-failure'"
```

Expected: both tests pass and no retained `tlp_entry_t` size changes.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_protocol.h bridge/table/cosim_table_ctrl_uapi.h \
        tests/unit/test_table_protocol.c tests/unit/CMakeLists.txt
git commit -m "feat(table): define target sideband ABI"
```

### Task 2: Parse operations and validate route generations

**Files:**
- Create: `bridge/table/cosim_table_route.h`
- Create: `bridge/table/cosim_table_route.c`
- Create: `tests/unit/test_table_route.c`
- Create: `tests/fixtures/table_routes_valid.ini`
- Create: `tests/fixtures/table_routes_overlap.ini`
- Create: `tests/fixtures/table_routes_invalid_operations.ini`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write failing parser, operation and slicing tests**

The valid fixture contains all three supported operation forms:

```ini
[route.default_write]
rc=0
device=0
target=pf0
bar=0
start=0x1000
end=0x2000
entry_bytes=16
stride_bytes=16
index_base=0
handler=default_write

[route.explicit_write]
rc=0
device=0
target=pf0
bar=1
start=0x4000
end=0x5000
entry_bytes=32
stride_bytes=64
index_base=8
handler=explicit_write
operations=write

[route.readable]
rc=0
device=0
target=pf0
bar=1
start=0x6000
end=0x7000
entry_bytes=128
stride_bytes=128
index_base=32
handler=readable
operations=write,read
```

Test that omission and `write` produce `COSIM_TABLE_OP_WRITE`, while
`write,read` produces both bits. Test 16/32/128-byte entry slicing, a packed
three-entry batch, stride holes, end-exclusive boundaries, maximum index and
overlap rejection. Iterate invalid fixtures for empty, duplicate, unknown,
`read`, and reversed `read,write` values.

- [ ] **Step 2: Run the route target and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_route'"
```

Expected: build fails because `cosim_table_route_load()` is undefined.

- [ ] **Step 3: Implement the route API and atomic validation**

Expose exactly:

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
                            uint64_t bar_offset, uint32_t payload_bytes,
                            uint64_t *first_index, uint32_t *entry_count);
```

Parse line-by-line without a new dependency. Reject duplicate/unknown keys,
non-numeric suffixes, non-PF0 targets, bars above 1, zero entry/stride, stride
smaller than entry width, invalid `[start,end)`, index overflow and overlapping
ranges for the same RC/device/target/bar. Sort a validation copy; publish the
map only after every route succeeds. Hash validated fixed-width entries with
FNV-1a 64.

- [ ] **Step 4: Run GREEN**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_route && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_table_route --output-on-failure'"
```

Expected: all operation, overlap, width, stride and index cases pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_route.c bridge/table/cosim_table_route.h \
        bridge/CMakeLists.txt tests/unit/test_table_route.c \
        tests/unit/CMakeLists.txt tests/fixtures/table_routes_*.ini
git commit -m "feat(table): validate VCS route operations"
```

### Task 3: Add the independent QEMU-server TCP transport

**Files:**
- Create: `bridge/table/cosim_table_transport.h`
- Create: `bridge/table/cosim_table_transport.c`
- Create: `bridge/table/cosim_table_transport_tcp.c`
- Create: `tests/unit/test_table_transport_tcp.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write a failing fragmented-frame and shutdown test**

Fork a QEMU-role server on `127.0.0.1` and a VCS-role client. Assert that the
server binds `table_port_base + instance_id`, the client connects to the same
port, HELLO identity matches, a 150000-byte payload arrives in
65536/65536/18928-byte frames, and a completion returns with the original
transaction ID. Close the client while the server is blocked in receive and
assert cleanup returns within two seconds.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_transport_tcp'"
```

Expected: link fails because `cosim_table_transport_create()` is absent.

- [ ] **Step 3: Implement the table-only transport**

Use this interface without editing `cosim_transport_t` or
`bridge/common/transport_tcp.c`:

```c
typedef struct cosim_table_transport cosim_table_transport_t;
typedef struct {
    const char *remote_host;
    const char *listen_addr;
    uint32_t table_port_base;
    uint32_t instance_id;
    uint16_t rc_id;
    int is_server;
    int connect_timeout_ms;
} cosim_table_transport_cfg_t;

cosim_table_transport_t *cosim_table_transport_create(
    const cosim_table_transport_cfg_t *cfg);
int cosim_table_send(cosim_table_transport_t *transport,
                     const cosim_table_frame_hdr_t *frame,
                     const void *header, const void *payload, int timeout_ms);
int cosim_table_recv(cosim_table_transport_t *transport,
                     cosim_table_frame_hdr_t *frame,
                     void *header, size_t header_capacity,
                     void *payload, size_t payload_capacity, int timeout_ms);
void cosim_table_transport_interrupt(cosim_table_transport_t *transport);
void cosim_table_transport_close(cosim_table_transport_t *transport);
```

Use one socket, `TCP_NODELAY`, `SO_REUSEADDR`, exact-length loops and `poll()`
deadlines. QEMU listens on `0.0.0.0`; VCS connects to `REMOTE_HOST` with bounded
retry so the controller worker and VCS service may start in either order.
Validate magic/version/RC identity and reject oversized lengths before reading
into a caller buffer. `interrupt()` must `shutdown()` the connected and listen
sockets to unblock accept, send or receive.

- [ ] **Step 4: Run GREEN and retained TCP regression**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_transport_tcp test_transport_tcp && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R \"test_table_transport_tcp|test_transport_tcp\" --output-on-failure'"
```

Expected: new and retained TCP tests pass with no port or symbol collision.

- [ ] **Step 5: Commit**

```bash
git add bridge/table/cosim_table_transport.h bridge/table/cosim_table_transport.c \
        bridge/table/cosim_table_transport_tcp.c bridge/CMakeLists.txt \
        tests/unit/test_table_transport_tcp.c tests/unit/CMakeLists.txt
git commit -m "feat(table): add QEMU-server table transport"
```

### Task 4: Add the QEMU semantic RPC and descriptor core

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

- [ ] **Step 1: Write failing ownership, fallback and roundtrip tests**

Use callback-backed fake DMA slots to cover READY false, malformed reserved
bytes, payload bounds, local slot contention, no route, three-entry success,
EXEC_ERROR after one commit, timeout, protocol completion, generation change
and a 4-byte read. Assert `COMPLETE` is published after all result fields and
that only the four safe statuses allow frontdoor replay.

The integration test starts the QEMU transport as server and a mock VCS peer as
client, publishes one route generation, submits a fragmented write, verifies
first index/count and returns SUCCESS, then handles one read DWORD.

- [ ] **Step 2: Run both targets and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_ctrl_core test_table_roundtrip'"
```

Expected: undefined table client and controller-core symbols.

- [ ] **Step 3: Implement route installation, RPC and slot processing**

The semantic client accepts a transport that is already connected in server
mode and exposes:

```c
cosim_table_client_t *cosim_table_client_create(
    cosim_table_transport_t *transport, uint16_t rc_id);
int cosim_table_client_wait_routes(cosim_table_client_t *client,
                                   int timeout_ms);
const cosim_table_route_entry_t *cosim_table_client_match(
    cosim_table_client_t *client, const cosim_table_target_t *target,
    uint64_t offset, uint8_t operation);
cosim_table_status_t cosim_table_client_write(
    cosim_table_client_t *client, const cosim_table_write_begin_t *request,
    const uint8_t *payload, cosim_table_completion_t *completion,
    int timeout_ms);
cosim_table_status_t cosim_table_client_read_dword(
    cosim_table_client_t *client, const cosim_table_read_dword_t *request,
    cosim_table_completion_t *completion, int timeout_ms);
void cosim_table_client_destroy(cosim_table_client_t *client);
```

Publish a route map only after a complete matching BEGIN/ENTRY/END generation.
Serialize requests, fragment writes at 64 KiB, preserve transport timeout as
`TIMEOUT`, and validate SUCCESS/EXEC_ERROR completion counts and failed index.

`table_ctrl_core` owns these pure helpers:

```c
int cosim_table_map_logical_bar(const uint64_t bar_sizes[6],
                                uint8_t logical_bar, uint8_t *pci_region,
                                uint64_t *aperture_bytes);
int cosim_table_decode_read(const uint64_t bar_sizes[6], uint16_t rc_id,
                            uint16_t device_instance, uint8_t pf_index,
                            uint8_t pci_region, int is_vf,
                            uint64_t bar_offset, unsigned size,
                            cosim_table_target_t *target,
                            uint64_t *aligned_offset, uint8_t *byte_offset);
uint64_t cosim_table_extract_read(uint32_t dword, uint8_t byte_offset,
                                  unsigned size);
cosim_table_status_t cosim_table_ctrl_process_slot(
    cosim_table_ctrl_core_t *core, uint64_t slot_dma_address,
    uint32_t slot_bytes, int timeout_ms);
```

- [ ] **Step 4: Run GREEN**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_ctrl_core test_table_roundtrip && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R \"test_table_ctrl_core|test_table_roundtrip\" --output-on-failure'"
```

Expected: ownership, partial failure, timeout, fragmented write and read cases
all pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/qemu/table_client.c bridge/qemu/table_client.h \
        bridge/qemu/table_ctrl_core.c bridge/qemu/table_ctrl_core.h \
        bridge/CMakeLists.txt tests/unit/test_table_ctrl_core.c \
        tests/unit/CMakeLists.txt tests/integration/test_table_roundtrip.c \
        tests/integration/CMakeLists.txt
git commit -m "feat(table): add semantic RPC controller core"
```

### Task 5: Add the VCS client, route activation and request assembler

**Files:**
- Create: `bridge/vcs/table_vcs_core.h`
- Create: `bridge/vcs/table_vcs_core.c`
- Create: `tests/unit/test_table_vcs_core.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `scripts/build_cosim_lib.sh`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write a failing per-RC VCS core test**

Start a mock QEMU server. In RC0 load the valid route fixture, register all
three handler names, connect as a VCS client and publish the generation. Send a
fragmented request from the mock server, poll it from the VCS core, assert the
handler, first index, entry count and payload words, and send one completion.

Repeat with RC1 using the same offset and a different byte pattern. Assert no
state crosses RCs. Then omit one handler and assert route activation fails
before ROUTE_BEGIN. Mark `readable` unsupported and assert capability mismatch
also prevents publication.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_vcs_core'"
```

Expected: link fails because `table_vcs_init_rc()` is absent.

- [ ] **Step 3: Implement per-RC connection and scalar DPI-safe accessors**

Expose a simulator-independent interface; `bridge/vcs/bridge_vcs.sv` will
import these symbols directly:

```c
int table_vcs_init_rc(int rc, const char *remote_host,
                      int table_port_base, int instance_id,
                      int connect_timeout_ms);
int table_vcs_load_routes_rc(int rc, const char *absolute_path);
int table_vcs_register_handler_rc(int rc, const char *name,
                                  int supports_read);
int table_vcs_activate_routes_rc(int rc);
int table_vcs_poll_request_rc(int rc);
int table_vcs_get_request_kind_rc(int rc);
const char *table_vcs_get_request_handler_rc(int rc);
int table_vcs_get_request_rc_id_rc(int rc);
int table_vcs_get_request_device_instance_rc(int rc);
int table_vcs_get_request_pci_domain_rc(int rc);
int table_vcs_get_request_target_bdf_rc(int rc);
int table_vcs_get_request_target_type_rc(int rc);
int table_vcs_get_request_pf_index_rc(int rc);
int table_vcs_get_request_vf_index_rc(int rc);
int table_vcs_get_request_bar_index_rc(int rc);
unsigned int table_vcs_get_request_generation_rc(int rc);
unsigned int table_vcs_get_request_route_id_rc(int rc);
unsigned long long table_vcs_get_request_first_index_rc(int rc);
unsigned long long table_vcs_get_request_bar_offset_rc(int rc);
unsigned int table_vcs_get_request_entry_count_rc(int rc);
unsigned int table_vcs_get_request_entry_bytes_rc(int rc);
unsigned int table_vcs_get_request_payload_bytes_rc(int rc);
unsigned int table_vcs_get_request_byte_offset_rc(int rc);
unsigned int table_vcs_get_request_flags_rc(int rc);
unsigned long long table_vcs_get_request_transaction_id_rc(int rc);
unsigned long long table_vcs_get_request_payload_u64_rc(int rc,
                                                        unsigned int word);
int table_vcs_complete_rc(int rc, int status,
                          unsigned long long failed_index,
                          unsigned int committed, int handler_error,
                          unsigned int read_data);
void table_vcs_interrupt_rc(int rc);
void table_vcs_cleanup_rc(int rc);
```

Keep one state object per retained `COSIM_MAX_RCS=4`. The initialization order
is: load and validate map, register handler capabilities, initialize/connect the
client, then activate/publish routes. Connect with `is_server=0`, publish only
a complete valid generation, reassemble all fragments before returning a
request, and require exactly one completion before accepting another request.
The 64-bit payload getter returns eight little-endian bytes and zero-pads the
last partial word; this follows the target branch's scalar DPI pattern and
avoids a new `svOpenArrayHandle` dependency in the default library.

Each RC state filters the shared map to routes whose `target.rc_id` equals that
state's `rc`; it validates handlers and publishes only that subset to the
matching QEMU endpoint. Route IDs remain the stable IDs assigned by the full
validated file, so logs from different RCs still identify the same source
section unambiguously.

Add route/transport/VCS core sources to the standalone library closure in
`scripts/build_cosim_lib.sh` without changing its existing ETH selection.
Cleanup calls `interrupt` before joining or closing.

- [ ] **Step 4: Run GREEN and verify both library forms still export old DPI**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_vcs_core cosim_bridge_vcs && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_table_vcs_core --output-on-failure && \
   cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   OUT=/home/ubuntu/test_cosim/builds/table-sideband-target-build/lib \
   scripts/build_cosim_lib.sh && \
   nm -D /home/ubuntu/test_cosim/builds/table-sideband-target-build/lib/libcosim_bridge.so | \
   grep -E \"bridge_vcs_init_ex_rc|table_vcs_init_rc\"'"
```

Expected: RC isolation passes and both retained and table symbols are exported.

- [ ] **Step 5: Commit**

```bash
git add bridge/vcs/table_vcs_core.c bridge/vcs/table_vcs_core.h \
        bridge/CMakeLists.txt scripts/build_cosim_lib.sh \
        tests/unit/test_table_vcs_core.c tests/unit/CMakeLists.txt
git commit -m "feat(table): add per-RC VCS table client"
```

### Task 6: Add SystemVerilog handler, protection codec and registry types

**Files:**
- Create: `vcs-tb/cosim_table_types.sv`
- Create: `vcs-tb/cosim_table_codec.sv`
- Create: `vcs-tb/cosim_table_handler.sv`
- Create: `vcs-tb/cosim_table_registry.sv`
- Create: `vcs-tb/cosim_table_pkg.sv`
- Create: `tests/sv/test_cosim_table_unit.sv`
- Create: `tests/sv/run_test_cosim_table_unit.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write a failing standalone SV unit test**

The test registers handlers named `vio_notify` and `VIO_NOTIFY`, rejects an
exact duplicate and an empty name, packs bytes LSB-first, and checks:

```systemverilog
codec.protect_entry('{8'hff}, COSIM_TABLE_PROTECTION_PARITY_EVEN, bits);
check(bits.size() == 1 && bits[0] == 1'b0, "even parity");
codec.protect_entry('{8'hff}, COSIM_TABLE_PROTECTION_PARITY_ODD, bits);
check(bits.size() == 1 && bits[0] == 1'b1, "odd parity");
codec.protect_entry('{8'h00}, COSIM_TABLE_PROTECTION_ECC, bits);
check(bits.size() == 5 && {bits[4],bits[3],bits[2],bits[1],bits[0]} == 5'b00000,
      "zero SECDED");
codec.protect_entry('{8'h01}, COSIM_TABLE_PROTECTION_SECDED, bits);
check(bits.size() == 5 && {bits[4],bits[3],bits[2],bits[1],bits[0]} == 5'b10011,
      "one SECDED");
```

Also pass a 128-byte raw entry to prove a 1024-bit table is not truncated.

- [ ] **Step 2: Run on host 53 and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_unit.sh'"
```

Expected: VCS compilation fails because `cosim_table_pkg` is missing.

- [ ] **Step 3: Implement the package contracts**

Use these protection and handler interfaces:

```systemverilog
typedef enum int unsigned {
  COSIM_TABLE_PROTECTION_NONE,
  COSIM_TABLE_PROTECTION_PARITY_EVEN,
  COSIM_TABLE_PROTECTION_PARITY_ODD,
  COSIM_TABLE_PROTECTION_ECC,
  COSIM_TABLE_PROTECTION_SECDED,
  COSIM_TABLE_PROTECTION_CUSTOM
} cosim_table_protection_e;

virtual class cosim_table_handler;
  pure virtual function string get_name();
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
  virtual function void set_codec(cosim_table_codec_base codec);
endclass

virtual class cosim_table_codec_base;
  pure virtual function void protect_entry(
      input byte unsigned raw_data[],
      input cosim_table_protection_e protection,
      output bit protection_bits[]);
endclass
```

Registry keys are exact case-sensitive `get_name()` results. Implement none,
group-wise even/odd parity and generic SECDED with data in non-power-of-two
Hamming positions and overall parity last. `ecc` and `secded` select the same
common SECDED implementation; `custom` requires a non-null user codec. Entry
and table geometry never appears as an SV compile-time constant.

- [ ] **Step 4: Run GREEN on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_unit.sh'"
```

Expected log ends with `COSIM_TABLE_UNIT: ALL PASS` and VCS reports zero errors.

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/cosim_table_types.sv vcs-tb/cosim_table_codec.sv \
        vcs-tb/cosim_table_handler.sv vcs-tb/cosim_table_registry.sv \
        vcs-tb/cosim_table_pkg.sv tests/sv/test_cosim_table_unit.sv \
        tests/sv/run_test_cosim_table_unit.sh tests/integration/CMakeLists.txt
git commit -m "feat(table): add SV handler and protection framework"
```

### Task 7: Run table requests through a per-RC SV service

**Files:**
- Create: `vcs-tb/cosim_table_service.sv`
- Create: `tests/sv/test_cosim_table_service.sv`
- Create: `tests/sv/run_test_cosim_table_service.sh`
- Modify: `bridge/vcs/bridge_vcs.sv`
- Modify: `vcs-tb/cosim_table_pkg.sv`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write a failing service test with DPI doubles**

Deliver a 48-byte request for three 16-byte entries starting at logical index
2. Assert calls occur for indices 2, 3 and 4 with byte-exact data. Inject a
failure at index 3 and assert completion contains
`EXEC_ERROR, committed=1, failed_index=3`. Deliver a read at entry 4 byte
offset 8 and assert exactly one `read_dword()` call and returned DWORD.

Test a write-only route with a handler whose `supports_read()` is false, and a
`write,read` route with the same handler; only the latter activation must fail.
Test HIGH log output contains RC, route, transaction, raw bytes, protection,
handler result, committed count and failed index.

- [ ] **Step 2: Run and verify RED on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_service.sh'"
```

Expected: compilation fails because `cosim_table_service` is absent.

- [ ] **Step 3: Implement service parsing and dispatch**

Add scalar DPI imports for every Task 5 function to
`cosim_bridge_pkg`. The service constructor takes `rc_id`; initialization takes
the registered handlers, `REMOTE_HOST`, `TABLE_PORT_BASE`, the RC instance ID,
and absolute `COSIM_TABLE_MAP` path.

Expose this lifecycle to the runtime facade:

```systemverilog
class cosim_table_service;
  function new(int unsigned rc_id);
  function bit register_handler(
      cosim_table_handler handler,
      cosim_table_protection_e default_protection);
  function int initialize(string remote_host, int table_port_base,
                          int instance_id, string absolute_map_path);
  task run();
  function void request_stop();
  task wait_stopped();
  function void shutdown();
endclass
```

Parse protection overrides exactly:

```systemverilog
case (value)
  "none":        protection = COSIM_TABLE_PROTECTION_NONE;
  "parity_even": protection = COSIM_TABLE_PROTECTION_PARITY_EVEN;
  "parity_odd":  protection = COSIM_TABLE_PROTECTION_PARITY_ODD;
  "ecc":         protection = COSIM_TABLE_PROTECTION_ECC;
  "secded":      protection = COSIM_TABLE_PROTECTION_SECDED;
  "custom":      protection = COSIM_TABLE_PROTECTION_CUSTOM;
  default:        return 1'b0;
endcase
```

Construct the lookup key as
`COSIM_TABLE_PROTECT_<handler.get_name()>`; an absent override retains the
protection supplied during registration. Parse
`+COSIM_TABLE_DUMP_LIMIT=<positive bytes>` and keep every HIGH payload dump
within that bound.

Reconstruct the payload from 64-bit scalar words, slice by route geometry,
dispatch entries sequentially, and complete every accepted request exactly
once. Maintain per-RC/route/handler accepted, entry, byte, success, read and
error counters. `request_stop()` interrupts the C receive; `wait_stopped()`
joins the run task; `shutdown()` cleans C state only after it is quiescent.

- [ ] **Step 4: Run GREEN and compile the retained DPI package**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_service.sh && \
   out=\$(mktemp -d) && cd \"\$out\" && \
   vlogan -full64 -sverilog \
   /home/ubuntu/test_cosim/builds/table-sideband-target-src/bridge/vcs/bridge_vcs.sv'"
```

Expected: service test prints `COSIM_TABLE_SERVICE: ALL PASS`; DPI package parse
succeeds without running a table service.

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/cosim_table_service.sv vcs-tb/cosim_table_pkg.sv \
        bridge/vcs/bridge_vcs.sv tests/sv/test_cosim_table_service.sv \
        tests/sv/run_test_cosim_table_service.sh tests/integration/CMakeLists.txt
git commit -m "feat(table): dispatch per-RC table requests"
```

### Task 8: Add the target-native runtime facade and driver lifecycle hooks

**Files:**
- Create: `vcs-tb/cosim_table_runtime.sv`
- Create: `tests/sv/test_cosim_table_runtime.sv`
- Create: `tests/sv/run_test_cosim_table_runtime.sh`
- Create: `tests/integration/test_table_xrc_source_contract.sh`
- Modify: `vcs-tb/cosim_table_pkg.sv`
- Modify: `vcs-tb/cosim_xrc_pkg.sv`
- Modify: `vcs-tb/cosim_xrc_driver.sv`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write failing runtime and source-order tests**

The SV test registers handlers for RC0 and RC1 before creating services,
rejects an RC/name duplicate, verifies default protection retention, and checks
that disabled runtime creates no service. Run a subprocess with
`+COSIM_TABLE_ENABLE=1` but without `+COSIM`; it must exit nonzero before a TCP
connect attempt.

The source contract extracts `cosim_xrc_driver::run_phase` and asserts:

```text
self_init_bridge
bridge_vcs_is_realized_rc
cosim_table_runtime::start_rc
request_loop
cosim_table_runtime::stop_rc
bridge_vcs_cleanup_ex_rc
```

occur in that order. It also asserts the retained default-off
`cosim_maybe_enable()` early return remains before both factory overrides.

- [ ] **Step 2: Run both tests and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_runtime.sh; \
   tests/integration/test_table_xrc_source_contract.sh'"
```

Expected: missing runtime class and lifecycle calls cause failures.

- [ ] **Step 3: Implement the facade and hook only the cosim driver**

Expose the user-facing API:

```systemverilog
class cosim_table_runtime;
  static function bit register_handler(
      int unsigned rc, cosim_table_handler handler,
      cosim_table_protection_e default_protection =
          COSIM_TABLE_PROTECTION_NONE);
  static function bit enabled();
  static task start_rc(int unsigned rc);
  static task stop_rc(int unsigned rc);
endclass
```

Registration stores handler objects per RC before the environment builds. In
`cosim_maybe_enable()`, evaluate table enable first: if table is enabled and
`+COSIM` is absent, call `$fatal` before any override or connection. Without
either plusarg, preserve the current immediate return.

Place `` `include "cosim_table_pkg.sv" `` before the
`package cosim_xrc_pkg` declaration and import `cosim_table_pkg::*` inside the
package. This preserves the target's two-file user contract: external tops
still compile only `bridge/vcs/bridge_vcs.sv` and
`vcs-tb/cosim_xrc_pkg.sv`, with `vcs-tb` on the include path.

After `self_init_bridge()` and bounded polling of
`bridge_vcs_is_realized_rc(rc_index)`, call `start_rc()`. It parses the same
`REMOTE_HOST`, requires absolute readable `COSIM_TABLE_MAP`, defaults
`TABLE_PORT_BASE=10100`, creates one `cosim_table_service`, calls
`service.register_handler()` for every saved RC handler, initializes it and
forks `service.run()`.
Before the existing bridge cleanup, call `stop_rc()` to interrupt, join and
clean the table client. Do not create or restore `cosim_xrc_test.sv`.

A missing/unreadable map, invalid route, unknown protection override, missing
handler, read-capability mismatch or table transport failure emits a table
configuration error and leaves that RC's table service inactive; it does not
fatal or stop the main `request_loop`. The QEMU endpoint therefore remains
not-ready and Guest writes take the approved frontdoor fallback. The sole
fail-fast combination is table enable without `+COSIM`, because no main bridge
could service the Guest in that configuration.

- [ ] **Step 4: Run GREEN plus the retained minimal integration parse**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_runtime.sh && \
   tests/integration/test_table_xrc_source_contract.sh && \
   tests/sv/run_test_runtime_bdf_utils.sh'"
```

Expected: runtime/source contracts pass and retained runtime BDF test remains
green.

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/cosim_table_runtime.sv vcs-tb/cosim_table_pkg.sv \
        vcs-tb/cosim_xrc_pkg.sv vcs-tb/cosim_xrc_driver.sv \
        tests/sv/test_cosim_table_runtime.sv \
        tests/sv/run_test_cosim_table_runtime.sh \
        tests/integration/test_table_xrc_source_contract.sh \
        tests/integration/CMakeLists.txt
git commit -m "feat(table): bind service lifecycle to xrc driver"
```

### Task 9: Expose a read-only PF0 target snapshot from `cosim-pcie-rc`

**Files:**
- Create: `bridge/qemu/table_target.h`
- Create: `bridge/qemu/table_target.c`
- Create: `tests/unit/test_table_target.c`
- Modify: `bridge/CMakeLists.txt`
- Modify: `qemu-plugin/cosim_pcie_rc.h`
- Modify: `qemu-plugin/cosim_pcie_rc.c:315-322,1362-1718`
- Modify: `tests/unit/CMakeLists.txt`
- Modify: `tests/integration/test_qemu_request_routing_source.sh`

- [ ] **Step 1: Write failing snapshot, generation and source-policy tests**

The unit test creates snapshots for physical BAR owners 0/2/4 and asserts
logical BAR0/BAR1 sizes, PF0 identity, domain/BDF and generation matching. It
rejects PF1, VFs, a zero generation, replaced generation, absent BAR and device
instance mismatch.

Extend the retained QEMU source test to require one PF0 snapshot registry keyed
by `instance_id`, while forbidding a second PF/VF topology array. It must still
assert all existing config/MMIO/DMA requester routing rules.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_target && \
   /home/ubuntu/test_cosim/builds/table-sideband-target-src/tests/integration/test_qemu_request_routing_source.sh'"
```

Expected: test target or snapshot symbols are missing.

- [ ] **Step 3: Add the neutral snapshot and a thin QEMU adapter**

Use a QEMU-independent value type:

```c
typedef struct {
    uint16_t rc_id;
    uint16_t device_instance;
    uint16_t pci_domain;
    uint16_t target_bdf;
    uint32_t generation;
    uint64_t bar_sizes[6];
} cosim_table_target_snapshot_t;

int cosim_table_target_snapshot_valid(
    const cosim_table_target_snapshot_t *snapshot);
int cosim_table_target_matches(
    const cosim_table_target_snapshot_t *snapshot,
    const cosim_table_target_t *target);
```

In `cosim_pcie_rc.c`, register only the successfully realized primary PF0,
keyed by its existing `instance_id`. Derive domain and live BDF from the
`PCIDevice`; copy sizes from the already authoritative topology/BAR contexts.
Assign a nonzero monotonically increasing generation on successful realize,
reset and removal. Export:

```c
bool cosim_pcie_rc_get_table_target(
    uint32_t instance_id, cosim_table_target_snapshot_t *snapshot);
```

Sibling PFs and VFs never register. Removal clears the pointer before freeing
the main bridge. The adapter is read-only and does not discover, realize or
size a BAR itself.

- [ ] **Step 4: Run GREEN plus retained routing contract**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_target && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_table_target --output-on-failure && \
   /home/ubuntu/test_cosim/builds/table-sideband-target-src/tests/integration/test_qemu_request_routing_source.sh'"
```

Expected: target generation cases and all original routing assertions pass.

- [ ] **Step 5: Commit**

```bash
git add bridge/qemu/table_target.c bridge/qemu/table_target.h \
        bridge/CMakeLists.txt qemu-plugin/cosim_pcie_rc.c \
        qemu-plugin/cosim_pcie_rc.h tests/unit/test_table_target.c \
        tests/unit/CMakeLists.txt \
        tests/integration/test_qemu_request_routing_source.sh
git commit -m "feat(table): expose live PF0 target snapshot"
```

### Task 10: Add the asynchronous QEMU table control endpoint

**Files:**
- Create: `qemu-plugin/cosim_table_ctrl.h`
- Create: `qemu-plugin/cosim_table_ctrl.c`
- Create: `bridge/qemu/table_ctrl_lifecycle.h`
- Create: `tests/unit/test_table_lifecycle.c`
- Create: `tests/integration/test_qemu_table_setup_smoke.sh`
- Modify: `Makefile:127-138`
- Modify: `setup.sh:2070-2088`
- Modify: `tests/unit/CMakeLists.txt`
- Modify: `tests/integration/CMakeLists.txt`
- Modify: `tests/integration/test_pcie_launch_topology.sh`

- [ ] **Step 1: Write failing lifecycle and injection tests**

The lifecycle test uses a fake accept/receive worker and asserts realize returns
while the endpoint is not ready, routes transition it to ready, disconnect
returns it to not-ready, and exit interrupts and joins a blocked accept.

The setup smoke creates a fake QEMU tree and requires both setup paths to copy:

```text
qemu-plugin/cosim_table_ctrl.c       -> hw/net/cosim_table_ctrl.c
qemu-plugin/cosim_table_ctrl.h       -> include/hw/net/cosim_table_ctrl.h
bridge/table/*.h                     -> include/hw/net/
bridge/qemu/table_*.h                -> include/hw/net/
```

It runs injection twice and requires exactly one
`system_ss.add(files('cosim_table_ctrl.c'))` line.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_lifecycle && \
   /home/ubuntu/test_cosim/builds/table-sideband-target-src/tests/integration/test_qemu_table_setup_smoke.sh'"
```

Expected: lifecycle and injection fail because the endpoint is absent.

- [ ] **Step 3: Implement the PCI endpoint and background server worker**

Define QOM type `cosim-table-ctrl`, class `PCI_CLASS_OTHERS`, one 4 KiB memory
BAR, and properties:

```text
listen_addr, table_port_base, instance_id, rc_id,
device_instance, timeout_ms, debug
```

Realize validates numeric properties, initializes BAR/core/mutex state, and
starts a worker; it must not block Guest boot while no VCS client or invalid map
exists. The worker creates the table transport with `is_server=1`, accepts one
VCS client, validates a full route generation and then sets READY. Disconnect,
protocol error or cleanup clears READY before destroying the semantic client.

Doorbell handling is serialized. It validates slot index/count, reads the
128-byte header and payload through `pci_dma_read()`, compares every Guest
target identity field with the latest Task 9 snapshot, returns TARGET_GONE on
any mismatch, calls `cosim_table_ctrl_process_slot()` for a matching target,
and writes result then COMPLETE through `pci_dma_write()` before returning.
BAR reads publish magic/version/caps/ready, immutable RC/device identity and
the live target generation. Reset clears DMA programming and bumps target
generation without changing existing `cosim-pcie-rc` state.

Exit order is: clear READY, interrupt table sockets, join worker, finish any
doorbell critical section, destroy client/transport, then destroy BAR/mutex
state.

- [ ] **Step 4: Run GREEN, inject, build QEMU and query help on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_lifecycle && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_table_lifecycle --output-on-failure && \
   cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_qemu_table_setup_smoke.sh && \
   make qemu-device && \
   third_party/qemu/build/qemu-system-x86_64 -device cosim-pcie-rc,help >/dev/null && \
   third_party/qemu/build/qemu-system-x86_64 -device cosim-table-ctrl,help | \
   grep -E \"table_port_base|instance_id|rc_id|device_instance\"'"
```

Expected: lifecycle/injection pass, QEMU links, and both device help queries
succeed.

- [ ] **Step 5: Commit**

```bash
git add qemu-plugin/cosim_table_ctrl.c qemu-plugin/cosim_table_ctrl.h \
        bridge/qemu/table_ctrl_lifecycle.h \
        Makefile setup.sh tests/unit/test_table_lifecycle.c \
        tests/unit/CMakeLists.txt \
        tests/integration/test_qemu_table_setup_smoke.sh \
        tests/integration/test_pcie_launch_topology.sh \
        tests/integration/CMakeLists.txt
git commit -m "feat(table): add asynchronous QEMU control endpoint"
```

### Task 11: Intercept only eligible PF0 table reads

**Files:**
- Create: `tests/unit/test_table_read_decode.c`
- Create: `tests/integration/test_table_read_source_contract.sh`
- Modify: `qemu-plugin/cosim_pcie_rc.c:175-195`
- Modify: `qemu-plugin/cosim_table_ctrl.h`
- Modify: `qemu-plugin/cosim_table_ctrl.c`
- Modify: `tests/unit/CMakeLists.txt`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write failing decode and frontdoor-preservation tests**

Cover 1/2/4-byte non-crossing reads, DWORD alignment, little-endian extraction,
physical BAR0/BAR2 to logical BAR0/BAR1, stride holes and end boundaries.
Reject 8-byte/cross-DWORD reads, PF1, VF, logical BAR2, inactive controller,
write-only route and stale generation.

The source contract extracts `cosim_mmio_read()` and asserts table lookup occurs
before `cosim_mmio_do_read()`. It extracts `cosim_mmio_write()` and requires its
current call to `cosim_mmio_do_write()` with no table call.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_read_decode && \
   /home/ubuntu/test_cosim/builds/table-sideband-target-src/tests/integration/test_table_read_source_contract.sh'"
```

Expected: source interception is missing.

- [ ] **Step 3: Add the read callback before the existing forwarder**

Expose:

```c
cosim_table_status_t cosim_table_ctrl_try_read(
    uint16_t rc_id, uint16_t device_instance,
    const cosim_table_target_t *target,
    uint64_t aligned_bar_offset, uint32_t *returned_dword);
```

At the beginning of `cosim_mmio_read()`, and only when `s->pf_index == 0`, use
the current `CosimBarContext` physical owner, Task 9 snapshot and Task 4 decode
helper. Call the controller only for 1/2/4-byte non-crossing accesses. On
SUCCESS extract the requested bytes and return. On `NOT_READY`, `NO_ROUTE` or
`UNSUPPORTED`, execute the exact existing `cosim_mmio_do_read()` path. On
TIMEOUT, TARGET_GONE, PROTOCOL, UNKNOWN or EXEC_ERROR, log and return all ones
without replay. An 8-byte access bypasses table lookup entirely.

- [ ] **Step 4: Run GREEN, retained routing tests and QEMU build**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_table_read_decode && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_table_read_decode --output-on-failure && \
   cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_table_read_source_contract.sh && \
   tests/integration/test_qemu_request_routing_source.sh && make qemu-device'"
```

Expected: decode/source contracts pass and QEMU links.

- [ ] **Step 5: Commit**

```bash
git add tests/unit/test_table_read_decode.c tests/unit/CMakeLists.txt \
        tests/integration/test_table_read_source_contract.sh \
        tests/integration/CMakeLists.txt qemu-plugin/cosim_pcie_rc.c \
        qemu-plugin/cosim_table_ctrl.c qemu-plugin/cosim_table_ctrl.h
git commit -m "feat(table): intercept eligible PF0 reads"
```

### Task 12: Add the default-off Makefile runtime switch

**Files:**
- Create: `tests/integration/test_table_launch_switch.sh`
- Create: `tests/fixtures/table_default_off_qemu_args.txt`
- Modify: `Makefile:8-280`
- Modify: `tests/integration/CMakeLists.txt`
- Modify: `tests/integration/test_pcie_launch_topology.sh`

- [ ] **Step 1: Capture the target baseline and write failing enabled checks**

Normalize the three baseline dry-run QEMU commands (`login`, `login-multi`,
`file`) by replacing absolute project paths with `<PROJECT>` and save them in
`tests/fixtures/table_default_off_qemu_args.txt`.

The test compares current default/off dry runs byte-for-byte with that fixture.
For `TABLE_BACKDOOR=on TABLE_PORT_BASE=10100`, require exactly one controller per
QEMU process with:

```text
-device cosim-table-ctrl,bus=pcie.0,addr=0x6,
        table_port_base=10100,instance_id=<r>,rc_id=<r>,device_instance=0
```

Require Guest kernel parameter `dpu_snd1.table_backdoor=1`, and table fields in
`cosim-conn.json` only while enabled. Reject unknown switch values, port zero,
overflow, and any collision between table ports and an existing RC's three
main transport ports.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_table_launch_switch.sh'"
```

Expected: enabled-mode assertions fail because `TABLE_BACKDOOR` is not defined.

- [ ] **Step 3: Implement validation and conditional command fragments**

Add dormant defaults:

```make
TABLE_BACKDOOR ?= off
TABLE_PORT_BASE ?= 10100
override TABLE_BACKDOOR := $(value TABLE_BACKDOOR)
override TABLE_PORT_BASE := $(value TABLE_PORT_BASE)
export TABLE_BACKDOOR TABLE_PORT_BASE
```

Validate before `run-qemu`. Define empty off-mode fragments and on-mode
fragments for the controller, kernel argument and descriptor fields. Use the
same `pcie.0,addr=0x6` in every console recipe. For multi-process loops, derive
the table port with the endpoint's `instance_id`; do not place the controller
behind `cosim_rp<N>` and do not add a second root port.

Keep `cosim-pcie-rc` command text, address, `NUM_PFS`, bridge port formula and
ordering unchanged. No route-map option is accepted by QEMU.

- [ ] **Step 4: Run GREEN plus the retained topology suite**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_table_launch_switch.sh && \
   tests/integration/test_pcie_launch_topology.sh'"
```

Expected: default/off matches the baseline fixture, enabled placement is exact,
invalid values are rejected before launch, and retained topology assertions
pass.

- [ ] **Step 5: Commit**

```bash
git add Makefile tests/integration/test_table_launch_switch.sh \
        tests/fixtures/table_default_off_qemu_args.txt \
        tests/integration/test_pcie_launch_topology.sh \
        tests/integration/CMakeLists.txt
git commit -m "feat(table): gate controller at QEMU runtime"
```

### Task 13: Add the transactional Guest controller overlay

**Files:**
- Create: `guest/dpu-table-sideband/cosim_table_ctrl.h`
- Create: `guest/dpu-table-sideband/cosim_table_ctrl.c`
- Create: `guest/dpu-table-sideband/0001-dpu-table-sideband-core.patch`
- Create: `guest/dpu-table-sideband/README.md`
- Create: `scripts/apply_dpu_table_sideband.sh`
- Create: `tests/integration/test_dpu_table_overlay_apply.sh`
- Create: `tests/unit/test_dpu_table_policy.c`
- Modify: `tests/integration/CMakeLists.txt`
- Modify: `tests/unit/CMakeLists.txt`

- [ ] **Step 1: Write failing transaction, fallback and idempotence tests**

Build a synthetic `host-driver-net` tree with the exact anchors expected by the
patch. Assert a missing anchor leaves every original file byte-identical.
Assert a valid tree receives the controller source, shared UAPI headers and
patch, and that a second application changes no checksum. Inject failure after
the first staged file and assert rollback restores the complete tree.

The C policy test checks:

```c
assert(dpu_table_policy(COSIM_TABLE_ST_SUCCESS) == DPU_TABLE_SUCCESS);
assert(dpu_table_policy(COSIM_TABLE_ST_NOT_READY) == DPU_TABLE_FRONTDOOR);
assert(dpu_table_policy(COSIM_TABLE_ST_NO_ROUTE) == DPU_TABLE_FRONTDOOR);
assert(dpu_table_policy(COSIM_TABLE_ST_UNSUPPORTED) == DPU_TABLE_FRONTDOOR);
assert(dpu_table_policy(COSIM_TABLE_ST_SLOT_BUSY) == DPU_TABLE_FRONTDOOR);
assert(dpu_table_policy(COSIM_TABLE_ST_EXEC_ERROR) == DPU_TABLE_ERROR);
assert(dpu_table_policy(COSIM_TABLE_ST_TIMEOUT) == DPU_TABLE_ERROR);
assert(dpu_table_policy(COSIM_TABLE_ST_TARGET_GONE) == DPU_TABLE_ERROR);
```

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_dpu_table_policy && \
   /home/ubuntu/test_cosim/builds/table-sideband-target-src/tests/integration/test_dpu_table_overlay_apply.sh'"
```

Expected: controller policy and apply script are absent.

- [ ] **Step 3: Implement controller discovery, coherent slots and patch 0001**

The overlay builds into `dpu_snd1.ko`; it is not a second module. Add:

```c
enum dpu_table_submit_result {
    DPU_TABLE_FRONTDOOR = 0,
    DPU_TABLE_SUCCESS = 1,
    DPU_TABLE_ERROR = 2,
};
enum dpu_table_write_order {
    DPU_TABLE_LOW_TO_HIGH = 0,
    DPU_TABLE_HIGH_TO_LOW = 1,
};
enum dpu_table_submit_result dpu_table_submit(
    struct dpu_hw *hw, unsigned int logical_bar, u64 offset,
    const void *data, u32 bytes, enum dpu_table_write_order order);
enum dpu_table_submit_result dpu_table_submit_batch(
    struct dpu_hw *hw, unsigned int logical_bar, u64 first_offset,
    const void *entries, u32 entry_bytes, u32 stride_bytes,
    u32 entry_count, enum dpu_table_write_order order);
```

Register a second PCI driver for `1af4:10f0` from the existing module init/exit
path. Probe enables bus mastering, requests/maps controller BAR0, negotiates a
64-bit then 32-bit DMA mask, allocates four coherent slots, programs exact DMA
base/bytes/count and adds one controller per PCI domain. Since the controller
is at root bus address 0x6 while the DUT PF is behind address 0x3, lookup is by
PCI domain and controller RC/device identity, not common root-port ancestry.
Reject a duplicate controller in one domain.

With `table_backdoor=false`, return FRONTDOOR before controller lookup or MMIO.
Accept PF0 and logical BAR0/BAR1 only. Claim a slot with `cmpxchg`, fill the
live target BDF plus controller generation, publish READY with release ordering,
ring the doorbell, acquire COMPLETE, map status through the tested policy, and
release FREE. Hard errors log committed and failed index and never replay.

The apply script validates all numbered patches with `patch --dry-run` against
a staged copy, applies the complete stack there, and atomically replaces only
files under the supplied driver tree. It never writes the repository or the
reference release while validating.

- [ ] **Step 4: Run GREEN and build patch 0001 from a clean copy on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_dpu_table_policy && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_dpu_table_policy --output-on-failure && \
   cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_dpu_table_overlay_apply.sh && \
   work=\$(mktemp -d /home/ubuntu/test_cosim/builds/dpu-table-core.XXXXXX) && \
   cp -a /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net \"\$work/\" && \
   scripts/apply_dpu_table_sideband.sh \"\$work/host-driver-net\" && \
   make -C \"\$work/host-driver-net\" modules && \
   modinfo \"\$work/host-driver-net/dpu_snd1.ko\" | grep table_backdoor'"
```

Expected: policy/transaction tests pass and the patched module builds with a
`table_backdoor` parameter.

- [ ] **Step 5: Commit**

```bash
git add guest/dpu-table-sideband scripts/apply_dpu_table_sideband.sh \
        tests/integration/test_dpu_table_overlay_apply.sh \
        tests/integration/CMakeLists.txt tests/unit/test_dpu_table_policy.c \
        tests/unit/CMakeLists.txt
git commit -m "feat(guest): add transactional table controller overlay"
```

### Task 14: Route complete driver buffers and QID batches through the overlay

**Files:**
- Create: `guest/dpu-table-sideband/cosim_table_batch_core.h`
- Create: `guest/dpu-table-sideband/0002-dpu-table-complete-buffers.patch`
- Create: `guest/dpu-table-sideband/0003-dpu-qid-table-batch.patch`
- Create: `tests/fixtures/dpu_qid_reference/af_mng.c`
- Create: `tests/unit/test_dpu_table_batch.c`
- Create: `tests/integration/test_dpu_complete_buffer_patch.sh`
- Create: `tests/integration/test_dpu_qid_batch_patch.sh`
- Modify: `guest/dpu-table-sideband/README.md`
- Modify: `tests/unit/CMakeLists.txt`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write failing split, order and source-coverage tests**

The batch unit test submits entry widths 16, 32 and 128 bytes, multiple depths,
and a payload larger than one slot. Assert splitting never divides an entry,
the next request offset advances by `entries_sent * stride_bytes`, and a hard
error stops without submitting remaining entries. Assert FRONTDOOR preserves
the requested low-to-high or high-to-low DWORD order.

The complete-buffer source test requires patched definitions of both
`wr32_for_each` and `wr32_for_high_order` to call `dpu_table_submit()` before
their original loops. It counts all call sites in the supplied release and
proves each still resolves through one of those wrappers. The QID test anchors
the existing write/delay/read/retry loop and requires a whole-table batch path
for insertion and remove/compaction.

- [ ] **Step 2: Run and verify RED**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_dpu_table_batch && \
   cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_dpu_complete_buffer_patch.sh && \
   tests/integration/test_dpu_qid_batch_patch.sh'"
```

Expected: batch helper and patches 0002/0003 are absent.

- [ ] **Step 3: Implement generic entry submission and QID whole-table fast path**

`cosim_table_batch_core.h` is userspace-testable and accepts an injected
single-request callback. Use checked multiplication/addition for total bytes,
offset and entry count. Pack contiguous raw entry bytes; stride exists only in
logical address calculation and does not create payload holes.

Patch 0002 replaces the two central DWORD-order macros/functions with inline
wrappers that receive the original complete buffer and byte count:

```c
result = dpu_table_submit(hw, logical_bar, offset, buffer, bytes, order);
if (result == DPU_TABLE_SUCCESS)
    return;
if (result == DPU_TABLE_ERROR)
    return; /* error already logged; no frontdoor replay */
/* FRONTDOOR executes the original writel loop in its original order. */
```

This attempts semantic submission for every complete-buffer table call site;
the VCS route map decides which addresses are backdoored, so no table list is
hard-coded in the Guest.

Patch 0003 calls `dpu_table_submit_batch()` for the complete QID/vio-notify
array in both insertion and remove/compaction. On SUCCESS it skips the original
write/delay/readback/retry loop; on FRONTDOOR it executes that loop unchanged;
on ERROR it returns without replay. Single-command structures that do not own a
complete entry remain on their existing path.

- [ ] **Step 4: Run GREEN and build the full patch stack on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --target test_dpu_table_batch && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   -R test_dpu_table_batch --output-on-failure && \
   cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/integration/test_dpu_complete_buffer_patch.sh && \
   tests/integration/test_dpu_qid_batch_patch.sh && \
   work=\$(mktemp -d /home/ubuntu/test_cosim/builds/dpu-table-full.XXXXXX) && \
   cp -a /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net \"\$work/\" && \
   scripts/apply_dpu_table_sideband.sh \"\$work/host-driver-net\" && \
   make -C \"\$work/host-driver-net\" modules && \
   nm \"\$work/host-driver-net/dpu_snd1.ko\" | \
   grep -E \"dpu_table_submit(_batch)?\"'"
```

Expected: all widths/order/status cases pass, patch coverage includes every
complete-buffer wrapper, and the module exports both submit functions.

- [ ] **Step 5: Commit**

```bash
git add guest/dpu-table-sideband/cosim_table_batch_core.h \
        guest/dpu-table-sideband/0002-dpu-table-complete-buffers.patch \
        guest/dpu-table-sideband/0003-dpu-qid-table-batch.patch \
        guest/dpu-table-sideband/README.md \
        tests/fixtures/dpu_qid_reference/af_mng.c \
        tests/unit/test_dpu_table_batch.c tests/unit/CMakeLists.txt \
        tests/integration/test_dpu_complete_buffer_patch.sh \
        tests/integration/test_dpu_qid_batch_patch.sh \
        tests/integration/CMakeLists.txt
git commit -m "feat(guest): submit complete table buffers"
```

### Task 15: Add the integration kit, multi-RAM reference and usage docs

**Files:**
- Create: `vcs-tb/examples/table_routes.ini`
- Create: `vcs-tb/examples/vio_notify_mock_handler.sv`
- Create: `tests/sv/test_cosim_table_multiram.sv`
- Create: `tests/sv/run_test_cosim_table_multiram.sh`
- Modify: `docs/COSIM-MINIMAL-INTEGRATION.md`
- Modify: `docs/COSIM-VCS-INTEGRATION.md`
- Modify: `docs/COSIM-C-BUILD.md`
- Modify: `docs/VCS-INTEGRATION-GUIDE.md`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write a failing multi-table/multi-RAM handler test**

Register `vio_notify` and `flat_table` for RC0. Route two disjoint address
ranges to `vio_notify` and one range to `flat_table`; omit `operations` on one
route to prove the default is write-only. For indices 0, 15 and 255, assert
one/two/three deposits and these selections:

```text
l3_bank      = index % 4
l3_ram_index = index / 4
l2_bank      = ((index + 1) / 16 - 1) % 4
l2_ram_index = ((index - 15) / 16) / 4
l1_bank      = ((index + 1) / 256 - 1) % 4
l1_ram_index = ((index - 255) / 256) / 4
```

Run none, parity and SECDED protection. Assert HIGH output shows the incoming
raw bytes, selected protection, final protected value, logical index and every
mock RAM destination. Add a readable mock route and verify one 4-byte callback.

- [ ] **Step 2: Run and verify RED on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_multiram.sh'"
```

Expected: reference handler and routes are absent.

- [ ] **Step 3: Implement the mock/reference handler and document user hooks**

The mock stores values in arrays and contains no DUT hierarchy. Keep physical
deposit/read operations in overridable tasks so a production subclass can call
the user's `ST_WRITE_DEPOSIT_RAM(index, value, path_macro)` forms. Index routing
and protection selection remain in VCS. The production handler invokes the
selected common or custom codec, owns its DUT-specific data/protection
concatenation, and owns the actual RAM macros and read backend.

Document the compile-once/runtime-select flow:

```systemverilog
cosim_xrc_pkg::cosim_maybe_enable();
handler[0] = new("vio_notify");
if (!cosim_table_runtime::register_handler(
        0, handler[0], COSIM_TABLE_PROTECTION_NONE))
  `uvm_fatal("TABLE", "RC0 handler registration failed")
```

```bash
TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 make run-qemu
./simv +COSIM +REMOTE_HOST=<QEMU-host> +PORT_BASE=9100 \
  +COSIM_TABLE_ENABLE=1 +COSIM_TABLE_MAP=/absolute/routes.ini \
  +TABLE_PORT_BASE=10100 +COSIM_TABLE_LOG=high \
  +COSIM_TABLE_PROTECT_vio_notify=none
insmod dpu_snd1.ko table_backdoor=1
```

Explain that the protection plusarg changes only the named handler's packing;
it does not enable the feature or reads. Explain omitted `operations` means
write and only `operations=write,read` enables the 4-byte callback.

- [ ] **Step 4: Run GREEN and validate documented commands**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_multiram.sh && \
   tests/integration/test_workflow_command_contracts.sh'"
```

Expected: multi-RAM test prints `COSIM_TABLE_MULTIRAM: ALL PASS`, documented
interfaces match source and retained workflow checks pass.

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/examples/table_routes.ini \
        vcs-tb/examples/vio_notify_mock_handler.sv \
        tests/sv/test_cosim_table_multiram.sv \
        tests/sv/run_test_cosim_table_multiram.sh \
        docs/COSIM-MINIMAL-INTEGRATION.md docs/COSIM-VCS-INTEGRATION.md \
        docs/COSIM-C-BUILD.md docs/VCS-INTEGRATION-GUIDE.md \
        tests/integration/CMakeLists.txt
git commit -m "docs(table): add target integration kit"
```

### Task 16: Run complete target, QEMU, VCS and Guest verification

**Files:**
- Create: `docs/validation/2026-08-18-table-sideband-target-validation.md`
- Modify only a file from Tasks 1-15 when a reproducible test identifies a defect in that file.

- [ ] **Step 1: Run the complete CTest suite on host 53**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cmake -S /home/ubuntu/test_cosim/builds/table-sideband-target-src \
   -B /home/ubuntu/test_cosim/builds/table-sideband-target-build -DCMAKE_BUILD_TYPE=Debug && \
   cmake --build /home/ubuntu/test_cosim/builds/table-sideband-target-build -j\$(nproc) && \
   ctest --test-dir /home/ubuntu/test_cosim/builds/table-sideband-target-build \
   --output-on-failure'"
```

Expected: all 45 retained baseline tests and every added table test pass with
zero failures.

- [ ] **Step 2: Prove default-off and unsupported-target behavior**

Run `test_table_launch_switch.sh`, `test_pcie_launch_topology.sh`,
`test_qemu_request_routing_source.sh`, and `test_table_read_source_contract.sh`.
Capture normalized off-mode commands. Assert no table device, table port,
Guest parameter, descriptor field, route load, handler or table socket appears.
Assert PF1, VF, BAR beyond logical 1, route miss, write-only read and 8-byte read
all reach the original target code path.

- [ ] **Step 3: Build QEMU and run device-level smoke checks**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   make qemu-device && \
   third_party/qemu/build/qemu-system-x86_64 -device cosim-pcie-rc,help >/dev/null && \
   third_party/qemu/build/qemu-system-x86_64 -device cosim-table-ctrl,help >/dev/null && \
   tests/integration/test_qemu_table_setup_smoke.sh && \
   tests/integration/test_table_launch_switch.sh'"
```

Expected: QEMU 9.2 builds, both device types exist, and enabled commands place
the controller exactly at `bus=pcie.0,addr=0x6`.

- [ ] **Step 4: Run every table and retained VCS source runner**

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/builds/table-sideband-target-src && \
   tests/sv/run_test_cosim_table_unit.sh && \
   tests/sv/run_test_cosim_table_service.sh && \
   tests/sv/run_test_cosim_table_runtime.sh && \
   tests/sv/run_test_cosim_table_multiram.sh && \
   tests/sv/run_test_runtime_bdf_utils.sh && \
   tests/sv/run_test_dpu_501x_profile.sh && \
   tests/sv/run_test_cosim_cpl_payload_codec.sh'"
```

Expected: every runner exits zero, every table runner prints `ALL PASS`, and
VCS reports zero UVM errors/fatals. Compile the retained PCIe TL/Xilinx cosim
filelist without adding a production DUT top:

```bash
sshpass -e ssh ubuntu@10.11.10.53 \
  "bash -lic 'src=/home/ubuntu/test_cosim/builds/table-sideband-target-src; \
   out=/home/ubuntu/test_cosim/builds/table-sideband-target-build/vcs-cosim; \
   mkdir -p \"\$out\" && cd \"\$src\" && \
   OUT=/home/ubuntu/test_cosim/builds/table-sideband-target-build/lib \
   scripts/build_cosim_lib.sh && \
   vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
   -CFLAGS \"-I\$src/bridge/common -I\$src/bridge/vcs -I\$src/bridge/table\" \
   -LDFLAGS \"-Wl,--whole-archive \
   /home/ubuntu/test_cosim/builds/table-sideband-target-build/lib/libcosim_bridge.a \
   -Wl,--no-whole-archive -lrt -lpthread\" \
   -Mdir=\"\$out/csrc\" -f pcie_tl_vip/sim/filelist_cosim.f \
   -o \"\$out/simv_cosim\" -l \"\$out/compile.log\"'"
```

Expected: VCS links `simv_cosim` with both retained bridge and table DPI symbols.

- [ ] **Step 5: Rebuild the complete Guest patch stack**

Create a fresh build-directory copy of the specified release, apply the overlay
once, apply it again to prove idempotence, build `dpu_snd1.ko`, inspect
`table_backdoor`, and run the batch/policy tests. Do not modify the release
directory itself. Expected: both apply runs succeed, the module builds, and
single-entry plus batch symbols are present.

- [ ] **Step 6: Exercise deterministic completion and two-RC isolation tests**

Run C/QEMU-independent integration harnesses for SUCCESS, NOT_READY, NO_ROUTE,
UNSUPPORTED, local SLOT_BUSY, partial EXEC_ERROR, TIMEOUT, TARGET_GONE and
PROTOCOL. Assert only approved statuses replay. Run RC0/RC1 concurrently with
the same route offset but different values and assert each VCS service, handler,
port and mock RAM sees only its own request.

Run the live QEMU controller with no VCS table client and with an invalid VCS
map; in both cases the controller remains not-ready while the main QEMU/VCS
bridge remains usable. This proves configuration failure falls back rather than
breaking the original target path.

- [ ] **Step 7: Record evidence, review and commit validation**

Record exact commits, command lines, test counts, QEMU help, module metadata,
status/replay results and two-RC evidence in
`docs/validation/2026-08-18-table-sideband-target-validation.md`. State that
mock handlers validate integration only; real DUT deposits require the user's
production handler, matching Guest image and DUT hierarchy.

Run:

```bash
git diff bca79aaa6a54ecb881bb0fdff73245216492bc93...HEAD --check
git status --short
```

Then use `superpowers:requesting-code-review` for specification compliance and
code quality. Resolve every critical or important finding and rerun affected
tests before committing:

```bash
git add docs/validation/2026-08-18-table-sideband-target-validation.md
git commit -m "test(table): record target-native validation"
```

## Final integration gate

Do not merge or push until all of these are true:

1. Full host-53 CTest has zero failures and includes the retained 45-test baseline.
2. Default/off normalized QEMU commands match the target baseline exactly.
3. Both QEMU device help queries and the injected QEMU 9.2 build pass.
4. All standalone table SV and retained target VCS compile tests pass on host 53.
5. The complete Guest overlay applies transactionally and its module builds.
6. SUCCESS, safe fallback, partial EXEC_ERROR, TIMEOUT and two-RC isolation have deterministic evidence.
7. PF1/VF/non-route/8-byte accesses retain their original frontdoor behavior.
8. No deleted target architecture file, production DUT path, build product or credential is tracked.
9. Independent specification and code-quality reviews have no open critical or important issue.
