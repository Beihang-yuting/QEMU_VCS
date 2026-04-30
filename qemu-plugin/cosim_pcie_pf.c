/* cosim-platform/qemu-plugin/cosim_pcie_pf.c
 * QEMU SR-IOV PF device model — multi-function cosim
 *
 * Place in QEMU source tree: qemu/hw/net/cosim_pcie_pf.c
 * Header: qemu/include/hw/net/cosim_pcie_pf.h
 * Build: modify qemu/hw/net/meson.build
 *
 * Linked against libcosim_bridge.so at runtime.
 */
#include "hw/net/cosim_pcie_pf.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qemu/main-loop.h"       /* qemu_bh_new / qemu_bh_schedule */
#include "exec/address-spaces.h"
#include "exec/cpu-common.h"       /* cpu_physical_memory_read/write */
#include "hw/qdev-properties.h"
#include "qapi/error.h"
#include "hw/pci/pcie_sriov.h"
#include "hw/pci/msi.h"

/* Debug macro: enabled via -device cosim-pcie-pf,...,debug=on */
#define PF_DPRINTF(s, fmt, ...) do { \
    if ((s)->debug) fprintf(stderr, "cosim-pf%d: " fmt, \
                            (s)->pf_index, ##__VA_ARGS__); \
} while (0)

/* Bridge API — linked dynamically */
#include "bridge_qemu.h"
#include "cosim_transport.h"
#include "irq_poller.h"

/* ========== Global shared state ========== */

CosimSharedState g_cosim_shared = { .initialized = false };

/* ========== BDF helpers ========== */

int cosim_find_pf_by_bdf(uint16_t bdf)
{
    for (int i = 0; i < g_cosim_shared.num_pfs; i++) {
        if (g_cosim_shared.topo.pfs[i].bdf == bdf) {
            return i;
        }
    }
    return -1;
}

/* Find the PF device that owns a given requester_id (could be PF or its VF) */
static CosimPCIePF *find_device_owner(uint16_t requester_id)
{
    /* First check if it's a PF BDF directly */
    for (int i = 0; i < g_cosim_shared.num_pfs; i++) {
        CosimPCIePF *pf = g_cosim_shared.pf_devices[i];
        if (!pf) continue;
        if (g_cosim_shared.topo.pfs[i].bdf == requester_id) {
            return pf;
        }
        /* Check if requester_id falls in VF range for this PF.
         * VF BDFs are contiguous after PF BDF:
         *   VF0 = PF_BDF + vf_offset, VF1 = PF_BDF + vf_offset + vf_stride ...
         * For simplicity, check if requester_id > PF BDF and within num_vfs range.
         * A more precise check would use SR-IOV VF offset/stride from config,
         * but for the common case PF+1..PF+num_vfs works. */
        uint16_t pf_bdf = g_cosim_shared.topo.pfs[i].bdf;
        uint16_t nvfs = g_cosim_shared.topo.pfs[i].num_vfs;
        if (nvfs > 0 && requester_id > pf_bdf &&
            requester_id <= pf_bdf + nvfs) {
            return pf;
        }
    }
    return NULL;
}

/* ========== MMIO operations (shared by PF and VF) ========== */

static uint64_t cosim_pf_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    CosimPFBarContext *bc = (CosimPFBarContext *)opaque;
    PCIDevice *pci_dev;
    CosimPCIePF *pf;
    bridge_ctx_t *ctx;

    if (bc->is_vf) {
        /* VF: dev points to CosimPCIeVF; get parent PF for bridge_ctx.
         * The VF struct stores a back-pointer to its parent PF.
         * For now, use the shared bridge context. */
        pci_dev = (PCIDevice *)bc->dev;
        ctx = (bridge_ctx_t *)g_cosim_shared.bridge_ctx;
        pf = NULL;  /* VF path */
    } else {
        pf = (CosimPCIePF *)bc->dev;
        pci_dev = &pf->parent_obj;
        ctx = (bridge_ctx_t *)pf->bridge_ctx;
    }

    if (!ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim-pf: read before bridge connected\n");
        return 0xFFFFFFFF;
    }

    /* Reconstruct full PCIe address: BAR base + offset */
    uint64_t bar_base  = pci_get_bar_addr(pci_dev, bc->bar_index);
    uint64_t pcie_addr = bar_base + addr;
    uint32_t byte_off  = pcie_addr & 3u;
    uint64_t dw_addr   = pcie_addr & ~3ULL;
    uint8_t  first_be  = (uint8_t)(((1u << size) - 1) << byte_off);

    /* Build MRd TLP with requester_id = 0 (RC perspective) */
    tlp_entry_t req = {0};
    req.type     = TLP_MRD;
    req.addr     = dw_addr;
    req.len      = 4;
    req.first_be = first_be;
    req.last_be  = 0;
    req.requester_id = 0;  /* RC BDF */

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim-pf: MRd failed addr=0x%lx\n",
                      (unsigned long)addr);
        return 0xFFFFFFFF;
    }

    /* Extract requested bytes from CplD DWORD */
    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }
    uint64_t val = dword >> (byte_off * 8);
    if (size < 4) {
        val &= (1ULL << (size * 8)) - 1;
    }

    if (pf) {
        PF_DPRINTF(pf, "MRd bar%d off=0x%04lx pcie=0x%lx be=0x%x val=0x%lx\n",
                bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
                first_be, (unsigned long)val);
    }
    return val;
}

