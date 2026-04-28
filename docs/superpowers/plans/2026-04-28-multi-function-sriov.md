# Multi-Function SR-IOV + MSI-X Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend cosim-platform PCIe layer to support 4 PF + 1024 VF with SR-IOV, MSI-X, configurable BAR/tag from VIP side.

**Architecture:** VIP func_manager is the single source of truth. QEMU queries topology at realize time via bridge, auto-creates PF/VF devices using QEMU's native SR-IOV framework. Single bridge connection with BDF-based TLP routing.

**Tech Stack:** C (QEMU plugin, bridge library), SystemVerilog/UVM (VIP, testbench), DPI-C (bridge-VCS interface)

**Design Spec:** `docs/superpowers/specs/2026-04-28-multi-function-sriov-design.md`

---

## File Structure

### New Files
| File | Responsibility |
|------|---------------|
| `qemu-plugin/cosim_pcie_pf.c` | PF device model (SR-IOV capable) |
| `qemu-plugin/cosim_pcie_pf.h` | PF device header |
| `qemu-plugin/cosim_pcie_vf.c` | VF device model (auto-created by QEMU SR-IOV framework) |
| `qemu-plugin/cosim_pcie_vf.h` | VF device header |
| `bridge/common/cosim_topology.h` | Topology query/response structures |

### Modified Files
| File | Changes |
|------|---------|
| `bridge/common/cosim_types.h` | Extend tlp/cpl/msi/dma structs with BDF fields; tag to uint16_t |
| `bridge/common/shm_layout.h` | Expand SHM to 16MB |
| `bridge/common/shm_layout.c` | Update ring buffer sizes |
| `bridge/common/cosim_transport.h` | Add topology/VF event to transport interface |
| `bridge/common/transport_tcp.c` | New TCP message types for topology/VF events |
| `bridge/common/transport_shm.c` | Topology via ctrl region |
| `bridge/qemu/bridge_qemu.h` | Add topology query API, tag_mask |
| `bridge/qemu/bridge_qemu.c` | Implement topology query, BDF-aware TLP |
| `bridge/vcs/bridge_vcs.c` | DPI-C topology export, BDF in send/recv |
| `bridge/qemu/irq_poller.c` | MSI-X routing by requester_id |
| `bridge/common/trace_log.c` | Log BDF fields |
| `pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv` | Delegate to func_manager, multi-BDF |
| `pcie_tl_vip/src/shared/pcie_tl_func_manager.sv` | BAR config, MSI-X, topology DPI-C |
| `pcie_tl_vip/src/shared/pcie_tl_sriov_cap.sv` | VF BAR size fields |
| `vcs-tb/cosim_rc_driver.sv` | Multi-BDF TLP routing |
| `vcs-tb/glue_if_to_stub.sv` | Accept func_id from driver |
| `vcs-tb/pcie_ep_stub.sv` | Sparse multi-function register model |
| `vcs-tb/cosim_vip_top.sv` | Wire func_id signals |
| `vcs-tb/cosim_test.sv` | Multi-PF/VF plusarg configuration |
| `Makefile` | New build targets |

---

## Task 1: Create Feature Branch

**Files:** None (git only)

- [ ] **Step 1: Create and switch to feature branch**

```bash
cd /home/ubuntu/ryan/software/cosim-platform
git checkout -b feature/multi-function-sriov
```

- [ ] **Step 2: Verify branch**

```bash
git branch --show-current
```
Expected: `feature/multi-function-sriov`

- [ ] **Step 3: Initial commit**

```bash
git commit --allow-empty -m "feat: start multi-function SR-IOV branch"
```

---

## Task 2: Extend Bridge Types (cosim_types.h)

**Files:**
- Modify: `bridge/common/cosim_types.h:55-135`

- [ ] **Step 1: Add new sync message types**

In `bridge/common/cosim_types.h`, add after line 66 (after existing `SYNC_MSG_*` enum entries):

```c
    SYNC_MSG_QUERY_TOPOLOGY = 0x10,
    SYNC_MSG_TOPOLOGY_RESP  = 0x11,
    SYNC_MSG_VF_EVENT       = 0x12,
```

- [ ] **Step 2: Extend tlp_entry_t**

Replace the existing `tlp_entry_t` (lines 73-87) with:

```c
typedef struct {
    uint8_t   type;
    uint8_t   _pad_type;
    uint16_t  tag;              /* 16-bit: supports 5/8/10-bit tag */
    uint16_t  requester_id;     /* sender BDF [15:8]=Bus [7:3]=Dev [2:0]=Func */
    uint16_t  target_bdf;       /* CfgRd/CfgWr target BDF */
    uint16_t  len;              /* DW count */
    uint8_t   msg_code;
    uint8_t   atomic_op_size;
    uint16_t  vendor_id;
    uint64_t  addr;
    uint8_t   data[64];
    uint64_t  dma_offset;
    uint64_t  timestamp;
    uint8_t   first_be;
    uint8_t   last_be;
    uint8_t   _pad_end[2];
} __attribute__((packed)) tlp_entry_t;
```

- [ ] **Step 3: Extend cpl_entry_t**

Replace existing `cpl_entry_t` (lines 91-101) with:

```c
typedef struct {
    uint8_t   type;
    uint8_t   status;
    uint16_t  tag;              /* 16-bit (matches request tag width) */
    uint16_t  requester_id;     /* original requester BDF */
    uint16_t  completer_id;     /* completer BDF */
    uint32_t  len;
    uint8_t   data[64];
    uint64_t  timestamp;
} __attribute__((packed)) cpl_entry_t;
```

