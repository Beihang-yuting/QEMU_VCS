/* cosim-platform/qemu-plugin/cosim_pcie_rc.c
 * QEMU 自定义 PCIe RC 设备 — 实现
 *
 * 放入 QEMU 源码树: qemu/hw/net/cosim_pcie_rc.c
 * 头文件: qemu/include/hw/net/cosim_pcie_rc.h
 * 构建集成: 修改 qemu/hw/net/meson.build
 *
 * 编译时需要链接 libcosim_bridge.so
 */
#include "hw/net/cosim_pcie_rc.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qemu/main-loop.h"   /* qemu_bh_new / qemu_bh_schedule */
#include "exec/address-spaces.h" /* address_space_memory */
#include "exec/cpu-common.h"     /* cpu_physical_memory_read/write */
#include "hw/pci/pcie.h"        /* pcie_ari_init */
#include "hw/qdev-properties.h"
#include "qapi/error.h"
#include "qemu/timer.h"
#include "sysemu/cpu-timers.h"
#include "sysemu/runstate.h"

/* Debug 打印：运行时通过 -device cosim-pcie-rc,...,debug=on 开启 */
#define COSIM_DPRINTF(s, fmt, ...) do { \
    if ((s)->debug) fprintf(stderr, "cosim: " fmt, ##__VA_ARGS__); \
} while (0)

/* Bridge API — 通过动态链接使用 */
#include "bridge_qemu.h"
#include "cosim_transport.h"
#include "irq_poller.h"
#include "hw/net/cosim_mmio_be.h"
#include "hw/net/cosim_pcie_request.h"

/* ========== MMIO 操作 ========== */

static uint16_t cosim_current_bdf(PCIDevice *dev)
{
    return cosim_pcie_bdf((uint8_t)pci_bus_num(pci_get_bus(dev)), dev->devfn);
}

static uint16_t cosim_current_pci_domain(PCIDevice *pci_dev)
{
    const char *root_path = pci_root_bus_path(pci_dev);
    unsigned int domain;
    unsigned int root_bus;

    if (root_path == NULL ||
        sscanf(root_path, "%x:%x", &domain, &root_bus) != 2 ||
        domain > UINT16_MAX) {
        return 0;
    }
    return (uint16_t)domain;
}

/* A VCS/DUT round trip can consume seconds of host time while the vCPU is
 * blocked in a device callback. The guest executes no instructions during
 * that interval, but adaptive iCount would otherwise compare itself against
 * an advancing QEMU_CLOCK_VIRTUAL_RT and accelerate afterwards to catch up.
 * Stop that host-time reference for only the outermost bridge wait. */
static void cosim_vcs_wait_begin(void *opaque)
{
    CosimPCIeRC *s = opaque;

    g_assert(s != NULL);
    g_assert(bql_locked());
    if (s->vcs_wait_depth++ != 0) {
        return;
    }

    s->vcs_wait_ticks_owned = false;
    if (!runstate_is_running()) {
        return;
    }

    s->vcs_wait_started_ns = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
    cpu_disable_ticks();
    s->vcs_wait_ticks_owned = true;
    COSIM_DPRINTF(s, "VCS wait: adaptive host-time reference frozen\n");
}

static void cosim_vcs_wait_end(void *opaque)
{
    CosimPCIeRC *s = opaque;

    g_assert(s != NULL);
    g_assert(bql_locked());
    if (s->vcs_wait_depth == 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: unbalanced VCS wait end\n");
        return;
    }
    if (--s->vcs_wait_depth != 0) {
        return;
    }

    if (s->vcs_wait_ticks_owned) {
        int64_t elapsed = qemu_clock_get_ns(QEMU_CLOCK_REALTIME) -
                          s->vcs_wait_started_ns;
        if (runstate_is_running()) {
            cpu_enable_ticks();
        }
        s->vcs_wait_ticks_owned = false;
        COSIM_DPRINTF(s,
                      "VCS wait: adaptive host-time reference resumed after %.3f ms\n",
                      (double)elapsed / 1000000.0);
    }
}

/* Core MMIO forward: turn QEMU's 1/2/4/8B access into a DWORD-aligned PCIe
 * request with correct first/last byte enables.  An unaligned 8B access may
 * occupy three DWORDs, so it must not be truncated to a single DWORD. */
static uint64_t cosim_mmio_do_read(CosimPCIeRC *s, uint64_t pcie_addr,
                                   uint16_t target_bdf, unsigned size)
{
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
    uint32_t byte_off = pcie_addr & 3u;
    uint64_t dw_addr  = pcie_addr & ~3ULL;
    cosim_mmio_be_layout_t layout;
    if (cosim_mmio_be_layout_build(byte_off, size, 0, &layout) < 0)
        return UINT64_MAX;

    tlp_entry_t req = {0};
    req.type       = TLP_MRD;
    req.addr       = dw_addr;
    req.len        = layout.wire_len;
    req.first_be   = layout.first_be;
    req.last_be    = layout.last_be;
    cosim_route_host_to_device(&req, target_bdf);

    cpl_entry_t cpl = {0};
    /* mmio_timeout_ms>0: 超时即返回 0xFFFFFFFF, guest 不死等无响应的 VCS。 */
    int ret = (s->mmio_timeout_ms > 0)
              ? bridge_send_tlp_and_wait_timed(ctx, &req, &cpl, (int)s->mmio_timeout_ms)
              : bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: MRd %s pcie=0x%lx bdf=0x%04x -> 0xFFFFFFFF\n",
                      ret == -2 ? "timeout" : "failed",
                      (unsigned long)pcie_addr, target_bdf);
        return UINT64_MAX;
    }

    uint64_t val;
    bool cpl_success = cosim_cpl_value_decode(cpl.status, cpl.data, size, &val);
    if (!cpl_success) {
        uint64_t error_count = ++s->mmio_cpl_error_count;
        if (error_count <= 8 || error_count % 1024 == 0) {
            qemu_log_mask(LOG_GUEST_ERROR,
                          "cosim: MRd completion error status=%u pcie=0x%lx "
                          "bdf=0x%04x count=%" PRIu64 " -> 0xFFFFFFFF\n",
                          cpl.status, (unsigned long)pcie_addr, target_bdf,
                          error_count);
        }
        return val;
    }
    return val;
}

static void cosim_mmio_do_write(CosimPCIeRC *s, uint64_t pcie_addr,
                                uint16_t target_bdf, uint64_t val, unsigned size)
{
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
    uint32_t byte_off = pcie_addr & 3u;
    uint64_t dw_addr  = pcie_addr & ~3ULL;
    cosim_mmio_be_layout_t layout;
    if (cosim_mmio_be_layout_build(byte_off, size, val, &layout) < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: invalid MMIO write size=%u offset=%u\n",
                      size, byte_off);
        return;
    }

    tlp_entry_t req = {0};
    req.type       = TLP_MWR;
    req.addr       = dw_addr;
    req.len        = layout.wire_len;
    req.first_be   = layout.first_be;
    req.last_be    = layout.last_be;
    cosim_route_host_to_device(&req, target_bdf);
    memcpy(req.data, layout.data, layout.wire_len);

    if (bridge_send_tlp_fire(ctx, &req) < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: MWr failed pcie=0x%lx bdf=0x%04x\n",
                      (unsigned long)pcie_addr, target_bdf);
    }
}

/* PF (and fixed-BDF) BAR MMIO. */
static uint64_t cosim_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    CosimBarContext *bc = (CosimBarContext *)opaque;
    CosimPCIeRC *s = bc->dev;
    if (!s->bridge_ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: read before bridge connected\n");
        return 0xFFFFFFFF;
    }
    uint64_t bar_base  = bc->explicit_base
                         ? bc->explicit_base
                         : pci_get_bar_addr(&bc->dev->parent_obj, bc->bar_index);
    uint64_t pcie_addr = bar_base + addr;
    uint16_t target_bdf = cosim_current_bdf(PCI_DEVICE(bc->dev));
    uint64_t val = cosim_mmio_do_read(s, pcie_addr, target_bdf, size);
    COSIM_DPRINTF(s, "MRd bar%d off=0x%04lx pcie=0x%lx val=0x%lx\n",
            bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
            (unsigned long)val);
    return val;
}

static void cosim_mmio_write(void *opaque, hwaddr addr, uint64_t val,
                              unsigned size)
{
    CosimBarContext *bc = (CosimBarContext *)opaque;
    CosimPCIeRC *s = bc->dev;
    if (!s->bridge_ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: write before bridge connected\n");
        return;
    }
    uint64_t bar_base  = bc->explicit_base
                         ? bc->explicit_base
                         : pci_get_bar_addr(&bc->dev->parent_obj, bc->bar_index);
    uint64_t pcie_addr = bar_base + addr;
    uint16_t target_bdf = cosim_current_bdf(PCI_DEVICE(bc->dev));
    cosim_mmio_do_write(s, pcie_addr, target_bdf, val, size);
    COSIM_DPRINTF(s, "MWr bar%d off=0x%04lx pcie=0x%lx val=0x%lx\n",
            bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
            (unsigned long)val);
}

/* SR-IOV VF BAR aperture MMIO: one region per (PF,BAR) covers all VFs. Decode
 * vf_index from the region offset (real-HW aperture + stride), route to that
 * VF's RID. Scales to 256 VF/PF with a single region per BAR. */
static uint64_t cosim_vf_aperture_read(void *opaque, hwaddr addr, unsigned size)
{
    CosimBarContext *bc = (CosimBarContext *)opaque;
    CosimPCIeRC *s = bc->dev;
    if (!s->bridge_ctx || bc->vf_bar_size == 0) {
        return 0xFFFFFFFF;
    }
    int vf_index = (int)(addr / bc->vf_bar_size);
    if (vf_index >= bc->num_vfs) {
        return 0xFFFFFFFF;   /* access outside enabled VFs */
    }
    uint16_t vf_bdf = (uint16_t)(bc->first_vf_bdf + vf_index * bc->vf_bdf_stride);
    uint64_t pcie_addr = bc->explicit_base + addr;
    uint64_t val = cosim_mmio_do_read(s, pcie_addr, vf_bdf, size);
    COSIM_DPRINTF(s, "VF MRd bar%d vf%d bdf=0x%04x off=0x%lx val=0x%lx\n",
            bc->bar_index, vf_index, vf_bdf, (unsigned long)addr,
            (unsigned long)val);
    return val;
}

static void cosim_vf_aperture_write(void *opaque, hwaddr addr, uint64_t val,
                                    unsigned size)
{
    CosimBarContext *bc = (CosimBarContext *)opaque;
    CosimPCIeRC *s = bc->dev;
    if (!s->bridge_ctx || bc->vf_bar_size == 0) {
        return;
    }
    int vf_index = (int)(addr / bc->vf_bar_size);
    if (vf_index >= bc->num_vfs) {
        return;
    }
    uint16_t vf_bdf = (uint16_t)(bc->first_vf_bdf + vf_index * bc->vf_bdf_stride);
    uint64_t pcie_addr = bc->explicit_base + addr;
    cosim_mmio_do_write(s, pcie_addr, vf_bdf, val, size);
    COSIM_DPRINTF(s, "VF MWr bar%d vf%d bdf=0x%04x off=0x%lx val=0x%lx\n",
            bc->bar_index, vf_index, vf_bdf, (unsigned long)addr,
            (unsigned long)val);
}

