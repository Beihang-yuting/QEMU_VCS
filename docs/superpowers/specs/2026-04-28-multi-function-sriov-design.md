# PCIe Multi-Function SR-IOV + MSI-X Design

**Date:** 2026-04-28
**Branch:** `feature/multi-function-sriov`
**Status:** Design Approved

---

## 1. Overview

Extend the cosim-platform PCIe layer to support a DPU-class device with:

- Up to 4 Physical Functions (PF)
- Up to 256 Virtual Functions (VF) per PF
- Maximum 1024 Functions total (4 PF + 4x256 VF)
- Each Function = 1 virtio device, up to 2K queues
- SR-IOV mechanism for VF management
- MSI-X interrupt support (replacing MSI)
- All topology parameters configurable from VIP side

**Validation goal:** Stub mode first to validate the complete software flow, then replace with real DPU RTL.

## 2. Constraints

- New branch `feature/multi-function-sriov`, must not merge into or break existing code
- TCP cross-machine mode must remain unaffected on master branch
- VIP func_manager is the single source of truth for all topology/configuration
- QEMU discovers topology at realize time via bridge query (no hardcoding)
- Single bridge connection (matches real hardware: one PCIe Link per EP)
- Waveform dump enabled by default (`+NO_WAVE` to disable)

## 3. Architecture

### 3.1 Layer Responsibilities

```
VIP Layer (Configuration Source)
  func_manager  -> Define PF/VF count, BAR sizes, tag width
  sriov_cap     -> SR-IOV Extended Capability per PF
  config_proxy  -> Per-BDF config space, MSI-X cap, BAR sizing
  cosim_rc_driver -> TLP routing by BDF

Bridge Layer (Transport)
  tlp_entry_t   -> Add requester_id, target_bdf
  cpl_entry_t   -> Add requester_id, completer_id
  msi_event_t   -> Add requester_id
  dma_req_t     -> Add requester_id
  New: QUERY_TOPOLOGY / TOPOLOGY_RESP / VF_EVENT control messages

QEMU Layer (Device Model)
  cosim-pcie-pf -> SR-IOV PF device, pcie_sriov_pf_init()
  cosim-pcie-vf -> VF device, auto-created by QEMU SR-IOV framework
  irq_poller    -> Route MSI-X by requester_id to correct Function
```

### 3.2 Topology Discovery Flow

```
1. QEMU realize (cosim-pcie-pf, pf_index=0)
     |-- Establish bridge connection
     |-- Send QUERY_TOPOLOGY -> VIP
     |     <- Returns: num_pfs, per-PF config (BAR sizes, VF params,
     |        msix_vectors, vendor/device IDs, tag_width)
     |-- Register PF0 BARs, msix_init(), pcie_sriov_pf_init()
     |-- Auto-create PF1~PF(N-1) on same bus slot (multifunction)
     |
2. Guest boot
     |-- PCI enumeration: CfgRd -> bridge -> VIP config_proxy
     |     config_proxy routes by target_bdf to func_manager.cfg_read()
     |-- Guest discovers N PFs, each with SR-IOV cap
     |
3. Guest writes sriov_numvfs
     |-- CfgWr SR-IOV NumVFs -> VIP config_proxy
     |     config_proxy calls func_manager.enable_vfs()
     |     Sends VF_EVENT(enable) to QEMU via bridge
     |-- QEMU SR-IOV framework creates VF device instances
     |-- Guest re-enumerates, discovers VF devices
```

### 3.3 PF Count Flexibility

QEMU does not preset PF count. The realize flow queries VIP:

- VIP configures `n_pfs=1` -> QEMU creates 1 PF, works normally
- VIP configures `n_pfs=4` -> QEMU creates 4 PFs on same slot
- User command line stays the same either way

## 4. Bridge Protocol Extensions

### 4.1 tlp_entry_t

```c
typedef struct {
    uint8_t   type;
    uint16_t  tag;            // 16-bit: supports 5/8/10-bit tag (VIP configured)
    uint16_t  requester_id;   // NEW: sender BDF [15:8]=Bus [7:3]=Dev [2:0]=Func
    uint16_t  target_bdf;     // NEW: CfgRd/CfgWr target BDF
    uint16_t  len;
    uint8_t   msg_code;
    uint8_t   atomic_op_size;
    uint16_t  vendor_id;
    uint64_t  addr;
    uint8_t   data[64];
    uint64_t  dma_offset;
    uint64_t  timestamp;
    uint8_t   first_be;
    uint8_t   last_be;
} __attribute__((packed)) tlp_entry_t;
```

### 4.2 cpl_entry_t

