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
#include "qapi/error.h"

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

    /* Standard PCI header (0x00-0x3F): QEMU manages locally. */
    if (address < 0x40) {
        uint32_t v = pci_default_read_config(pci_dev, address, len);
        if (address >= 0x34)
            fprintf(stderr, "[cfg_read] local addr=0x%02x len=%d val=0x%x\n",
                    address, len, v);
        return v;
    }

    /* Capability chain (0x40+): forward to VCS. */
    fprintf(stderr, "[cfg_read] VCS forward addr=0x%02x len=%d\n", address, len);
    uint32_t dword_addr = address & ~3u;
    uint32_t byte_offset = address & 3u;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len = 4;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        return pci_default_read_config(pci_dev, address, len);
    }

    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }

    uint32_t val = dword >> (byte_offset * 8);
    if (len < 4) {
        val &= (1u << (len * 8)) - 1;
    }

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

    /* 初始化 MSI — auto-allocate offset.
     * Note: msi_init sets *errp on failure and returns non-zero.
     * We clear errp before calling so a failure doesn't abort realize. */
    {
        Error *msi_err = NULL;
        int ret = msi_init(pci_dev, 0, 1, true, false, &msi_err);
        if (ret != 0) {
            fprintf(stderr, "[realize] msi_init failed (ret=%d): %s\n",
                    ret, msi_err ? error_get_pretty(msi_err) : "unknown");
            error_free(msi_err);
            /* Continue without MSI — set cap_pointer directly to virtio chain */
            pci_set_word(pci_dev->config + PCI_STATUS,
                         pci_get_word(pci_dev->config + PCI_STATUS) | PCI_STATUS_CAP_LIST);
            pci_set_byte(pci_dev->config + PCI_CAPABILITY_LIST, 0x50);
        } else {
            /* MSI succeeded — find where it was placed and link to virtio caps */
            uint8_t msi_cap = pci_dev->config[PCI_CAPABILITY_LIST];
            fprintf(stderr, "[realize] MSI at 0x%02x, linking next→0x50\n", msi_cap);
            /* Walk to end of MSI capability chain and append 0x50 */
            while (pci_dev->config[msi_cap + 1] != 0)
                msi_cap = pci_dev->config[msi_cap + 1];
            pci_set_byte(pci_dev->config + msi_cap + 1, 0x50);
        }
    }

    /* Virtio PCI capabilities in local config space.
     * Linux reads config via MMCONFIG (direct memory map of config[]),
     * bypassing config_read callback. Layout must also match VCS
     * ep_stub for CfgRd TLP forwarding consistency.
     *
     * Capability offsets (after MSI at 0x38-0x45):
     *   0x50: COMMON_CFG (16B) → next=0x64
     *   0x64: NOTIFY_CFG (20B) → next=0x78
     *   0x78: ISR_CFG    (16B) → next=0x88
     *   0x88: DEVICE_CFG (16B) → next=0 (end)
     */
    uint8_t *c = pci_dev->config;

    /* COMMON_CFG at 0x50 */
    c[0x50] = 0x09; c[0x51] = 0x64; c[0x52] = 0x10; c[0x53] = 0x01;
    c[0x54] = 0x00; c[0x55] = 0x00; c[0x56] = 0x00; c[0x57] = 0x00;
    pci_set_long(c + 0x58, 0x1000);  /* offset in BAR0 */
    pci_set_long(c + 0x5C, 0x0038);  /* length = 56 */

    /* NOTIFY_CFG at 0x64 */
    c[0x64] = 0x09; c[0x65] = 0x78; c[0x66] = 0x14; c[0x67] = 0x02;
    c[0x68] = 0x00; c[0x69] = 0x00; c[0x6A] = 0x00; c[0x6B] = 0x00;
    pci_set_long(c + 0x6C, 0x2000);  /* offset */
    pci_set_long(c + 0x70, 0x0004);  /* length */
    pci_set_long(c + 0x74, 0x0000);  /* notify_off_multiplier */

    /* ISR_CFG at 0x78 */
    c[0x78] = 0x09; c[0x79] = 0x88; c[0x7A] = 0x10; c[0x7B] = 0x03;
    c[0x7C] = 0x00; c[0x7D] = 0x00; c[0x7E] = 0x00; c[0x7F] = 0x00;
    pci_set_long(c + 0x80, 0x3000);  /* offset */
    pci_set_long(c + 0x84, 0x0004);  /* length */

    /* DEVICE_CFG at 0x88 */
    c[0x88] = 0x09; c[0x89] = 0x00; c[0x8A] = 0x10; c[0x8B] = 0x04;
    c[0x8C] = 0x00; c[0x8D] = 0x00; c[0x8E] = 0x00; c[0x8F] = 0x00;
    pci_set_long(c + 0x90, 0x4000);  /* offset */
    pci_set_long(c + 0x94, 0x0010);  /* length = 16 */

    /* Debug: dump capability chain */
    fprintf(stderr, "[realize] cap_ptr=0x%02x status=0x%04x\n",
            c[PCI_CAPABILITY_LIST], pci_get_word(c + PCI_STATUS));
    fprintf(stderr, "[realize] config[0x34-0x3F]: ");
    for (int i = 0x34; i < 0x40; i++) fprintf(stderr, "%02x ", c[i]);
    fprintf(stderr, "\n[realize] config[0x38-0x4F]: ");
    for (int i = 0x38; i < 0x50; i++) fprintf(stderr, "%02x ", c[i]);
    fprintf(stderr, "\n[realize] config[0x50-0x5F]: ");
    for (int i = 0x50; i < 0x60; i++) fprintf(stderr, "%02x ", c[i]);
    fprintf(stderr, "\n");

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