static void cosim_pf_mmio_write(void *opaque, hwaddr addr, uint64_t val,
                                 unsigned size)
{
    CosimPFBarContext *bc = (CosimPFBarContext *)opaque;
    PCIDevice *pci_dev;
    CosimPCIePF *pf;
    bridge_ctx_t *ctx;

    if (bc->is_vf) {
        pci_dev = (PCIDevice *)bc->dev;
        ctx = (bridge_ctx_t *)g_cosim_shared.bridge_ctx;
        pf = NULL;
    } else {
        pf = (CosimPCIePF *)bc->dev;
        pci_dev = &pf->parent_obj;
        ctx = (bridge_ctx_t *)pf->bridge_ctx;
    }

    if (!ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim-pf: write before bridge connected\n");
        return;
    }

    uint64_t bar_base  = pci_get_bar_addr(pci_dev, bc->bar_index);
    uint64_t pcie_addr = bar_base + addr;
    uint32_t byte_off  = pcie_addr & 3u;
    uint64_t dw_addr   = pcie_addr & ~3ULL;
    uint8_t  first_be  = (uint8_t)(((1u << size) - 1) << byte_off);

    uint32_t shifted_val = (uint32_t)val << (byte_off * 8);

    tlp_entry_t req = {0};
    req.type     = TLP_MWR;
    req.addr     = dw_addr;
    req.len      = 4;
    req.first_be = first_be;
    req.last_be  = 0;
    req.requester_id = 0;  /* RC BDF */
    for (int i = 0; i < 4; i++) {
        req.data[i] = (shifted_val >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim-pf: MWr failed addr=0x%lx\n",
                      (unsigned long)addr);
    }

    if (pf) {
        PF_DPRINTF(pf, "MWr bar%d off=0x%04lx pcie=0x%lx be=0x%x val=0x%lx\n",
                bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
                first_be, (unsigned long)val);
    }
}

const MemoryRegionOps cosim_pf_mmio_ops = {
    .read  = cosim_pf_mmio_read,
    .write = cosim_pf_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 1,
        .max_access_size = 8,
    },
};

/* ========== Config Space forwarding ========== */

/* Check if config address falls in QEMU-managed capability region.
 * Capabilities (MSI-X, PCIe, SR-IOV) are managed by QEMU locally and
 * must NOT be forwarded to VCS. */
static bool cosim_pf_addr_is_local(PCIDevice *pci_dev, uint32_t address, int len)
{
    /* Status register (0x06): must expose Capabilities List bit from local */
    /* Capability Pointer (0x34): must come from local QEMU chain */
    if (address == PCI_CAPABILITY_LIST || address == 0x34 ||
        address == 0x35 || address == 0x36 || address == 0x37) {
        return true;
    }

    /* All standard capability structures (0x40+) are QEMU-managed:
     * MSI-X, PCIe Endpoint cap, etc. */
    if (address >= 0x40 && address < PCI_CONFIG_SPACE_SIZE) {
        return true;
    }

    /* Extended config space (0x100+): SR-IOV and other extended caps */
    if (address >= PCI_CONFIG_SPACE_SIZE) {
        return true;
    }

    /* Status register: merge locally to ensure Cap bit is visible */
    if (address <= PCI_STATUS && address + len > PCI_STATUS) {
        return true;
    }

    return false;
}