- [ ] **Step 4: Extend dma_req_t**

Replace existing `dma_req_t` (lines 109-118) with:

```c
typedef struct {
    uint16_t  requester_id;     /* DMA initiator BDF */
    uint8_t   direction;
    uint8_t   tag;
    uint32_t  len;
    uint64_t  host_addr;
    uint64_t  dma_offset;
    uint64_t  timestamp;
} __attribute__((packed)) dma_req_t;
```

- [ ] **Step 5: Extend msi_event_t**

Replace existing `msi_event_t` (lines 129-133) with:

```c
typedef struct {
    uint16_t  requester_id;     /* which Function triggered MSI-X */
    uint16_t  vector;           /* MSI-X vector number (max 2048) */
    uint32_t  _pad0;
    uint64_t  timestamp;
} __attribute__((packed)) msi_event_t;
```

- [ ] **Step 6: Update static assertions**

```c
_Static_assert(sizeof(msi_event_t) == 16, "msi_event_t must be 16 bytes");
_Static_assert(sizeof(dma_req_t) == 32, "dma_req_t must be 32 bytes");
```

- [ ] **Step 7: Compile to identify downstream breakage**

```bash
cd /home/ubuntu/ryan/software/cosim-platform
mkdir -p build && cd build && cmake ../bridge && make -j$(nproc) 2>&1 | head -50
```

Expected: Compilation errors from old field references. Fixed in Task 5.

- [ ] **Step 8: Commit**

```bash
git add bridge/common/cosim_types.h
git commit -m "feat: extend bridge types with BDF fields for multi-function SR-IOV"
```

---

## Task 3: Create Topology Structures (cosim_topology.h)

**Files:**
- Create: `bridge/common/cosim_topology.h`

- [ ] **Step 1: Create topology header**

```c
#ifndef COSIM_TOPOLOGY_H
#define COSIM_TOPOLOGY_H

#include <stdint.h>

#define COSIM_MAX_PFS       8
#define COSIM_MAX_BARS      6

/* Tag width encoding */
#define TAG_WIDTH_5BIT      0
#define TAG_WIDTH_8BIT      1
#define TAG_WIDTH_10BIT     2

typedef struct {
    uint8_t  num_pfs;
    uint8_t  tag_width;       /* TAG_WIDTH_5BIT / 8BIT / 10BIT */
    uint8_t  _pad[2];
} __attribute__((packed)) topology_header_t;

typedef struct {
    uint16_t bdf;
    uint16_t num_vfs;
    uint16_t vf_device_id;
    uint16_t vendor_id;
    uint16_t device_id;
    uint16_t msix_vectors;
    uint16_t vf_msix_vectors;
    uint16_t _pad;
    uint64_t pf_bar_size[COSIM_MAX_BARS];
    uint64_t vf_bar_size[COSIM_MAX_BARS];
} __attribute__((packed)) pf_topology_t;

typedef struct {
    topology_header_t header;
    pf_topology_t     pfs[COSIM_MAX_PFS];
} __attribute__((packed)) topology_resp_t;

typedef struct {
    uint8_t  event_type;      /* 0=enable, 1=disable */
    uint8_t  pf_index;
    uint16_t num_vfs;
} __attribute__((packed)) vf_event_t;

#define VF_EVENT_ENABLE     0
#define VF_EVENT_DISABLE    1

static inline uint16_t tag_width_to_mask(uint8_t tag_width) {
    switch (tag_width) {
    case TAG_WIDTH_5BIT:  return 0x001F;
    case TAG_WIDTH_8BIT:  return 0x00FF;
    case TAG_WIDTH_10BIT: return 0x03FF;
    default:              return 0x00FF;
    }
}

#endif /* COSIM_TOPOLOGY_H */
```

- [ ] **Step 2: Commit**

```bash
git add bridge/common/cosim_topology.h
git commit -m "feat: add topology query/response structures"
```

---

## Task 4: Expand SHM Layout

**Files:**
- Modify: `bridge/common/shm_layout.h:9-25`
- Modify: `bridge/common/shm_layout.c`

- [ ] **Step 1: Update SHM size constants in shm_layout.h**

Replace lines 9-25 with:

```c
#define COSIM_SHM_TOTAL_SIZE      (16 * 1024 * 1024)

#define COSIM_SHM_CTRL_OFFSET     0x000000
#define COSIM_SHM_CTRL_SIZE       0x001000        /*   4KB */

#define COSIM_SHM_REQ_OFFSET      0x001000
#define COSIM_SHM_REQ_SIZE        0x100000        /*   1MB */

#define COSIM_SHM_CPL_OFFSET      0x101000
#define COSIM_SHM_CPL_SIZE        0x100000        /*   1MB */

#define COSIM_SHM_DMA_REQ_OFFSET  0x201000
#define COSIM_SHM_DMA_REQ_SIZE    0x040000        /* 256KB */

#define COSIM_SHM_DMA_CPL_OFFSET  0x241000
#define COSIM_SHM_DMA_CPL_SIZE    0x040000        /* 256KB */

#define COSIM_SHM_MSI_OFFSET      0x281000
#define COSIM_SHM_MSI_SIZE        0x010000        /*  64KB */

#define COSIM_SHM_DMA_BUF_OFFSET  0x291000
```