```c
typedef struct {
    uint8_t   type;
    uint16_t  tag;            // 16-bit (matches request tag width)
    uint8_t   status;
    uint16_t  requester_id;   // NEW: original requester BDF
    uint16_t  completer_id;   // NEW: completer BDF
    uint32_t  len;
    uint8_t   data[64];
    uint64_t  timestamp;
} __attribute__((packed)) cpl_entry_t;
```

### 4.3 msi_event_t

```c
typedef struct {
    uint16_t  requester_id;   // NEW: which Function triggered MSI-X
    uint16_t  vector;         // MSI-X vector number (max 2048)
    uint32_t  _pad0;
    uint64_t  timestamp;
} __attribute__((packed)) msi_event_t;
```

### 4.4 dma_req_t

```c
typedef struct {
    uint16_t  requester_id;   // NEW: DMA initiator BDF
    uint8_t   direction;
    uint8_t   tag;
    uint32_t  len;
    uint64_t  host_addr;
    uint64_t  dma_offset;
    uint64_t  timestamp;
} __attribute__((packed)) dma_req_t;
```

### 4.5 Topology Query Protocol

```c
// New control messages
#define SYNC_MSG_QUERY_TOPOLOGY    0x10
#define SYNC_MSG_TOPOLOGY_RESP     0x11
#define SYNC_MSG_VF_EVENT          0x12

typedef struct {
    uint8_t  num_pfs;
    uint8_t  tag_width;       // 0=5-bit, 1=8-bit, 2=10-bit
    uint8_t  _pad[2];
} topology_header_t;

typedef struct {
    uint16_t bdf;
    uint16_t num_vfs;
    uint16_t vf_device_id;
    uint16_t vendor_id;
    uint16_t device_id;
    uint16_t msix_vectors;
    uint16_t vf_msix_vectors;
    uint16_t _pad;
    uint64_t pf_bar_size[6];
    uint64_t vf_bar_size[6];
} pf_topology_t;

typedef struct {
    uint8_t  event_type;      // 0=enable, 1=disable
    uint8_t  pf_index;
    uint16_t num_vfs;
} vf_event_t;
```

## 5. VIP Side Changes

### 5.1 config_proxy Refactor

Current config_proxy holds a single config_space[1024]. Change to delegate to func_manager:

```
config_proxy.handle_cfg_read(target_bdf, dw_addr)
    -> func_manager.cfg_read(target_bdf, dw_addr)

config_proxy.handle_cfg_write(target_bdf, dw_addr, data, be)
    -> func_manager.cfg_write(target_bdf, dw_addr, data, be)
    -> Detect SR-IOV NumVFs write -> trigger enable_vfs/disable_vfs
    -> Detect BAR assignment -> update bar_base, sync to glue layer
```

### 5.2 func_manager Enhancements

Existing func_manager already supports PF/VF contexts and BDF lookup. Add:

1. **Per-PF BAR size configuration** via `pf_ctx[i].bar_size[0..5]`
2. **Per-PF VF BAR size configuration** via `sriov_caps[i].vf_bar_size[0..5]`
3. **MSI-X Capability registration** per PF/VF in cfg_mgr
4. **Tag width configuration** field
5. **Topology query DPI-C export** for bridge to call

### 5.3 MSI-X Config Space Layout

Per-Function capability chain:

```
0x40: MSI-X Capability (CAP_ID=0x11)
      Message Control: Table Size = N-1, Function Mask, Enable
      Table BIR + Offset: points to MSI-X Table in BAR0
      PBA BIR + Offset: points to PBA in BAR0

0x50: Virtio PCI Caps (COMMON/NOTIFY/ISR/DEVICE)

0x100+: SR-IOV Extended Capability (PF only)
```

BAR0 internal layout per Function:

```
0x0000 - size:  MSI-X Table (16 bytes per entry)
next:           MSI-X PBA (Pending Bit Array)
next:           Virtio registers (common_cfg, notify, isr, device_cfg)
```

### 5.4 cosim_rc_driver Changes

```
request_loop:
  1. bridge_vcs_poll_tlp() returns TLP with target_bdf
  2. CfgRd/CfgWr -> config_proxy.handle_cfg_read/write(target_bdf, ...)
     - Internally queries func_manager
     - Detects SR-IOV writes, triggers VF enable/disable
     - VF events sent to QEMU via bridge
  3. MRd/MWr -> match address against all enabled Functions' BAR ranges
     - Iterate func_manager.bdf_lut
     - Match bar_base <= addr < bar_base + bar_size
     - Dispatch to ep_stub with func_id

completion_loop:
  cpl carries requester_id, sent back to QEMU

dma_msi_loop:
  MSI-X send carries requester_id
  DMA request carries requester_id
```