static uint32_t cosim_pf_config_read(PCIDevice *pci_dev, uint32_t address, int len)
{
    CosimPCIePF *s = COSIM_PCIE_PF(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* Serve QEMU-managed capability regions from local config space */
    if (!ctx || cosim_pf_addr_is_local(pci_dev, address, len)) {
        uint32_t val = pci_default_read_config(pci_dev, address, len);
        PF_DPRINTF(s, "cfg_read addr=0x%02x len=%d -> 0x%x (local)\n",
                   address, len, val);
        return val;
    }

    uint32_t dword_addr  = address & ~3u;
    uint32_t byte_offset = address & 3u;

    /* Use BDF-aware TLP to route to correct function on VCS side */
    uint16_t target_bdf = s->topo ? s->topo->pfs[s->pf_index].bdf : 0;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len  = 4;
    req.requester_id = 0;          /* RC BDF */
    req.target_bdf   = target_bdf;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait_bdf(ctx, &req, &cpl, 0, target_bdf);
    if (ret < 0) {
        uint32_t fallback = pci_default_read_config(pci_dev, address, len);
        PF_DPRINTF(s, "cfg_read addr=0x%02x VCS_FAIL -> local=0x%x\n",
                   address, fallback);
        return fallback;
    }

    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }

    uint32_t val = dword >> (byte_offset * 8);
    if (len < 4) {
        val &= (1u << (len * 8)) - 1;
    }

    /* Inject multifunction bit into Header Type register for PF0
     * so the Guest probes function 1..7 on the same slot */
    if (s->pf_index == 0 && address <= PCI_HEADER_TYPE &&
        address + len > PCI_HEADER_TYPE) {
        int byte_pos = PCI_HEADER_TYPE - address;
        if (g_cosim_shared.num_pfs > 1) {
            val |= (uint32_t)PCI_HEADER_TYPE_MULTI_FUNCTION << (byte_pos * 8);
        }
    }

    PF_DPRINTF(s, "cfg_read addr=0x%02x len=%d -> 0x%x\n", address, len, val);
    return val;
}