- [ ] **Step 2: Verify shm_layout.c uses macros, fix any hardcoded values**

Read `bridge/common/shm_layout.c` and confirm all ring_buf_init calls reference `COSIM_SHM_*` macros.

- [ ] **Step 3: Commit**

```bash
git add bridge/common/shm_layout.h bridge/common/shm_layout.c
git commit -m "feat: expand SHM layout to 16MB for multi-function support"
```

---

## Task 5: Fix Bridge Library Compilation (Adapt to New Types)

**Files:**
- Modify: `bridge/qemu/bridge_qemu.h:14` (next_tag uint8_t -> uint16_t)
- Modify: `bridge/qemu/bridge_qemu.c` (tag references)
- Modify: `bridge/vcs/bridge_vcs.c` (field references, DPI-C signatures)
- Modify: `bridge/qemu/irq_poller.c` (msi_event_t fields)
- Modify: `bridge/common/transport_tcp.c` (message sizes auto-adapt)
- Modify: `bridge/common/trace_log.c` (format strings)

- [ ] **Step 1: Fix bridge_qemu.h**

In `bridge/qemu/bridge_qemu.h` line 14, change:

```c
    uint16_t     next_tag;         /* was uint8_t */
    uint16_t     tag_mask;         /* NEW: from topology tag_width */
```

- [ ] **Step 2: Fix bridge_qemu.c**

Update `bridge_send_tlp()`:
- Initialize `req->requester_id = 0; req->target_bdf = 0;` for default path.
- Tag assignment: `req->tag = (ctx->next_tag++) & ctx->tag_mask;`

Update `bridge_wait_completion()`:
- `cpl.tag` comparison works with uint16_t already.
- Add `cpl.requester_id` to debug log.

- [ ] **Step 3: Fix bridge_vcs.c**

Update DPI-C exports to match new struct fields:
- `bridge_vcs_send_completion`: add `requester_id`, `completer_id` params.
- `bridge_vcs_send_msi`: `msi_event_t` now has `requester_id` (uint16_t) and `vector` (uint16_t).
- `g_tlp_cache[]` auto-adapts since it stores `tlp_entry_t`.

- [ ] **Step 4: Fix irq_poller.c**

Update MSI callback dispatch:
- `ev.vector` is now `uint16_t` (was `uint32_t`).
- Pass `ev.requester_id` to callback.

- [ ] **Step 5: Fix trace_log.c**

Update format strings:
- `trace_log_tlp()`: add `req_id=0x%04x tgt_bdf=0x%04x`.
- `trace_log_cpl()`: add `req_id=0x%04x cpl_id=0x%04x`.
- `trace_log_msi()`: add `req_id=0x%04x`.

- [ ] **Step 6: Compile successfully**

```bash
cd /home/ubuntu/ryan/software/cosim-platform/build && cmake ../bridge && make -j$(nproc)
```

Expected: Clean compilation, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add bridge/
git commit -m "fix: adapt all bridge code to extended type definitions"
```

---

## Task 6: Add Topology Query to Bridge (QEMU + Transport)

**Files:**
- Modify: `bridge/common/cosim_transport.h`
- Modify: `bridge/common/transport_tcp.c`
- Modify: `bridge/common/transport_shm.c`
- Modify: `bridge/qemu/bridge_qemu.h`
- Modify: `bridge/qemu/bridge_qemu.c`

- [ ] **Step 1: Add topology methods to transport interface**

In `bridge/common/cosim_transport.h`, add to `cosim_transport_t`:

```c
    int  (*send_topology)(cosim_transport_t *t, const topology_resp_t *topo);
    int  (*recv_topology)(cosim_transport_t *t, topology_resp_t *topo);
    int  (*send_vf_event)(cosim_transport_t *t, const vf_event_t *ev);
    int  (*recv_vf_event)(cosim_transport_t *t, vf_event_t *ev);
```

- [ ] **Step 2: Implement TCP topology in transport_tcp.c**

Add new TCP message type defines:

```c
#define TCP_MSG_QUERY_TOPOLOGY  0x20
#define TCP_MSG_TOPOLOGY_RESP   0x21
#define TCP_MSG_VF_EVENT        0x22
```

Add implementations:

```c
static int tcp_send_topology(cosim_transport_t *t, const topology_resp_t *topo) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->ctrl_fd, TCP_MSG_TOPOLOGY_RESP, topo, sizeof(*topo));
}

static int tcp_recv_topology(cosim_transport_t *t, topology_resp_t *topo) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_TOPOLOGY_RESP) return -1;
    return tcp_recv_all(p->ctrl_fd, topo, sizeof(*topo));
}

static int tcp_send_vf_event(cosim_transport_t *t, const vf_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    return tcp_send_msg(p->ctrl_fd, TCP_MSG_VF_EVENT, ev, sizeof(*ev));
}

static int tcp_recv_vf_event(cosim_transport_t *t, vf_event_t *ev) {
    transport_tcp_priv_t *p = (transport_tcp_priv_t *)t->priv;
    tcp_msg_hdr_t hdr;
    if (tcp_recv_hdr(p->ctrl_fd, &hdr) < 0) return -1;
    if (hdr.msg_type != TCP_MSG_VF_EVENT) return -1;
    return tcp_recv_all(p->ctrl_fd, ev, sizeof(*ev));
}
```

Wire into vtable in `transport_tcp_create()`.

- [ ] **Step 3: Add topology API to bridge_qemu.h**

```c
#include "cosim_topology.h"