/* ========== P2: DMA / MSI 回调 ========== */

/* Inbound AtomicOp compute — PCIe AtomicOp operands are little-endian.
 * dir ∈ {DMA_DIR_ATOMIC_FETCHADD/SWAP/CAS}; sz = op_size (4 or 8 bytes).
 * ops: [operand] for FetchAdd/Swap, [compare‖swap] for CAS.
 * Writes the new value into newv (sz bytes); *do_write=0 iff CAS mismatched
 * (memory then stays unchanged, but the ORIGINAL value is still returned). */
static void cosim_atomic_compute(uint32_t dir, uint32_t sz,
                                 const uint8_t *oldv, const uint8_t *ops,
                                 uint8_t *newv, int *do_write)
{
    uint64_t o = 0, a = 0;
    for (uint32_t i = 0; i < sz; i++) {
        o |= (uint64_t)oldv[i] << (8 * i);
        a |= (uint64_t)ops[i]  << (8 * i);   /* first operand: add/swap/compare */
    }
    uint64_t n = o;
    *do_write = 1;
    switch (dir) {
    case DMA_DIR_ATOMIC_FETCHADD:
        n = o + a;
        break;
    case DMA_DIR_ATOMIC_SWAP:
        n = a;
        break;
    case DMA_DIR_ATOMIC_CAS: {
        uint64_t swp = 0;
        for (uint32_t i = 0; i < sz; i++)
            swp |= (uint64_t)ops[sz + i] << (8 * i);  /* second operand: swap */
        if (o == a) n = swp;         /* compare matched → store swap */
        else        *do_write = 0;   /* mismatch → leave memory unchanged */
        break;
    }
    default:
        *do_write = 0;
        break;
    }
    if (sz == 4) n &= 0xFFFFFFFFull;  /* 32-bit AtomicOp wraps mod 2^32 */
    for (uint32_t i = 0; i < sz; i++)
        newv[i] = (uint8_t)(n >> (8 * i));
}

/* DMA 请求回调：从 VCS 收到 DMA 请求 —
 *   direction=WRITE 表示设备→Host 写 (DMA write to guest memory)
 *   direction=READ  表示 Host→设备 读 (DMA read from guest memory)
 */
/* VF config stub type — full definition below (cosim_rc_vf_*). Declared here so
 * cosim_dma_dev/cosim_dma_cb can resolve a VF stub PCIDevice by BDF. */
struct CosimRcVF {
    PCIDevice   parent_obj;
    CosimPCIeRC *pf;
    uint16_t    vf_bdf;
};
typedef struct CosimRcVF CosimRcVF;
#define TYPE_COSIM_RC_VF "cosim-pcie-rc-vf"
DECLARE_INSTANCE_CHECKER(CosimRcVF, COSIM_RC_VF, TYPE_COSIM_RC_VF)

/* Registry of PF devices sharing one transport, indexed by pf_index. Populated
 * at realize; used to route VF-config events (which carry pf_index) to the
 * right PF and to resolve DMA requester BDFs across PFs. */
#define COSIM_RC_MAX_PF COSIM_MAX_PFS
static CosimPCIeRC *g_rc_pfs[COSIM_RC_MAX_PF];

/* PF0-only table snapshot registry.  It is a list, rather than another PF/VF
 * topology array: instance_id is a sparse 32-bit transport identity.  QEMU
 * device lifecycle and consumers run under the BQL. */
static CosimPCIeRC *g_table_target_registry;
static uint32_t g_table_target_generation;

static uint32_t cosim_table_target_allocate_generation(void)
{
    uint32_t next =
        cosim_table_target_next_generation(g_table_target_generation);

    if (next != 0) {
        g_table_target_generation = next;
    }
    return next;
}

static void cosim_table_target_unlink(CosimPCIeRC *s)
{
    CosimPCIeRC **link = &g_table_target_registry;

    while (*link != NULL && *link != s) {
        link = &(*link)->table_target_next;
    }
    if (*link == s) {
        *link = s->table_target_next;
    }
    s->table_target_next = NULL;
    s->table_target_registered = false;
}

static void cosim_table_target_remove(CosimPCIeRC *s)
{
    if (s->pf_index != 0 || !s->table_target_registered) {
        return;
    }
    cosim_table_target_unlink(s);
    s->table_target_snapshot.generation =
        cosim_table_target_allocate_generation();
}

static void cosim_table_target_publish(CosimPCIeRC *s, PCIDevice *pci_dev)
{
    cosim_table_target_snapshot_t snapshot = {0};
    CosimPCIeRC *existing;
    int physical_bar;

    if (s->pf_index != 0 || s->instance_id > UINT16_MAX) {
        cosim_table_target_remove(s);
        return;
    }

    if (s->table_target_registered) {
        cosim_table_target_unlink(s);
    }
    existing = g_table_target_registry;
    while (existing != NULL) {
        CosimPCIeRC *next = existing->table_target_next;

        if (existing->instance_id == s->instance_id) {
            cosim_table_target_unlink(existing);
            existing->table_target_snapshot.generation =
                cosim_table_target_allocate_generation();
            break;
        }
        existing = next;
    }

    snapshot.rc_id = (uint16_t)s->instance_id;
    snapshot.device_instance = 0;
    snapshot.pci_domain = cosim_current_pci_domain(pci_dev);
    snapshot.target_bdf = cosim_current_bdf(pci_dev);
    snapshot.generation = cosim_table_target_allocate_generation();
    for (physical_bar = 0; physical_bar < COSIM_MAX_BARS; ++physical_bar) {
        if (s->bar_ctx[physical_bar].dev != s) {
            continue;
        }
        snapshot.bar_sizes[physical_bar] =
            memory_region_size(&s->bars[physical_bar]);
    }

    s->table_target_snapshot = snapshot;
    if (!cosim_table_target_snapshot_valid(&snapshot)) {
        return;
    }
    s->table_target_next = g_table_target_registry;
    g_table_target_registry = s;
    s->table_target_registered = true;
}

bool cosim_pcie_rc_get_table_target(
    uint32_t instance_id, cosim_table_target_snapshot_t *snapshot)
{
    CosimPCIeRC *entry;

    if (snapshot == NULL || instance_id > UINT16_MAX) {
        return false;
    }
    for (entry = g_table_target_registry; entry != NULL;
         entry = entry->table_target_next) {
        if (entry->instance_id == instance_id &&
            cosim_table_target_snapshot_valid(&entry->table_target_snapshot)) {
            *snapshot = entry->table_target_snapshot;
            return true;
        }
    }
    return false;
}

bool cosim_pcie_rc_bump_table_target_generation(uint32_t instance_id)
{
    CosimPCIeRC *entry;

    if (instance_id > UINT16_MAX) {
        return false;
    }
    for (entry = g_table_target_registry; entry != NULL;
         entry = entry->table_target_next) {
        uint32_t generation;

        if (entry->instance_id == instance_id) {
            generation = cosim_table_target_allocate_generation();
            if (generation == 0) {
                cosim_table_target_unlink(entry);
                entry->table_target_snapshot.generation = 0;
                return false;
            }
            entry->table_target_snapshot.generation = generation;
            return true;
        }
    }
    return false;
}

/* ---- Per-VF DMA isolation IOMMU (opt-in vf_iommu=on) --------------------
 * Each VF gets an AddressSpace whose IOMMU translate() is identity within the
 * VF's host-assigned window [win_base, win_base+win_size) and rejects (perm=0)
 * everything else — out-of-window and neighbor-VF alike — modeling a host IOMMU
 * keyed by requester BDF. The MSI region is always allowed: interrupt writes
 * (0xFEE.. via DMA-write) are not data DMA and must still reach the APIC. */
#define COSIM_MSI_BASE        0xFEE00000ULL
#define COSIM_MSI_END         0xFEF00000ULL
#define COSIM_IOMMU_PAGE_MASK 0xFFFULL          /* 4K translation granularity */
#define COSIM_IOMMU_AS_SIZE   (1ULL << 44)      /* IOVA space superset of GPA */
#define COSIM_PASID_WIN_SIZE  0x100000ULL       /* per-PASID sub-window slot = 1MB */

#define TYPE_COSIM_VF_IOMMU "cosim-vf-iommu"
struct CosimVfIommu {
    IOMMUMemoryRegion parent_obj;
    uint16_t vf_bdf;
    uint64_t win_base;
    uint64_t win_size;
};
typedef struct CosimVfIommu CosimVfIommu;
DECLARE_INSTANCE_CHECKER(CosimVfIommu, COSIM_VF_IOMMU, TYPE_COSIM_VF_IOMMU)

static IOMMUTLBEntry cosim_vf_translate(IOMMUMemoryRegion *iommu, hwaddr addr,
                                        IOMMUAccessFlags flag, int iommu_idx)
{
    CosimVfIommu *v = COSIM_VF_IOMMU(iommu);
    IOMMUTLBEntry e = {
        .target_as       = &address_space_memory,
        .iova            = addr & ~COSIM_IOMMU_PAGE_MASK,
        .translated_addr = addr & ~COSIM_IOMMU_PAGE_MASK,   /* identity remap */
        .addr_mask       = COSIM_IOMMU_PAGE_MASK,
        .perm            = IOMMU_NONE,                        /* deny by default */
    };
    bool in_win = (addr >= v->win_base && addr < v->win_base + v->win_size);
    bool is_msi = (addr >= COSIM_MSI_BASE && addr < COSIM_MSI_END);
    if (in_win || is_msi) e.perm = IOMMU_RW;
    return e;
}

static void cosim_vf_iommu_class_init(ObjectClass *klass, void *data)
{
    IOMMUMemoryRegionClass *imrc = IOMMU_MEMORY_REGION_CLASS(klass);
    imrc->translate = cosim_vf_translate;
}

static const TypeInfo cosim_vf_iommu_info = {
    .name          = TYPE_COSIM_VF_IOMMU,
    .parent        = TYPE_IOMMU_MEMORY_REGION,
    .instance_size = sizeof(CosimVfIommu),
    .class_init    = cosim_vf_iommu_class_init,
};

/* Resolve the VF that owns requester_id: returns the owning PF and sets
 * *vf_index_out to its aperture-local VF index, or NULL / -1 if not a VF.
 * Judged by the VF BAR aperture BDF range (first_vf_bdf + vf_index*stride),
 * NOT the config-stub table — cross-bus VFs have no stub yet are valid VFs. */
static CosimPCIeRC *cosim_vf_owner(uint16_t requester_id, int *vf_index_out)
{
    if (requester_id) {
        for (int p = 0; p < COSIM_RC_MAX_PF; p++) {
            CosimPCIeRC *pf = g_rc_pfs[p];
            if (!pf || !pf->vf_bar_ctx) continue;
            for (int i = 0; i < pf->num_vf_bars; i++) {
                CosimBarContext *bc = &pf->vf_bar_ctx[i];
                if (!bc->is_aperture || bc->vf_bdf_stride == 0) continue;
                if (requester_id < bc->first_vf_bdf) continue;
                uint32_t d = (uint32_t)(requester_id - bc->first_vf_bdf);
                if (d % bc->vf_bdf_stride == 0 &&
                    d / bc->vf_bdf_stride < (uint32_t)bc->num_vfs) {
                    if (vf_index_out) *vf_index_out = (int)(d / bc->vf_bdf_stride);
                    return pf;
                }
            }
        }
    }
    if (vf_index_out) *vf_index_out = -1;
    return NULL;
}

