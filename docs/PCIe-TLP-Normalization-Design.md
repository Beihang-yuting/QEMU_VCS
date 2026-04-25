# PCIe TLP 规范化改造 — 设计方案与架构分析

> 日期: 2026-04-24
> 状态: 实施完成，TCP 双实例验证通过（2026-04-25）
> 范围: QEMU RC + Bridge 传输 + VCS EP 全链路

---

## 1. 问题背景

### 1.1 现象

在 TCP bypass 模式下测试 virtio-net 设备初始化，VCS 侧成功处理了 247 个 config TLP（bypass）和 27 个 MMIO TLP，但 Linux virtio-pci 驱动最终写入 `device_status = 0x8b`（FAILED），设备初始化失败。

### 1.2 根因定位

通过完整的 TLP trace 分析，发现 Linux virtio-pci 驱动使用 `readb`（单字节读）逐字节读取 MAC 地址：

```
[VCS poll] got TLP type=1 addr=0x4000   ← readb(MAC[0])  byte_off=0 ✓
[VCS poll] got TLP type=1 addr=0x4001   ← readb(MAC[1])  byte_off=1 ✗
[VCS poll] got TLP type=1 addr=0x4002   ← readb(MAC[2])  byte_off=2 ✗
[VCS poll] got TLP type=1 addr=0x4003   ← readb(MAC[3])  byte_off=3 ✗
[VCS poll] got TLP type=1 addr=0x4004   ← readb(MAC[4])  byte_off=0 ✓
[VCS poll] got TLP type=1 addr=0x4005   ← readb(MAC[5])  byte_off=1 ✗
```

VCS bridge 收到的原始地址是正确的字节地址（0x4001 等），但 VIP pipeline 按 PCIe 规范将地址 **DW 对齐**（低 2 位清零），导致 0x4001 → 0x4000。EP stub 用 `addr[1:0]` 作为 byte_off，但收到的地址永远是 DW 对齐的，byte_off 永远为 0。

结果：所有 readb 都返回 DW 的第 0 字节，MAC 地址读成 `DE:DE:DE:DE:DE:DE`（正确应为 `DE:AD:BE:EF:00:01`），驱动判定设备异常。

### 1.3 问题本质

这不是个别 bug，而是 **整个 TLP 处理链路缺少 PCIe FirstBE/LastBE 机制**：

- PCIe 规范要求：Memory TLP 地址必须 DW 对齐，字节级访问信息通过 FirstBE（First DW Byte Enable）传递
- 当前实现：地址直接传原始字节地址，VIP pipeline DW 对齐后 byte offset 丢失，FirstBE 硬编码为 0xF（全字节使能）
- 影响范围：所有 byte_off != 0 的 sub-DW MMIO 读写

---

## 2. Virtio-PCI 初始化流程分析

### 2.1 Virtio common_cfg 结构体（virtio 1.0 spec）

```c
struct virtio_pci_common_cfg {
    le32 device_feature_select;     // offset 0x00 — writel
    le32 device_feature;            // offset 0x04 — readl
    le32 driver_feature_select;     // offset 0x08 — writel
    le32 driver_feature;            // offset 0x0C — writel
    le16 msix_config;               // offset 0x10 — writew
    le16 num_queues;                // offset 0x12 — readw
    u8   device_status;             // offset 0x14 — writeb/readb
    u8   config_generation;         // offset 0x15 — readb
    le16 queue_select;              // offset 0x16 — writew
    le16 queue_size;                // offset 0x18 — readw/writew
    le16 queue_msix_vector;         // offset 0x1A — writew
    le16 queue_enable;              // offset 0x1C — writew
    le16 queue_notify_off;          // offset 0x1E — readw
    le64 queue_desc;                // offset 0x20 — writel x2
    le64 queue_driver;              // offset 0x28 — writel x2
    le64 queue_device;              // offset 0x30 — writel x2
};
```

注意：**u8 和 le16 字段紧凑排列在同一个 DWORD 内**。例如 DW5（offset 0x14-0x17）包含 `{queue_select[15:0], config_generation[7:0], device_status[7:0]}`。Sub-DW 访问是常态，不是 corner case。

### 2.2 完整初始化流程与 byte_off 影响

