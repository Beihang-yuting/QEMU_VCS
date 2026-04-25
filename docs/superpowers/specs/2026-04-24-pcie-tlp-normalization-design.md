# PCIe TLP 规范化改造 Spec

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this spec.

**Goal:** 修复 PCIe TLP 链路中 FirstBE/LastBE 缺失导致的 sub-DW MMIO 访问失败，同时将整个 TLP 处理流程规范化为完整 PCIe 协议语义（完整地址 + BE + 64位BAR + 设备发现）。

**Success Criteria:** TCP bypass 模式下 virtio-net 设备初始化完成（device_status=0x0F/DRIVER_OK），iperf 打流成功。

---

## 改动清单

### 1. QEMU cosim_pcie_rc.c — MMIO 读写规范化

**cosim_mmio_read:**
- 通过 opaque 获取 bar_index（多BAR预留）
- `bar_base = pci_get_bar_addr(pci_dev, bar_index)`
- `pcie_addr = bar_base + addr`（完整64位PCIe地址）
- `dw_addr = pcie_addr & ~3ULL`（DW对齐）
- `byte_off = pcie_addr & 3`
- `first_be = ((1 << size) - 1) << byte_off`
- `req.addr = dw_addr`, `req.len = 4`, `req.first_be = first_be`, `req.last_be = 0`
- CplD 收到后：`val = (dword >> (byte_off * 8)) & mask`

**cosim_mmio_write:**
- 同上计算 dw_addr / first_be
- 数据定位：`shifted_val = (uint32_t)val << (byte_off * 8)`
- `req.data` 按 LE 打包 shifted_val

### 2. QEMU cosim_pcie_rc.c — realize 设备发现

- 删除全部 virtio capability 硬编码（0x50-0x94 区域）
- 连接建立后通过 CfgRd/CfgWr 从 VCS 发现：
  - BAR sizing：写 0xFFFFFFFF → 读 mask → 恢复 → 计算大小
  - Capability 链遍历：从 cap_ptr 开始找 MSI cap 位置和 vector 数
- 基于发现结果调用 `pci_register_bar()` 和 `msi_init()`
- 保留 Command register 设置

### 3. QEMU cosim_pcie_rc.h — 多BAR预留

- `MemoryRegion bars[6]` 替代 `MemoryRegion bar0`
- 添加 `CosimBarContext bar_ctx[6]`（包含 dev 指针 + bar_index）
- 删除 `COSIM_BAR0_SIZE` 硬编码

### 4. bridge/vcs/bridge_vcs.c — DPI-C 扩展

- 添加 `g_bar_base[6]`（uint64_t）
- 添加 `bridge_vcs_set_bar_base(int idx, unsigned long long base)`
- 添加 `bridge_vcs_get_bar_base(int idx)` → `unsigned long long`
- 添加 `bridge_vcs_get_poll_first_be()` → `unsigned char`
- 添加 `bridge_vcs_get_poll_last_be()` → `unsigned char`

### 5. bridge/vcs/bridge_vcs.sv — DPI-C import

- 添加 4 个 import 声明（set_bar_base, get_bar_base, get_poll_first_be, get_poll_last_be）

### 6. vcs-tb/cosim_rc_driver.sv — FirstBE + BAR 同步

- request_loop 中：`ext_first_be = bridge_vcs_get_poll_first_be()`（替代硬编码 0xF）
- request_loop 中：`ext_last_be = bridge_vcs_get_poll_last_be()`
- bypass CfgWr 处理中：BAR 赋值时调用 `bridge_vcs_set_bar_base()`

### 7. vcs-tb/glue_if_to_stub.sv — FirstBE + BAR 匹配

- 新增输入：`input logic [63:0] bar_base[0:5]`
- 新增输出：`output logic [3:0] stub_first_be`, `output logic [2:0] stub_bar_index`
- 提取 FirstBE：`hdr_first_be = beat0_q[59:56]`
- BAR 匹配：遍历 bar_base，找到匹配的 BAR，计算偏移
- 从 FirstBE 计算 byte_off，恢复到 stub_tlp_addr 低2位
- Config TLP 不做 BAR 匹配（地址直接传递）

### 8. vcs-tb/pcie_ep_stub.sv — FirstBE 字节级访问

- 新增输入：`input logic [3:0] first_be`, `input logic [2:0] bar_index`
- MRd：返回整个 DW（删除 `cpl_rdata <= raw >> (byte_off * 8)` 的 shift）
- MWr：按 `first_be` mask 做字节级写入（替代 byte_off 启发式）
- 顶层 case(bar_index) 预留多 BAR 分发

### 9. vcs-tb/cosim_vip_top.sv — 连线

- 添加 `bar_base_regs[0:5]`（每 clock 从 DPI-C 读取）
- 连线 glue 的 bar_base 输入
- 连线 glue→EP stub 的 first_be 和 bar_index

### 10. pcie_tl_config_proxy.sv — Config Space 统一

- cap_ptr 改为 0x38（与 QEMU msi_init 发现结果对齐）
- 添加 MSI Capability stub（DW14-DW18, offset 0x38）
- Virtio caps 偏移调整为 0x50/0x64/0x78/0x88
- `bar0_addr` 扩展为 `bit [63:0]`
- BAR0 type=10（64-bit BAR），sizing 处理 lo+hi 两个 DW
- EP stub cfg_space 初始化同步调整

---

## 不改的部分

- `cosim_types.h`：tlp_entry_t 已有 first_be/last_be 字段
- `transport_tcp.c`：wire format 随 tlp_entry_t 自动变化
- CfgRd/CfgWr bypass 逻辑：config proxy 处理不变
- DMA/MSI 路径：不受影响
- VIP pipeline 内部：VIP codec 已正确处理 first_be 字段

---

## 测试计划

1. **TCP bypass 模式**：virtio-net 初始化到 DRIVER_OK（优先）
2. **TCP bypass 模式**：iperf 打流
3. **SHM 模式**：回归测试确保不破坏
4. **波形验证**：FSDB dump 检查 FirstBE 编码正确性