/* Does requester_id name one of any PF's VFs? Used only to attribute a DMA in
 * the log. In config-bypass without isolation the PF performs every transfer on
 * behalf of the VF; with vf_iommu=on each VF's transfer is routed through its
 * own windowed AddressSpace (cosim_dma_as). */
static bool cosim_rid_is_vf(CosimPCIeRC *s, uint16_t requester_id)
{
    (void)s;
    return cosim_vf_owner(requester_id, NULL) != NULL;
}

/* Pick the AddressSpace a DMA (requester_id, addr) must traverse. Default: the
 * PF bus-master AS (== pci_dma_* target, so behavior is byte-identical when
 * vf_iommu is off). With vf_iommu on, a VF's data DMA is routed through that
 * VF's windowed IOMMU AS; MSI writes stay on the PF AS (interrupt path). */
static AddressSpace *cosim_dma_as(CosimPCIeRC *s, uint16_t rid, uint64_t addr,
                                  bool translated)
{
    AddressSpace *pf_as = pci_get_address_space(PCI_DEVICE(s));
    /* AT=10: address already IOMMU-translated (pre-authorized via ATS). Trust it
     * and bypass both the per-VF window and the PF bus-master AddressSpace.
     * In config-bypass the guest's Command.BME write is intentionally consumed
     * by the VIP, so the PF DMA AS may remain disabled even after an ATS grant.
     * The translated PA must therefore be issued on QEMU's system address
     * space; AT=00 keeps using the requester/IOMMU path below. */
    if (translated) return &address_space_memory;
    if (!s->vf_iommu) return pf_as;
    if (addr >= COSIM_MSI_BASE && addr < COSIM_MSI_END) return pf_as;
    int vi = -1;
    CosimPCIeRC *owner = cosim_vf_owner(rid, &vi);
    if (!owner || !owner->vf_iommu || !owner->vf_as ||
        vi < 0 || vi >= owner->num_vf_iommu)
        return pf_as;
    return &((AddressSpace *)owner->vf_as)[vi];
}

static MemTxResult cosim_dma_wr(CosimPCIeRC *s, uint16_t rid, uint64_t addr,
                                const void *buf, uint32_t len, bool translated)
{
    return dma_memory_write(cosim_dma_as(s, rid, addr, translated), addr, buf,
                            len, MEMTXATTRS_UNSPECIFIED);
}

static MemTxResult cosim_dma_rd(CosimPCIeRC *s, uint16_t rid, uint64_t addr,
                                void *buf, uint32_t len, bool translated)
{
    return dma_memory_read(cosim_dma_as(s, rid, addr, translated), addr, buf,
                           len, MEMTXATTRS_UNSPECIFIED);
}

/* ATS Translation: resolve (rid, iova) through the per-VF window policy WITHOUT
 * performing a memory access. Returns true if a translation is granted, filling
 * *out_pa (translated PA; identity within the window) and *out_perm (IOMMU_RW).
 * Denied (out-of-window) → false. With vf_iommu off, translation is identity
 * passthrough (granted) — the ATS protocol still round-trips, just no isolation.
 * MSI region is always granted (interrupt writes are AT-exempt in real HW). */
static bool cosim_ats_translate(CosimPCIeRC *s, uint16_t rid, uint16_t pasid,
                                uint64_t iova, uint64_t *out_pa, uint32_t *out_perm)
{
    if (out_perm) *out_perm = IOMMU_RW;
    if (!s->vf_iommu) { if (out_pa) *out_pa = iova; return true; }
    if (iova >= COSIM_MSI_BASE && iova < COSIM_MSI_END) {
        if (out_pa) *out_pa = iova;
        return true;
    }
    int vi = -1;
    CosimPCIeRC *owner = cosim_vf_owner(rid, &vi);
    if (!owner || !owner->vf_iommu || !owner->vf_iommu_mr ||
        vi < 0 || vi >= owner->num_vf_iommu)
        return false;
    CosimVfIommu *v = &((CosimVfIommu *)owner->vf_iommu_mr)[vi];
    uint64_t lo = v->win_base, hi = v->win_base + v->win_size;
    if (pasid != 0) {
        /* Per-PASID isolation: each PASID gets a disjoint sub-window (slot) of
         * size COSIM_PASID_WIN_SIZE inside the VF window, so PASID p can only be
         * granted translations within its own slot — a separate address space. */
        uint64_t slot = (uint64_t)pasid * COSIM_PASID_WIN_SIZE;
        if (slot + COSIM_PASID_WIN_SIZE > v->win_size)
            return false;             /* PASID slot falls outside the VF window */
        lo = v->win_base + slot;
        hi = lo + COSIM_PASID_WIN_SIZE;
    }
    if (iova >= lo && iova < hi) {
        if (out_pa) *out_pa = iova;   /* identity remap within the (PASID) window */
        return true;
    }
    return false;
}

static void cosim_dma_cb(const dma_req_t *req, void *user)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(user);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    uint32_t dir = DMA_DIR_BASE(req->direction);
    bool at_translated = DMA_DIR_IS_TRANSLATED(req->direction);

    if (ctx->transport) {
        if (dir == DMA_DIR_ATS_TRANSLATE) {
            /* PCIe ATS Translation Request: device asks to translate host_addr
             * (an IOVA). Reply with the 8B translated PA via DMA_DATA+DMA_CPL;
             * cpl.status 0 = granted, 1 = no translation (isolation denies
             * out-of-window). No memory is touched. */
            uint64_t pa = 0; uint32_t perm = 0;
            bool granted = cosim_ats_translate(s, req->requester_id, req->_pad_rid,
                                               req->host_addr, &pa, &perm);
            uint8_t pbuf[8];
            for (int i = 0; i < 8; i++) pbuf[i] = (uint8_t)(pa >> (8 * i));
            bridge_complete_dma_with_data(ctx, req->tag, granted ? 0 : 1,
                                          DMA_DIR_READ, req->host_addr, pbuf, 8);
            qemu_log("cosim: ATS translate rid=0x%04x pasid=0x%05x IOVA=0x%lx -> %s PA=0x%lx "
                     "perm=0x%x tag=%u\n", req->requester_id, req->_pad_rid,
                     (unsigned long)req->host_addr,
                     granted ? "GRANT" : "DENY", (unsigned long)pa, perm, req->tag);
            return;
        }
        if (dir == DMA_DIR_ATS_PAGE_REQ) {
            /* PRI Page Request: device asks the host to make a page present.
             * Simple model — present iff the IOVA has a translation (in-window).
             * cpl.status 0 = PRG success (page ready), 1 = failure. */
            bool present = cosim_ats_translate(s, req->requester_id, req->_pad_rid,
                                               req->host_addr, NULL, NULL);
            bridge_complete_dma(ctx, req->tag, present ? 0 : 1);
            qemu_log("cosim: PRI page-req rid=0x%04x IOVA=0x%lx -> %s tag=%u\n",
                     req->requester_id, (unsigned long)req->host_addr,
                     present ? "SUCCESS" : "FAIL", req->tag);
            return;
        }
        if (DMA_DIR_IS_ATOMIC(dir)) {
            /* Inbound AtomicOp (EP requester): operand(s) arrive via DMA_DATA
             * (like a write); RMW guest RAM and return the ORIGINAL value via
             * DMA_DATA+DMA_CPL (like a read). The single poller thread serializes
             * this RMW w.r.t. other device DMA. req->len carries op_size (4/8). */
            uint32_t rtag, rdir, oplen = sizeof(((tlp_entry_t *)0)->data);
            uint64_t raddr;
            uint8_t opbuf[COSIM_TLP_DATA_SIZE];
            int ret = ctx->transport->recv_dma_data(ctx->transport, &rtag, &rdir,
                                                     &raddr, opbuf, &oplen);
            uint32_t sz = req->len;
            if (ret < 0 || (sz != 4 && sz != 8)) {
                qemu_log("cosim: AtomicOp bad (ret=%d sz=%u) tag=%u\n", ret, sz, req->tag);
                bridge_complete_dma(ctx, req->tag, 1);
                return;
            }
            uint8_t oldv[8] = {0}, newv[8] = {0};
            int do_write = 0;
            if (cosim_dma_rd(s, req->requester_id, req->host_addr, oldv, sz, false) != MEMTX_OK) {
                qemu_log("cosim: IOMMU BLOCK atomic rid=0x%04x GPA=0x%lx tag=%u\n",
                         req->requester_id, (unsigned long)req->host_addr, req->tag);
                bridge_complete_dma(ctx, req->tag, 1);
                return;
            }
            cosim_atomic_compute(dir, sz, oldv, opbuf, newv, &do_write);
            if (do_write)
                cosim_dma_wr(s, req->requester_id, req->host_addr, newv, sz, false);
            bridge_complete_dma_with_data(ctx, req->tag, 0, DMA_DIR_READ,
                                          req->host_addr, oldv, sz);
            uint64_t old_u64 = 0;
            for (uint32_t i = 0; i < sz; i++) old_u64 |= (uint64_t)oldv[i] << (8 * i);
            qemu_log("cosim: AtomicOp dir=%u GPA=0x%lx sz=%u old=0x%llx wrote=%d tag=%u (TCP)\n",
                     req->direction, (unsigned long)req->host_addr, sz,
                     (unsigned long long)old_u64, do_write, req->tag);
            return;
        }
        /* TCP mode: no shared dma_buf, must transfer data via network */
        if (dir == DMA_DIR_WRITE) {
            /* Device→Host: VCS sends data via DMA_DATA, we write to guest RAM.
             * In TCP mode, DMA_DATA arrives separately on the aux channel.
             * For DMA_DIR_WRITE, VCS should have sent DMA_DATA before DMA_REQ.
             * We need to recv_dma_data first, then write to guest memory. */
            uint32_t tag, direction;
            uint64_t host_addr;
            uint8_t buf[65536];
            uint32_t len = sizeof(buf);
            int ret = ctx->transport->recv_dma_data(ctx->transport, &tag, &direction,
                                                      &host_addr, buf, &len);
            if (ret < 0) {
                qemu_log("cosim: DMA write recv_dma_data failed tag=%u\n", req->tag);
                bridge_complete_dma(ctx, req->tag, 1);
                return;
            }
            /* pci_dma_write routes via the device bus-master AS so writes to
             * the APIC MSI region (0xFEE...) actually deliver an interrupt —
             * cpu_physical_memory_write hits raw RAM and drops the MSI. This
             * is how VCS-side MSI-X delivery (DMA-write msg_data->msg_addr)
             * reaches the guest. Normal RAM DMA is unaffected. */
            if (cosim_dma_wr(s, req->requester_id, req->host_addr, buf, len, at_translated) != MEMTX_OK) {
                qemu_log("cosim: IOMMU BLOCK write rid=0x%04x GPA=0x%lx len=%u tag=%u "
                         "(out-of-window)\n", req->requester_id,
                         (unsigned long)req->host_addr, len, req->tag);
                bridge_complete_dma(ctx, req->tag, 1);
                return;
            }
            bridge_complete_dma(ctx, req->tag, 0);
        } else {
            /* Host→Device: read guest RAM, send data back to VCS via DMA_DATA.
             * Route via cosim_dma_rd (the VF's IOMMU AS when vf_iommu on, else
             * the PF bus-master AS) to match the write path; cpu_physical_memory
             * bypasses the device AS and can disagree with what a write stored. */
            uint8_t buf[65536];
            uint32_t len = req->len > sizeof(buf) ? sizeof(buf) : req->len;
            if (cosim_dma_rd(s, req->requester_id, req->host_addr, buf, len, at_translated) != MEMTX_OK) {
                qemu_log("cosim: IOMMU BLOCK read rid=0x%04x GPA=0x%lx len=%u tag=%u "
                         "(out-of-window)\n", req->requester_id,
                         (unsigned long)req->host_addr, len, req->tag);
                bridge_complete_dma(ctx, req->tag, 1);
                return;
            }
            bridge_complete_dma_with_data(ctx, req->tag, 0,
                                           dir, req->host_addr, buf, len);
        }
    } else {
        /* SHM mode: data is in shared dma_buf */
        uint8_t *dma_buf = (uint8_t *)ctx->shm.dma_buf + req->dma_offset;
        if (DMA_DIR_IS_ATOMIC(req->direction)) {
            /* Operand(s) sit in dma_buf; RMW guest RAM, write ORIGINAL value
             * back into dma_buf for the requester to read. */
            uint32_t sz = req->len, status = 0;
            if (sz == 4 || sz == 8) {
                uint8_t oldv[8] = {0}, newv[8] = {0};
                int do_write = 0;
                cosim_dma_rd(s, req->requester_id, req->host_addr, oldv, sz, false);
                cosim_atomic_compute(dir, sz, oldv, dma_buf, newv, &do_write);
                if (do_write)
                    cosim_dma_wr(s, req->requester_id, req->host_addr, newv, sz, false);
                memcpy(dma_buf, oldv, sz);
            } else {
                status = 1;
            }
            bridge_complete_dma(ctx, req->tag, status);
        } else {
            if (req->direction == DMA_DIR_WRITE) {
                cpu_physical_memory_write(req->host_addr, dma_buf, req->len);
            } else {
                cpu_physical_memory_read(req->host_addr, dma_buf, req->len);
            }
            bridge_complete_dma(ctx, req->tag, 0);
        }
    }

    qemu_log("cosim: DMA %s%s OK GPA=0x%lx len=%u tag=%u rid=0x%04x from=%s (%s)\n",
             dir == DMA_DIR_WRITE ? "write" : "read",
             at_translated ? "(AT)" : "",
             (unsigned long)req->host_addr, req->len, req->tag,
             req->requester_id,
             cosim_rid_is_vf(s, req->requester_id) ? "vf" : "pf",
             ctx->transport ? "TCP" : "SHM");
}

