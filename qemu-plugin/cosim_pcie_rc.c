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
    CosimBarContext *bc = (CosimBarContext *)opaque;
    CosimPCIeRC *s = bc->dev;
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    if (!ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: read before bridge connected\n");
        return 0xFFFFFFFF;
    }

    /* 重建完整 PCIe 地址: BAR base + offset, DW 对齐 */
    uint64_t bar_base   = pci_get_bar_addr(&s->parent_obj, bc->bar_index);
    uint64_t pcie_addr  = bar_base + addr;
    uint32_t byte_off   = pcie_addr & 3u;
    uint64_t dw_addr    = pcie_addr & ~3ULL;
    uint8_t  first_be   = (uint8_t)(((1u << size) - 1) << byte_off);

    tlp_entry_t req = {0};
    req.type     = TLP_MRD;
    req.addr     = dw_addr;
    req.len      = 4;  /* 始终读整个 DWORD */
    req.first_be = first_be;
    req.last_be  = 0;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: MRd failed addr=0x%lx\n",
                      (unsigned long)addr);
        return 0xFFFFFFFF;
    }

    /* CplD 返回整个 DWORD，按 byte_off 提取请求的字节 */
    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }
    uint64_t val = dword >> (byte_off * 8);
    if (size < 4) {
        val &= (1ULL << (size * 8)) - 1;
    }

    fprintf(stderr, "cosim: MRd bar%d off=0x%04lx pcie=0x%lx be=0x%x val=0x%lx\n",
            bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
            first_be, (unsigned long)val);
    return val;
}

