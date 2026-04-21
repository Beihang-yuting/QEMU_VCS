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
#include "hw/qdev-properties.h"

/* Bridge API — 通过动态链接使用 */
#include "bridge_qemu.h"
#include "cosim_transport.h"
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

    if (ctx->transport) {
        /* TCP mode: no shared dma_buf, must transfer data via network */
        if (req->direction == DMA_DIR_WRITE) {
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
            cpu_physical_memory_write(req->host_addr, buf, len);
            bridge_complete_dma(ctx, req->tag, 0);
        } else {
            /* Host→Device: read guest RAM, send data back to VCS via DMA_DATA */
            uint8_t buf[65536];
            uint32_t len = req->len > sizeof(buf) ? sizeof(buf) : req->len;
            cpu_physical_memory_read(req->host_addr, buf, len);
            bridge_complete_dma_with_data(ctx, req->tag, 0,
                                           req->direction, req->host_addr, buf, len);
        }
    } else {
        /* SHM mode: data is in shared dma_buf */
        uint8_t *dma_buf = (uint8_t *)ctx->shm.dma_buf + req->dma_offset;
        if (req->direction == DMA_DIR_WRITE) {
            cpu_physical_memory_write(req->host_addr, dma_buf, req->len);
        } else {
            cpu_physical_memory_read(req->host_addr, dma_buf, req->len);
        }
        bridge_complete_dma(ctx, req->tag, 0);
    }

    qemu_log("cosim: DMA %s OK GPA=0x%lx len=%u tag=%u (%s)\n",
             req->direction == DMA_DIR_WRITE ? "write" : "read",
             (unsigned long)req->host_addr, req->len, req->tag,
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

/* ========== Phase 1: Config Space 转发 ========== */

static uint32_t cosim_config_read(PCIDevice *pci_dev, uint32_t address, int len)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    /* Bridge 未连接时，使用 QEMU 本地 config space */
    if (!ctx) {
        return pci_default_read_config(pci_dev, address, len);
    }

    /* VCS 按 dword 索引 config space，需对齐地址并处理字节偏移 */
    uint32_t dword_addr = address & ~3u;
    uint32_t byte_offset = address & 3u;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len = 4;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: CfgRd failed addr=0x%x, fallback to local\n",
                      address);
        return pci_default_read_config(pci_dev, address, len);
    }

    /* 从 completion 重建完整 dword，再提取目标字节 */
    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }

    uint32_t val = dword >> (byte_offset * 8);
    if (len < 4) {
        val &= (1u << (len * 8)) - 1;
    }

    qemu_log_mask(LOG_UNIMP, "cosim: CfgRd addr=0x%02x len=%d val=0x%x\n",
                  address, len, val);
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

    /* 同时转发 CfgWr TLP 到 VCS */
    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = address;
    req.len = len;
    for (int i = 0; i < len && i < COSIM_TLP_DATA_SIZE; i++) {
        req.data[i] = (data >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: CfgWr failed addr=0x%x data=0x%x\n",
                      address, data);
    }

    qemu_log_mask(LOG_UNIMP, "cosim: CfgWr addr=0x%02x len=%d data=0x%x\n",
                  address, len, data);
}

/* ========== 设备生命周期 ========== */

static void cosim_pcie_rc_realize(PCIDevice *pci_dev, Error **errp)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);

    /* 注册 BAR0 */
    memory_region_init_io(&s->bar0, OBJECT(s), &cosim_mmio_ops, s,
                          "cosim-bar0", COSIM_BAR0_SIZE);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar0);

    /* Enable bus mastering so pci_dma_read/write can access guest memory */
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);

    /* 配置 INTx 中断引脚 (INTA) — 需要在 msi_init 之前设置 */
    pci_config_set_interrupt_pin(pci_dev->config, 1);  /* INTA */

    /* 初始化 MSI（P2 阶段启用中断） */
    if (msi_init(pci_dev, 0, 1, true, false, errp)) {
        return;
    }

    /* 初始化 Bridge */
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

    qemu_log("cosim: PCIe RC device realized (%s mode)\n",
             (s->transport && strcmp(s->transport, "tcp") == 0) ? "TCP" : "SHM");
}

static void cosim_pcie_rc_exit(PCIDevice *pci_dev)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    if (s->irq_poller) {
        irq_poller_stop((irq_poller_t *)s->irq_poller);
        s->irq_poller = NULL;
    }
    if (s->msi_bh) {
        qemu_bh_delete((QEMUBH *)s->msi_bh);
        s->msi_bh = NULL;
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
    DEFINE_PROP_STRING("transport", CosimPCIeRC, transport),
    DEFINE_PROP_STRING("remote_host", CosimPCIeRC, remote_host),
    DEFINE_PROP_UINT32("port_base", CosimPCIeRC, port_base, 9100),
    DEFINE_PROP_UINT32("instance_id", CosimPCIeRC, instance_id, 0),
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