/* MSI BH 回调：在 QEMU 主循环中执行，自然持有 BQL，无死锁风险 */
static void cosim_msi_bh_cb(void *opaque)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(opaque);
    PCIDevice *pci_dev = PCI_DEVICE(s);

    while (s->msi_queue_head != s->msi_queue_tail) {
        uint32_t vector = s->msi_queue[s->msi_queue_head % COSIM_MSI_QUEUE_SIZE];
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        s->msi_queue_head++;

        if (vector == 0xFFFEu) {
            qemu_log("cosim: MSI bh: deassert INTx (vector=0xFFFE)\n");
            pci_set_irq(pci_dev, 0);
        } else if (msi_enabled(pci_dev)) {
            qemu_log("cosim: MSI bh: msi_notify vector=%u\n", vector);
            msi_notify(pci_dev, vector);
        } else {
            qemu_log("cosim: MSI bh: pci_set_irq(1) INTx assert vector=%u\n", vector);
            pci_set_irq(pci_dev, 1);
        }
    }
}

/* MSI 中断回调：从 irq_poller 线程调用 — 不获取 BQL，仅入队 + 调度 BH */
static void cosim_msi_cb(uint32_t vector, void *user)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(user);

    int tail = s->msi_queue_tail;
    int head = s->msi_queue_head;
    if (tail - head >= COSIM_MSI_QUEUE_SIZE) {
        qemu_log("cosim: MSI queue full, dropping vector=%u\n", vector);
        return;
    }

    s->msi_queue[tail % COSIM_MSI_QUEUE_SIZE] = vector;
    __atomic_thread_fence(__ATOMIC_RELEASE);
    s->msi_queue_tail = tail + 1;

    qemu_bh_schedule((QEMUBH *)s->msi_bh);
}

static const MemoryRegionOps cosim_mmio_ops = {
    .read = cosim_mmio_read,
    .write = cosim_mmio_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 1,
        .max_access_size = 8,
    },
};

/* VF BAR aperture ops — decode vf_index from offset (see cosim_vf_aperture_*). */
static const MemoryRegionOps cosim_vf_aperture_ops = {
    .read = cosim_vf_aperture_read,
    .write = cosim_vf_aperture_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .impl = {
        .min_access_size = 1,
        .max_access_size = 8,
    },
};

/* ========== Phase 1: Config Space 转发 ========== */

static uint32_t cosim_config_read(PCIDevice *pci_dev, uint32_t address, int len)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* Bridge 未连接时，使用 QEMU 本地 config space */
    if (!ctx) {
        uint32_t local_val = pci_default_read_config(pci_dev, address, len);
        COSIM_DPRINTF(s, "cfg_read LOCAL addr=0x%02x len=%d -> 0x%x\n",
                address, len, local_val);
        return local_val;
    }

    /* ---- BDF 缓存过滤 ---- */
    int bus  = pci_bus_num(pci_get_bus(pci_dev));
    int dev  = PCI_SLOT(pci_dev->devfn);
    int func = PCI_FUNC(pci_dev->devfn);

    if (bus < COSIM_MAX_BUS && dev < COSIM_MAX_DEV && func < COSIM_MAX_FUNC) {
        CosimBdfCacheEntry *entry = &s->bdf_cache[bus][dev][func];

        if (!entry->probed) {
            /* 首次访问: 主动读 vendor/device ID (offset 0x00) */
            tlp_entry_t probe_req = {0};
            probe_req.type     = TLP_CFGRD;
            probe_req.addr     = 0x00;
            probe_req.len      = 4;
            probe_req.first_be = 0xF;
            /* Route to this device's function: target_bdf = its PCIe BDF.
               Without it the VCS config_proxy (multi-function) cannot match
               the PF and returns 0xFFFFFFFF -> device never enumerates. */
            cosim_route_host_to_device(&probe_req, cosim_current_bdf(pci_dev));

            cpl_entry_t probe_cpl = {0};
            int probe_ret = bridge_send_tlp_and_wait(ctx, &probe_req, &probe_cpl);

            if (probe_ret < 0) {
                entry->vendor_id = 0xFFFF;
            } else {
                entry->vendor_id = (uint16_t)(probe_cpl.data[0] |
                                              (probe_cpl.data[1] << 8));
            }
            entry->probed = true;
            entry->valid  = (entry->vendor_id != 0xFFFF);

            COSIM_DPRINTF(s, "BDF %02x:%02x.%x probe: vendor=0x%04x valid=%d\n",
                    bus, dev, func, entry->vendor_id, entry->valid);

            if (!entry->valid) {
                return 0xFFFFFFFF;
            }

            /* 如果内核请求的就是 offset 0x00，直接返回已获取的数据 */
            if ((address & ~3u) == 0x00) {
                uint32_t dword = 0;
                for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
                    dword |= ((uint32_t)probe_cpl.data[i]) << (i * 8);
                }
                uint32_t byte_offset = address & 3u;
                uint32_t val = dword >> (byte_offset * 8);
                if (len < 4) {
                    val &= (1u << (len * 8)) - 1;
                }
                return val;
            }
        }

        if (!entry->valid) {
            return 0xFFFFFFFF;
        }
    }

    /* 有效设备 — 正常转发 VCS */
    uint32_t dword_addr = address & ~3u;
    uint32_t byte_offset = address & 3u;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len = 4;
    cosim_route_host_to_device(&req, cosim_current_bdf(pci_dev));

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        uint32_t fallback = pci_default_read_config(pci_dev, address, len);
        COSIM_DPRINTF(s, "cfg_read addr=0x%02x len=%d VCS_FAIL -> local=0x%x\n",
                address, len, fallback);
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

    COSIM_DPRINTF(s, "cfg_read addr=0x%02x len=%d -> 0x%x (dw=0x%08x off=%u)\n",
            address, len, val, dword, byte_offset);
    return val;
}

static void cosim_config_write(PCIDevice *pci_dev, uint32_t address,
                               uint32_t data, int len)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* 始终先写本地 config space，保证 QEMU 内部状态一致 */
    pci_default_write_config(pci_dev, address, data, len);

    if (!ctx) {
        return;
    }

    /* ---- BDF 缓存过滤: 无效设备的 CfgWr 直接丢弃 ---- */
    int bus  = pci_bus_num(pci_get_bus(pci_dev));
    int dev  = PCI_SLOT(pci_dev->devfn);
    int func = PCI_FUNC(pci_dev->devfn);

    if (bus < COSIM_MAX_BUS && dev < COSIM_MAX_DEV && func < COSIM_MAX_FUNC) {
        CosimBdfCacheEntry *entry = &s->bdf_cache[bus][dev][func];
        if (!entry->probed || !entry->valid) {
            COSIM_DPRINTF(s, "BDF %02x:%02x.%x CfgWr dropped (invalid device)\n",
                    bus, dev, func);
            return;
        }
    }

    /* 有效设备 — 转发 CfgWr TLP 到 VCS */
    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = address;
    req.len = len;
    cosim_route_host_to_device(&req, cosim_current_bdf(pci_dev));
    for (int i = 0; i < len && i < COSIM_TLP_DATA_SIZE; i++) {
        req.data[i] = (data >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: CfgWr failed addr=0x%x data=0x%x\n",
                      address, data);
    }

    COSIM_DPRINTF(s, "CfgWr addr=0x%02x len=%d data=0x%x\n",
                  address, len, data);

    /* An extended-config write (offset >= 0x100) may be an SR-IOV VF-enable
     * (SR-IOV Control lives in the PF's SR-IOV cap). VCS answers such a write by
     * pushing VF_EVENT/VF_CONFIG on ctrl_fd (no CfgWr completion). The guest
     * kernel reads VF config synchronously right after the VFE write, so drain
     * and apply those messages NOW (bounded) — otherwise the VF stubs/apertures
     * aren't in place yet and the VF reads back 0xFF (rejected). Normal writes
     * (< 0x100, e.g. BAR sizing) stay fire-and-forget for fast enumeration. */
    if (address >= 0x100) {
        bridge_drain_vf_pending(ctx, 200);
    }
}

/* ========== 设备发现: 从 VCS EP 查询配置 ========== */