int  bridge_query_topology(bridge_ctx_t *ctx, topology_resp_t *topo);
int  bridge_send_tlp_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                          uint16_t requester_id, uint16_t target_bdf);
int  bridge_send_tlp_and_wait_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                                   cpl_entry_t *cpl,
                                   uint16_t requester_id, uint16_t target_bdf);
```

- [ ] **Step 4: Implement in bridge_qemu.c**

```c
int bridge_query_topology(bridge_ctx_t *ctx, topology_resp_t *topo)
{
    if (ctx->transport) {
        sync_msg_t msg = { .type = SYNC_MSG_QUERY_TOPOLOGY };
        ctx->transport->send_sync(ctx->transport, &msg);
        return ctx->transport->recv_topology(ctx->transport, topo);
    } else {
        sync_msg_t msg = { .type = SYNC_MSG_QUERY_TOPOLOGY };
        sock_sync_send(ctx->sock_fd, &msg);
        sync_msg_t resp;
        sock_sync_recv(ctx->sock_fd, &resp);
        if (resp.type != SYNC_MSG_TOPOLOGY_RESP) return -1;
        memcpy(topo, (uint8_t *)ctx->shm.ctrl + sizeof(cosim_ctrl_t),
               sizeof(topology_resp_t));
        return 0;
    }
}

int bridge_send_tlp_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                         uint16_t requester_id, uint16_t target_bdf)
{
    req->requester_id = requester_id;
    req->target_bdf   = target_bdf;
    return bridge_send_tlp(ctx, req);
}

int bridge_send_tlp_and_wait_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                                  cpl_entry_t *cpl,
                                  uint16_t requester_id, uint16_t target_bdf)
{
    req->requester_id = requester_id;
    req->target_bdf   = target_bdf;
    return bridge_send_tlp_and_wait(ctx, req, cpl);
}
```

- [ ] **Step 5: Compile and verify**

```bash
cd /home/ubuntu/ryan/software/cosim-platform/build && make -j$(nproc)
```

- [ ] **Step 6: Commit**

```bash
git add bridge/
git commit -m "feat: add topology query and BDF-aware TLP to bridge"
```

---

## Task 7: Add Topology to VCS Bridge (DPI-C Side)

**Files:**
- Modify: `bridge/vcs/bridge_vcs.c`

- [ ] **Step 1: Add topology storage and DPI-C exports**

Add global state and DPI-C functions:

```c
#include "cosim_topology.h"

static topology_resp_t g_topology;
static int g_topology_ready = 0;

/* Called by cosim_rc_driver after func_manager.build() */
void bridge_vcs_set_pf_topology(
    int pf_idx, int bdf, int num_vfs, int vf_device_id,
    int vendor_id, int device_id, int msix_vectors, int vf_msix_vectors,
    long long pf_bar0, long long pf_bar1, long long pf_bar2,
    long long pf_bar3, long long pf_bar4, long long pf_bar5,
    long long vf_bar0, long long vf_bar1, long long vf_bar2,
    long long vf_bar3, long long vf_bar4, long long vf_bar5)
{
    pf_topology_t *pf = &g_topology.pfs[pf_idx];
    pf->bdf = (uint16_t)bdf;
    pf->num_vfs = (uint16_t)num_vfs;
    pf->vf_device_id = (uint16_t)vf_device_id;
    pf->vendor_id = (uint16_t)vendor_id;
    pf->device_id = (uint16_t)device_id;
    pf->msix_vectors = (uint16_t)msix_vectors;
    pf->vf_msix_vectors = (uint16_t)vf_msix_vectors;
    pf->pf_bar_size[0] = (uint64_t)pf_bar0;
    pf->pf_bar_size[1] = (uint64_t)pf_bar1;
    pf->pf_bar_size[2] = (uint64_t)pf_bar2;
    pf->pf_bar_size[3] = (uint64_t)pf_bar3;
    pf->pf_bar_size[4] = (uint64_t)pf_bar4;
    pf->pf_bar_size[5] = (uint64_t)pf_bar5;
    pf->vf_bar_size[0] = (uint64_t)vf_bar0;
    pf->vf_bar_size[1] = (uint64_t)vf_bar1;
    pf->vf_bar_size[2] = (uint64_t)vf_bar2;
    pf->vf_bar_size[3] = (uint64_t)vf_bar3;
    pf->vf_bar_size[4] = (uint64_t)vf_bar4;
    pf->vf_bar_size[5] = (uint64_t)vf_bar5;
}