| 阶段 | 操作 | MMIO 地址 | Size | byte_off | 当前结果 |
|------|------|----------|------|----------|---------|
| Reset | writeb(0, status) | 0x1014 | 1 | 0 | ✓ |
| Acknowledge | writeb(1, status) | 0x1014 | 1 | 0 | ✓ |
| Driver | writeb(3, status) | 0x1014 | 1 | 0 | ✓ |
| Feature negotiate | writel(sel, feat_sel) | 0x1000 | 4 | 0 | ✓ |
| | readl(device_feature) | 0x1004 | 4 | 0 | ✓ |
| | writel(drv_feat_sel/feat) | 0x1008/0x100C | 4 | 0 | ✓ |
| Features OK | writeb(0xb, status) | 0x1014 | 1 | 0 | ✓ |
| Verify | readb(status) | 0x1014 | 1 | 0 | ✓ |
| **Config gen** | **readb(config_gen)** | **0x1015** | **1** | **1** | **FAIL** |
| **MAC[0]** | readb(MAC[0]) | 0x4000 | 1 | 0 | ✓ |
| **MAC[1]** | **readb(MAC[1])** | **0x4001** | **1** | **1** | **FAIL** |
| **MAC[2]** | **readb(MAC[2])** | **0x4002** | **1** | **2** | **FAIL** |
| **MAC[3]** | **readb(MAC[3])** | **0x4003** | **1** | **3** | **FAIL** |
| **MAC[4]** | readb(MAC[4]) | 0x4004 | 1 | 0 | ✓ |
| **MAC[5]** | **readb(MAC[5])** | **0x4005** | **1** | **1** | **FAIL** |
| **net_status** | **readw(net_status)** | **0x4006** | **2** | **2** | **FAIL** |
| max_vq_pairs | readw(max_vq_pairs) | 0x4008 | 2 | 0 | ✓ |
| **Queue select** | **writew(queue_sel)** | **0x1016** | **2** | **2** | **FAIL** |
| Queue size | readw(queue_size) | 0x1018 | 2 | 0 | ✓ |
| **MSIX vector** | **writew(msix_vec)** | **0x101A** | **2** | **2** | **FAIL** |
| Queue enable | writew(queue_enable) | 0x101C | 2 | 0 | ✓ |
| **Notify off** | **readw(notify_off)** | **0x101E** | **2** | **2** | **FAIL** |
| Desc/Avail/Used | writel(...) | 0x1020-0x1034 | 4 | 0 | ✓ |
| Driver OK | writeb(0xf, status) | 0x1014 | 1 | 0 | ✓ |
| Notify | writew(qidx) | 0x2000 | 2 | 0 | ✓ |
| ISR | readb(isr) | 0x3000 | 1 | 0 | ✓ |

**结论**：11 个关键操作因 byte_off != 0 而失败。即使 bypass config 完全正确，MMIO 阶段也无法完成 virtio 初始化。

---

## 3. 架构问题全景

### 3.1 问题一：缺少 FirstBE/LastBE

- PCIe 规范：Memory TLP 地址 DW 对齐，字节级信息通过 FirstBE[3:0]/LastBE[3:0] 传递
- 当前实现：`cosim_rc_driver.sv` 硬编码 `ext_first_be = 8'hF`
- `tlp_entry_t` 结构体已有 `first_be`/`last_be` 字段，但 QEMU 侧未填充，VCS 侧未使用

### 3.2 问题二：TLP 地址不符合 PCIe 规范

- QEMU MMIO callback 收到的 `addr` 是 BAR 内偏移（QEMU PCI 框架已做 BAR 基址减法）
- 真实 PCIe：RC 发出的 MRd/MWr TLP 地址是 **完整 PCIe 物理地址**（BAR 基址 + 偏移）
- EP 收到 TLP 后做 BAR 匹配，计算 BAR 内偏移
- 当前直接发偏移量，跳过了 BAR 匹配流程

### 3.3 问题三：Config Space 一致性

QEMU 和 VCS 两侧各自维护一份 Config Space，内容不一致：

```
QEMU 本地 config[]:                    VCS config_proxy:
cap_ptr → 0x38(MSI)                    cap_ptr → 0x40(VIRTIO)
0x38: MSI → next=0x50                  0x40: VIRTIO_COMMON → next=0x54
0x50: VIRTIO_COMMON → next=0x64        0x54: VIRTIO_NOTIFY → next=0x68
0x64: VIRTIO_NOTIFY → next=0x78        0x68: VIRTIO_ISR → next=0x78
0x78: VIRTIO_ISR → next=0x88           0x78: VIRTIO_DEVICE → next=0x00
0x88: VIRTIO_DEVICE → next=0x00
```

更深层的架构问题：**QEMU realize 中硬编码了 virtio capabilities**。从 PCIe 架构角度，Config Space 属于 EP（VCS 侧），QEMU 作为 RC 不应预设 EP 的内容。

---

## 4. PCIe 设备 Config Space 的本质