static void cosim_pf_config_write(PCIDevice *pci_dev, uint32_t address,
                                   uint32_t data, int len)
{
    CosimPCIePF *s = COSIM_PCIE_PF(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* Always write local config for QEMU framework consistency
     * (this also triggers pcie_sriov_config_write for VF enable) */
    pci_default_write_config(pci_dev, address, data, len);

    /* Detect SR-IOV VF Enable change and notify VCS via vf_event.
     * SR-IOV Control is at SRIOV_CAP_OFFSET + PCI_SRIOV_CTRL (0x108).
     * After pci_default_write_config → pcie_sriov_config_write creates/
     * destroys VFs locally, we must tell VCS to enable/disable VF BDFs
     * in its func_manager so CfgRd/CfgWr to VF BDFs are routed correctly. */
    if (ctx && s->num_vfs > 0 &&
        address == COSIM_SRIOV_CAP_OFFSET + PCI_SRIOV_CTRL && len == 2) {
        bridge_ctx_t *bctx = (bridge_ctx_t *)ctx;
        uint16_t num_vfs_active = pci_dev->exp.sriov_pf.num_vfs;
        vf_event_t ev;

        if ((data & PCI_SRIOV_CTRL_VFE) && num_vfs_active > 0) {
            ev.event_type = VF_EVENT_ENABLE;
            ev.pf_index   = s->pf_index;
            ev.num_vfs    = num_vfs_active;
        } else {
            ev.event_type = VF_EVENT_DISABLE;
            ev.pf_index   = s->pf_index;
            ev.num_vfs    = 0;
        }

        bridge_send_vf_event(bctx, &ev);
        PF_DPRINTF(s, "SR-IOV vf_event: type=%s pf=%d num_vfs=%d\n",
                   ev.event_type == VF_EVENT_ENABLE ? "ENABLE" : "DISABLE",
                   ev.pf_index, ev.num_vfs);
    }

    /* Don't forward QEMU-managed capability writes to VCS */
    if (!ctx || cosim_pf_addr_is_local(pci_dev, address, len)) {
        PF_DPRINTF(s, "CfgWr addr=0x%02x len=%d data=0x%x (local only)\n",
                   address, len, data);
        return;
    }

    uint16_t target_bdf = s->topo ? s->topo->pfs[s->pf_index].bdf : 0;

    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = address;
    req.len  = len;
    req.requester_id = 0;
    req.target_bdf   = target_bdf;
    for (int i = 0; i < len && i < COSIM_TLP_DATA_SIZE; i++) {
        req.data[i] = (data >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim-pf%d: CfgWr failed addr=0x%x data=0x%x\n",
                      s->pf_index, address, data);
    }

    PF_DPRINTF(s, "CfgWr addr=0x%02x len=%d data=0x%x target_bdf=0x%04x\n",
               address, len, data, target_bdf);
}

/* ========== DMA callback ========== */

static void cosim_pf_dma_cb(const dma_req_t *req, void *user)
{
    /* DMA callback is shared — PF0 owns the bridge, route via shared state.
     * The DMA request contains host_addr (GPA), which is global to the guest.
     * Same logic as cosim_pcie_rc.c but uses shared bridge_ctx. */
    CosimPCIePF *s = COSIM_PCIE_PF(user);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    if (ctx->transport) {
        if (req->direction == DMA_DIR_WRITE) {
            uint32_t tag, direction;
            uint64_t host_addr;
            uint8_t buf[65536];
            uint32_t len = sizeof(buf);
            int ret = ctx->transport->recv_dma_data(ctx->transport, &tag,
                            &direction, &host_addr, buf, &len);
            if (ret < 0) {
                qemu_log("cosim-pf: DMA write recv_dma_data failed tag=%u\n",
                         req->tag);
                bridge_complete_dma(ctx, req->tag, 1);
                return;
            }
            cpu_physical_memory_write(req->host_addr, buf, len);
            bridge_complete_dma(ctx, req->tag, 0);
        } else {
            uint8_t buf[65536];
            uint32_t len = req->len > sizeof(buf) ? sizeof(buf) : req->len;
            cpu_physical_memory_read(req->host_addr, buf, len);
            bridge_complete_dma_with_data(ctx, req->tag, 0,
                                           req->direction, req->host_addr,
                                           buf, len);
        }
    } else {
        uint8_t *dma_buf = (uint8_t *)ctx->shm.dma_buf + req->dma_offset;
        if (req->direction == DMA_DIR_WRITE) {
            cpu_physical_memory_write(req->host_addr, dma_buf, req->len);
        } else {
            cpu_physical_memory_read(req->host_addr, dma_buf, req->len);
        }
        bridge_complete_dma(ctx, req->tag, 0);
    }

    qemu_log("cosim-pf: DMA %s OK GPA=0x%lx len=%u tag=%u (%s)\n",
             req->direction == DMA_DIR_WRITE ? "write" : "read",
             (unsigned long)req->host_addr, req->len, req->tag,
             ctx->transport ? "TCP" : "SHM");
}

/* ========== MSI-X BH: dequeue and fire in QEMU main loop ========== */

static void cosim_pf_msix_bh_cb(void *opaque)
{
    CosimPCIePF *s = COSIM_PCIE_PF(opaque);

    while (s->msix_queue_head != s->msix_queue_tail) {
        int idx = s->msix_queue_head % COSIM_MSIX_QUEUE_SIZE;
        uint16_t rid    = (uint16_t)s->msix_queue_rid[idx];
        uint16_t vector = s->msix_queue_vec[idx];
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        s->msix_queue_head++;

        /* Find the target PCIDevice by requester_id */
        PCIDevice *target = NULL;

        /* Check PF BDFs first */
        for (int i = 0; i < g_cosim_shared.num_pfs; i++) {
            CosimPCIePF *pf = g_cosim_shared.pf_devices[i];
            if (!pf) continue;
            if (g_cosim_shared.topo.pfs[i].bdf == rid) {
                target = PCI_DEVICE(pf);
                break;
            }
        }

        /* If not a PF, check VF ranges — for now use pcie_sriov helpers
         * if available, otherwise linear search is acceptable for small
         * function counts. VF devices are auto-created by SR-IOV framework. */
        if (!target) {
            /* Find which PF owns this VF BDF */
            CosimPCIePF *owner = find_device_owner(rid);
            if (owner) {
                /* In QEMU SR-IOV, VFs are separate PCIDevices on the bus.
                 * We need to find the actual VF PCIDevice by BDF.
                 * Use pci_find_device on the bus. */
                PCIBus *bus = pci_get_bus(&owner->parent_obj);
                if (bus) {
                    int bus_num = (rid >> 8) & 0xFF;
                    int devfn   = rid & 0xFF;
                    target = pci_find_device(bus, bus_num, devfn);
                }
            }
        }

        if (!target) {
            qemu_log("cosim-pf: MSI-X BH: unknown requester_id=0x%04x "
                     "vector=%u, dropping\n", rid, vector);
            continue;
        }

        if (msix_enabled(target)) {
            PF_DPRINTF(s, "MSI-X BH: msix_notify rid=0x%04x vector=%u\n",
                       rid, vector);
            msix_notify(target, vector);
        } else if (msi_enabled(target)) {
            qemu_log("cosim-pf: MSI-X BH: fallback msi_notify rid=0x%04x "
                     "vector=%u\n", rid, vector);
            msi_notify(target, vector);
        } else {
            qemu_log("cosim-pf: MSI-X BH: INTx assert rid=0x%04x vector=%u\n",
                     rid, vector);
            pci_set_irq(target, 1);
        }
    }
}

/* MSI-X callback from irq_poller (extended: with requester_id) */
static void cosim_pf_msi_cb(uint16_t requester_id, uint16_t vector, void *user)
{
    CosimPCIePF *s = COSIM_PCIE_PF(user);

    int tail = s->msix_queue_tail;
    int head = s->msix_queue_head;
    if (tail - head >= COSIM_MSIX_QUEUE_SIZE) {
        qemu_log("cosim-pf: MSI-X queue full, dropping rid=0x%04x vector=%u\n",
                 requester_id, vector);
        return;
    }

    int idx = tail % COSIM_MSIX_QUEUE_SIZE;
    s->msix_queue_rid[idx] = requester_id;
    s->msix_queue_vec[idx] = vector;
    __atomic_thread_fence(__ATOMIC_RELEASE);
    s->msix_queue_tail = tail + 1;

    qemu_bh_schedule((QEMUBH *)s->msix_bh);
}

/* ========== Device lifecycle ========== */

static void cosim_pcie_pf_realize(PCIDevice *pci_dev, Error **errp)
{
    CosimPCIePF *s = COSIM_PCIE_PF(pci_dev);
    s->num_bars = 0;

    /* ======== Step 1: PF0 initializes bridge + topology ======== */
    if (s->pf_index == 0) {
        if (g_cosim_shared.initialized) {
            error_setg(errp, "cosim-pf: shared state already initialized "
                       "(duplicate PF0?)");
            return;
        }

        /* Connect bridge */
        if (s->transport && strcmp(s->transport, "tcp") == 0) {
            transport_cfg_t cfg = {
                .transport   = "tcp",
                .listen_addr = "0.0.0.0",
                .remote_host = s->remote_host,
                .port_base   = (int)s->port_base,
                .instance_id = (int)s->instance_id,
                .is_server   = 1,
            };
            s->bridge_ctx = bridge_init_ex(&cfg);
            if (!s->bridge_ctx) {
                error_setg(errp, "cosim-pf: bridge_init_ex failed (tcp)");
                return;
            }
            bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
            if (bridge_connect_ex(ctx) < 0) {
                error_setg(errp, "cosim-pf: bridge_connect_ex failed");
                bridge_destroy(ctx);
                s->bridge_ctx = NULL;
                return;
            }
        } else {
            if (!s->shm_name || !s->sock_path) {
                error_setg(errp, "cosim-pf: shm_name and sock_path required");
                return;
            }
            s->bridge_ctx = bridge_init(s->shm_name, s->sock_path);
            if (!s->bridge_ctx) {
                error_setg(errp, "cosim-pf: bridge_init failed");
                return;
            }
            bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
            if (bridge_connect(ctx) < 0) {
                error_setg(errp, "cosim-pf: bridge_connect failed");
                bridge_destroy(ctx);
                s->bridge_ctx = NULL;
                return;
            }
        }

        bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
        ctx->debug = s->debug;

        /* Query topology from VCS */
        memset(&g_cosim_shared.topo, 0, sizeof(g_cosim_shared.topo));
        if (bridge_query_topology(ctx, &g_cosim_shared.topo) < 0) {
            error_setg(errp, "cosim-pf: bridge_query_topology failed");
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            return;
        }

        g_cosim_shared.bridge_ctx = s->bridge_ctx;
        g_cosim_shared.num_pfs = g_cosim_shared.topo.header.num_pfs;
        s->topo = &g_cosim_shared.topo;
        s->tag_mask = tag_width_to_mask(g_cosim_shared.topo.header.tag_width);

        qemu_log("cosim-pf: topology: %d PFs, tag_width=%d\n",
                 g_cosim_shared.num_pfs,
                 g_cosim_shared.topo.header.tag_width);

        for (int i = 0; i < g_cosim_shared.num_pfs && i < COSIM_MAX_PFS; i++) {
            pf_topology_t *pt = &g_cosim_shared.topo.pfs[i];
            qemu_log("cosim-pf: PF%d bdf=0x%04x vid=0x%04x did=0x%04x "
                     "msix=%d vfs=%d vf_did=0x%04x\n",
                     i, pt->bdf, pt->vendor_id, pt->device_id,
                     pt->msix_vectors, pt->num_vfs, pt->vf_device_id);
        }
    } else {
        /* PF1..N: reuse shared bridge context */
        s->bridge_ctx = g_cosim_shared.bridge_ctx;
        s->topo = &g_cosim_shared.topo;
        s->tag_mask = tag_width_to_mask(g_cosim_shared.topo.header.tag_width);
    }

    /* Register this PF in shared state */
    if (s->pf_index < COSIM_MAX_PF_DEVICES) {
        g_cosim_shared.pf_devices[s->pf_index] = s;
    }

    /* ======== Step 2: Get this PF's config from topology ======== */
    pf_topology_t *my_topo = &g_cosim_shared.topo.pfs[s->pf_index];

    s->msix_vectors    = my_topo->msix_vectors;
    s->num_vfs         = my_topo->num_vfs;
    s->vf_device_id    = my_topo->vf_device_id;
    s->vf_msix_vectors = my_topo->vf_msix_vectors;
    for (int i = 0; i < 6; i++) {
        s->bar_sizes[i]    = my_topo->pf_bar_size[i];
        s->vf_bar_sizes[i] = my_topo->vf_bar_size[i];
    }

    /* ======== Step 3: Register BARs ======== */
    /* 64-bit BARs use even indices (0, 2, 4) */
    for (int i = 0; i < 6; i += 2) {
        uint64_t sz = s->bar_sizes[i];
        if (sz == 0) continue;

        char name[32];
        snprintf(name, sizeof(name), "cosim-pf%d-bar%d", s->pf_index, i);

        s->bar_ctx[i].dev       = s;
        s->bar_ctx[i].bar_index = i;
        s->bar_ctx[i].is_vf     = 0;

        memory_region_init_io(&s->bars[i], OBJECT(s), &cosim_pf_mmio_ops,
                              &s->bar_ctx[i], name, sz);
        pci_register_bar(pci_dev, i,
                         PCI_BASE_ADDRESS_SPACE_MEMORY |
                         PCI_BASE_ADDRESS_MEM_TYPE_64,
                         &s->bars[i]);
        s->num_bars++;

        PF_DPRINTF(s, "BAR%d registered, size=0x%lx\n", i, (unsigned long)sz);
    }

    /* Enable bus mastering */
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);

    /* INTx pin */
    pci_config_set_interrupt_pin(pci_dev->config, 1);

    /* ======== Step 4: MSI-X init ======== */
    if (s->msix_vectors > 0) {
        /* MSI-X table in BAR0, PBA after table.
         * Table size = vectors * 16 bytes, PBA = aligned after table */
        uint32_t table_size = s->msix_vectors * PCI_MSIX_ENTRY_SIZE;
        uint32_t pba_offset = QEMU_ALIGN_UP(table_size, 0x1000);
        int bar_nr = 0;  /* MSI-X table in BAR0 */

        Error *msix_err = NULL;
        int ret = msix_init(pci_dev, s->msix_vectors,
                            &s->bars[bar_nr], bar_nr, 0,
                            &s->bars[bar_nr], bar_nr, pba_offset,
                            0, &msix_err);
        if (ret < 0) {
            PF_DPRINTF(s, "msix_init failed: %s\n",
                       msix_err ? error_get_pretty(msix_err) : "?");
            error_free(msix_err);
        } else {
            PF_DPRINTF(s, "MSI-X initialized: %d vectors\n", s->msix_vectors);
        }
    }

    /* ======== Step 5: PCIe Capability + SR-IOV ======== */
    /* PCIe Endpoint Capability is required for SR-IOV Extended Capability */
    int pcie_cap_ret = pcie_endpoint_cap_init(pci_dev, 0x80);
    if (pcie_cap_ret < 0) {
        qemu_log("cosim-pf%d: pcie_endpoint_cap_init failed (ret=%d), "
                 "SR-IOV will not work\n", s->pf_index, pcie_cap_ret);
    } else {
        PF_DPRINTF(s, "PCIe Endpoint Capability initialized at 0x%x\n",
                   pcie_cap_ret);
    }

    if (s->num_vfs > 0 && pcie_cap_ret >= 0) {
        /* Initialize SR-IOV capability for this PF.
         * VF offset/stride must skip over all PF functions to avoid
         * devfn collisions: PF0..PF(N-1) occupy func 0..(N-1),
         * so VFs start at func N with stride N for interleaving. */
        uint16_t npfs = g_cosim_shared.num_pfs > 1
                      ? g_cosim_shared.num_pfs : 1;
        pcie_sriov_pf_init(pci_dev, COSIM_SRIOV_CAP_OFFSET,
                           TYPE_COSIM_PCIE_VF,
                           s->vf_device_id,
                           s->num_vfs,    /* initial VFs */
                           s->num_vfs,    /* total VFs */
                           npfs,          /* vf_offset: skip PF functions */
                           npfs);         /* vf_stride: interleave across PFs */

        /* Register VF BARs with SR-IOV framework */
        for (int i = 0; i < 6; i += 2) {
            if (s->vf_bar_sizes[i] == 0) continue;
            pcie_sriov_pf_init_vf_bar(pci_dev, i,
                                       PCI_BASE_ADDRESS_SPACE_MEMORY |
                                       PCI_BASE_ADDRESS_MEM_TYPE_64,
                                       s->vf_bar_sizes[i]);
            PF_DPRINTF(s, "VF BAR%d registered in SR-IOV cap, size=0x%lx\n",
                       i, (unsigned long)s->vf_bar_sizes[i]);
        }

        PF_DPRINTF(s, "SR-IOV initialized: %d VFs, vf_did=0x%04x\n",
                   s->num_vfs, s->vf_device_id);
    }

    /* ======== Step 6: PF0 starts irq_poller + auto-creates PF1..N ======== */
    if (s->pf_index == 0) {
        /* Create MSI-X BH */
        s->msix_queue_head = 0;
        s->msix_queue_tail = 0;
        s->msix_bh = qemu_bh_new(cosim_pf_msix_bh_cb, s);

        /* Start IRQ/DMA poller with extended MSI callback */
        bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
        if (ctx->transport) {
            s->irq_poller = irq_poller_start_ex_v2(ctx->transport,
                                cosim_pf_dma_cb, cosim_pf_msi_cb, s);
        } else {
            s->irq_poller = irq_poller_start_v2(&ctx->shm,
                                cosim_pf_dma_cb, cosim_pf_msi_cb, s);
        }
        if (!s->irq_poller) {
            error_setg(errp, "cosim-pf: irq_poller_start failed");
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            g_cosim_shared.bridge_ctx = NULL;
            return;
        }
        g_cosim_shared.irq_poller = s->irq_poller;
        g_cosim_shared.initialized = true;

        /* Mark PF0 as multifunction so QEMU allows func>0 devices */
        pci_dev->cap_present |= QEMU_PCI_CAP_MULTIFUNCTION;
        pci_dev->config[PCI_HEADER_TYPE] |= PCI_HEADER_TYPE_MULTI_FUNCTION;

        /* Auto-create PF1..N on the same bus */
        PCIBus *bus = pci_get_bus(pci_dev);
        for (int i = 1; i < g_cosim_shared.num_pfs && i < COSIM_MAX_PF_DEVICES; i++) {
            DeviceState *vdev = qdev_new(TYPE_COSIM_PCIE_PF);
            CosimPCIePF *pf_n = COSIM_PCIE_PF(vdev);
            pf_n->pf_index = i;
            pf_n->debug = s->debug;
            /* PF1..N share the bridge; transport properties not needed */

            Error *local_err = NULL;
            /* Place on same slot as PF0, function = i */
            int slot = PCI_SLOT(pci_dev->devfn);
            int devfn = PCI_DEVFN(slot, i);
            qdev_prop_set_int32(vdev, "addr", devfn);

            if (!qdev_realize_and_unref(vdev, BUS(bus), &local_err)) {
                qemu_log("cosim-pf: failed to create PF%d: %s\n",
                         i, local_err ? error_get_pretty(local_err) : "?");
                error_free(local_err);
            } else {
                qemu_log("cosim-pf: PF%d created at devfn=0x%02x\n", i, devfn);
            }
        }

        qemu_log("cosim-pf: PF0 realized, %d PFs total (%s mode)\n",
                 g_cosim_shared.num_pfs,
                 (s->transport && strcmp(s->transport, "tcp") == 0)
                     ? "TCP" : "SHM");
    } else {
        /* PF1..N: share the BH from PF0 (MSI-X routing is centralized) */
        CosimPCIePF *pf0 = g_cosim_shared.pf_devices[0];
        if (pf0) {
            s->msix_bh = pf0->msix_bh;
            s->msix_queue_head = 0;
            s->msix_queue_tail = 0;
        }
        s->irq_poller = g_cosim_shared.irq_poller;

        qemu_log("cosim-pf: PF%d realized (shared bridge)\n", s->pf_index);
    }
}