### 5.5 glue_if_to_stub

Routing logic moves to cosim_rc_driver (software layer). Glue receives pre-resolved {func_id, bar_index, bar_offset} from driver. Keeps glue layer simple.

## 6. QEMU Side Changes

### 6.1 Device Model Split

```
cosim-pcie-pf  <- PF device (SR-IOV capable), replaces cosim-pcie-rc
cosim-pcie-vf  <- VF device, auto-created by QEMU SR-IOV framework
```

### 6.2 CosimPCIePF Structure

```c
struct CosimPCIePF {
    PCIDevice parent_obj;
    uint8_t   pf_index;
    uint16_t  bdf;
    MemoryRegion bars[6];
    uint64_t     bar_sizes[6];     // from VIP topology
    uint16_t  msix_vectors;        // from VIP topology
    uint16_t  num_vfs;
    uint16_t  vf_device_id;
    uint64_t  vf_bar_sizes[6];
    void     *bridge_ctx;          // PF0 creates, others reference
    void     *irq_poller;          // PF0 creates, shared
    uint16_t  tag_mask;            // from VIP tag_width
    bool      debug;
};
```

### 6.3 PF Realize Flow

```
cosim_pcie_pf_realize(dev):
  1. if pf_index == 0:
       bridge_init(), QUERY_TOPOLOGY -> get topo
       Save topo to shared context
     else:
       Reference PF0's bridge_ctx

  2. Extract this PF's config from topo

  3. Register BARs (64-bit, sizes from topo)

  4. msix_init(dev, msix_vectors, table_bar, table_offset, pba_bar, pba_offset)

  5. pcie_sriov_pf_init(dev, sriov_cap_offset,
         "cosim-pcie-vf", vf_device_id, num_vfs, num_vfs, vf_bar_sizes)

  6. if pf_index == 0:
       Start irq_poller thread
       Auto-create PF1~PF(N-1) via qdev_new + qdev_realize
```

### 6.4 CosimPCIeVF Structure

```c
struct CosimPCIeVF {
    PCIDevice parent_obj;
    uint16_t  pf_index;
    uint16_t  vf_index;
    uint16_t  bdf;
    MemoryRegion bars[6];
    uint16_t  msix_vectors;
    void     *bridge_ctx;          // references PF's bridge
};
```

VF realize: find parent PF, reference bridge_ctx, register BARs (sizes from SR-IOV framework), msix_init(), notify VIP via VF_EVENT.

### 6.5 QEMU Command Line

```bash
# Minimal - VIP decides everything
qemu-system-x86_64 \
    -device pcie-root-port,id=rp0,slot=4,chassis=1 \
    -device cosim-pcie-pf,id=dpu,bus=rp0,transport=tcp,\
            remote_host=10.11.10.61,port_base=9000

# PF0 realize queries VIP, auto-creates PF1~PF(N-1) as multifunction
# VF created automatically when Guest writes sriov_numvfs
```

### 6.6 MSI-X Interrupt Injection

```
irq_poller thread:
  recv_msi_nb(&ev)  // ev contains requester_id + vector
  target = lookup_device_by_bdf(ev.requester_id)
  enqueue_msix(target, ev.vector)
  qemu_bh_schedule(msix_bh)

msix_bh callback (main thread, holds BQL):
  while dequeue_msix(&target, &vector):
    msix_notify(target, vector)
```

## 7. EP Stub Extension

### 7.1 Single Stub + Function ID

No 1028 stub instances. Single stub with func_id parameter:

```
cosim_rc_driver resolves func_id from address matching
  -> passes {func_id, bar_index, bar_offset, data, first_be, tag} to stub
  -> stub indexes register model by func_id
```

### 7.2 Sparse Register Model (Stub Mode)

```systemverilog
// Only allocate space for accessed Functions
bit [31:0] func_mem[int][int];     // func_mem[func_id][dw_offset]
bit [31:0] msix_table[int][int];   // msix_table[func_id][entry*4+field]
bit [7:0]  virtio_status[int];     // per-function virtio device status
bit [15:0] virtio_queue_sel[int];
```

### 7.3 DUT RTL Switch

```
+EP_MODE=stub    -> pcie_ep_stub (software simulation)
+EP_MODE=rtl     -> DUT PCIe TL interface (real hardware logic)
```

Interface between cosim_rc_driver and stub/DUT is standardized so switching requires no changes above the glue layer.

### 7.4 MSI-X Trigger Flow (Stub Mode)