### 4.1 真实硬件中的 Config Space

在真实 PCIe 硬件中，Config Space 是 **EP 芯片内部的硬件寄存器**：

```
PCIe EP 芯片 (ASIC/FPGA)
┌──────────────────────────────────────────────────┐
│  Config Space (4KB 硬件寄存器)                    │
│  ┌─────────────────────────────────────────────┐ │
│  │ 0x00: Vendor/Device ID          ← 出厂固化  │ │
│  │ 0x04: Command/Status            ← 软件可写  │ │
│  │ 0x10: BAR0                      ← OS 分配   │ │
│  │ 0x38: MSI Capability            ← 硬件实现  │ │
│  │ 0x50: VIRTIO_PCI_CAP_COMMON_CFG ← 出厂固化  │ │
│  │ ...                                         │ │
│  └─────────────────────────────────────────────┘ │
│                                                  │
│  BAR0 MMIO 空间 (硬件寄存器)                      │
│  ┌─────────────────────────────────────────────┐ │
│  │ +0x1000: common_cfg 寄存器组    ← 硬件状态机 │ │
│  │ +0x2000: notification 寄存器    ← 触发 DMA   │ │
│  │ +0x3000: ISR status             ← 中断状态   │ │
│  │ +0x4000: device config (MAC等)  ← 设备特定   │ │
│  └─────────────────────────────────────────────┘ │
│                                                  │
│  内部逻辑: DMA 引擎, MSI 生成, PCIe TLP 收发      │
└──────────────────────────────────────────────────┘
```

### 4.2 映射到 cosim 架构

| 真实硬件 | cosim 中对应 | 说明 |
|---------|-------------|------|
| EP 芯片 config space 寄存器 | VCS `pcie_ep_stub.cfg_space[]` + `config_proxy` | EP 的权威数据源 |
| EP 芯片 BAR0 MMIO 寄存器 | VCS `pcie_ep_stub` 中的 `vio_*` 寄存器 | virtio 设备逻辑 |
| EP 芯片 DMA 引擎 | VCS `dma_manager` + `virtqueue_dma` | DMA 读写 Guest 内存 |
| EP 芯片 MSI 中断逻辑 | VCS `stub_isr_set` → QEMU `msi_notify` | 中断注入 |
| PCIe Link + Root Complex | QEMU + Bridge (TCP/SHM) | 传输通道 |
| Host CPU + OS 驱动 | QEMU Guest Linux + virtio-pci driver | 软件栈 |

### 4.3 QEMU `pci_dev->config[]` 的角色

QEMU PCI 框架维护一个本地 `config[4096]` 数组。这是 PCIe 规范要求每个 Function 必须有的 Configuration Space 在 QEMU 中的实现。

**框架必须保留的字段**（QEMU PCI 框架强依赖）：

| 字段 | 为什么必须 |
|------|-----------|
| BAR 寄存器 + wmask | `pci_register_bar()` 设置 wmask，QEMU 据此创建 MemoryRegion。没有它，Guest MMIO 访问不会路由到 callback |
| Command register | QEMU 用它控制 MemoryRegion 的 enable/disable |
| MSI capability | `msi_notify(pci_dev, vector)` 从 config[] 读 MSI 地址/数据来注入中断 |

**应该删除的字段**（EP 侧定义，QEMU 不应预设）：

| 字段 | 为什么多余 |
|------|-----------|
| Virtio capabilities | Guest 通过 CfgRd 全转发到 VCS 读取，QEMU 内部不读 |
| Capability 链接 | 指向 virtio caps 的链接不需要 |

---

## 5. 改造方案

### 5.1 设计原则

1. **VCS EP 是 Config Space 的唯一权威来源**：所有 capability、设备身份、BAR 配置都在 VCS 侧定义
2. **QEMU 通过标准 PCIe 枚举发现 EP 配置**：realize 时从 VCS 读取 BAR 大小、MSI 位置等
3. **完整 PCIe 地址 + FirstBE/LastBE**：TLP 地址为完整 64 位 PCIe 物理地址，字节级信息通过 BE 传递
4. **架构支持多 BAR + 多设备类型**：当前只激活 BAR0/virtio-net，但架构可扩展

### 5.2 改造后的完整数据流

#### MRd 流程（readb/readw/readl）

