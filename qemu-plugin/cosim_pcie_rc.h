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

/* BAR0 大小：64KB */
#define COSIM_BAR0_SIZE        (64 * 1024)

#define TYPE_COSIM_PCIE_RC     "cosim-pcie-rc"

OBJECT_DECLARE_SIMPLE_TYPE(CosimPCIeRC, COSIM_PCIE_RC)

/* MSI 延迟处理队列大小 */
#define COSIM_MSI_QUEUE_SIZE 256

struct CosimPCIeRC {
    PCIDevice parent_obj;

    MemoryRegion bar0;

    /* Bridge 连接参数（QEMU 命令行 -device 属性） */
    char *shm_name;
    char *sock_path;

    /* TCP transport parameters (optional, NULL = SHM mode) */
    char *transport;       /* "shm" (default) or "tcp" */
    char *remote_host;     /* TCP: VCS server address */
    uint32_t port_base;    /* TCP: port base (default 9100) */
    uint32_t instance_id;  /* TCP: instance ID (default 0) */

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