static uint32_t cosim_cfgrd(bridge_ctx_t *ctx, uint16_t target_bdf,
                            uint32_t reg) {
    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = reg & ~3u;
    req.len  = 4;
    req.first_be = 0xF;
    cosim_route_host_to_device(&req, target_bdf);
    cpl_entry_t cpl = {0};
    if (bridge_send_tlp_and_wait(ctx, &req, &cpl) < 0) return 0xFFFFFFFF;
    uint32_t dw = 0;
    for (int i = 0; i < 4; i++) dw |= ((uint32_t)cpl.data[i]) << (i * 8);
    return dw;
}

static void cosim_cfgwr(bridge_ctx_t *ctx, uint16_t target_bdf,
                        uint32_t reg, uint32_t data) {
    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = reg;
    req.len  = 4;
    req.first_be = 0xF;
    cosim_route_host_to_device(&req, target_bdf);
    for (int i = 0; i < 4; i++) req.data[i] = (data >> (i * 8)) & 0xFF;
    bridge_send_tlp_fire(ctx, &req);
}

/* BAR sizing: 写 0xFFFFFFFF → 读回 mask → 恢复 → 计算大小 */
static uint32_t cosim_query_bar_size(bridge_ctx_t *ctx, uint16_t target_bdf,
                                     int bar) {
    uint32_t reg = 0x10 + bar * 4;  /* PCI_BASE_ADDRESS_0 = 0x10 */
    uint32_t orig = cosim_cfgrd(ctx, target_bdf, reg);
    cosim_cfgwr(ctx, target_bdf, reg, 0xFFFFFFFF);
    uint32_t mask = cosim_cfgrd(ctx, target_bdf, reg);
    cosim_cfgwr(ctx, target_bdf, reg, orig);  /* 恢复 */
    if (mask == 0 || mask == 0xFFFFFFFF) return 0;
    /* 清除低 4 位 (type/prefetch bits) */
    mask &= ~0xFu;
    return ~mask + 1;
}

/* 遍历 capability 链找 MSI */
static void cosim_discover_caps(CosimPCIeRC *s, bridge_ctx_t *ctx,
                                 uint16_t target_bdf,
                                 int *msi_offset, int *msi_vectors) {
    *msi_offset = -1;
    *msi_vectors = 0;
    uint32_t status_cmd = cosim_cfgrd(ctx, target_bdf, 0x04);
    if (!((status_cmd >> 20) & 1)) return;  /* CAP_LIST bit in Status */
    uint8_t ptr = cosim_cfgrd(ctx, target_bdf, 0x34) & 0xFC;
    int safety = 48;  /* 防止无限循环 */
    while (ptr && safety-- > 0) {
        uint32_t dw = cosim_cfgrd(ctx, target_bdf, ptr);
        uint8_t cap_id = dw & 0xFF;
        if (cap_id == 0x05) {  /* PCI_CAP_ID_MSI */
            *msi_offset = ptr;
            uint16_t msg_ctrl = (dw >> 16) & 0xFFFF;
            *msi_vectors = 1 << ((msg_ctrl >> 1) & 0x7);
            COSIM_DPRINTF(s, "discover MSI cap at 0x%02x, vectors=%d, ctrl=0x%04x\n",
                    ptr, *msi_vectors, msg_ctrl);
        }
        ptr = (dw >> 8) & 0xFC;
    }
}

/* Register the BARs owned by one PF topology entry.  A 64-bit BAR consumes
 * its following config DWORD, so that upper slot must have neither a size nor
 * flags and must never be registered as an independent QEMU BAR. */
static bool cosim_register_pf_bars(CosimPCIeRC *s, PCIDevice *dev,
                                   const pf_topology_t *pf, Error **errp)
{
    const uint32_t allowed_flags = PCI_BASE_ADDRESS_MEM_TYPE_MASK |
                                   PCI_BASE_ADDRESS_MEM_PREFETCH;
    const uint32_t mem64_prefetch_flags =
        PCI_BASE_ADDRESS_MEM_TYPE_64 | PCI_BASE_ADDRESS_MEM_PREFETCH;
    int bus_num = pci_bus_num(pci_get_bus(dev));
    uint16_t target_bdf = (uint16_t)((bus_num << 8) | dev->devfn);

    s->num_bars = 0;
    for (int bar = 0; bar < COSIM_MAX_BARS; bar++) {
        uint64_t size = pf->pf_bar_size[bar];
        uint32_t raw_flags = pf->pf_bar_flags[bar];

        if (size == 0) {
            if (raw_flags != 0) {
                error_setg(errp, "cosim: PF%u BAR%d has flags without a size",
                           s->pf_index, bar);
                return false;
            }
            continue;
        }
        if (!is_power_of_2(size)) {
            error_setg(errp,
                       "cosim: PF%u BAR%d has non-power-of-two size 0x%" PRIx64,
                       s->pf_index, bar, size);
            return false;
        }
        if (raw_flags & PCI_BASE_ADDRESS_SPACE_IO) {
            error_setg(errp, "cosim: PF%u BAR%d I/O space is unsupported",
                       s->pf_index, bar);
            return false;
        }
        if (raw_flags & ~allowed_flags) {
            error_setg(errp, "cosim: PF%u BAR%d has unsupported flags 0x%x",
                       s->pf_index, bar, raw_flags);
            return false;
        }

        uint32_t memory_type = raw_flags & PCI_BASE_ADDRESS_MEM_TYPE_MASK;
        if (memory_type != 0 &&
            memory_type != PCI_BASE_ADDRESS_MEM_TYPE_64) {
            error_setg(errp,
                       "cosim: PF%u BAR%d has reserved memory type 0x%x",
                       s->pf_index, bar, memory_type);
            return false;
        }
        uint32_t flags = raw_flags & allowed_flags;
        bool is_64bit = memory_type == PCI_BASE_ADDRESS_MEM_TYPE_64;
        if (is_64bit) {
            if ((flags & mem64_prefetch_flags) != mem64_prefetch_flags) {
                error_setg(errp,
                           "cosim: PF%u BAR%d 64-bit owner must be prefetchable",
                           s->pf_index, bar);
                return false;
            }
            if (bar + 1 >= COSIM_MAX_BARS) {
                error_setg(errp, "cosim: PF%u BAR%d is a 64-bit BAR without an upper DWORD",
                           s->pf_index, bar);
                return false;
            }
            if (pf->pf_bar_size[bar + 1] != 0 ||
                pf->pf_bar_flags[bar + 1] != 0) {
                error_setg(errp,
                           "cosim: PF%u BAR%d 64-bit upper DWORD owns BAR data",
                           s->pf_index, bar);
                return false;
            }
            flags = mem64_prefetch_flags;
        }

        CosimBarContext *bc = &s->bar_ctx[bar];
        bc->dev = s;
        bc->bar_index = bar;
        bc->explicit_base = 0;
        bc->target_bdf = target_bdf;

        char name[48];
        snprintf(name, sizeof(name), "cosim-pf%u-bar%d", s->pf_index, bar);
        memory_region_init_io(&s->bars[bar], OBJECT(dev), &cosim_mmio_ops,
                              bc, name, size);
        pci_register_bar(dev, bar, flags, &s->bars[bar]);
        s->num_bars++;

        if (is_64bit)
            bar++;  /* upper DWORD is owned by this registration */
    }

    if (s->num_bars == 0) {
        error_setg(errp, "cosim: PF%u topology has no owner BAR", s->pf_index);
        return false;
    }

    return true;
}

/* ========== 设备生命周期 ========== */

/* ========== VF config apply (VCS/DUT → QEMU) ========== */

/* ---- SR-IOV VF config-space stub device ------------------------------------
 * The guest kernel enumerates each VF at its own BDF and reads the VF config
 * header (class, header type, caps); it rejects the VF if those read back 0xFF
 * (no device responding). VF BARs are served by the PF's aperture, but the VF
 * still needs a config space. We create a tiny stub PCIDevice at each VF BDF
 * whose config_read/write forward to VCS (the DUT owns the VF config space),
 * routed by the VF's own BDF. */
/* Named cosim-pcie-rc-vf to avoid colliding with the separate cosim-pcie-vf
 * type (cosim_pcie_vf.c, the cosim-pcie-pf multi-function model). This stub is
 * the VF companion of the cosim-pcie-rc config-bypass model. */

static uint32_t cosim_rc_vf_config_read(PCIDevice *pci_dev, uint32_t address, int len)
{
    CosimRcVF *vf = COSIM_RC_VF(pci_dev);
    CosimPCIeRC *s = vf->pf;
    bridge_ctx_t *ctx = s ? (bridge_ctx_t *)s->bridge_ctx : NULL;
    if (!ctx)
        return pci_default_read_config(pci_dev, address, len);

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = address & ~3u;
    req.len = 4;
    req.first_be = 0xF;
    cosim_route_host_to_device(&req, vf->vf_bdf);

    cpl_entry_t cpl = {0};
    if (bridge_send_tlp_and_wait(ctx, &req, &cpl) < 0)
        return 0xFFFFFFFF;

    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++)
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);

    uint32_t val = dword >> ((address & 3u) * 8);
    if (len < 4)
        val &= (1u << (len * 8)) - 1;
    return val;
}

static void cosim_rc_vf_config_write(PCIDevice *pci_dev, uint32_t address,
                                  uint32_t data, int len)
{
    CosimRcVF *vf = COSIM_RC_VF(pci_dev);
    CosimPCIeRC *s = vf->pf;
    pci_default_write_config(pci_dev, address, data, len);
    bridge_ctx_t *ctx = s ? (bridge_ctx_t *)s->bridge_ctx : NULL;
    if (!ctx)
        return;

    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = address;
    req.len = len;
    cosim_route_host_to_device(&req, vf->vf_bdf);
    for (int i = 0; i < len && i < COSIM_TLP_DATA_SIZE; i++)
        req.data[i] = (data >> (i * 8)) & 0xFF;
    bridge_send_tlp_fire(ctx, &req);
}

static void cosim_rc_vf_realize(PCIDevice *dev, Error **errp)
{
    /* Guest config is forwarded to VCS.  The local ARI marker is still needed
     * by QEMU's post-realize link check for raw devfn values above 7. */
    pcie_ari_init(dev, 0x100);
    (void)errp;
}

static void cosim_rc_vf_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);
    k->realize      = cosim_rc_vf_realize;
    k->config_read  = cosim_rc_vf_config_read;
    k->config_write = cosim_rc_vf_config_write;
    k->vendor_id = COSIM_PCI_VENDOR_ID;
    k->device_id = COSIM_PCI_DEVICE_ID;
    k->revision  = COSIM_PCI_REVISION;
    k->class_id  = PCI_CLASS_NETWORK_ETHERNET;
    dc->user_creatable = false;   /* created only via SR-IOV VF enable */
    dc->desc = "CoSim SR-IOV VF config stub (cosim-pcie-rc)";
}

