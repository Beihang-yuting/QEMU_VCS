/* cosim-platform/qemu-plugin/cosim_pcie_rc.c
 * QEMU 自定义 PCIe RC 设备 — 实现
 *
 * 放入 QEMU 源码树: qemu/hw/net/cosim_pcie_rc.c
 * 头文件: qemu/include/hw/net/cosim_pcie_rc.h
 * 构建集成: 修改 qemu/hw/net/meson.build
 *
 * 编译时需要链接 libcosim_bridge.so
 */
#include "cosim_pcie_rc.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "hw/qdev-properties.h"

/* Bridge API — 通过动态链接使用 */
#include "bridge_qemu.h"
#include "irq_poller.h"

/* ========== MMIO 操作 ========== */

static uint64_t cosim_mmio_read(void *opaque, hwaddr addr, unsigned size)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(opaque);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    if (!ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: read before bridge connected\n");
        return 0xFFFFFFFF;
    }

    tlp_entry_t req = {0};
    req.type = TLP_MRD;
    req.addr = addr;
    req.len = size;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: MRd failed addr=0x%lx\n",
                      (unsigned long)addr);
        return 0xFFFFFFFF;
    }

    /* 从 completion 数据中提取返回值 */
    uint64_t val = 0;
    for (unsigned i = 0; i < size && i < COSIM_TLP_DATA_SIZE; i++) {
        val |= ((uint64_t)cpl.data[i]) << (i * 8);
    }

    qemu_log_mask(LOG_UNIMP, "cosim: MRd addr=0x%04lx size=%u val=0x%lx\n",
                  (unsigned long)addr, size, (unsigned long)val);
    return val;
}

static void cosim_mmio_write(void *opaque, hwaddr addr, uint64_t val,
                              unsigned size)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(opaque);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    if (!ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: write before bridge connected\n");
        return;
    }

    tlp_entry_t req = {0};
    req.type = TLP_MWR;
    req.addr = addr;
    req.len = size;
    for (unsigned i = 0; i < size && i < COSIM_TLP_DATA_SIZE; i++) {
        req.data[i] = (val >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: MWr failed addr=0x%lx\n",
                      (unsigned long)addr);
    }

    qemu_log_mask(LOG_UNIMP, "cosim: MWr addr=0x%04lx size=%u val=0x%lx\n",
                  (unsigned long)addr, size, (unsigned long)val);
}

/* ========== P2: DMA / MSI 回调 ========== */

/* DMA 请求回调：从 VCS 收到 DMA 请求 —
 *   direction=WRITE 表示设备→Host 写 (DMA write to guest memory)
 *   direction=READ  表示 Host→设备 读 (DMA read from guest memory)
 */
static void cosim_dma_cb(const dma_req_t *req, void *user)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(user);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;
    PCIDevice *pci_dev = PCI_DEVICE(s);
    uint8_t *dma_buf = (uint8_t *)ctx->shm.dma_buf + req->dma_offset;

    if (req->direction == DMA_DIR_WRITE) {
        /* 设备→Host：从 DMA 区读数据，写入 Guest 内存 */
        pci_dma_write(pci_dev, req->host_addr, dma_buf, req->len);
    } else {
        /* Host→设备：从 Guest 内存读数据，写到 DMA 区 */
        pci_dma_read(pci_dev, req->host_addr, dma_buf, req->len);
    }

    bridge_complete_dma(ctx, req->tag, 0);
}

/* MSI 中断回调：从 VCS 收到中断，注入 Guest */
static void cosim_msi_cb(uint32_t vector, void *user)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(user);
    PCIDevice *pci_dev = PCI_DEVICE(s);
    if (msi_enabled(pci_dev)) {
        msi_notify(pci_dev, vector);
    }
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

/* ========== 设备生命周期 ========== */

static void cosim_pcie_rc_realize(PCIDevice *pci_dev, Error **errp)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);

    /* 注册 BAR0 */
    memory_region_init_io(&s->bar0, OBJECT(s), &cosim_mmio_ops, s,
                          "cosim-bar0", COSIM_BAR0_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar0);

    /* 初始化 MSI（P2 阶段启用中断） */
    if (msi_init(pci_dev, 0, 1, true, false, errp)) {
        return;
    }

    /* 初始化 Bridge */
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

    /* 启动 IRQ/DMA 轮询线程（DMA 请求与 MSI 异步事件处理） */
    s->irq_poller = irq_poller_start(&ctx->shm, cosim_dma_cb, cosim_msi_cb, s);
    if (!s->irq_poller) {
        error_setg(errp, "cosim: irq_poller_start failed");
        bridge_destroy(ctx);
        s->bridge_ctx = NULL;
        return;
    }

    qemu_log("cosim: PCIe RC device realized (shm=%s sock=%s)\n",
             s->shm_name, s->sock_path);
}

static void cosim_pcie_rc_exit(PCIDevice *pci_dev)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    if (s->irq_poller) {
        irq_poller_stop((irq_poller_t *)s->irq_poller);
        s->irq_poller = NULL;
    }
    if (s->bridge_ctx) {
        bridge_destroy((bridge_ctx_t *)s->bridge_ctx);
        s->bridge_ctx = NULL;
    }
    msi_uninit(pci_dev);
}

/* ========== 设备属性 ========== */

static Property cosim_properties[] = {
    DEFINE_PROP_STRING("shm_name", CosimPCIeRC, shm_name),
    DEFINE_PROP_STRING("sock_path", CosimPCIeRC, sock_path),
    DEFINE_PROP_END_OF_LIST(),
};

/* ========== 设备注册 ========== */

static void cosim_pcie_rc_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize = cosim_pcie_rc_realize;
    k->exit = cosim_pcie_rc_exit;
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
}

type_init(cosim_register_types)