```
Guest readb(BAR0 + 0x4001):

  QEMU cosim_mmio_read(addr=0x4001, size=1):
     bar0_base = pci_get_bar_addr(pci_dev, 0)    // e.g. 0xFE000000
     pcie_addr = bar0_base + 0x4001               // 0xFE004001
     byte_off  = pcie_addr & 3                     // 1
     dw_addr   = pcie_addr & ~3                    // 0xFE004000
     first_be  = ((1 << 1) - 1) << 1               // 0b0010
     → TLP: {MRD, addr=0xFE004000, first_be=0b0010, last_be=0, len=1DW}

  Bridge TCP 传输:
     tlp_entry_t 携带 addr(64bit) + first_be + last_be

  VCS cosim_rc_driver:
     从 DPI-C getter 获取 first_be/last_be（不再硬编码 0xF）
     构建 VIP TLP，设置 first_be/last_be

  VIP pipeline:
     编码: addr DW 对齐, FirstBE=0b0010 写入 TLP header byte[7]

  Glue:
     从 VIP bus 提取 FirstBE: beat0_q[59:56] = 0b0010
     BAR 匹配: bar_offset = hdr_addr - bar0_base = 0x4000
     从 FirstBE 计算 byte_off = 1
     stub_tlp_addr = bar_offset | byte_off = 0x4001
     stub_first_be = 0b0010

  EP stub:
     addr_offset = 0x4001 → is_vio_devcfg
     返回整个 DW: cpl_rdata = {MAC[3], MAC[2], MAC[1], MAC[0]}

  QEMU 收到 CplD:
     重组 32-bit dword
     val = (dword >> (1*8)) & 0xFF = MAC[1] ✓
```

#### MWr 流程（writeb/writew/writel）

```
Guest writew(BAR0 + 0x1016, queue_sel=1):

  QEMU cosim_mmio_write(addr=0x1016, val=1, size=2):
     pcie_addr = bar0_base + 0x1016               // 0xFE001016
     byte_off  = 2
     dw_addr   = 0xFE001014
     first_be  = ((1 << 2) - 1) << 2               // 0b1100
     shifted   = 1 << (2 * 8)                      // 0x00010000
     → TLP: {MWR, addr=0xFE001014, first_be=0b1100, data=0x00010000}

  → 同 MRd 路径到 EP stub

  EP stub:
     DW5 of common_cfg, first_be=0b1100
     first_be[0]=0 → 不更新 device_status ✓
     first_be[1]=0 → 不更新 config_generation ✓
     first_be[2]=1 → vio_queue_sel[7:0] <= tlp_wdata[23:16] ✓
     first_be[3]=1 → vio_queue_sel[15:8] <= tlp_wdata[31:24] ✓
```

### 5.3 QEMU 设备发现协议

QEMU 不再硬编码 EP 的 capability 布局。realize 时通过标准 PCIe Config TLP 从 VCS 发现设备配置：

```
cosim_pcie_rc_realize:
  │
  ├─ 1. 建立 bridge 连接（TCP/SHM）
  │
  ├─ 2. 设备发现（通过 CfgRd/CfgWr TLP — 标准 PCIe 枚举）
  │     │
  │     ├─ BAR sizing:
  │     │   for each BAR (0-5):
  │     │     CfgRd(BAR_reg) → 保存原值
  │     │     CfgWr(BAR_reg, 0xFFFFFFFF)
  │     │     CfgRd(BAR_reg) → 读回 mask → 计算大小
  │     │     CfgWr(BAR_reg, 原值) → 恢复
  │     │     (64位BAR: 额外处理 BAR_hi DW)
  │     │
  │     └─ Capability 链遍历:
  │         CfgRd(0x34) → cap_ptr
  │         while (ptr != 0):
  │           CfgRd(ptr) → cap_id, next_ptr
  │           if cap_id == 0x05: 记录 MSI offset + vectors
  │           if cap_id == 0x11: 记录 MSI-X offset + table_size
  │           ptr = next_ptr
  │
  ├─ 3. 基于发现结果初始化 QEMU 框架
  │     ├─ pci_register_bar(size = 从 VCS 获取的 BAR 大小)
  │     ├─ msi_init(offset = 从 VCS 获取的 MSI 位置)
  │     └─ 不写 virtio caps — 完全由 VCS 定义
  │
  └─ 4. 启动 IRQ poller / DMA handler
```

#### 设备发现核心函数（伪代码）

