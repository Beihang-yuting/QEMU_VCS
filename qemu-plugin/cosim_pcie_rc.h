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
};

#endif /* COSIM_PCIE_RC_H */