```
Guest writes virtio notify register (MWr)
  -> ep_stub identifies notify write for func_id
  -> Look up msix_table[func_id][vector] for {msg_addr, msg_data}
  -> DPI-C: bridge_vcs_send_msi(requester_id, vector)
  -> bridge transmits to QEMU irq_poller
  -> irq_poller finds PCIDevice by requester_id
  -> msix_notify(dev, vector)
```

## 8. Tag Management

### 8.1 Tag Width from VIP

VIP configures tag_width (5/8/10-bit). Reported via topology query. Controls:

- PCIe Device Capabilities 2: 10-Bit Tag Completer Supported
- PCIe Device Control 2: 10-Bit Tag Requester Enable (Guest writes)
- Bridge tag field: uint16_t (accommodates all widths)
- QEMU tag_mask = (1 << actual_bits) - 1

### 8.2 Per-Function Tag Space

```
Each Function maintains independent tag counter.
Completion matching key: {requester_id, tag} (24+ bit unique).
No cross-function tag collision.
```

## 9. SHM Layout (Expanded)

```
Region          Offset      Size    Notes
ctrl            0x000000    4KB     Status, ready flags, topo cache
req_ring        0x001000    1MB     TLP request queue (4x current)
cpl_ring        0x101000    1MB     Completion queue (4x current)
dma_req_ring    0x201000    256KB   DMA request queue (4x current)
dma_cpl_ring    0x241000    256KB   DMA completion queue (4x current)
msi_ring        0x281000    64KB    MSI-X event queue (16x current)
dma_buf         0x291000    ~14MB   DMA data area
Total                       16MB    (configurable via shm_size param)
```

TCP mode: unaffected by SHM layout, message-framed protocol auto-adapts.

## 10. VIP Configuration Example

```systemverilog
function void build_phase(uvm_phase phase);
    cfg.func_manager.build(
        .n_pfs(2), .max_vfs(8),
        .v_id(16'hABCD), .d_id(16'h1234), .vf_dev_id(16'h1235)
    );

    // PF0 BARs (3x 64-bit)
    cfg.func_manager.pf_ctx[0].bar_size[0] = 64'h0200_0000;  // BAR0-1: 32MB
    cfg.func_manager.pf_ctx[0].bar_size[2] = 64'h0001_0000;  // BAR2-3: 64KB
    cfg.func_manager.pf_ctx[0].bar_size[4] = 64'h0001_0000;  // BAR4-5: 64KB

    // PF0's VF BARs
    cfg.func_manager.sriov_caps[0].vf_bar_size[0] = 64'h0001_0000;  // 64KB
    cfg.func_manager.sriov_caps[0].vf_bar_size[2] = 64'h0000_1000;  // 4KB

    // MSI-X
    cfg.msix_vectors    = 64;    // PF: 64 vectors
    cfg.vf_msix_vectors = 8;     // VF: 8 vectors

    // Tag width
    cfg.tag_width = 2;           // 10-bit tag
endfunction
```

## 11. QEMU Command Line

```bash
# Minimal - VIP decides everything
qemu-system-x86_64 \
    -device pcie-root-port,id=rp0,slot=4,chassis=1 \
    -device cosim-pcie-pf,id=dpu,bus=rp0,transport=tcp,\
            remote_host=10.11.10.61,port_base=9000
```

## 12. Verification Stages

| Stage | VIP Config | Verification Points |
|-------|-----------|---------------------|
| 1. Single PF baseline | n_pfs=1, max_vfs=0 | Guest sees 1 device, CfgRd/CfgWr via func_manager, MSI-X works, MMIO works, regression against current behavior |
| 2. Multi PF | n_pfs=4, max_vfs=0 | Guest sees 4 devices (XX:00.0~.3), independent config/BAR/MSI-X per PF |
| 3. SR-IOV VF creation | n_pfs=1, max_vfs=4 | SR-IOV cap visible, sriov_numvfs creates VFs, VFs appear in lspci, VF config space independent |
| 4. VF data plane | n_pfs=1, max_vfs=4 | VF MMIO routes correctly, VF MSI-X to correct device, VF DMA with correct requester_id, virtio init on VF |
| 5. Full scale | n_pfs=4, max_vfs=256 | 1028 Functions enumerate, no address overlap, no tag collision, memory/perf acceptable |

## 13. Unchanged Components

- TCP/SHM dual transport architecture
- sock_sync control channel mechanism
- DMA data transfer flow (adds requester_id, logic unchanged)
- Waveform dump default on
- Guest rootfs build (Alpine/Debian)
- cosim-init adaptive device discovery