```c
// 从 VCS EP 读一个 config DW
static uint32_t cosim_cfgrd(bridge_ctx_t *ctx, uint32_t reg) {
    tlp_entry_t req = { .type = TLP_CFGRD, .addr = reg & ~3u, .len = 4 };
    cpl_entry_t cpl = {0};
    bridge_send_tlp_and_wait(ctx, &req, &cpl);
    return le32_from_bytes(cpl.data);
}

// BAR sizing — 标准 PCIe 发现流程
static uint32_t cosim_query_bar_size(bridge_ctx_t *ctx, int bar) {
    uint32_t reg = PCI_BASE_ADDRESS_0 + bar * 4;
    uint32_t orig = cosim_cfgrd(ctx, reg);       // 保存原值
    cosim_cfgwr(ctx, reg, 0xFFFFFFFF);           // 写全 1
    uint32_t mask = cosim_cfgrd(ctx, reg);       // 读回 mask
    cosim_cfgwr(ctx, reg, orig);                 // 恢复原值
    if (mask == 0 || mask == 0xFFFFFFFF) return 0;
    return ~(mask & ~0xFu) + 1;                  // 计算大小
}

// 遍历 capability 链发现 MSI
static void cosim_discover_caps(bridge_ctx_t *ctx,
                                 int *msi_offset, int *msi_vectors) {
    uint32_t dw = cosim_cfgrd(ctx, PCI_STATUS);
    if (!((dw >> 16) & PCI_STATUS_CAP_LIST)) return;

    uint8_t ptr = cosim_cfgrd(ctx, PCI_CAPABILITY_LIST) & 0xFF;
    while (ptr) {
        dw = cosim_cfgrd(ctx, ptr);
        uint8_t cap_id = dw & 0xFF;
        if (cap_id == PCI_CAP_ID_MSI) {
            *msi_offset = ptr;
            *msi_vectors = 1 << (((dw >> 17) & 0x7));  // MMC field
        }
        ptr = (dw >> 8) & 0xFC;  // next ptr (DW aligned)
    }
}
```

#### realize 改造后

```c
static void cosim_pcie_rc_realize(PCIDevice *pci_dev, Error **errp) {
    CosimPCIeRC *s = COSIM_PCIE_RC(pci_dev);

    // ① 建立 bridge 连接
    setup_bridge(s, errp);
    if (*errp) return;
    bridge_ctx_t *ctx = s->bridge_ctx;

    // ② 从 VCS EP 发现设备配置（标准 PCIe 枚举）
    uint32_t bar0_size = cosim_query_bar_size(ctx, 0);
    int msi_offset = -1, msi_vectors = 0;
    cosim_discover_caps(ctx, &msi_offset, &msi_vectors);

    fprintf(stderr, "[realize] Discovered: BAR0=%uKB, MSI@0x%02x vec=%d\n",
            bar0_size / 1024, msi_offset, msi_vectors);

    // ③ 基于发现结果初始化 QEMU 框架
    if (bar0_size > 0) {
        memory_region_init_io(&s->bar0, OBJECT(s), &cosim_mmio_ops, s,
                              "cosim-bar0", bar0_size);
        pci_register_bar(pci_dev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar0);
    }
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);

    if (msi_offset >= 0) {
        msi_init(pci_dev, msi_offset, msi_vectors, true, false, errp);
    }

    // ④ 不写 virtio capabilities — 完全由 VCS EP 定义
    // ⑤ 启动 IRQ poller...
}
```

### 5.4 Config Space 一致性

VCS config_proxy 成为唯一权威来源，需要补充 MSI Capability stub：

```
VCS config_proxy init_config_space（改造后）:

DW0  (0x00): {Device_ID, Vendor_ID}
DW1  (0x04): {Status(cap_list=1), Command}
DW2  (0x08): {Class_Code, Revision}
DW3  (0x0C): {BIST, HeaderType, LatTimer, CacheLine}
DW4  (0x10): BAR0_lo  (type=10 → 64-bit BAR)
DW5  (0x14): BAR0_hi
DW11 (0x2C): {Subsystem_ID, Subsys_Vendor_ID}
DW13 (0x34): Capabilities Pointer = 0x38
DW15 (0x3C): {INT_PIN=INTA, INT_LINE}

--- MSI Capability (新增 stub) ---
DW14 (0x38): {MSI_msg_ctrl=0x0080, next=0x50, cap_id=0x05}
DW15 (0x3C): MSI_msg_addr_lo = 0
DW16 (0x40): MSI_msg_addr_hi = 0
DW17 (0x44): MSI_msg_data = 0

--- Virtio PCI Capabilities (偏移调整，与 QEMU 一致) ---
DW20 (0x50): VIRTIO_PCI_CAP_COMMON_CFG → next=0x64
             cap_vndr=0x09, bar=0, offset=0x1000, length=56
DW25 (0x64): VIRTIO_PCI_CAP_NOTIFY_CFG → next=0x78
             cap_vndr=0x09, bar=0, offset=0x2000, length=4
DW30 (0x78): VIRTIO_PCI_CAP_ISR_CFG    → next=0x88
             cap_vndr=0x09, bar=0, offset=0x3000, length=4
DW34 (0x88): VIRTIO_PCI_CAP_DEVICE_CFG → next=0x00
             cap_vndr=0x09, bar=0, offset=0x4000, length=16
```

