/* cosim-platform/qemu-plugin/cosim_pcie_rc.h
 * QEMU 自定义 PCIe RC 设备 — 头文件
 * 注意：此文件在 QEMU 源码树中使用，依赖 QEMU 内部头文件
 */
#ifndef COSIM_PCIE_RC_H
#define COSIM_PCIE_RC_H

#include "qemu/osdep.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/msi.h"
#include "qom/object.h"

/* Virtio PCI ID (modern virtio-net) */
#define COSIM_PCI_VENDOR_ID    0x1AF4
#define COSIM_PCI_DEVICE_ID    0x1041
#define COSIM_PCI_REVISION     0x01

#define COSIM_MAX_BARS         6

/* BDF 动态缓存: 首次 CfgRd 探测 vendor ID，缓存结果
 * 无效 BDF 后续访问直接返回 0xFFFFFFFF，不转发 VCS */
#define COSIM_MAX_BUS   256
#define COSIM_MAX_DEV   32
#define COSIM_MAX_FUNC  8

typedef struct CosimBdfCacheEntry {
    uint16_t vendor_id;    /* 缓存的 vendor ID */
    bool     probed;       /* 是否已探测过 */
    bool     valid;        /* VCS 是否返回了有效设备 */
} CosimBdfCacheEntry;

#define TYPE_COSIM_PCIE_RC     "cosim-pcie-rc"

OBJECT_DECLARE_SIMPLE_TYPE(CosimPCIeRC, COSIM_PCIE_RC)

/* MSI 延迟处理队列大小 */
#define COSIM_MSI_QUEUE_SIZE 256

/* 每个 BAR 的 MMIO callback opaque，携带 BAR index */
typedef struct CosimBarContext {
    struct CosimPCIeRC *dev;
    int bar_index;
    /* VF BAR support (from vf_config sync). explicit_base != 0 selects a VF
     * region whose absolute PCIe base is not derivable from pci_get_bar_addr
     * (VFs are not QEMU PCIDevices here); target_bdf routes the forwarded TLP. */
    uint64_t explicit_base;   /* 0 = PF BAR (use pci_get_bar_addr); else BAR/aperture base */
    uint16_t target_bdf;      /* 0 = PF/none; else fixed VF RID for TLP routing */

    /* SR-IOV VF BAR aperture (real-HW model): one region per (PF,BAR) spans all
     * VFs; the MMIO handler decodes vf_index from the offset, matching hardware
     * VF_BAR_base + vf_index*size striping. Scales to 256 VF/PF without per-VF
     * regions. Active when is_aperture != 0. */
    uint8_t  is_aperture;     /* 1 = VF BAR aperture; decode vf_index per access */
    uint64_t vf_bar_size;     /* per-VF BAR size (stride within the aperture) */
    uint16_t first_vf_bdf;    /* RID of VF0 */
    uint16_t vf_bdf_stride;   /* RID stride between consecutive VFs */
    uint16_t num_vfs;         /* number of VFs in this aperture */
} CosimBarContext;

struct CosimPCIeRC {
    PCIDevice parent_obj;

    MemoryRegion bars[COSIM_MAX_BARS];
    CosimBarContext bar_ctx[COSIM_MAX_BARS];
    int num_bars;

    /* Bridge 连接参数（QEMU 命令行 -device 属性） */
    char *shm_name;
    char *sock_path;

    /* TCP transport parameters (optional, NULL = SHM mode) */
    char *transport;       /* "shm" (default) or "tcp" */
    char *remote_host;     /* TCP: VCS server address */
    uint32_t port_base;    /* TCP: port base (default 9100) */
    uint32_t instance_id;  /* TCP: instance ID (default 0) */

    /* MMIO 读完成超时(ms): >0 时 BAR MMIO 读等 VCS completion 超时即返回
     * 0xFFFFFFFF(设备视为无响应), guest 不再死等 -> 能启动到登录。0=禁用(永久阻塞,
     * 旧行为)。默认 180000(3min)。-device cosim-pcie-rc,...,mmio_timeout_ms=N */
    uint32_t mmio_timeout_ms;

    /* 运行时 debug 开关 -- -device cosim-pcie-rc,...,debug=on */
    bool debug;

    /* Multi-PF SR-IOV: the primary device (function 0) owns the transport and
     * auto-creates PF1..num_pfs-1 as sibling functions on the same slot, all
     * sharing the primary's bridge_ctx/irq_poller. pf_index = PCI_FUNC(devfn).
     * Config space forwards each PF's own BDF to VCS (config-bypass). Default
     * num_pfs=1 keeps the single-PF path unchanged. */
    uint32_t pf_index;     /* this device's PF number (0 = primary) */
    uint32_t num_pfs;      /* total PFs (only meaningful on primary) */

    /* BDF 动态缓存 — config space 访问过滤 */
    CosimBdfCacheEntry bdf_cache[COSIM_MAX_BUS][COSIM_MAX_DEV][COSIM_MAX_FUNC];

    /* Bridge 上下文 — 使用 opaque 指针避免在 QEMU 编译环境中引入 bridge 头文件 */
    void *bridge_ctx;

    /* P2: IRQ/DMA 轮询线程（opaque pointer 到 irq_poller_t） */
    void *irq_poller;

    /* MSI 延迟队列：irq_poller 入队，QEMU 主循环 BH 处理（避免 BQL 死锁） */
    void *msi_bh;      /* QEMUBH* — opaque 避免头文件依赖 */
    uint32_t msi_queue[COSIM_MSI_QUEUE_SIZE];
    volatile int msi_queue_head;   /* 主循环 BH 读 */
    volatile int msi_queue_tail;   /* irq_poller 线程写 */

    /* VF BAR MMIO regions dynamically mapped from vf_config sync (SR-IOV VF
     * enable). VFs are not QEMU PCIDevices here; we map raw MemoryRegions at
     * each VF BAR base forwarding to VCS with target_bdf = VF RID. */
    MemoryRegion    *vf_bars;      /* array of num_vf_bars regions */
    CosimBarContext *vf_bar_ctx;   /* parallel per-region context */
    int              num_vf_bars;  /* active VF BAR regions */

    /* VF config-space stubs: tiny PCIDevices at each VF BDF whose config_read/
     * write forward to VCS (the DUT owns VF config space). Needed so the guest
     * kernel can read the VF config header (class/header-type/caps) and accept
     * the VF. BARs stay handled by the PF's vf_bars aperture. */
    PCIDevice      **vf_devs;      /* array of num_vf_devs stub PCIDevices */
    int              num_vf_devs;  /* active VF config stubs */

    /* Per-VF DMA isolation (opt-in vf_iommu=on). Each VF gets an IOMMU
     * AddressSpace whose translate() is identity within the VF's host-assigned
     * window [vf_dma_base + vf_index*vf_dma_size, +vf_dma_size) and rejects all
     * else — modeling a host IOMMU keyed by requester BDF. Default off =
     * passthrough (validated TCP/DMA/MSI-X paths unchanged). Opaque pointers:
     * CosimVfIommu[] and AddressSpace[] (types are .c-local). */
    bool     vf_iommu;         /* enable per-VF windowed isolation */
    uint64_t vf_dma_base;      /* VF0 window base (VFk base = +k*vf_dma_size) */
    uint64_t vf_dma_size;      /* per-VF window size (stride) */
    void    *vf_iommu_mr;      /* CosimVfIommu[num_vf_iommu] */
    void    *vf_as;            /* AddressSpace[num_vf_iommu] */
    int      num_vf_iommu;     /* active per-VF IOMMU AddressSpaces */
};

#endif /* COSIM_PCIE_RC_H */