static void cosim_pcie_pf_exit(PCIDevice *pci_dev)
{
    CosimPCIePF *s = COSIM_PCIE_PF(pci_dev);

    /* Only PF0 owns and cleans up shared resources */
    if (s->pf_index == 0) {
        if (s->irq_poller) {
            irq_poller_stop((irq_poller_t *)s->irq_poller);
            s->irq_poller = NULL;
            g_cosim_shared.irq_poller = NULL;
        }
        if (s->msix_bh) {
            qemu_bh_delete((QEMUBH *)s->msix_bh);
            s->msix_bh = NULL;
        }
        if (s->bridge_ctx) {
            bridge_destroy((bridge_ctx_t *)s->bridge_ctx);
            s->bridge_ctx = NULL;
            g_cosim_shared.bridge_ctx = NULL;
        }
        g_cosim_shared.initialized = false;
    }

    if (s->pf_index < COSIM_MAX_PF_DEVICES) {
        g_cosim_shared.pf_devices[s->pf_index] = NULL;
    }

    if (s->num_vfs > 0) {
        pcie_sriov_pf_exit(pci_dev);
    }

    pcie_cap_exit(pci_dev);
    msix_uninit(pci_dev, &s->bars[0], &s->bars[0]);
}

/* ========== Device properties ========== */