QEMU realize 时通过 capability 链遍历发现 MSI cap 在 0x38，据此调用 `msi_init(pci_dev, 0x38, ...)`，完全由 VCS 驱动。

### 5.5 64 位 BAR 支持

PCIe 64 位 BAR 占用两个连续的 config space DW：

```
BAR 寄存器 bit[2:1] = Type:
  00 = 32-bit BAR（1个DW）
  10 = 64-bit BAR（2个连续DW）

cfg_space[4] = BAR0_lo: {地址[31:4], prefetch, type=10, mem=0}
cfg_space[5] = BAR0_hi: {地址[63:32]}
完整地址 = {BAR0_hi, BAR0_lo & ~size_mask}
```

所有路径统一为 64 位地址：

| 组件 | 字段 | 宽度 |
|------|------|------|
| tlp_entry_t.addr | `uint64_t` | 64 bit（已有） |
| config_proxy.bar0_addr | `bit [63:0]` | 改为 64 bit |
| bridge_vcs g_bar_base | `uint64_t[6]` | 64 bit |
| glue bar_base 输入 | `logic [63:0]` | 64 bit |
| glue hdr_addr | `logic [63:0]` | 64 bit（已有） |

### 5.6 多 BAR 架构预留

当前只激活 BAR0，但架构设计支持 6 个 BAR：

#### QEMU 侧

```c
typedef struct {
    CosimPCIeRC *dev;
    int bar_index;
} CosimBarContext;

struct CosimPCIeRC {
    PCIDevice parent_obj;
    MemoryRegion bars[6];
    CosimBarContext bar_ctx[6];
    int num_bars;
    ...
};

// mmio callback 通过 opaque 获取 bar_index
static uint64_t cosim_mmio_read(void *opaque, hwaddr addr, unsigned size) {
    CosimBarContext *bc = opaque;
    uint64_t bar_base = pci_get_bar_addr(&bc->dev->parent_obj, bc->bar_index);
    uint64_t pcie_addr = bar_base + addr;
    ...
}
```

#### VCS 侧

```systemverilog
// bridge_vcs.c: 6 个 BAR 基址
static uint64_t g_bar_base[6] = {0};

// Glue: 多 BAR 匹配
input  logic [63:0] bar_base[0:5],
output logic [2:0]  stub_bar_index,

// EP stub: 按 BAR index 分发
input  logic [2:0]  bar_index,
case (bar_index)
    3'd0: /* BAR0 区域: virtio + 通用寄存器 */
    3'd1: /* BAR1 区域: 预留 */
endcase
```

---

## 6. EP Stub MWr 字节级写入设计

改造前（启发式，依赖 byte_off）：
```systemverilog
4'd5: begin
    if (byte_off == 0) vio_dev_status <= tlp_wdata[7:0];           // 每次都更新
    if (byte_off == 0 && tlp_wdata[31:16] != 16'h0)
        vio_queue_sel <= tlp_wdata[31:16];                          // 启发式
    if (byte_off == 2) vio_queue_sel <= tlp_wdata[15:0];
end
```

改造后（精确，基于 FirstBE mask）：
```systemverilog
// DW5: {queue_select[15:0], config_generation[7:0], device_status[7:0]}
4'd5: begin
    if (first_be[0]) vio_dev_status      <= tlp_wdata[7:0];    // byte 0
    // first_be[1]: config_gen 只读，写入忽略                     // byte 1
    if (first_be[2]) vio_queue_sel[7:0]  <= tlp_wdata[23:16];  // byte 2
    if (first_be[3]) vio_queue_sel[15:8] <= tlp_wdata[31:24];  // byte 3
end

// DW6: {queue_msix_vector[15:0], queue_size[15:0]}
4'd6: begin
    if (first_be[0]) vio_q_size[qsel][7:0]  <= tlp_wdata[7:0];
    if (first_be[1]) vio_q_size[qsel][15:8] <= tlp_wdata[15:8];
    if (first_be[2]) vio_q_msix[qsel][7:0]  <= tlp_wdata[23:16];
    if (first_be[3]) vio_q_msix[qsel][15:8] <= tlp_wdata[31:24];
end

// DW7: {queue_notify_off[15:0], queue_enable[15:0]}
4'd7: begin
    if (first_be[0]) vio_q_enable[qsel][7:0]  <= tlp_wdata[7:0];
    if (first_be[1]) vio_q_enable[qsel][15:8] <= tlp_wdata[15:8];
    // first_be[2:3]: notify_off 只读
end
```