void bridge_vcs_finalize_topology(int num_pfs, int tag_width)
{
    g_topology.header.num_pfs = (uint8_t)num_pfs;
    g_topology.header.tag_width = (uint8_t)tag_width;
    g_topology_ready = 1;
}
```

- [ ] **Step 2: Handle topology query in poll loop**

In `bridge_vcs_poll_tlp()`, add:

```c
if (msg.type == SYNC_MSG_QUERY_TOPOLOGY) {
    if (g_transport) {
        g_transport->send_topology(g_transport, &g_topology);
    } else {
        memcpy((uint8_t *)g_shm.ctrl + sizeof(cosim_ctrl_t),
               &g_topology, sizeof(g_topology));
        sync_msg_t resp = { .type = SYNC_MSG_TOPOLOGY_RESP };
        sock_sync_send(g_sock_fd, &resp);
    }
    continue;
}
```

- [ ] **Step 3: Update send_completion with BDF**

```c
void bridge_vcs_send_completion(int requester_id, int completer_id,
                                 int tag, int status,
                                 const svOpenArrayHandle data_arr, int len)
{
    cpl_entry_t cpl = {0};
    cpl.type         = TLP_CPL;
    cpl.tag          = (uint16_t)tag;
    cpl.status       = (uint8_t)status;
    cpl.requester_id = (uint16_t)requester_id;
    cpl.completer_id = (uint16_t)completer_id;
    cpl.len          = (uint32_t)len;
    /* ... data copy ... */
    /* ... enqueue/send ... */
}
```

- [ ] **Step 4: Update send_msi with requester_id**

```c
void bridge_vcs_send_msi(int requester_id, int vector)
{
    msi_event_t ev = {
        .requester_id = (uint16_t)requester_id,
        .vector       = (uint16_t)vector,
    };
    /* ... enqueue/send ... */
}
```

- [ ] **Step 5: Add VF event send**

```c
void bridge_vcs_send_vf_event(int event_type, int pf_index, int num_vfs)
{
    vf_event_t ev = {
        .event_type = (uint8_t)event_type,
        .pf_index   = (uint8_t)pf_index,
        .num_vfs    = (uint16_t)num_vfs,
    };
    if (g_transport) {
        g_transport->send_vf_event(g_transport, &ev);
    } else {
        sync_msg_t msg = { .type = SYNC_MSG_VF_EVENT };
        sock_sync_send(g_sock_fd, &msg);
    }
}
```

- [ ] **Step 6: Compile**

```bash
cd /home/ubuntu/ryan/software/cosim-platform/build && make -j$(nproc)
```

- [ ] **Step 7: Commit**

```bash
git add bridge/vcs/bridge_vcs.c
git commit -m "feat: add topology DPI-C exports and BDF-aware completion/MSI to VCS bridge"
```

---

## Task 8: VIP func_manager Enhancements

**Files:**
- Modify: `pcie_tl_vip/src/shared/pcie_tl_func_manager.sv`
- Modify: `pcie_tl_vip/src/shared/pcie_tl_sriov_cap.sv`

- [ ] **Step 1: Add VF BAR size to sriov_cap**

In `pcie_tl_sriov_cap.sv`, add after line 33:

```systemverilog
    bit [63:0] vf_bar_size[6];
```

- [ ] **Step 2: Add MSI-X and tag config to func_manager**

In `pcie_tl_func_manager.sv`, add after line 70:

```systemverilog
    int        pf_msix_vectors = 64;
    int        vf_msix_vectors = 8;
    int        tag_width = 1;
```

- [ ] **Step 3: Add BAR sizing state to func_context**

In `pcie_tl_func_context`, add:

```systemverilog
    bit        bar_sizing[6];   // BAR sizing state per BAR
```

- [ ] **Step 4: Add topology DPI-C export function**

In func_manager, add:

```systemverilog
    import "DPI-C" function void bridge_vcs_set_pf_topology(
        int pf_idx, int bdf, int num_vfs, int vf_device_id,
        int vendor_id, int device_id, int msix_vectors, int vf_msix_vectors,
        longint pf_bar0, longint pf_bar1, longint pf_bar2,
        longint pf_bar3, longint pf_bar4, longint pf_bar5,
        longint vf_bar0, longint vf_bar1, longint vf_bar2,
        longint vf_bar3, longint vf_bar4, longint vf_bar5);
    import "DPI-C" function void bridge_vcs_finalize_topology(
        int num_pfs, int tag_width);

    function void export_topology_to_bridge();
        for (int pf = 0; pf < num_pfs; pf++) begin
            bridge_vcs_set_pf_topology(
                pf, pf_ctx[pf].bdf, max_vfs_per_pf, vf_device_id,
                vendor_id, device_id, pf_msix_vectors, vf_msix_vectors,
                pf_ctx[pf].bar_size[0], pf_ctx[pf].bar_size[1],
                pf_ctx[pf].bar_size[2], pf_ctx[pf].bar_size[3],
                pf_ctx[pf].bar_size[4], pf_ctx[pf].bar_size[5],
                sriov_caps[pf].vf_bar_size[0], sriov_caps[pf].vf_bar_size[1],
                sriov_caps[pf].vf_bar_size[2], sriov_caps[pf].vf_bar_size[3],
                sriov_caps[pf].vf_bar_size[4], sriov_caps[pf].vf_bar_size[5]
            );
        end
        bridge_vcs_finalize_topology(num_pfs, tag_width);
    endfunction
```

- [ ] **Step 5: Commit**

```bash
git add pcie_tl_vip/src/shared/
git commit -m "feat: enhance func_manager with MSI-X, tag width, topology DPI-C"
```

---

## Task 9: Refactor config_proxy for Multi-BDF

**Files:**
- Modify: `pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv`

- [ ] **Step 1: Add func_manager reference**

Add to class fields:

```systemverilog
    pcie_tl_func_manager func_mgr;
    bit multi_function_mode = 0;