static const TypeInfo cosim_rc_vf_info = {
    .name          = TYPE_COSIM_RC_VF,
    .parent        = TYPE_PCI_DEVICE,
    .instance_size = sizeof(CosimRcVF),
    .class_init    = cosim_rc_vf_class_init,
    .interfaces    = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

/* Tear down all dynamically mapped VF BAR regions and VF config stubs. */
/* ATS Invalidation (RC→device): the per-VF window is going away, so tell the
 * device to flush its ATC for each VF. Sent as a TLP_ATS_INVAL that the EP
 * answers with a Completion (the invalidation ACK); bridge_send_tlp_and_wait
 * blocks until the ACK — a genuine closed loop. Only meaningful on the config-
 * write path (transport live, VCS polling); skipped on device teardown/exit. */
static void cosim_vf_invalidate_atc(CosimPCIeRC *s)
{
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
    if (!ctx || !ctx->transport || !s->vf_iommu_mr || s->num_vf_iommu <= 0)
        return;
    CosimVfIommu *ima = (CosimVfIommu *)s->vf_iommu_mr;
    for (int i = 0; i < s->num_vf_iommu; i++) {
        tlp_entry_t req = {0};
        cpl_entry_t cpl = {0};
        req.type         = TLP_ATS_INVAL;
        req.addr         = ima[i].win_base;
        req.len          = 1;
        cosim_route_host_to_device(&req, ima[i].vf_bdf);
        int r = bridge_send_tlp_and_wait_timed(ctx, &req, &cpl, 5000);
        qemu_log("cosim: ATS invalidate VF 0x%04x win=0x%lx -> %s\n",
                 ima[i].vf_bdf, (unsigned long)ima[i].win_base,
                 r >= 0 ? "ACK" : "no-ack/timeout");
    }
}

static void cosim_vf_teardown(CosimPCIeRC *s, bool invalidate)
{
    /* Flush the device ATC before the windows disappear (config-write path). */
    if (invalidate)
        cosim_vf_invalidate_atc(s);

    for (int i = 0; i < s->num_vf_devs; i++) {
        if (s->vf_devs[i])
            object_unparent(OBJECT(s->vf_devs[i]));
    }
    g_free(s->vf_devs); s->vf_devs = NULL;
    s->num_vf_devs = 0;

    for (int i = 0; i < s->num_vf_bars; i++) {
        memory_region_del_subregion(get_system_memory(), &s->vf_bars[i]);
        object_unparent(OBJECT(&s->vf_bars[i]));
    }
    g_free(s->vf_bars);    s->vf_bars = NULL;
    g_free(s->vf_bar_ctx); s->vf_bar_ctx = NULL;
    s->num_vf_bars = 0;

    if (s->vf_as) {
        AddressSpace *asa = (AddressSpace *)s->vf_as;
        CosimVfIommu *ima = (CosimVfIommu *)s->vf_iommu_mr;
        for (int i = 0; i < s->num_vf_iommu; i++) {
            address_space_destroy(&asa[i]);
            object_unparent(OBJECT(&ima[i]));
        }
        g_free(asa); s->vf_as = NULL;
        g_free(ima); s->vf_iommu_mr = NULL;
        s->num_vf_iommu = 0;
    }
}

/* Callback invoked (in the QEMU main thread, BQL held, during a VF-enable
 * CfgWr completion wait) when VCS pushes the VF layout. Real-HW aperture model:
 * map ONE MMIO region per (PF,BAR) covering all VFs; the aperture handler
 * decodes vf_index from the offset and routes to that VF's RID. This mirrors
 * hardware VF_BAR_base + vf_index*size striping and scales to 256 VF/PF with
 * ≤6 regions (vs. num_vfs*6 per-VF regions). VF config enumeration is answered
 * by VCS via config bypass; here we only wire the data-plane MMIO windows. */
static void cosim_vf_config_apply(const vf_config_t *cfg, void *user)
{
    CosimPCIeRC *s = (CosimPCIeRC *)user;

    /* The primary PF registers a single VF-config callback for the shared
     * transport; route each event to the PF the VCS addressed by pf_index. */
    if (cfg->pf_index >= COSIM_RC_MAX_PF || !g_rc_pfs[cfg->pf_index]) {
        qemu_log("cosim-vf: reject config for unavailable PF index %u\n",
                 cfg->pf_index);
        return;
    }
    s = g_rc_pfs[cfg->pf_index];

    /* Re-apply is idempotent; invalidate the device ATC for the outgoing windows
     * (transport is live on this config-write path — closed-loop ACK). */
    cosim_vf_teardown(s, true);

    if (!cfg->valid || cfg->num_vfs == 0) {
        qemu_log("cosim-vf: pf%d VF disabled, apertures torn down\n",
                 cfg->pf_index);
        return;
    }

    /* Guest just enabled VFs -> device-initiated DMA (EP -> cosim_dma_cb) will
     * follow. Machine reset after realize cleared PCI_COMMAND and disabled the
     * PF's bus_master_enable_region; in config-bypass the guest's re-enable of
     * MASTER goes to VCS, never to QEMU's shadow, so the region would stay off
     * and DMA to guest RAM hits MEMTX_DECODE_ERROR. Force it on here (BQL held
     * on this config-write path). */
    {
        PCIDevice *pd = PCI_DEVICE(s);
        pci_set_word(pd->config + PCI_COMMAND,
                     pci_get_word(pd->config + PCI_COMMAND) | PCI_COMMAND_MASTER);
        memory_region_set_enabled(&pd->bus_master_enable_region, true);
    }

    /* One aperture region per BAR (≤ COSIM_MAX_BARS). */
    s->vf_bars    = g_new0(MemoryRegion, COSIM_MAX_BARS);
    s->vf_bar_ctx = g_new0(CosimBarContext, COSIM_MAX_BARS);

    int idx = 0;
    for (int b = 0; b < COSIM_MAX_BARS; b++) {
        uint64_t base   = cfg->vf_bar_base[b];    /* VF0 BAR base = aperture base */
        uint64_t stride = cfg->vf_bar_stride[b];  /* per-VF BAR size */
        if (base == 0 || stride == 0) continue;

        uint64_t aperture_size = (uint64_t)cfg->num_vfs * stride;

        CosimBarContext *bc = &s->vf_bar_ctx[idx];
        bc->dev           = s;
        bc->bar_index     = b;
        bc->explicit_base = base;
        bc->is_aperture   = 1;
        bc->vf_bar_size   = stride;
        bc->first_vf_bdf  = cfg->first_vf_bdf;
        bc->vf_bdf_stride = cfg->vf_bdf_stride;
        bc->num_vfs       = cfg->num_vfs;

        char name[48];
        snprintf(name, sizeof(name), "cosim-vf-ap-pf%d-bar%d", cfg->pf_index, b);
        memory_region_init_io(&s->vf_bars[idx], OBJECT(s), &cosim_vf_aperture_ops,
                              bc, name, aperture_size);
        memory_region_add_subregion_overlap(get_system_memory(), base,
                                            &s->vf_bars[idx], 1);
        idx++;
    }
    s->num_vf_bars = idx;
    qemu_log("cosim-vf: pf%d mapped %d VF BAR aperture(s) for %d VFs "
             "(first_bdf=0x%04x bdf_stride=%u)\n",
             cfg->pf_index, idx, cfg->num_vfs, cfg->first_vf_bdf,
             cfg->vf_bdf_stride);

    /* Per-VF DMA isolation: one windowed IOMMU AddressSpace per VF. VFk may only
     * DMA within [vf_dma_base + k*vf_dma_size, +vf_dma_size); out-of-window and
     * neighbor-VF accesses hit perm=0 -> MEMTX_ERROR -> "IOMMU BLOCK". Window is
     * host-side policy (like a real host IOMMU), derived locally, NOT sent from
     * VCS — keeps the vf_config wire format and validated TCP path unchanged. */
    if (s->vf_iommu) {
        CosimVfIommu *ima = g_new0(CosimVfIommu, cfg->num_vfs);
        AddressSpace *asa = g_new0(AddressSpace, cfg->num_vfs);
        for (int vf = 0; vf < cfg->num_vfs; vf++) {
            uint16_t vbdf = cfg->first_vf_bdf + vf * cfg->vf_bdf_stride;
            char nm[64];
            snprintf(nm, sizeof(nm), "cosim-vf-iommu-%04x", vbdf);
            memory_region_init_iommu(&ima[vf], sizeof(CosimVfIommu),
                                     TYPE_COSIM_VF_IOMMU, OBJECT(s), nm,
                                     COSIM_IOMMU_AS_SIZE);
            ima[vf].vf_bdf   = vbdf;
            /* Globally-unique window per (PF,VF) so different PFs' VFs don't
             * alias — a real host IOMMU isolates by full requester BDF. */
            ima[vf].win_base = s->vf_dma_base +
                ((uint64_t)cfg->pf_index * cfg->num_vfs + vf) * s->vf_dma_size;
            ima[vf].win_size = s->vf_dma_size;
            char an[64];
            snprintf(an, sizeof(an), "cosim-vf-as-%04x", vbdf);
            address_space_init(&asa[vf], MEMORY_REGION(&ima[vf]), an);
        }
        s->vf_iommu_mr  = ima;
        s->vf_as        = asa;
        s->num_vf_iommu = cfg->num_vfs;
        qemu_log("cosim-vf: pf%d IOMMU isolation ON — %d VF AS, win base=0x%lx "
                 "size=0x%lx/VF\n", cfg->pf_index, cfg->num_vfs,
                 (unsigned long)s->vf_dma_base, (unsigned long)s->vf_dma_size);
    }

    /* Create a config-space stub PCIDevice at each VF BDF so the guest kernel
     * can read the VF config header (class/header-type/caps) — forwarded to VCS
     * by the stub's own BDF. VF BARs stay served by the apertures above. */
    PCIBus *pbus = pci_get_bus(&s->parent_obj);
    int pf_bus = pci_bus_num(pbus);
    s->vf_devs = g_new0(PCIDevice *, cfg->num_vfs);
    int nd = 0;
    for (int vf = 0; vf < cfg->num_vfs; vf++) {
        uint16_t vf_bdf = cfg->first_vf_bdf + vf * cfg->vf_bdf_stride;
        if ((vf_bdf >> 8) != pf_bus) {
            /* VF spilled onto a bus other than the PF's — creating a stub there
             * needs that child bus to exist (TODO for >255-func fan-out). */
            qemu_log("cosim-vf: VF bdf 0x%04x on bus %d (pf bus %d) — cross-bus "
                     "config stub not yet supported, skipped\n",
                     vf_bdf, vf_bdf >> 8, pf_bus);
            continue;
        }
        PCIDevice *d = pci_new(vf_bdf & 0xFF, TYPE_COSIM_RC_VF);
        /* Created programmatically on SR-IOV enable, not a user hotplug: clear
         * the hotplugged flag (device_initfn sets it once the machine is ready)
         * so do_pci_register_device() allows adding this non-func-0 device to
         * the PF's slot. */
        DEVICE(d)->hotplugged = false;
        /* Mark each stub multifunction too: VFs span multiple slots (devfn 1..N
         * = slot 0..31 without ARI), and pci_init_multifunction() requires each
         * slot's func-0 device to be multifunction-capable before funcs 1-7 can
         * be added to that slot. */
        d->cap_present |= QEMU_PCI_CAP_MULTIFUNCTION;
        CosimRcVF *vfd = COSIM_RC_VF(d);
        vfd->pf = s;
        vfd->vf_bdf = vf_bdf;
        Error *err = NULL;
        if (!pci_realize_and_unref(d, pbus, &err)) {
            qemu_log("cosim-vf: realize VF stub bdf 0x%04x failed: %s\n",
                     vf_bdf, err ? error_get_pretty(err) : "?");
            error_free(err);
            continue;
        }
        s->vf_devs[nd++] = d;
    }
    s->num_vf_devs = nd;
    qemu_log("cosim-vf: pf%d created %d VF config stub(s)\n", cfg->pf_index, nd);
}

static void cosim_pcie_rc_exit(PCIDevice *pci_dev);

static void cosim_pcie_rc_realize(PCIDevice *pci_dev, Error **errp)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    s->num_bars = 0;
    s->vcs_wait_depth = 0;
    s->vcs_wait_ticks_owned = false;
    s->vcs_wait_started_ns = 0;

    /* Mark the PF multifunction so QEMU allows adding VF stub PCIDevices
     * (func 1+) to this slot on SR-IOV enable. pci_init_multifunction() gates
     * new functions on the slot-0 device's cap_present bit (not the config
     * header byte), so set the capability here. The guest never depends on
     * this (config is forwarded to VCS; VFs are enumerated via ARI). */
    pci_dev->cap_present |= QEMU_PCI_CAP_MULTIFUNCTION;
    pci_dev->config[PCI_HEADER_TYPE] |= PCI_HEADER_TYPE_MULTI_FUNCTION;

    /* QEMU's post-realize PCIe link check consults the local shadow config,
     * while guest config reads are forwarded to the VIP. Mark every local PF
     * ARI-capable as well so raw devfn 8..15 are recognized as ARI functions
     * rather than invalid device numbers behind a Downstream Port. */
    pcie_ari_init(pci_dev, 0x100);

    /* 清零 BDF 缓存 */
    memset(s->bdf_cache, 0, sizeof(s->bdf_cache));

    /* Sibling PFs (function 1..num_pfs-1): share the primary PF0's transport and
     * irq_poller. Config space is forwarded to VCS by this device's own BDF
     * (cosim_config_read/write derive it from devfn), so no local discovery,
     * MSI, or poller is needed here — only topology-driven BARs + bus
     * mastering. */
    if (s->pf_index != 0) {
        CosimPCIeRC *pf0 = g_rc_pfs[0];
        if (!pf0 || !pf0->bridge_ctx || !pf0->topology_valid ||
            s->pf_index >= pf0->topology.header.num_pfs) {
            error_setg(errp, "cosim: PF%u realized before primary PF0",
                       s->pf_index);
            return;
        }
        s->bridge_ctx = pf0->bridge_ctx;   /* shared, not owned */
        if (!cosim_register_pf_bars(s, pci_dev,
                                    &g_rc_pfs[0]->topology.pfs[s->pf_index],
                                    errp)) {
            s->bridge_ctx = NULL;
            return;
        }
        pci_set_word(pci_dev->config + PCI_COMMAND,
                     PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);
        memory_region_set_enabled(&pci_dev->bus_master_enable_region, true);
        pci_config_set_interrupt_pin(pci_dev->config, 1);
        if (s->pf_index < COSIM_RC_MAX_PF) g_rc_pfs[s->pf_index] = s;
        qemu_log("cosim: PF%u sibling realized at %02x:%02x.%x (shares PF0 transport)\n",
                 s->pf_index, pci_bus_num(pci_get_bus(pci_dev)),
                 PCI_SLOT(pci_dev->devfn), PCI_FUNC(pci_dev->devfn));
        return;
    }

    if (s->num_pfs < 1 || s->num_pfs > COSIM_RC_MAX_PF) {
        error_setg(errp, "cosim: num_pfs must be in range 1..%d, got %u",
                   COSIM_RC_MAX_PF, s->num_pfs);
        return;
    }
    if (!cosim_single_bus_profile_fits(pci_dev->devfn, s->num_pfs, 0)) {
        error_setg(errp, "cosim: %u PFs starting at devfn 0x%02x overflow one bus",
                   s->num_pfs, pci_dev->devfn);
        return;
    }
    if (s->num_pfs == COSIM_RC_MAX_PF && pci_dev->devfn != 0) {
        error_setg(errp,
                   "cosim: 16-PF single-bus profile requires PF0 at devfn 0");
        return;
    }

    /* ======== 第一步: 建立 Bridge 连接 ======== */
    if (s->transport && strcmp(s->transport, "tcp") == 0) {
        /* TCP mode */
        transport_cfg_t cfg = {
            .transport   = "tcp",
            .listen_addr = "0.0.0.0",
            .remote_host = s->remote_host,
            .port_base   = (int)s->port_base,
            .instance_id = (int)s->instance_id,
            .is_server   = 1,  /* QEMU side listens */
        };
        s->bridge_ctx = bridge_init_ex(&cfg);
        if (!s->bridge_ctx) {
            error_setg(errp, "cosim: bridge_init_ex failed (tcp, port_base=%d)",
                       s->port_base);
            return;
        }
        bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
        if (bridge_connect_ex(ctx) < 0) {
            error_setg(errp, "cosim: bridge_connect_ex failed (waiting for VCS)");
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            return;
        }
    } else {
        /* SHM mode (original path) */
        if (!s->shm_name || !s->sock_path) {
            error_setg(errp, "cosim: shm_name and sock_path properties required");
            return;
        }
        s->bridge_ctx = bridge_init(s->shm_name, s->sock_path);
        if (!s->bridge_ctx) {
            error_setg(errp, "cosim: bridge_init failed (shm=%s sock=%s)",
                       s->shm_name, s->sock_path);
            return;
        }
        bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
        if (bridge_connect(ctx) < 0) {
            error_setg(errp, "cosim: bridge_connect failed (waiting for VCS)");
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            return;
        }
    }

    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
    /* QEMU software tags remain 10-bit. The VCS RC proxy maps them onto the
     * selected 8/10-bit physical VIP/DUT tag pool. Future PF devices use this
     * public API instead of directly modifying bridge_ctx_t internals. */
    if (bridge_set_tag_bit(ctx, 10) < 0) {
        error_setg(errp, "cosim: failed to select 10-bit QEMU bridge tags");
        bridge_destroy(ctx);
        s->bridge_ctx = NULL;
        return;
    }
    ctx->debug = s->debug;  /* propagate runtime debug flag to bridge */

    /* ======== 第二步: 查询 VCS 拓扑并建立 PF BAR profile ======== */
    memset(&s->topology, 0, sizeof(s->topology));
    s->topology_valid = false;
    if (bridge_query_topology(ctx, &s->topology) < 0) {
        error_setg(errp, "cosim: bridge_query_topology failed");
        bridge_destroy(ctx);
        s->bridge_ctx = NULL;
        return;
    }
    s->topology_valid = s->topology.header.num_pfs != 0;
    if (!s->topology_valid && s->num_pfs != 1) {
        error_setg(errp,
                   "cosim: VCS returned no topology for QEMU num_pfs=%u",
                   s->num_pfs);
        bridge_destroy(ctx);
        s->bridge_ctx = NULL;
        return;
    }
    if (s->topology_valid) {
        if (s->topology.header.num_pfs > COSIM_MAX_PFS) {
            error_setg(errp, "cosim: VCS topology has invalid num_pfs=%u",
                       s->topology.header.num_pfs);
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            return;
        }
        if (s->topology.header.num_pfs != s->num_pfs) {
            error_setg(errp,
                       "cosim: QEMU num_pfs=%u differs from VCS topology=%u",
                       s->num_pfs, s->topology.header.num_pfs);
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            return;
        }
        if (!cosim_register_pf_bars(s, pci_dev, &s->topology.pfs[0], errp)) {
            bridge_destroy(ctx);
            s->bridge_ctx = NULL;
            return;
        }
    }

    /* ======== 第三步: 从 VCS EP 发现剩余设备配置 ======== */

    /* A successful zero-PF reply identifies the legacy non-topology flow.
     * It remains single-PF BAR0 discovery only; cosim topology profiles never
     * enter this compatibility path. */
    if (!s->topology_valid) {
        uint32_t bar0_size = cosim_query_bar_size(
            ctx, cosim_current_bdf(pci_dev), 0);
        if (bar0_size == 0) bar0_size = 64 * 1024;
        COSIM_DPRINTF(s, "legacy realize BAR0 size: %u bytes (0x%x)\n",
                bar0_size, bar0_size);
        s->bar_ctx[0].dev = s;
        s->bar_ctx[0].bar_index = 0;
        s->bar_ctx[0].explicit_base = 0;
        s->bar_ctx[0].target_bdf = (uint16_t)(
            (pci_bus_num(pci_get_bus(pci_dev)) << 8) | pci_dev->devfn);
        memory_region_init_io(&s->bars[0], OBJECT(pci_dev), &cosim_mmio_ops,
                              &s->bar_ctx[0], "cosim-legacy-bar0", bar0_size);
        pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bars[0]);
        s->num_bars = 1;
    }

    /* Capability 链遍历 — 找 MSI cap */
    int msi_offset = -1, msi_vectors = 0;
    cosim_discover_caps(s, ctx, cosim_current_bdf(pci_dev),
                        &msi_offset, &msi_vectors);

    /* Enable bus mastering. In config-bypass mode the guest's PCI_COMMAND
     * writes go to VCS, so QEMU's shadow command never gets MASTER set and the
     * device's bus_master_enable_region (alias to guest RAM) stays disabled —
     * device-initiated DMA then hits MEMTX_DECODE_ERROR. pci_set_word only
     * updates the shadow config; explicitly enable the region so our EP DMA
     * (cosim_dma_cb -> pci_dma_write/read) can reach guest RAM. */
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);
    memory_region_set_enabled(&pci_dev->bus_master_enable_region, true);

    /* INTx 中断引脚 */
    pci_config_set_interrupt_pin(pci_dev->config, 1);

    /* MSI 初始化 — 使用从 VCS EP 发现的 offset */
    if (msi_offset >= 0) {
        Error *msi_err = NULL;
        if (msi_vectors < 1) msi_vectors = 1;
        int ret = msi_init(pci_dev, msi_offset, msi_vectors, true, false, &msi_err);
        if (ret != 0) {
            COSIM_DPRINTF(s, "realize msi_init at 0x%02x failed: %s\n",
                    msi_offset, msi_err ? error_get_pretty(msi_err) : "?");
            error_free(msi_err);
        } else {
            COSIM_DPRINTF(s, "realize MSI initialized at 0x%02x, %d vectors\n",
                    msi_offset, msi_vectors);
        }
    } else {
        COSIM_DPRINTF(s, "realize No MSI capability found in EP config\n");
    }

    /* NOTE: Virtio vendor caps 不需要在 QEMU 侧注册，不影响架构。
     *
     * 设计说明：virtio caps 是 EP（VCS 侧）的属性。Guest 的所有 config 读取
     * 通过 cosim_config_read → CfgRd TLP → VCS config_proxy 返回，不读 QEMU
     * 本地 config[]。QEMU 只需注册 MSI cap（上面 msi_init 已完成），因为
     * msi_enabled()/msi_notify() 依赖本地 config[] 中的 MSI 字段。
     *
     * 真正让 Guest 发现 virtio caps 的关键修复在 VCS 侧：
     *   1. MSI cap offset 从 0x38 → 0x40（Linux 要求 cap ptr >= 0x40）
     *   2. config_proxy CfgWr 字节级合并（防止覆盖 INT_PIN）
     */

    /* Debug: dump final config bytes around cap chain */
    {
        uint8_t *c = pci_dev->config;
        COSIM_DPRINTF(s, "realize FINAL config dump:\n");
        COSIM_DPRINTF(s, "  [0x34]=0x%02x (cap_ptr)\n", c[0x34]);
        COSIM_DPRINTF(s, "  [0x38..0x3B]=%02x %02x %02x %02x (MSI cap)\n",
                c[0x38], c[0x39], c[0x3a], c[0x3b]);
        COSIM_DPRINTF(s, "  [0x50..0x53]=%02x %02x %02x %02x (virtio COMMON)\n",
                c[0x50], c[0x51], c[0x52], c[0x53]);
        COSIM_DPRINTF(s, "  [0x64..0x67]=%02x %02x %02x %02x (virtio NOTIFY)\n",
                c[0x64], c[0x65], c[0x66], c[0x67]);
    }

    /* 创建 MSI bottom-half（在主循环中处理 MSI，避免 BQL 死锁） */
    s->msi_queue_head = 0;
    s->msi_queue_tail = 0;
    s->msi_bh = qemu_bh_new(cosim_msi_bh_cb, s);

    /* 启动 IRQ/DMA 轮询线程（DMA 请求与 MSI 异步事件处理） */
    if (ctx->transport) {
        s->irq_poller = irq_poller_start_ex(ctx->transport, cosim_dma_cb, cosim_msi_cb, s);
    } else {
        s->irq_poller = irq_poller_start(&ctx->shm, cosim_dma_cb, cosim_msi_cb, s);
    }
    if (!s->irq_poller) {
        error_setg(errp, "cosim: irq_poller_start failed");
        bridge_destroy(ctx);
        s->bridge_ctx = NULL;
        return;
    }

    /* Register VF config apply: VCS pushes per-VF BAR base/BDF on SR-IOV VF
     * enable; we map the VF MMIO windows so guest VF BAR access reaches VCS. */
    bridge_set_vf_config_cb(ctx, cosim_vf_config_apply, s);

    /* Debug: dump cap chain using raw write() to bypass any buffering */
    {
        uint8_t *cfg = pci_dev->config;
        char dbg[256];
        int n = snprintf(dbg, sizeof(dbg),
            "cosim-realize: cap_ptr=0x%02x status=0x%04x "
            "cfg[0x50..0x57]=%02x %02x %02x %02x %02x %02x %02x %02x\n",
            cfg[PCI_CAPABILITY_LIST],
            pci_get_word(cfg + PCI_STATUS),
            cfg[0x50], cfg[0x51], cfg[0x52], cfg[0x53],
            cfg[0x54], cfg[0x55], cfg[0x56], cfg[0x57]);
        (void)!write(2, dbg, n);
    }
    qemu_log("cosim: PCIe RC device realized (%s mode)\n",
             (s->transport && strcmp(s->transport, "tcp") == 0) ? "TCP" : "SHM");

    /* Register PF0 and auto-create PF1..num_pfs-1 as consecutive raw ARI
     * functions on the same bus. They share this bridge_ctx/irq_poller and
     * forward their own BDF's config to VCS (VCS func_manager answers for all PF BDFs when built
     * with +NUM_PFS=N). Default num_pfs=1 skips this (single-PF unchanged). */
    g_rc_pfs[0] = s;
    if (s->num_pfs > 1) {
        PCIBus *bus = pci_get_bus(pci_dev);
        for (uint32_t i = 1; i < s->num_pfs && i < COSIM_RC_MAX_PF; i++) {
            uint8_t sibling_devfn = (uint8_t)(pci_dev->devfn + i);
            PCIDevice *d = pci_new(sibling_devfn, TYPE_COSIM_PCIE_RC);
            DEVICE(d)->hotplugged = false;   /* programmatic, not user hotplug */
            d->cap_present |= QEMU_PCI_CAP_MULTIFUNCTION;
            /* Sibling PFs inherit the isolation policy so each builds its own
             * per-VF IOMMU AS on VF-enable (props only reach the primary). */
            {
                CosimPCIeRC *sib = COSIM_PCIE_RC(d);
                sib->pf_index    = i;
                sib->vf_iommu    = s->vf_iommu;
                sib->vf_dma_base = s->vf_dma_base;
                sib->vf_dma_size = s->vf_dma_size;
            }
            Error *e = NULL;
            if (!pci_realize_and_unref(d, bus, &e)) {
                /* A partial PF set cannot match the VCS topology. Remove any
                 * siblings already realized, then fail PF0 realize so no
                 * SYNC_MSG_REALIZED is emitted for an incomplete endpoint. */
                for (uint32_t j = 1; j < i; j++) {
                    if (g_rc_pfs[j])
                        object_unparent(OBJECT(g_rc_pfs[j]));
                }
                cosim_pcie_rc_exit(pci_dev);
                error_prepend(&e, "cosim: PF%u create failed: ", i);
                error_propagate(errp, e);
                return;
            }
        }
        qemu_log("cosim: primary PF0 realized, %u PF(s) total\n", s->num_pfs);
    }

    /* Register only after all realize-time bridge traffic and sibling creation
     * have completed. Runtime config/MMIO callbacks hold BQL, as required by
     * cpu_disable_ticks()/cpu_enable_ticks(). */
    if (icount_enabled()) {
        bridge_set_wait_hooks(ctx, cosim_vcs_wait_begin,
                              cosim_vcs_wait_end, s);
    }

    /* Signal VCS that device realize completed (BQL about to be released). A VCS
     * inbound-DMA before realize returns would deadlock pci_dma_write on the BQL
     * held during blocked config discovery; the VCS side waits for this. */
    if (ctx && ctx->transport) {
        sync_msg_t rmsg = { .type = SYNC_MSG_REALIZED, .payload = 0 };
        ctx->transport->send_sync(ctx->transport, &rmsg);
    }

    /* Publish only after PF0 and every requested sibling realized
     * successfully.  BAR sizes come solely from the registered owner regions. */
    cosim_table_target_publish(s, pci_dev);
}