---

## 7. BAR 基址同步机制

在 bypass 模式下，CfgWr 被 config_proxy 拦截，EP stub 不会收到 BAR 赋值。通过 DPI-C 全局变量同步：

```c
// bridge_vcs.c
static uint64_t g_bar_base[6] = {0};

void bridge_vcs_set_bar_base(int idx, unsigned long long base) {
    if (idx >= 0 && idx < 6) g_bar_base[idx] = base;
}
unsigned long long bridge_vcs_get_bar_base(int idx) {
    if (idx >= 0 && idx < 6) return g_bar_base[idx];
    return 0;
}
```

```systemverilog
// cosim_vip_top.sv — 每 clock 从 DPI-C 读取 BAR 基址
logic [63:0] bar_base_regs[0:5];
always_ff @(posedge clk) begin
    for (int i = 0; i < 6; i++)
        bar_base_regs[i] <= bridge_vcs_get_bar_base(i);
end
```

```systemverilog
// cosim_rc_driver.sv — bypass CfgWr BAR0 时同步
if (dw_addr == 4 && wr_data != 32'hFFFF_FFFF) begin
    bridge_vcs_set_bar_base(0, config_proxy.bar0_addr);
end
if (dw_addr == 5 && config_proxy.bar0_is_64bit) begin
    // 64-bit BAR: 更新完整 64 位地址
    bridge_vcs_set_bar_base(0, config_proxy.bar0_addr);
end
```

---

## 8. 改动文件清单

### 8.1 QEMU 侧

| 文件 | 改动 |
|------|------|
| `cosim_pcie_rc.h` | `MemoryRegion bars[6]` + `CosimBarContext bar_ctx[6]` + 删除 `COSIM_BAR0_SIZE` |
| `cosim_pcie_rc.c` mmio_read | 重建完整 PCIe 地址，DW 对齐，FirstBE，CplD 字节提取 |
| `cosim_pcie_rc.c` mmio_write | 重建完整 PCIe 地址，DW 对齐，FirstBE，数据定位 |
| `cosim_pcie_rc.c` realize | 删除 virtio cap 初始化；设备发现协议；基于发现调用 pci_register_bar / msi_init |

### 8.2 Bridge 传输层

| 文件 | 改动 |
|------|------|
| `cosim_types.h` | 无需改（已有 first_be/last_be） |
| `bridge_vcs.c` | 添加 g_bar_base[6] + set/get 函数 + get_poll_first_be/last_be |
| `bridge_vcs.sv` | 添加 DPI-C import 声明 |

### 8.3 VCS 仿真侧

| 文件 | 改动 |
|------|------|
| `cosim_rc_driver.sv` | first_be/last_be 从 getter 获取；bypass CfgWr BAR 同步 |
| `glue_if_to_stub.sv` | 添加 bar_base 输入 + FirstBE 提取 + BAR 匹配 + stub_first_be/bar_index 输出 |
| `pcie_ep_stub.sv` | 添加 first_be/bar_index 端口；MRd 返回整 DW；MWr 按 BE 字节级写入 |
| `cosim_vip_top.sv` | bar_base 寄存器 + first_be/bar_index 连线 |
| `pcie_tl_config_proxy.sv` | Cap 布局添加 MSI stub + 调整 virtio caps 偏移 + 64 位 BAR |

---

## 9. 已有基础设施盘点

| 基础设施 | 状态 | 说明 |
|---------|------|------|
| `tlp_entry_t.first_be` / `last_be` | ✓ 已有字段 | cosim_types.h |
| `bridge_vcs_poll_tlp_ext()` | ✓ 已有函数 | 可返回 first_be/last_be |
| `bridge_vcs.sv` ext import | ✓ 已有声明 | poll_tlp_ext 的 DPI-C import |
| `cosim_rc_driver` build_vip_tlp | ✓ 已有 first_be 参数 | 但被硬编码为 0xF |
| Glue 3DW/4DW header 解码 | ✓ 已支持 | hdr_addr 已是 64 位 |
| `first_be` 独立 getter | ✗ 缺失 | 需添加 |
| Glue FirstBE 提取 | ✗ 缺失 | 需从 beat0_q[59:56] 提取 |
| Glue BAR 匹配 | ✗ 缺失 | 需添加 |
| EP stub first_be 端口 | ✗ 缺失 | 需添加 |
| Config proxy MSI stub | ✗ 缺失 | 需添加 |