```

- [ ] **Step 2: Refactor handle_cfg_read with target_bdf**

Add new overload that accepts `target_bdf`:

```systemverilog
    function bit handle_cfg_read_bdf(bit [15:0] target_bdf, int dw_addr,
                                      output bit [31:0] data);
        if (!bypass_enable) return 0;
        if (!multi_function_mode || func_mgr == null) begin
            return handle_cfg_read(dw_addr, data); // legacy path
        end

        pcie_tl_func_context ctx = func_mgr.lookup_by_bdf(target_bdf);
        if (ctx == null) begin
            data = 32'hFFFF_FFFF;
            return 1;
        end

        // BAR sizing
        for (int i = 0; i < 6; i += 2) begin
            if (dw_addr == (4 + i) && ctx.bar_sizing[i]) begin
                data = ~(ctx.bar_size[i][31:0] - 1) | 32'h4;
                return 1;
            end
            if (dw_addr == (5 + i) && ctx.bar_sizing[i]) begin
                data = ~(ctx.bar_size[i][63:32]);
                return 1;
            end
        end

        data = func_mgr.cfg_read(target_bdf, dw_addr * 4);
        return 1;
    endfunction
```

- [ ] **Step 3: Refactor handle_cfg_write with target_bdf and SR-IOV detection**

```systemverilog
    function bit handle_cfg_write_bdf(bit [15:0] target_bdf, int dw_addr,
                                       bit [31:0] data,
                                       int byte_off = 0, int byte_len = 4);
        if (!bypass_enable) return 0;
        if (!multi_function_mode || func_mgr == null) begin
            return handle_cfg_write(dw_addr, data, byte_off, byte_len);
        end

        pcie_tl_func_context ctx = func_mgr.lookup_by_bdf(target_bdf);
        if (ctx == null) return 1;

        // BAR sizing detection
        for (int i = 0; i < 6; i += 2) begin
            if (dw_addr == (4 + i)) begin
                if (data == 32'hFFFF_FFFF) begin
                    ctx.bar_sizing[i] = 1;
                end else begin
                    ctx.bar_sizing[i] = 0;
                    ctx.bar_base[i][31:0] = data & ~(ctx.bar_size[i][31:0] - 1);
                end
                func_mgr.cfg_write(target_bdf, dw_addr * 4, data, 4'hF);
                return 1;
            end
        end

        // SR-IOV NumVFs write detection (PF extended config space)
        // SR-IOV cap at offset 0x200, NumVFs at +0x10 = 0x210 = DW 0x84
        if (!ctx.is_vf) begin
            int sriov_numvfs_dw = (12'h200 + 12'h10) / 4; // DW index for NumVFs
            if (dw_addr == sriov_numvfs_dw) begin
                int num_vfs = data[15:0];
                if (num_vfs > 0)
                    func_mgr.enable_vfs(ctx.pf_index, num_vfs);
                else
                    func_mgr.disable_vfs(ctx.pf_index);
                // Notify QEMU
                bridge_vcs_send_vf_event(
                    (num_vfs > 0) ? 0 : 1, ctx.pf_index, num_vfs);
            end
        end

        func_mgr.cfg_write(target_bdf, dw_addr * 4, data,
                           ((1 << byte_len) - 1) << byte_off);
        return 1;
    endfunction
```

- [ ] **Step 4: Commit**

```bash
git add pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv
git commit -m "feat: refactor config_proxy for multi-BDF with SR-IOV detection"
```

---

## Task 10: Refactor cosim_rc_driver for Multi-Function Routing

**Files:**
- Modify: `vcs-tb/cosim_rc_driver.sv`

- [ ] **Step 1: Add multi-function fields and DPI-C imports**

```systemverilog
    pcie_tl_func_manager func_mgr;
    bit multi_function_mode = 0;

    import "DPI-C" function void bridge_vcs_send_vf_event(
        int event_type, int pf_index, int num_vfs);
    import "DPI-C" function int bridge_vcs_get_tlp_target_bdf();
    import "DPI-C" function int bridge_vcs_get_tlp_requester_id();
```

- [ ] **Step 2: Update request_loop to extract and route by BDF**

After `bridge_vcs_poll_tlp_scalar()` returns 0:

```systemverilog
    int target_bdf_val = bridge_vcs_get_tlp_target_bdf();
    bit [15:0] target_bdf = target_bdf_val[15:0];
    int req_id_val = bridge_vcs_get_tlp_requester_id();

    // Config TLP with BDF routing
    if (config_proxy != null && config_proxy.bypass_enable) begin
        if (is_cfg_read) begin
            bit [31:0] cfg_data;
            if (config_proxy.handle_cfg_read_bdf(target_bdf, dw_addr, cfg_data)) begin
                bridge_vcs_send_completion(req_id_val, target_bdf,
                    qemu_tag, 0, cfg_data, 4);
                stat_cfg_rd++;
                continue;
            end
        end
        if (is_cfg_write) begin
            if (config_proxy.handle_cfg_write_bdf(target_bdf, dw_addr,
                    tlp_data, byte_off, byte_len)) begin
                stat_cfg_wr++;
                continue;
            end
        end
    end
```

- [ ] **Step 3: Add address resolution for MRd/MWr**

```systemverilog
    function bit resolve_address(bit [63:0] addr,
                                  output bit [15:0] matched_bdf,
                                  output int matched_bar,
                                  output bit [63:0] bar_offset);
        if (!multi_function_mode || func_mgr == null) begin
            // Legacy single-function path
            matched_bdf = 0;
            matched_bar = 0;
            bar_offset = addr;
            return 1;
        end

        foreach (func_mgr.bdf_lut[bdf]) begin
            pcie_tl_func_context ctx = func_mgr.bdf_lut[bdf];
            if (!ctx.enabled) continue;
            for (int b = 0; b < 6; b += 2) begin
                if (ctx.bar_size[b] == 0) continue;
                if (addr >= ctx.bar_base[b] &&
                    addr < ctx.bar_base[b] + ctx.bar_size[b]) begin
                    matched_bdf = bdf;
                    matched_bar = b;
                    bar_offset  = addr - ctx.bar_base[b];
                    return 1;
                end
            end
        end
        return 0;
    endfunction
```

- [ ] **Step 4: Commit**

```bash
git add vcs-tb/cosim_rc_driver.sv
git commit -m "feat: add multi-function BDF routing to cosim_rc_driver"
```

---

## Task 11: Multi-Function EP Stub

**Files:**
- Modify: `vcs-tb/pcie_ep_stub.sv`

- [ ] **Step 1: Add func_id input port**

```systemverilog
    input  [15:0]  func_id,
```

- [ ] **Step 2: Replace fixed registers with sparse model**

```systemverilog
    bit [31:0] func_reg[int][int];
    bit [31:0] func_msix_table[int][int];
    bit [31:0] func_virtio_common[int][int];
    bit [31:0] func_virtio_notify[int];
    bit [31:0] func_virtio_isr[int];
```

- [ ] **Step 3: Update MWr/MRd to index by func_id**

Replace `reg[reg_idx]` with `func_reg[func_id][reg_idx]` etc. throughout the always blocks.

- [ ] **Step 4: Add MSI-X trigger**

```systemverilog
    import "DPI-C" function void bridge_vcs_send_msi(int requester_id, int vector);

    task trigger_msix(int fid, int queue_id);
        int vector = queue_id + 1;
        bridge_vcs_send_msi(fid, vector);
    endtask
```

- [ ] **Step 5: Commit**

```bash
git add vcs-tb/pcie_ep_stub.sv
git commit -m "feat: convert ep_stub to sparse multi-function register model"
```

---

## Task 12: Wire func_id Through glue and cosim_vip_top

**Files:**
- Modify: `vcs-tb/glue_if_to_stub.sv`
- Modify: `vcs-tb/cosim_vip_top.sv`

- [ ] **Step 1: Add func_id ports to glue_if_to_stub**

```systemverilog
    input  [15:0]  func_id_in,
    output [15:0]  func_id_out,
```

Pass through in FSM: `func_id_out <= func_id_in;`

- [ ] **Step 2: Wire in cosim_vip_top**

```systemverilog
    wire [15:0] stub_func_id;

    // glue instance
    .func_id_in  (func_id_from_driver),
    .func_id_out (stub_func_id),

    // ep_stub instance
    .func_id     (stub_func_id),
```

- [ ] **Step 3: Commit**

```bash
git add vcs-tb/glue_if_to_stub.sv vcs-tb/cosim_vip_top.sv
git commit -m "feat: wire func_id through glue layer to ep_stub"
```

---

## Task 13: Update cosim_test.sv with Multi-Function Config

**Files:**
- Modify: `vcs-tb/cosim_test.sv`

- [ ] **Step 1: Add plusarg-driven multi-function config**

In `build_phase()`:

```systemverilog
    int n_pfs = 1, max_vfs = 0, msix_vecs = 4, vf_msix_vecs = 2, tag_w = 1;
    if ($value$plusargs("NUM_PFS=%d", n_pfs)) ;
    if ($value$plusargs("MAX_VFS=%d", max_vfs)) ;
    if ($value$plusargs("MSIX_VECTORS=%d", msix_vecs)) ;
    if ($value$plusargs("VF_MSIX_VECTORS=%d", vf_msix_vecs)) ;
    if ($value$plusargs("TAG_WIDTH=%d", tag_w)) ;

    cfg.func_manager = pcie_tl_func_manager::type_id::create("func_mgr");
    cfg.func_manager.build(.n_pfs(n_pfs), .max_vfs(max_vfs));
    cfg.func_manager.pf_msix_vectors = msix_vecs;
    cfg.func_manager.vf_msix_vectors = vf_msix_vecs;
    cfg.func_manager.tag_width = tag_w;

    for (int pf = 0; pf < n_pfs; pf++) begin
        cfg.func_manager.pf_ctx[pf].bar_size[0] = 64'h0200_0000; // 32MB
        cfg.func_manager.pf_ctx[pf].bar_size[2] = 64'h0001_0000; // 64KB
        cfg.func_manager.pf_ctx[pf].bar_size[4] = 64'h0001_0000; // 64KB
    end
```

- [ ] **Step 2: Export topology after bridge init**

In `run_phase()`, after bridge_vcs_init:

```systemverilog
    cfg.func_manager.export_topology_to_bridge();
```

- [ ] **Step 3: Wire func_manager to config_proxy and rc_driver**

```systemverilog
    // In connect_phase or build_phase:
    cfg.config_proxy.func_mgr = cfg.func_manager;
    cfg.config_proxy.multi_function_mode = (n_pfs > 1 || max_vfs > 0);
    cfg.rc_driver.func_mgr = cfg.func_manager;
    cfg.rc_driver.multi_function_mode = cfg.config_proxy.multi_function_mode;
```

- [ ] **Step 4: Commit**

```bash
git add vcs-tb/cosim_test.sv
git commit -m "feat: add multi-function plusarg config to cosim_test"
```

---

## Task 14: QEMU PF Device Model

**Files:**
- Create: `qemu-plugin/cosim_pcie_pf.h`
- Create: `qemu-plugin/cosim_pcie_pf.c`

- [ ] **Step 1: Create PF header**

Create `qemu-plugin/cosim_pcie_pf.h` with:
- `CosimPCIePF` struct: pf_index, bdf, bars[6], bar_sizes[6], msix_vectors, SR-IOV fields, bridge_ctx, tag_mask, debug
- `CosimSharedState` struct: bridge_ctx, irq_poller, topo, pf_devices[], num_pfs, initialized
- `g_cosim_shared` global extern

(Full code as shown in design discussion Section 4)

- [ ] **Step 2: Create PF implementation**

Create `qemu-plugin/cosim_pcie_pf.c` with:
- `cosim_pf_mmio_read/write()` — MMIO handlers (same logic as cosim_pcie_rc.c but with requester_id=0)
- `cosim_pf_config_read/write()` — Config handlers with target_bdf
- `cosim_pf_realize()` — Key function: bridge_init, query_topology, register BARs, msix_init, pcie_sriov_pf_init, auto-create PF1-N
- `cosim_msix_cb()` — MSI-X callback with BDF routing
- QEMU device type registration

(Full code as shown in design discussion Section 4)

- [ ] **Step 3: Commit**

```bash
git add qemu-plugin/cosim_pcie_pf.h qemu-plugin/cosim_pcie_pf.c
git commit -m "feat: add QEMU PF device model with SR-IOV and MSI-X"
```

---

## Task 15: QEMU VF Device Model

**Files:**
- Create: `qemu-plugin/cosim_pcie_vf.h`
- Create: `qemu-plugin/cosim_pcie_vf.c`

- [ ] **Step 1: Create VF header and implementation**

VF device:
- `cosim_vf_realize()`: find parent PF via `pcie_sriov_get_pf()`, reference bridge_ctx, register BARs, msix_init
- MMIO handlers share the same ops as PF (address-based routing to VIP)
- Type registration with `INTERFACE_PCIE_DEVICE`

- [ ] **Step 2: Commit**

```bash
git add qemu-plugin/cosim_pcie_vf.h qemu-plugin/cosim_pcie_vf.c
git commit -m "feat: add QEMU VF device model"
```

---

## Task 16: Update irq_poller for MSI-X BDF Routing

**Files:**
- Modify: `bridge/qemu/irq_poller.c`

- [ ] **Step 1: Update MSI callback signature**

```c
typedef void (*msix_cb_fn)(void *opaque, uint16_t requester_id, uint16_t vector);
```

- [ ] **Step 2: Pass requester_id from msi_event_t to callback**

```c
if (poller->msix_cb)
    poller->msix_cb(poller->opaque, msi_ev.requester_id, msi_ev.vector);
```

- [ ] **Step 3: Commit**

```bash
git add bridge/qemu/irq_poller.c
git commit -m "feat: route MSI-X by requester_id in irq_poller"
```

---

## Task 17: Update Makefile

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add PF/VF source files to QEMU plugin build**

- [ ] **Step 2: Add SR-IOV run targets**

```makefile
run-vcs-sriov:
	$(VCS_RUN) +NUM_PFS=4 +MAX_VFS=8 +MSIX_VECTORS=64 +TAG_WIDTH=2

run-qemu-sriov:
	$(QEMU) -device pcie-root-port,id=rp0,slot=4,chassis=1 \
	        -device cosim-pcie-pf,id=dpu,bus=rp0,transport=$(TRANSPORT),\
	        remote_host=$(REMOTE_HOST),port_base=$(PORT_BASE)
```

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "feat: add SR-IOV build targets to Makefile"
```

---

## Task 18: Integration — Stage 1 (Single PF Baseline)

- [ ] **Step 1: Compile all**

```bash
make clean && make bridge && make vcs-vip
```

- [ ] **Step 2: Run single PF regression**

VCS: `make run-vcs +NUM_PFS=1 +MAX_VFS=0 +MSIX_VECTORS=4`
QEMU: `make run-qemu-sriov TRANSPORT=tcp REMOTE_HOST=10.11.10.61`

- [ ] **Step 3: Verify Guest lspci**

Expected: 1 network controller with MSI-X capability.

---

## Task 19: Integration — Stage 2 (Multi PF)

- [ ] **Step 1: Run 4 PF config**

VCS: `make run-vcs +NUM_PFS=4 +MAX_VFS=0`

- [ ] **Step 2: Verify 4 devices**

```bash
lspci | grep -i network
# XX:00.0, XX:00.1, XX:00.2, XX:00.3
```

---

## Task 20: Integration — Stage 3 (SR-IOV VF)

- [ ] **Step 1: Run with VF support**

VCS: `make run-vcs +NUM_PFS=1 +MAX_VFS=4`

- [ ] **Step 2: Create and destroy VFs in Guest**

```bash
echo 4 > /sys/bus/pci/devices/0000:XX:00.0/sriov_numvfs
lspci | grep "Virtual Function"   # 4 entries
echo 0 > /sys/bus/pci/devices/0000:XX:00.0/sriov_numvfs
lspci | grep "Virtual Function"   # 0 entries
```
