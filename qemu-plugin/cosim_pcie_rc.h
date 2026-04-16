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

/* 自定义 PCI ID */
#define COSIM_PCI_VENDOR_ID    0x1234
#define COSIM_PCI_DEVICE_ID    0x0001
#define COSIM_PCI_REVISION     0x01

/* BAR0 大小：64KB */
#define COSIM_BAR0_SIZE        (64 * 1024)

#define TYPE_COSIM_PCIE_RC     "cosim-pcie-rc"

OBJECT_DECLARE_SIMPLE_TYPE(CosimPCIeRC, COSIM_PCIE_RC)

struct CosimPCIeRC {
    PCIDevice parent_obj;

    MemoryRegion bar0;

    /* Bridge 连接参数（QEMU 命令行 -device 属性） */
    char *shm_name;
    char *sock_path;

    /* Bridge 上下文 — 使用 opaque 指针避免在 QEMU 编译环境中引入 bridge 头文件 */
    void *bridge_ctx;
};

#endif /* COSIM_PCIE_RC_H */