static void cosim_pcie_rc_reset(DeviceState *dev)
{
    PCIDevice *pci_dev = PCI_DEVICE(dev);
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);

    /* The DUT and bridge own their reset behavior.  Only invalidate old table
     * targets and republish the live PF0 identity with a new generation. */
    if (s->table_target_registered) {
        cosim_table_target_publish(s, pci_dev);
    }
}

static void cosim_pcie_rc_exit(PCIDevice *pci_dev)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    cosim_table_target_remove(s);
    cosim_vf_teardown(s, false);  /* device exit: transport tearing down, no ATS inval */
    if (s->pf_index < COSIM_RC_MAX_PF && g_rc_pfs[s->pf_index] == s)
        g_rc_pfs[s->pf_index] = NULL;

    /* Sibling PFs share PF0's transport/poller/BH — don't tear those down here;
     * only PF0 (primary) owns and destroys them. */
    if (s->pf_index != 0) {
        s->bridge_ctx = NULL;  /* borrowed pointer, not owned */
        msi_uninit(pci_dev);
        return;
    }

    /* PF0 owns the auto-created PF siblings.  Their bridge_ctx borrows PF0's
     * transport, so detach them before stopping the poller or freeing that
     * transport.  Clear the registry slot first: each sibling's exit then sees
     * no ownership entry, which prevents recursive or duplicate teardown. */
    for (uint32_t i = 1; i < COSIM_RC_MAX_PF; i++) {
        CosimPCIeRC *sibling = g_rc_pfs[i];
        g_rc_pfs[i] = NULL;
        if (sibling)
            object_unparent(OBJECT(sibling));
    }

    if (s->irq_poller) {
        irq_poller_stop((irq_poller_t *)s->irq_poller);
        s->irq_poller = NULL;
    }
    if (s->msi_bh) {
        qemu_bh_delete((QEMUBH *)s->msi_bh);
        s->msi_bh = NULL;
    }
    if (s->bridge_ctx) {
        bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
        bridge_set_wait_hooks(ctx, NULL, NULL, NULL);
        if (s->vcs_wait_ticks_owned && runstate_is_running()) {
            cpu_enable_ticks();
        }
        s->vcs_wait_ticks_owned = false;
        s->vcs_wait_depth = 0;
        bridge_destroy(ctx);
        s->bridge_ctx = NULL;
    }
    msi_uninit(pci_dev);
}