static Property cosim_pf_properties[] = {
    DEFINE_PROP_STRING("shm_name",    CosimPCIePF, shm_name),
    DEFINE_PROP_STRING("sock_path",   CosimPCIePF, sock_path),
    DEFINE_PROP_STRING("transport",   CosimPCIePF, transport),
    DEFINE_PROP_STRING("remote_host", CosimPCIePF, remote_host),
    DEFINE_PROP_UINT32("port_base",   CosimPCIePF, port_base, 9100),
    DEFINE_PROP_UINT32("instance_id", CosimPCIePF, instance_id, 0),
    DEFINE_PROP_BOOL("debug",         CosimPCIePF, debug, false),
    DEFINE_PROP_END_OF_LIST(),
};

/* ========== Type registration ========== */

static void cosim_pcie_pf_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize      = cosim_pcie_pf_realize;
    k->exit         = cosim_pcie_pf_exit;
    k->config_read  = cosim_pf_config_read;
    k->config_write = cosim_pf_config_write;

    /* Default IDs — overridden by topology at realize time if available */
    k->vendor_id = 0x1AF4;   /* Red Hat / virtio */
    k->device_id = 0x1041;   /* virtio-net (modern) */
    k->revision  = 0x01;
    k->class_id  = PCI_CLASS_NETWORK_ETHERNET;

    device_class_set_props(dc, cosim_pf_properties);
    set_bit(DEVICE_CATEGORY_NETWORK, dc->categories);
    dc->desc = "CoSim PCIe PF Device (Multi-Function QEMU-VCS Bridge)";
}

static const TypeInfo cosim_pcie_pf_info = {
    .name          = TYPE_COSIM_PCIE_PF,
    .parent        = TYPE_PCI_DEVICE,
    .instance_size = sizeof(CosimPCIePF),
    .class_init    = cosim_pcie_pf_class_init,
    .interfaces    = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

static void cosim_pf_register_types(void)
{
    type_register_static(&cosim_pcie_pf_info);
}

type_init(cosim_pf_register_types)