static void cosim_mmio_write(void *opaque, hwaddr addr, uint64_t val,
                              unsigned size)
{
    CosimBarContext *bc = (CosimBarContext *)opaque;
    CosimPCIeRC *s = bc->dev;
    bridge_ctx_t *ctx = (bridge_ctx_t *)s->bridge_ctx;

    if (!ctx) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: write before bridge connected\n");
        return;
    }

    /* 重建完整 PCIe 地址: BAR base + offset, DW 对齐 */
    uint64_t bar_base   = pci_get_bar_addr(&s->parent_obj, bc->bar_index);
    uint64_t pcie_addr  = bar_base + addr;
    uint32_t byte_off   = pcie_addr & 3u;
    uint64_t dw_addr    = pcie_addr & ~3ULL;
    uint8_t  first_be   = (uint8_t)(((1u << size) - 1) << byte_off);

    /* 数据放到 DW 内正确的字节位置 */
    uint32_t shifted_val = (uint32_t)val << (byte_off * 8);

    tlp_entry_t req = {0};
    req.type     = TLP_MWR;
    req.addr     = dw_addr;
    req.len      = 4;
    req.first_be = first_be;
    req.last_be  = 0;
    for (int i = 0; i < 4; i++) {
        req.data[i] = (shifted_val >> (i * 8)) & 0xFF;
    }

    int ret = bridge_send_tlp_fire(ctx, &req);
    if (ret < 0) {
        qemu_log_mask(LOG_GUEST_ERROR, "cosim: MWr failed addr=0x%lx\n",
                      (unsigned long)addr);
    }

    fprintf(stderr, "cosim: MWr bar%d off=0x%04lx pcie=0x%lx be=0x%x val=0x%lx\n",
            bc->bar_index, (unsigned long)addr, (unsigned long)pcie_addr,
            first_be, (unsigned long)val);
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
        uint32_t local_val = pci_default_read_config(pci_dev, address, len);
        fprintf(stderr, "[cfg_read] LOCAL(no bridge) addr=0x%02x len=%d → 0x%x\n",
                address, len, local_val);
        return local_val;
    }

    /* 全部 config space 转发到 VCS（由 VCS bypass proxy 或 DUT RTL 处理）。
     * QEMU 本地 config[] 仍由 cosim_config_write 的 pci_default_write_config
     * 维护，供 QEMU PCI 框架内部使用（不影响 Guest 看到的值）。 */
    uint32_t dword_addr = address & ~3u;
    uint32_t byte_offset = address & 3u;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len = 4;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    if (ret < 0) {
        uint32_t fallback = pci_default_read_config(pci_dev, address, len);
        fprintf(stderr, "[cfg_read] addr=0x%02x len=%d VCS_FAIL → local=0x%x\n",
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

    fprintf(stderr, "[cfg_read] addr=0x%02x len=%d → 0x%x (dw=0x%08x off=%u)\n",
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

/* ========== 设备发现: 从 VCS EP 查询配置 ========== */

static uint32_t cosim_cfgrd(bridge_ctx_t *ctx, uint32_t reg) {
    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = reg & ~3u;
    req.len  = 4;
    req.first_be = 0xF;
    cpl_entry_t cpl = {0};
    if (bridge_send_tlp_and_wait(ctx, &req, &cpl) < 0) return 0xFFFFFFFF;
    uint32_t dw = 0;
    for (int i = 0; i < 4; i++) dw |= ((uint32_t)cpl.data[i]) << (i * 8);
    return dw;
}

static void cosim_cfgwr(bridge_ctx_t *ctx, uint32_t reg, uint32_t data) {
    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = reg;
    req.len  = 4;
    req.first_be = 0xF;
    for (int i = 0; i < 4; i++) req.data[i] = (data >> (i * 8)) & 0xFF;
    bridge_send_tlp_fire(ctx, &req);
}

/* BAR sizing: 写 0xFFFFFFFF → 读回 mask → 恢复 → 计算大小 */
static uint32_t cosim_query_bar_size(bridge_ctx_t *ctx, int bar) {
    uint32_t reg = 0x10 + bar * 4;  /* PCI_BASE_ADDRESS_0 = 0x10 */
    uint32_t orig = cosim_cfgrd(ctx, reg);
    cosim_cfgwr(ctx, reg, 0xFFFFFFFF);
    uint32_t mask = cosim_cfgrd(ctx, reg);
    cosim_cfgwr(ctx, reg, orig);  /* 恢复 */
    if (mask == 0 || mask == 0xFFFFFFFF) return 0;
    /* 清除低 4 位 (type/prefetch bits) */
    mask &= ~0xFu;
    return ~mask + 1;
}

/* 遍历 capability 链找 MSI */
static void cosim_discover_caps(bridge_ctx_t *ctx,
                                 int *msi_offset, int *msi_vectors) {
    *msi_offset = -1;
    *msi_vectors = 0;
    uint32_t status_cmd = cosim_cfgrd(ctx, 0x04);
    if (!((status_cmd >> 20) & 1)) return;  /* CAP_LIST bit in Status */
    uint8_t ptr = cosim_cfgrd(ctx, 0x34) & 0xFC;
    int safety = 48;  /* 防止无限循环 */
    while (ptr && safety-- > 0) {
        uint32_t dw = cosim_cfgrd(ctx, ptr);
        uint8_t cap_id = dw & 0xFF;
        if (cap_id == 0x05) {  /* PCI_CAP_ID_MSI */
            *msi_offset = ptr;
            uint16_t msg_ctrl = (dw >> 16) & 0xFFFF;
            *msi_vectors = 1 << ((msg_ctrl >> 1) & 0x7);
            fprintf(stderr, "[discover] MSI cap at 0x%02x, vectors=%d, ctrl=0x%04x\n",
                    ptr, *msi_vectors, msg_ctrl);
        }
        ptr = (dw >> 8) & 0xFC;
    }
}

/* ========== 设备生命周期 ========== */

static void cosim_pcie_rc_realize(PCIDevice *pci_dev, Error **errp)
{
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);
    s->num_bars = 0;

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

    /* ======== 第二步: 从 VCS EP 发现设备配置 (标准 PCIe 枚举) ======== */

    /* BAR sizing — 查询 BAR0 大小 */
    uint32_t bar0_size = cosim_query_bar_size(ctx, 0);
    if (bar0_size == 0) bar0_size = 64 * 1024;  /* fallback 64KB */
    fprintf(stderr, "[realize] Discovered BAR0 size: %u bytes (0x%x)\n",
            bar0_size, bar0_size);

    /* Capability 链遍历 — 找 MSI cap */
    int msi_offset = -1, msi_vectors = 0;
    cosim_discover_caps(ctx, &msi_offset, &msi_vectors);

    /* ======== 第三步: 基于发现结果初始化 QEMU 框架 ======== */

    /* 注册 BAR0 — opaque 指向 CosimBarContext（携带 bar_index） */
    s->bar_ctx[0].dev = s;
    s->bar_ctx[0].bar_index = 0;
    memory_region_init_io(&s->bars[0], OBJECT(s), &cosim_mmio_ops,
                          &s->bar_ctx[0], "cosim-bar0", bar0_size);
    pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bars[0]);
    s->num_bars = 1;

    /* Enable bus mastering */
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);

    /* INTx 中断引脚 */
    pci_config_set_interrupt_pin(pci_dev->config, 1);

    /* MSI 初始化 — 使用从 VCS EP 发现的 offset */
    if (msi_offset >= 0) {
        Error *msi_err = NULL;
        if (msi_vectors < 1) msi_vectors = 1;
        int ret = msi_init(pci_dev, msi_offset, msi_vectors, true, false, &msi_err);
        if (ret != 0) {
            fprintf(stderr, "[realize] msi_init at 0x%02x failed: %s\n",
                    msi_offset, msi_err ? error_get_pretty(msi_err) : "?");
            error_free(msi_err);
        } else {
            fprintf(stderr, "[realize] MSI initialized at 0x%02x, %d vectors\n",
                    msi_offset, msi_vectors);
        }
    } else {
        fprintf(stderr, "[realize] No MSI capability found in EP config\n");
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
        fprintf(stderr, "[realize] FINAL config dump:\n");
        fprintf(stderr, "  [0x34]=0x%02x (cap_ptr)\n", c[0x34]);
        fprintf(stderr, "  [0x38..0x3B]=%02x %02x %02x %02x (MSI cap)\n",
                c[0x38], c[0x39], c[0x3a], c[0x3b]);
        fprintf(stderr, "  [0x50..0x53]=%02x %02x %02x %02x (virtio COMMON)\n",
                c[0x50], c[0x51], c[0x52], c[0x53]);
        fprintf(stderr, "  [0x64..0x67]=%02x %02x %02x %02x (virtio NOTIFY)\n",
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