/* ========== 设备属性 ========== */

static Property cosim_properties[] = {
    DEFINE_PROP_STRING("shm_name", CosimPCIeRC, shm_name),
    DEFINE_PROP_STRING("sock_path", CosimPCIeRC, sock_path),
    DEFINE_PROP_STRING("transport", CosimPCIeRC, transport),
    DEFINE_PROP_STRING("remote_host", CosimPCIeRC, remote_host),
    DEFINE_PROP_UINT32("port_base", CosimPCIeRC, port_base, 9100),
    DEFINE_PROP_UINT32("instance_id", CosimPCIeRC, instance_id, 0),
    DEFINE_PROP_UINT32("mmio_timeout_ms", CosimPCIeRC, mmio_timeout_ms, 180000),
    DEFINE_PROP_UINT32("num_pfs", CosimPCIeRC, num_pfs, 1),
    DEFINE_PROP_BOOL("debug", CosimPCIeRC, debug, false),
    /* Per-VF DMA isolation: off = passthrough (default). On = each VF confined
     * to [vf_dma_base + vf_index*vf_dma_size, +vf_dma_size). */
    DEFINE_PROP_BOOL("vf_iommu", CosimPCIeRC, vf_iommu, false),
    DEFINE_PROP_UINT64("vf_dma_base", CosimPCIeRC, vf_dma_base, 0x10000000ULL),
    DEFINE_PROP_UINT64("vf_dma_size", CosimPCIeRC, vf_dma_size, 0x1000000ULL),
    DEFINE_PROP_END_OF_LIST(),
};

/* ========== 设备注册 ========== */

static void cosim_pcie_rc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize = cosim_pcie_rc_realize;
    k->exit = cosim_pcie_rc_exit;
    k->config_read = cosim_config_read;
    k->config_write = cosim_config_write;
    device_class_set_legacy_reset(dc, cosim_pcie_rc_reset);
    k->vendor_id = COSIM_PCI_VENDOR_ID;
    k->device_id = COSIM_PCI_DEVICE_ID;
    k->revision = COSIM_PCI_REVISION;
    k->class_id = PCI_CLASS_NETWORK_ETHERNET;

    device_class_set_props(dc, cosim_properties);
    set_bit(DEVICE_CATEGORY_NETWORK, dc->categories);
    dc->desc = "CoSim PCIe RC Device (QEMU-VCS Bridge)";
}

static const TypeInfo cosim_pcie_rc_info = {
    .name          = TYPE_COSIM_PCIE_RC,
    .parent        = TYPE_PCI_DEVICE,
    .instance_size = sizeof(CosimPCIeRC),
    .class_init    = cosim_pcie_rc_class_init,
    .interfaces    = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

static void cosim_register_types(void)
{
    type_register_static(&cosim_pcie_rc_info);
    type_register_static(&cosim_rc_vf_info);
    type_register_static(&cosim_vf_iommu_info);
}

type_init(cosim_register_types)