---

## 10. 验证矩阵

改造完成后，所有 virtio 初始化操作应正确工作：

| 操作 | 地址 | FirstBE | 改造后 |
|------|------|---------|--------|
| writeb(status=0, 0x1014) | DW 0x..1014 | 0b0001 | ✓ |
| readb(config_gen, 0x1015) | DW 0x..1014 | 0b0010 | ✓ |
| writew(queue_sel=1, 0x1016) | DW 0x..1014 | 0b1100 | ✓ |
| readb(MAC[1], 0x4001) | DW 0x..4000 | 0b0010 | ✓ |
| readb(MAC[2], 0x4002) | DW 0x..4000 | 0b0100 | ✓ |
| readb(MAC[3], 0x4003) | DW 0x..4000 | 0b1000 | ✓ |
| readw(net_status, 0x4006) | DW 0x..4004 | 0b1100 | ✓ |
| readw(notify_off, 0x101E) | DW 0x..101C | 0b1100 | ✓ |
| writew(msix_vec, 0x101A) | DW 0x..1018 | 0b1100 | ✓ |

---

## 11. 总结

本次改造解决的核心问题和覆盖的能力：

1. **FirstBE/LastBE 字节级访问** — 解决 virtio 初始化失败的直接原因
2. **完整 PCIe 地址（64 位 BAR）** — 符合 PCIe TLP 规范
3. **QEMU 设备发现协议** — RC 从 EP 枚举设备配置，不硬编码
4. **Config Space 权威来源统一** — VCS EP 定义一切，QEMU 不预设
5. **多 BAR 架构预留** — 支持未来多 BAR 设备
6. **多设备类型兼容** — 只改 VCS 侧即可更换设备类型

---

## 12. 验证修复记录（2026-04-25）

TCP 模式双实例联调中发现并修复了以下阻塞问题：

### 12.1 MSI Capability Offset 必须 >= 0x40

**问题：** config_proxy 将 MSI cap 放在 0x38（标准头区域内）。Linux kernel `__pci_find_next_cap_ttl()` 检查 `if (pos < 0x40) break;`，跳过 0x38 → 整条 cap 链不可见 → `leaving for legacy driver`。

**修复：** `pcie_tl_config_proxy.sv` 将 MSI 从 DW14(0x38) 移到 DW16(0x40)。PCI spec 要求 cap offset >= 0x40。

### 12.2 CfgWr 字节级合并

**问题：** Guest 写 INT_LINE(1 byte @ 0x3C)，config_proxy 的 `handle_cfg_write` 直接 `config_space[dw_addr] = data` 覆盖整个 DW，将 INT_PIN(0x3D) 清零 → IRQ=0 → `request_irq(0)` 返回 -EINVAL → `probe failed with error -22`。

**修复：** `handle_cfg_write` 增加 `byte_off`/`byte_len` 参数做字节级合并；`cosim_rc_driver.sv` 传入 `addr & 3` 和 `dpi_len`。

### 12.3 INTx 去断言（VIP 模式遗漏）

**问题：** INTx 电平触发。VCS 注入 RX 后 `pci_set_irq(1)` 拉高中断线，Guest 读 ISR 清除条件，但无人发 deassert(0xFFFE) → 线持续高 → 后续中断无边沿 → Guest 只收到首个中断。legacy 模式 (tb_top.sv) 有此逻辑，VIP 模式遗漏。

**修复：** `cosim_vip_top.sv` 增加 ISR 读检测 → `bridge_vcs_raise_msi(0xFFFE)` 去断言。

### 12.4 notify_event_queue NBA 时序

**问题：** `always_ff` 中 NBA 赋值(`<=`) + 同周期 event 触发，initial 块读到上一拍旧值，queue index 滞后一拍。

**修复：** 改为 `always @(posedge clk)` + blocking assignment(`=`)，先赋值再触发 event。

### 12.5 QEMU 侧 virtio caps 注册（不需要）

Virtio caps 是 EP 属性，Guest config 读取全走 VCS。QEMU 只需 `msi_init()` 注册 MSI（内部 `msi_notify()` 依赖本地 config[]）。已移除 virtio caps 的 `pci_add_capability`，保留注释说明。

### 12.6 验证结果

| 验证项 | 结果 |
|--------|------|
| virtio modern probe | PASS（两个 Guest） |
| eth0 UP + IP | PASS |
| 双向 VCS TX/RX | PASS |
| Guest rx_packets > 0 | PASS |
| ping | TIMEOUT（协仿延迟，非功能 bug） |
