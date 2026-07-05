# Xilinx PCIe TL-Layer BFM Design Specification

**Date:** 2026-04-27
**Status:** Approved
**Target:** UltraScale/UltraScale+ PG213 Integrated Block for PCIe
**Purpose:** FPGA NIC co-simulation BFM, providing Xilinx-specific 4-channel AXIS interface with standard PCIe TLP transaction model

---

## 1. Overview

### 1.1 Goals

Build a Xilinx PG213-specific Transaction Layer BFM that:

1. Presents standard `pcie_tl_tlp` transaction interface to users (sequences write PCIe TLPs)
2. Internally converts between standard PCIe TLPs and Xilinx proprietary descriptors
3. Drives/samples the 4-channel AXI-Stream interface (RQ/RC/CQ/CC) via reused `axis_agent` instances
4. Optionally models `cfg_mgmt` (configuration space) and `cfg_interrupt` (interrupt) sideband interfaces

### 1.2 Reuse Strategy: Composition

```
User Sequence (pcie_tl_tlp)
        |
 +-------------------------------------+
 |   xilinx_pcie_agent (RC/EP)         |
 |  +-------------------------------+  |
 |  |  xilinx_desc_codec            |  |  <-- NEW: TLP <-> Xilinx descriptor
 |  |  xilinx_tuser_codec           |  |  <-- NEW: tuser encode/decode
 |  |  xilinx_straddle_engine       |  |  <-- NEW: straddling pack/unpack
 |  |  xilinx_pcie_channel_router   |  |  <-- NEW: TLP -> channel routing
 |  +-------------------------------+  |
 |  +------------------------------+   |
 |  | 4x axis_agent (reused)       |   |  <-- RQ, RC, CQ, CC
 |  +------------------------------+   |
 |  +------------------------------+   |
 |  | cfg_mgmt + cfg_interrupt     |   |  <-- Optional modules
 |  | (reuses cfg_space_manager)   |   |
 |  +------------------------------+   |
 +-------------------------------------+
        |
   4x axis_if + cfg/interrupt signals
        |
      DUT (Xilinx PCIe IP or user NIC logic)
```

**Reused from axis_work:**
- `axis_agent` (master/slave drivers, monitor, sequencer, bandwidth controller)
- `axis_config` (7 valid + 7 ready generation modes)
- `axis_protocol_checker` + SVA assertions
- `axis_scoreboard`, `axis_coverage_collector`

**Reused from pcie_work:**
- `pcie_tl_tlp` class hierarchy (19 TLP types, 8 transaction classes)
- `pcie_tl_tag_manager` (10-bit tag allocation and tracking)
- `pcie_tl_fc_manager` (6-category flow control credits)
- `pcie_tl_ordering_engine` (PCIe Table 2-40 ordering rules)
- `pcie_tl_cfg_space_manager` (4KB config space model)
- `pcie_tl_codec` (reference for TLP field definitions)

**New code (~2000-3000 lines):**
- Xilinx descriptor codec (RQ/RC/CQ/CC encode/decode)
- tuser codec (per-channel, per-width field layout)
- Straddling engine (pack/unpack with enable switch)
- Channel router (TLP type -> AXIS channel mapping)
- Agent shell (RC/EP roles, driver pipeline, monitor)
- cfg_agent + interrupt_agent
- Scoreboard, coverage, sequences, testbench

### 1.3 Simulation Scenarios

| Scenario | Description |
|----------|-------------|
| **A (Primary)** | BFM connects directly to Xilinx PCIe IP user-side AXIS interface. BFM replaces user logic. |
| **C (Self-test)** | AXIS loopback: RC BFM <-> EP BFM via wire connection, verifying full descriptor encode/decode path. |

---

## 2. Directory Structure

```
xilinx_pcie/
+-- src/
|   +-- xilinx_pcie_pkg.sv              # Top-level package (includes all components)
|   +-- xilinx_pcie_types.sv            # Xilinx-specific type definitions
|   |
|   +-- interface/
|   |   +-- xilinx_pcie_if.sv           # Top-level SV interface (4x AXIS + clocking blocks)
|   |   +-- xilinx_pcie_cfg_if.sv       # cfg_mgmt + cfg_interrupt interface
|   |
|   +-- codec/
|   |   +-- xilinx_desc_codec.sv        # Descriptor <-> TLP conversion
|   |   +-- xilinx_tuser_codec.sv       # tuser field encode/decode
|   |   +-- xilinx_straddle_engine.sv   # Straddling pack/unpack engine
|   |
|   +-- agent/
|   |   +-- xilinx_pcie_base_agent.sv   # Base agent (common logic)
|   |   +-- xilinx_pcie_rc_agent.sv     # RC role agent
|   |   +-- xilinx_pcie_ep_agent.sv     # EP role agent
|   |   +-- xilinx_pcie_driver.sv       # TX direction: TLP -> descriptor -> AXIS
|   |   +-- xilinx_pcie_monitor.sv      # RX direction: AXIS -> descriptor -> TLP
|   |   +-- xilinx_pcie_channel_router.sv  # TLP type -> channel mapping
|   |
|   +-- cfg/
|   |   +-- xilinx_pcie_cfg_agent.sv    # cfg_mgmt driver/monitor
|   |   +-- xilinx_pcie_interrupt_agent.sv  # cfg_interrupt driver/monitor
|   |
|   +-- env/
|   |   +-- xilinx_pcie_env_config.sv   # Configuration object (100+ parameters)
|   |   +-- xilinx_pcie_env.sv          # Top-level environment
|   |   +-- xilinx_pcie_virtual_sequencer.sv
|   |   +-- xilinx_pcie_scoreboard.sv   # Descriptor-level + TLP-level checks
|   |   +-- xilinx_pcie_coverage.sv     # Functional coverage
|   |
|   +-- seq/
|       +-- xilinx_pcie_base_seq.sv     # Base sequence
|       +-- xilinx_pcie_mem_seq.sv      # Memory Read/Write
|       +-- xilinx_pcie_cfg_seq.sv      # Config Read/Write
|       +-- xilinx_pcie_dma_seq.sv      # DMA read/write (EP-initiated, auto MPS/4KB split)
|       +-- xilinx_pcie_msi_seq.sv      # MSI/MSI-X/Legacy interrupt
|       +-- xilinx_pcie_loopback_vseq.sv # RC<->EP loopback virtual sequence
|
+-- tb/
|   +-- tb_top.sv                       # Top-level testbench (loopback)
|   +-- xilinx_pcie_loopback_dut.sv     # AXIS loopback DUT (RQ->CQ, CC->RC wiring)
|   +-- tb_with_dut.sv                  # Template for connecting real Xilinx IP / NIC RTL
|
+-- tests/
|   +-- xilinx_pcie_base_test.sv
|   +-- xilinx_pcie_sanity_test.sv
|   +-- xilinx_pcie_straddle_test.sv
|   +-- xilinx_pcie_loopback_test.sv
|
+-- sim/
|   +-- filelist.f
|   +-- Makefile
|
+-- docs/
    +-- superpowers/specs/
        +-- 2026-04-27-xilinx-pcie-bfm-design.md  (this file)
```

---

## 3. Xilinx Descriptor Codec

### 3.1 RQ Descriptor (128-bit) -- EP 向 RC 发送请求

EP 通过此通道向 RC 发起 Memory Read/Write、IO、Atomic 等操作。

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [1:0] | Address Type | 地址类型。00=未翻译地址(Untranslated)，01=翻译请求(Translation Request)，10=已翻译地址(Translated) |
| [63:2] | Address[63:2] | 请求目标地址。字节地址，DW 对齐（低 2 位隐含为 0）。32-bit 地址时高 32 位为 0 |
| [74:64] | DWORD Count | 有效载荷长度，以 DW (4字节) 为单位。MRd 时为请求读取的 DW 数；MWr 时为写入数据的 DW 数。值为 0 表示 1024 DW |
| [78:75] | Request Type | 请求类型编码。0000=内存读(MRd)，0001=内存写(MWr)，0010=IO读(IORd)，0011=IO写(IOWr)，0100=锁定内存读(MRdLk)，1000=原子操作FetchAdd，1001=原子操作Swap，1010=原子操作CAS |
| [79] | Poisoned Request | 数据中毒标记。置 1 表示 TLP 数据可能已损坏，接收方应接受但不使用该数据 |
| [95:80] | Requester ID | 请求者标识符。[95:88]=总线号(Bus)，[87:85]=设备号(Device)，[84:80]=功能号(Function) |
| [103:96] | Tag[7:0] | 事务标签低 8 位。用于匹配请求与 completion 的对应关系。高 2 位 tag[9:8] 通过 tuser 传递 |
| [107:104] | Last DW BE | 末尾 DW 字节使能。4 bit 分别对应末尾 DW 的第 0~3 字节。单 DW 传输时此字段必须为 4'b0000 |
| [111:108] | First DW BE | 首位 DW 字节使能。4 bit 分别对应首个 DW 的第 0~3 字节。0-length read 时为 4'b0000 |
| [114:112] | Attr | 属性位。[112]=Relaxed Ordering(RO，允许乱序)，[113]=ID-based Ordering(IDO，基于ID排序)，[114]=No Snoop(NS，无需缓存一致性窥探) |
| [117:115] | TC | 流量等级 (Traffic Class)，0~7，用于虚拟通道映射和服务质量控制 |
| [118] | TH | TLP 处理提示存在标记 (TLP Processing Hint)。置 1 表示 tuser 中携带了 TPH Steering Tag |
| [126:119] | Reserved | 保留位，必须为 0 |
| [127] | Force ECRC | 强制 ECRC 插入。置 1 时 PCIe IP 强制为此 TLP 生成 ECRC，无论全局 ECRC 设置如何 |

### 3.2 RC Descriptor (96-bit) -- RC 向 EP 返回 Completion

RC 通过此通道将 completion 数据返回给 EP 的 DMA 读请求。

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [6:0] | Low Address | Completion 低地址。指示 completion 数据在原始请求首 DW 中的字节偏移，用于 EP 对齐接收数据 |
| [8:7] | Reserved | 保留位 |
| [11:9] | Error Code | 错误码。000=正常完成(Normal)，001=不支持的请求(UR)，010=配置重试(CRS)，100=完成者中止(CA)。提供比 Completion Status 更细粒度的错误信息 |
| [28:12] | Byte Count | 剩余字节计数。指示此 completion 及后续 split completion 中还需传输的总字节数。首个 completion 中为请求的总字节数 |
| [29] | Locked Read Completion | 锁定读 completion 标��。置 1 表示这是对锁定内存读(MRdLk)请求的回复 |
| [30] | Request Completed | 请求完成标记。置 1 表示这是最后一个 split completion，原始请求的所有数据已传输完毕 |
| [31] | Reserved | 保留位 |
| [42:32] | DWORD Count | 本次 completion 携带的数据长度，以 DW 为单位。注意：一个 MRd 可能被拆分为多个 completion，每个有独立的 DW Count |
| [45:43] | Completion Status | 完成状态。000=成功完成(SC)，001=不支持的请求(UR)，010=配置重试状态(CRS)，100=完成者中止(CA) |
| [46] | Poisoned Completion | Completion 数据中毒标记。置 1 表示 completion 携带的数据可能已损坏 |
| [47] | Reserved | 保留位 |
| [63:48] | Requester ID | 原始请求者标识符。与 RQ descriptor 中的 Requester ID 对应，EP 用此字段匹配自己发出的请求 |
| [71:64] | Tag[7:0] | 事务标签低 8 位���与原始请求的 tag 一致，EP 用此字段将 completion 与 outstanding 请求匹配 |
| [87:72] | Completer ID | 完成者标识符。回复此 completion 的 RC/Bridge 的 Bus/Device/Function |
| [90:88] | TC | 流量等��，与原始请求一致 |
| [93:91] | Attr | 属性位，与原始请求一致 |
| [95:94] | Reserved | 保留位 |

### 3.3 CQ Descriptor (128-bit) -- RC 请求到达 EP

PCIe IP 在 BAR 命中后通过此通道将 host 请求送达 EP 用户逻辑。

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [1:0] | Address Type | 地址类型。00=未翻译地址，01=翻译请求，10=已翻译地址 |
| [63:2] | Address[63:2] | 目标地址。BAR 命中后的实际访问地址，字节对齐（DW 对齐）。EP 用此地址确定内部寄存器/存储位置 |
| [74:64] | DWORD Count | 有效载荷长度（DW 为单位）。MWr 时为写入数据的 DW 数；MRd 时为请求读取的 DW 数 |
| [78:75] | Request Type | 请求类型编码。与 RQ 相同的编码方式：0000=MRd，0001=MWr，0010=IORd，0011=IOWr，0100=MRdLk，1000=FetchAdd，1001=Swap，1010=CAS |
| [79] | Poisoned Request | 数据中毒标记 |
| [95:80] | Requester ID | 原始请求者标识符。EP 在生成 completion 时需要将此值填入 CC descriptor 的 Requester ID 字段 |
| [103:96] | Tag[7:0] | 事务标签低 8 位。EP 在生成 completion 时需回填此值，确保 RC 能匹配 |
| [107:104] | Target Function | 目标功能号。指示 BAR 命中的是哪个 PF/VF，用于 SR-IOV 场景下的功能路由 |
| [110:108] | BAR ID | 命中的 BAR 编号（0~5）。EP 据此判断请求访问的是哪个地址空间（寄存器/存储/ROM 等） |
| [116:111] | BAR Aperture | BAR 大小指数。值 N 表示 BAR 大小为 2^(N+1) 字节。例如：12 表示 8KB (2^13)。EP 可据此计算 BAR 内偏移 |
| [118:117] | TC | 流量等级 |
| [121:119] | Attr | 属性位 |
| [126:122] | Reserved | 保留位 |
| [127] | Reserved | 保留位 |

### 3.4 CC Descriptor (96-bit) -- EP 向 RC 返回 Completion

EP 通过此通道向 RC 发送 completion 回复。

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [6:0] | Low Address | Completion 低地址。与 RC descriptor 含义相同，指示数据在首 DW 中的字节偏移 |
| [8:7] | Reserved | 保留位 |
| [11:9] | Error Code | 错误码。000=正常，001=UR，010=CRS，100=CA |
| [28:12] | Byte Count | 剩余字节计数 |
| [29] | Locked Read Completion | 锁定读 completion 标记 |
| [30] | Reserved | 保留位 |
| [31] | Reserved | 保留位 |
| [42:32] | DWORD Count | 本次 completion 数据长度（DW 为单位） |
| [45:43] | Completion Status | 完成状态。000=SC，001=UR，010=CRS，100=CA |
| [46] | Poisoned Completion | Completion 数据中毒标记 |
| [47] | Reserved | 保留位 |
| [63:48] | Requester ID | 原始请求者标识符。必须与 CQ 中收到的 Requester ID 一致 |
| [71:64] | Tag[7:0] | 事务标签低 8 位。必须与 CQ 中收到的 Tag 一致 |
| [87:72] | Completer ID | 完成者标识符。EP 自身的 Bus/Device/Function |
| [90:88] | TC | 流量等级 |
| [93:91] | Attr | 属性位 |
| [95:94] | Reserved | 保留位 |

### 3.5 Codec Class Design

```systemverilog
class xilinx_desc_codec;

  // ===== RQ: 标准 TLP -> RQ descriptor =====
  // 用途：EP agent driver 发送请求时调用
  // 输入：标准 pcie_tl_tlp 对象（MRd/MWr/IORd/IOWr/Atomic）
  // 输出：128-bit RQ descriptor
  static function bit [127:0] encode_rq(pcie_tl_tlp tlp);

  // ===== RQ: RQ descriptor -> 标准 TLP =====
  // 用途：RC agent monitor 接收 EP 请求时调用
  static function pcie_tl_tlp decode_rq(bit [127:0] desc, bit [7:0] payload[]);

  // ===== RC: 标准 TLP (completion) -> RC descriptor =====
  // 用途：RC agent driver 回复 DMA completion 时调用
  static function bit [95:0] encode_rc(pcie_tl_tlp tlp);

  // ===== RC: RC descriptor -> 标准 TLP =====
  // 用途���EP agent monitor 接收 completion 时调用
  static function pcie_tl_tlp decode_rc(bit [95:0] desc, bit [7:0] payload[]);

  // ===== CQ: 标准 TLP -> CQ descriptor =====
  // 用途：RC agent driver 发送请求给 EP 时调用
  // 额外参数：bar_id, bar_aperture, target_func（RC 模拟 BAR 匹配结果）
  static function bit [127:0] encode_cq(pcie_tl_tlp tlp,
                                         bit [2:0] bar_id,
                                         bit [5:0] bar_aperture,
                                         bit [7:0] target_func);

  // ===== CQ: CQ descriptor -> 标准 TLP =====
  // 用途：EP agent monitor 接收 RC 请求时调用
  static function pcie_tl_tlp decode_cq(bit [127:0] desc, bit [7:0] payload[]);

  // ===== CC: 标准 TLP (completion) -> CC descriptor =====
  // 用途：EP agent driver 回复 completion 时调用
  static function bit [95:0] encode_cc(pcie_tl_tlp tlp);

  // ===== CC: CC descriptor -> 标准 TLP =====
  // 用途：RC agent monitor 接收 EP completion 时调用
  static function pcie_tl_tlp decode_cc(bit [95:0] desc, bit [7:0] payload[]);

endclass
```

### 3.6 Request Type Mapping

```systemverilog
// Xilinx Request Type [3:0] <-> 标准 PCIe TLP Kind 映射
typedef enum bit [3:0] {
  XILINX_REQ_MRD       = 4'b0000,  // -> TLP_MEM_RD       内存读
  XILINX_REQ_MWR       = 4'b0001,  // -> TLP_MEM_WR       内存写
  XILINX_REQ_IORD      = 4'b0010,  // -> TLP_IO_RD        IO读
  XILINX_REQ_IOWR      = 4'b0011,  // -> TLP_IO_WR        IO写
  XILINX_REQ_MRD_LK    = 4'b0100,  // -> TLP_MEM_RD_LK    锁定内存读
  XILINX_REQ_FETCH_ADD = 4'b1000,  // -> TLP_ATOMIC_FETCHADD 原子操作FetchAdd
  XILINX_REQ_SWAP      = 4'b1001,  // -> TLP_ATOMIC_SWAP     原子操作Swap
  XILINX_REQ_CAS       = 4'b1010   // -> TLP_ATOMIC_CAS      原子操作CAS
} xilinx_req_type_e;
```

### 3.7 Descriptor Length and Payload Offset

| Channel | Descriptor Length | Payload Start in tdata |
|---------|-------------------|------------------------|
| RQ | 128-bit (4 DW) | beat 1, DW0 (tdata[31:0] of next beat) |
| RC | 96-bit (3 DW) | beat 0, DW3 (tdata[127:96] of first beat) |
| CQ | 128-bit (4 DW) | beat 1, DW0 |
| CC | 96-bit (3 DW) | beat 0, DW3 (tdata[127:96] of first beat) |

对于 96-bit descriptor（RC/CC），payload 数据从 beat 0 的 DW3 开始（bit [127:96]），而非从 beat 1 开始。128-bit descriptor（RQ/CQ）的 payload 从 beat 1 开始。Codec 在组装 payload 时必须正确处理此偏移。

### 3.8 10-bit Extended Tag

PG213 支持 10-bit 扩展标签。Tag[7:0] 在 descriptor 中携带，tag[9:8] 在 tuser 的通道特定位置传递。Codec 在编解码时需合并/拆分这两部分，与 pcie_work 的 `pcie_tl_tag_manager` 对接。

---

## 4. tuser Codec and Straddling Engine

### 4.1 tuser Width by DATA_WIDTH

| DATA_WIDTH | RQ tuser | RC tuser | CQ tuser | CC tuser |
|------------|----------|----------|----------|----------|
| 64 | 62 | 75 | 88 | 33 |
| 128 | 62 | 75 | 88 | 33 |
| 256 | 137 | 161 | 183 | 81 |
| 512 | 285 | 321 | 375 | 161 |

### 4.2 RQ tuser Fields (256-bit example, 137-bit)

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [3:0] | first_be | 首 DW 字节使能，标识第一个 DW 中哪些字节有效 |
| [7:4] | last_be | 末 DW 字节使能，标识最后一个 DW 中哪些字节有效 |
| [10:8] | addr_offset | 地址偏移，指示 payload 在首 beat 中的 DW 偏��量 |
| [11] | discontinue | 中止标记，置 1 时通知 PCIe IP 丢弃当前 TLP |
| [12] | tph_present | TPH 存在标记，指示是否携带 TLP Processing Hint |
| [14:13] | tph_type | TPH 类型，00=双向(Bidirectional)，01=请求者(Requester)，10=完成者(Completer) |
| [22:15] | tph_st_tag | TPH Steering Tag，用于缓存分配提示 |
| [26:23] | seq_num_0 | 序列号 0（低 4 位），用于 PCIe IP 内部排序追踪 |
| [30:27] | seq_num_1 | 序列号 1（低 4 位），straddling 时第二个 TLP 的序列号 |
| [60:31] | parity | 奇偶校验位，每 bit 对应 tdata 的 1 个字节 |
| [66:61] | seq_num_0[5:0] | 序列号 0 高位扩展（Gen3 x8 以上需要 6-bit） |
| [72:67] | seq_num_1[5:0] | 序列号 1 高位扩展 |
| [136:73] | tph/tag ext | tag[9:8] 及额外 TPH 字段（512-bit 时进一步扩展） |

### 4.3 RC tuser Fields (256-bit example, 161-bit)

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [31:0] | byte_en | 字节使能，每 bit 对应 tdata 中 1 个字节是否有效 |
| [32] | is_sof_0 | Start-of-Frame 0，标识当前 beat 包含第一个 TLP 的起始 |
| [33] | is_sof_1 | Start-of-Frame 1，标识当前 beat 包含第二个 TLP 的起始（straddling 模式） |
| [34] | is_eof_0 | End-of-Frame 0，标识当前 beat 包含第一个 TLP 的结束 |
| [37:35] | eof_offset_0 | EOF 0 偏移，指示第一个 TLP 结束在 beat 中的 DW 位置 |
| [38] | is_eof_1 | End-of-Frame 1，标识第二个 TLP 的结束（straddling 模式） |
| [41:39] | eof_offset_1 | EOF 1 偏移，指示第二个 TLP 结束的 DW 位置 |
| [42] | discontinue | 中止标记，置 1 时通知用户逻辑数据无效需丢弃 |
| [74:43] | parity | 奇偶校验位，每 bit 对应 tdata 的 1 个字节 |
| [160:75] | extended | 512-bit 时 byte_en/parity 扩展 |

### 4.4 CQ tuser Fields (256-bit example, 183-bit)

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [3:0] | first_be | 首 DW 字节使能 |
| [7:4] | last_be | 末 DW 字节使能 |
| [39:8] | byte_en | 字节使能，每 bit 对应 tdata 中 1 个字节 |
| [40] | sop | Start-of-Packet，标识当前 beat 包含 TLP 起始 |
| [41] | sop_1 | 第二个 TLP 的 SOP（straddling 模式） |
| [42] | discontinue | 中止标记 |
| [43] | tph_present | TPH 存在标记 |
| [45:44] | tph_type | TPH 类型 |
| [53:46] | tph_st_tag | TPH Steering Tag |
| [54] | parity_en | 校验使能，指示 parity 字段是否有效 |
| [86:55] | parity | 奇偶校验位 |
| [87] | is_eop | End-of-Packet 0 |
| [90:88] | eop_offset | EOP 偏移 |
| [91] | is_eop_1 | 第二个 TLP 的 EOP（straddling 模式） |
| [94:92] | eop_offset_1 | 第二个 TLP 的 EOP 偏移 |
| [182:95] | extended | tag[9:8]、额外 TPH（512-bit 扩展） |

### 4.5 CC tuser Fields (256-bit example, 81-bit)

| Bit Range | Field | Description |
|-----------|-------|-------------|
| [0] | discontinue | 中止标记 |
| [32:1] | parity | 奇偶校验位 |
| [80:33] | extended | 512-bit 时 parity 扩展 |

CC tuser 最简单，因为 completion 方向由 EP 主动发起，不需要 sop/eop/byte_en 等复杂控制。

### 4.6 tuser Codec Class

```systemverilog
class xilinx_tuser_codec;

  int DATA_WIDTH;  // 64/128/256/512，决定 tuser 宽度和字段布局

  // RQ tuser 编码/解码
  function bit [284:0] encode_rq_tuser(
    bit [3:0] first_be, bit [3:0] last_be, bit [2:0] addr_offset,
    bit discontinue, bit tph_present, bit [1:0] tph_type,
    bit [7:0] tph_st_tag, bit [5:0] seq_num_0, bit [5:0] seq_num_1,
    bit [1:0] tag_9_8, bit [7:0] payload[]
  );
  function void decode_rq_tuser(input bit [284:0] tuser, output ...);

  // RC tuser 编码/解码
  function bit [320:0] encode_rc_tuser(
    bit [63:0] byte_en, bit is_sof_0, bit is_sof_1,
    bit is_eof_0, bit [2:0] eof_offset_0,
    bit is_eof_1, bit [2:0] eof_offset_1,
    bit discontinue, bit [7:0] payload[]
  );
  function void decode_rc_tuser(input bit [320:0] tuser, output ...);

  // CQ tuser 编码/解码
  function bit [374:0] encode_cq_tuser(
    bit [3:0] first_be, bit [3:0] last_be, bit [63:0] byte_en,
    bit sop, bit sop_1, bit discontinue,
    bit tph_present, bit [1:0] tph_type, bit [7:0] tph_st_tag,
    bit is_eop, bit [2:0] eop_offset,
    bit is_eop_1, bit [2:0] eop_offset_1,
    bit [1:0] tag_9_8, bit [7:0] payload[]
  );
  function void decode_cq_tuser(input bit [374:0] tuser, output ...);

  // CC tuser 编码/解码
  function bit [160:0] encode_cc_tuser(bit discontinue, bit [7:0] payload[]);
  function void decode_cc_tuser(input bit [160:0] tuser, output ...);

  // Parity 计算：每个 tdata 字节对应 1 bit 奇偶校验
  static function bit calc_byte_parity(bit [7:0] data_byte);

endclass
```

### 4.7 Straddling Engine

```systemverilog
class xilinx_straddle_engine;

  bit straddle_enable;  // straddling 使能开关
  int DATA_WIDTH;       // 数据位宽

  // 发送方向：多个 TLP 组包成 AXIS beats
  // straddle_enable=1 且 DATA_WIDTH>=256 时允许合并
  function void pack_tlps(
    input  pcie_tl_tlp      tlp_queue[$],
    input  xilinx_channel_e channel,
    output axis_beat_t      beats[$],
    output tuser_t          tusers[$]
  );

  // 接收方向：AXIS beats 拆包成多个 TLP
  function void unpack_beats(
    input  axis_beat_t      beats[$],
    input  tuser_t          tusers[$],
    input  xilinx_channel_e channel,
    output pcie_tl_tlp      tlp_queue[$]
  );

endclass
```

**Straddling 规则 (PG213):**
- 仅 DATA_WIDTH >= 256 时支持 straddling
- 64/128-bit 时每个 TLP 独占完整 beat 序列
- 256-bit：每 beat 最多 2 个 TLP 片段
- 512-bit：每 beat 最多 2 个 TLP 片段
- 新 TLP 的 descriptor 必须从 DW 对齐位置开始
- `straddle_enable=0` 时高位宽退化为非 straddling 模式

**非 straddling 行为：** 每个 TLP 1:1 映射到一个 `axis_packet`，使用 axis_vip 的 `PKT_BOUNDARY_TLAST` 模式。sop 仅在 beat 0，tlast 标记 TLP 结束。

---

## 5. Channel Router

### 5.1 Routing Logic

```systemverilog
class xilinx_pcie_channel_router;
  xilinx_pcie_role_e role;  // RC 或 EP

  // 确定发送 TLP 应走哪条通道
  function xilinx_channel_e get_tx_channel(pcie_tl_tlp tlp);

  // 确定从哪条通道接收特定类型的 TLP
  function xilinx_channel_e get_rx_channel(pcie_tl_tlp tlp);
endclass
```

### 5.2 Complete Routing Table

**RC 角色 BFM:**

| Direction | Channel | TLP Types |
|-----------|---------|-----------|
| TX (发送) | CQ | MRd, MWr, IORd, IOWr, CfgRd0/1, CfgWr0/1, MRdLk, Atomic, Msg |
| TX (发送) | RC | CplD, Cpl（回复 EP 的 DMA 读请求） |
| RX (接收) | RQ | MRd, MWr（EP 发起的 DMA 请求） |
| RX (接收) | CC | CplD, Cpl（EP 回复 RC 的请求） |

**EP 角色 BFM:**

| Direction | Channel | TLP Types |
|-----------|---------|-----------|
| TX (发送) | RQ | MRd, MWr（EP 发起 DMA 请求） |
| TX (发送) | CC | CplD, Cpl（EP 回复 RC 请求） |
| RX (接收) | CQ | MRd, MWr, IORd, IOWr, CfgRd0/1, CfgWr0/1, MRdLk, Atomic, Msg |
| RX (接收) | RC | CplD, Cpl（RC 回复 EP 的 DMA 读请求） |

### 5.3 AXIS Agent Role per Channel

| Channel | RC Role BFM | EP Role BFM |
|---------|-------------|-------------|
| RQ | AXIS_SLAVE (接收) | AXIS_MASTER (发送) |
| RC | AXIS_MASTER (发送) | AXIS_SLAVE (接收) |
| CQ | AXIS_MASTER (发送) | AXIS_SLAVE (接收) |
| CC | AXIS_SLAVE (接收) | AXIS_MASTER (发送) |

---

## 6. Agent Architecture

### 6.1 Class Hierarchy

```
xilinx_pcie_base_agent (uvm_agent)
  +-- xilinx_pcie_rc_agent
  +-- xilinx_pcie_ep_agent
```

### 6.2 Base Agent Components

```systemverilog
class xilinx_pcie_base_agent extends uvm_agent;

  // 核心组件
  xilinx_pcie_driver           driver;       // 发送方向
  xilinx_pcie_monitor          monitor;      // 接收方向
  uvm_sequencer #(pcie_tl_tlp) sequencer;   // 用户面向标准 TLP 的 sequencer

  // 编解码层（新写）
  xilinx_desc_codec            desc_codec;   // descriptor 编解码
  xilinx_tuser_codec           tuser_codec;  // tuser 编解码
  xilinx_straddle_engine       straddle_eng; // straddling 引擎
  xilinx_pcie_channel_router   router;       // 通道路由

  // 4 个 AXIS Agent（复用 axis_work）
  axis_agent                   rq_agent;     // RQ 通道
  axis_agent                   rc_agent;     // RC 通道
  axis_agent                   cq_agent;     // CQ 通道
  axis_agent                   cc_agent;     // CC 通道

  // 可选侧带 agent
  xilinx_pcie_cfg_agent        cfg_agent;    // cfg_mgmt（cfg_enable=1 时）
  xilinx_pcie_interrupt_agent  int_agent;    // cfg_interrupt（interrupt_enable=1 时）

  // 复用 pcie_work 的共享服务
  pcie_tl_tag_manager          tag_mgr;      // Tag 管理
  pcie_tl_fc_manager           fc_mgr;       // Flow Control
  pcie_tl_ordering_engine      ord_eng;      // 排序引擎
  pcie_tl_cfg_space_manager    cfg_space;    // 配置空间模型

  // 分析端口
  uvm_analysis_port #(pcie_tl_tlp) tlp_tx_ap;  // 已发送的 TLP
  uvm_analysis_port #(pcie_tl_tlp) tlp_rx_ap;  // 已接收的 TLP

endclass
```

### 6.3 RC Agent Specifics

- Completion 超时追踪（复用 pcie_work rc_driver 逻辑）
- BAR 地址分配（枚举 EP 时使用）
- 中断处理回调（接收 MSI/INTx）
- 配置：RQ=SLAVE, RC=MASTER, CQ=MASTER, CC=SLAVE

### 6.4 EP Agent Specifics

- 自动回复模式：为收到的 CQ 请求自动生成 completion
- 内存模型（稀疏存储，64-bit 地址空间）
- DMA 发起（通过 RQ 通道）
- MSI/MSI-X 中断生成
- Completion 分割（遵守 MPS/RCB 边界）
- 配置：RQ=MASTER, RC=SLAVE, CQ=SLAVE, CC=MASTER

### 6.5 Driver Pipeline

```
1. 从 sequencer 获取 pcie_tl_tlp
2. 可选：Tag 分配（Non-Posted 请求）
3. 可选：Flow Control credit 检查
4. 可选：排序引擎入队
5. 通过 router 确定目标通道
6. 通过 desc_codec 编码为 Xilinx descriptor
7. 组装 AXIS packet（descriptor + payload）
8. 通过 tuser_codec 编码 tuser
9. 通过目标通道的 axis_agent sequencer 发送
10. 消耗 FC credit
11. 发布到 tlp_tx_ap
```

### 6.6 Monitor Architecture

- 连接所有 4 个 axis_agent monitor 的分析端口（rq_imp, rc_imp, cq_imp, cc_imp）
- Straddling 模式：使用 straddle_engine.unpack_beats() 从 beats 重组 TLP
- 非 straddling 模式：每个 axis_packet 对应一个 TLP，直接解码
- 解码后的 pcie_tl_tlp 发布到 tlp_rx_ap

### 6.7 EP Auto-Response Flow

```
CQ axis_monitor 收到请求
  -> xilinx_pcie_monitor.write_cq() 解码为 pcie_tl_tlp
    -> 发布到 tlp_rx_ap
      -> EP 自动回复逻辑（如果使能）：
         MRd  -> 读内存模型 -> 生成 CplD -> 通过 CC 发送
         MWr  -> 写入内存模型 -> 无需回复
         IORd -> 读 IO 空间 -> 生成 CplD -> 通过 CC 发送
         IOWr -> 写 IO 空间 -> 生成 Cpl -> 通过 CC 发送
         CfgRd -> 读 cfg_space_manager -> 生成 CplD -> 通过 CC 发送
         CfgWr -> 写 cfg_space_manager -> 生成 Cpl -> 通过 CC 发送
```

---

## 7. Configuration Object

```systemverilog
class xilinx_pcie_env_config extends uvm_object;

  // === 第一组：基本角色与模式 ===
  xilinx_pcie_role_e role = XILINX_ROLE_EP;           // BFM 角色
  uvm_active_passive_enum is_active = UVM_ACTIVE;     // 活跃模式

  // === 第二组：数据位宽 ===
  int DATA_WIDTH = 256;  // 64/128/256/512

  // === 第三组：Straddling ===
  bit straddle_enable = 0;  // straddling 使能开关

  // === 第四组：PCIe 能力参数 ===
  int max_payload_size = 256;        // MPS: 128/256/512/1024/2048/4096
  int max_read_request_size = 512;   // MRRS
  int read_completion_boundary = 64; // RCB: 64 或 128
  xilinx_pcie_speed_e link_speed = XILINX_GEN3;
  int link_width = 8;

  // === 第五组：Tag 管理 ===
  bit extended_tag_enable = 1;       // 10-bit 扩展标签使能
  int max_outstanding = 256;         // 最大并发未完成请求

  // === 第六组：Flow Control ===
  bit fc_enable = 1;
  bit infinite_credit = 0;
  int init_ph_credit = 32;    int init_pd_credit = 256;
  int init_nph_credit = 32;   int init_npd_credit = 256;
  int init_cplh_credit = 32;  int init_cpld_credit = 256;

  // === 第七组：排序引擎 ===
  bit relaxed_ordering_enable = 1;
  bit id_based_ordering_enable = 1;
  bit bypass_ordering = 0;

  // === 第八组：配置空间（cfg_mgmt 接口） ===
  bit cfg_enable = 1;
  bit [15:0] vendor_id = 16'h10EE;
  bit [15:0] device_id = 16'h9038;
  bit [23:0] class_code = 24'h02_00_00;
  bit [15:0] subsys_vendor_id = 16'h10EE;
  bit [15:0] subsys_device_id = 16'h0000;
  xilinx_bar_config_t bar_cfg[6];

  // === 第九组：中断（cfg_interrupt 接口） ===
  bit interrupt_enable = 1;
  xilinx_interrupt_mode_e interrupt_mode = XILINX_INT_MSI;
  int msi_vector_count = 1;
  int msix_table_size = 0;
  int msix_table_bar = 0;    bit [31:0] msix_table_offset = 0;
  int msix_pba_bar = 0;      bit [31:0] msix_pba_offset = 0;

  // === 第十组：AXIS 带宽控制 ===
  axis_valid_gen_mode_e tx_valid_mode = VALID_ZERO_IDLE;
  axis_ready_gen_mode_e rx_ready_mode = READY_ALWAYS;
  int tx_idle_cycles = 0;   int tx_valid_weight = 100;
  int rx_ready_weight = 100;
  bit per_channel_bw_config = 0;
  xilinx_channel_bw_config_t channel_bw_cfg[4];

  // === 第十一组：EP 自动回复 ===
  bit ep_auto_response = 1;
  int response_delay_min = 0;  int response_delay_max = 10;
  bit [63:0] mem_size = 64'h0000_0001_0000_0000;

  // === 第十二组：Completion 超时 ===
  int cpl_timeout_ns = 50000;

  // === 第十三组：Scoreboard 与 Coverage ===
  bit scb_enable = 1;
  bit scb_completion_check = 1;  bit scb_data_integrity = 1;
  bit scb_ordering_check = 1;   bit scb_descriptor_check = 1;
  bit cov_enable = 0;
  bit cov_tlp_type = 0;    bit cov_descriptor = 0;
  bit cov_tuser = 0;       bit cov_straddle = 0;
  bit cov_channel = 0;     bit cov_fc = 0;

  // === 第十四组：协议检查 ===
  bit rq_protocol_check_enable = 1;
  bit rc_protocol_check_enable = 1;
  bit cq_protocol_check_enable = 1;
  bit cc_protocol_check_enable = 1;
  bit desc_format_check_enable = 1;
  bit tuser_consistency_check = 1;
  bit payload_alignment_check = 1;
  bit straddle_boundary_check = 1;

  // 辅助方法
  function int get_rq_tuser_width();
  function int get_rc_tuser_width();
  function int get_cq_tuser_width();
  function int get_cc_tuser_width();
  function bit validate();
  function axis_config create_axis_config(xilinx_channel_e ch);

endclass
```

### 7.1 Type Definitions

```systemverilog
typedef enum bit {
  XILINX_ROLE_RC = 1'b0,  // Root Complex 角色
  XILINX_ROLE_EP = 1'b1   // Endpoint 角色
} xilinx_pcie_role_e;

typedef enum bit [1:0] {
  XILINX_CH_RQ = 2'b00,   // Requester Request
  XILINX_CH_RC = 2'b01,   // Requester Completion
  XILINX_CH_CQ = 2'b10,   // Completer Request
  XILINX_CH_CC = 2'b11    // Completer Completion
} xilinx_channel_e;

typedef enum bit [1:0] {
  XILINX_GEN1 = 2'b00,    // 2.5 GT/s
  XILINX_GEN2 = 2'b01,    // 5.0 GT/s
  XILINX_GEN3 = 2'b10,    // 8.0 GT/s
  XILINX_GEN4 = 2'b11     // 16.0 GT/s
} xilinx_pcie_speed_e;

typedef enum bit [1:0] {
  XILINX_INT_LEGACY = 2'b00,  // INTx Legacy 中断
  XILINX_INT_MSI    = 2'b01,  // MSI 中断
  XILINX_INT_MSIX   = 2'b10   // MSI-X 中断
} xilinx_interrupt_mode_e;

typedef struct {
  bit        enable;       // BAR 使能
  bit        is_64bit;     // 64-bit BAR
  bit        is_prefetch;  // 可预取
  bit        is_io;        // IO BAR
  bit [63:0] size;         // BAR 大小（字节，2 的幂次）
  bit [63:0] base_addr;    // BAR 基地址
} xilinx_bar_config_t;

typedef struct {
  axis_valid_gen_mode_e valid_mode;
  axis_ready_gen_mode_e ready_mode;
  int idle_cycles;
  int valid_weight;
  int ready_weight;
  int burst_len;
  int pause_len;
} xilinx_channel_bw_config_t;
```

---

## 8. SV Interface

### 8.1 Top-Level Interface (xilinx_pcie_if)

参数化 DATA_WIDTH，包含：
- 4 条 AXIS 通道（RQ/RC/CQ/CC），每条有 tdata, tkeep, tlast, tvalid, tready, tuser
- 3 个 clocking block：ep_drv_cb, rc_drv_cb, mon_cb
- 3 个 modport：ep_mp, rc_mp, mon_mp

**tkeep 粒度：** PG213 的 tkeep 是 per-DW（每 bit = 32-bit），不是 per-byte。字节级使能通过 tuser 的 byte_en 字段提供。

### 8.2 cfg Interface (xilinx_pcie_cfg_if)

包含：
- cfg_mgmt 信号：addr[9:0], byte_enable[3:0], read, write, write_data[31:0], read_data[31:0], read_write_done, debug_access
- cfg_interrupt Legacy：int[3:0], pending[3:0], sent
- cfg_interrupt MSI：enable, mmenable[2:0], mask_update, data[31:0], select[3:0], int[31:0], pending_status[31:0], sent, fail
- cfg_interrupt MSI-X：enable, mask, data[31:0], address[63:0], int, vec_pending[1:0], vec_pending_status
- 2 个 clocking block：user_cb (EP 视角), pcie_ip_cb (RC 视角)

### 8.3 AXIS Interface Mapping

xilinx_pcie_if 的每条通道映射到独立的 axis_if 实例。wrapper module 或 testbench 负责 xilinx_pcie_if 与 4x axis_if 之间的信号连接。

---

## 9. cfg_agent and interrupt_agent

### 9.1 cfg_agent

- EP 角色：用户 sequence 驱动 cfg_mgmt_read/write，等待 cfg_mgmt_read_write_done
- RC 角色：monitor 监听 cfg_mgmt 请求，自动读写 cfg_space_manager，驱动 read_data 和 done
- 复用 pcie_work 的 `pcie_tl_cfg_space_manager`（4KB 配置空间、capability 链、字段属性）

**cfg_mgmt 时序 (PG213):**
1. 用户断言 cfg_mgmt_read=1 或 cfg_mgmt_write=1，同时提供 addr 和 byte_enable
2. 写操作同时提供 cfg_mgmt_write_data
3. PCIe IP 操作完成后断言 cfg_mgmt_read_write_done（1 cycle）
4. 读数据在 done 同周期有效
5. 用户在 done 断言后才能发起下一次操作

### 9.2 interrupt_agent

支持 Legacy、MSI、MSI-X 三种中断流程：

**Legacy:** 断言 cfg_interrupt_int[0]，等待 cfg_interrupt_sent
**MSI:** 检查 cfg_interrupt_msi_enable，断言 cfg_interrupt_msi_int[vector]，等待 sent/fail
**MSI-X:** 检查 cfg_interrupt_msix_enable 和 mask，提供 address/data，断言 cfg_interrupt_msix_int

分析端口发布 `xilinx_interrupt_item`，包含 mode, vector, address/data, timestamp。

---

## 10. Scoreboard

### 10.1 Check Items

| Check | Config Switch | Description |
|-------|---------------|-------------|
| 请求-Completion 匹配 | scb_completion_check | Tag + Requester_ID 匹配，split completion 字节追踪，超时检测 |
| 数据完整性 | scb_data_integrity | MWr payload vs EP 内存模型；MRd CplD vs 内存模型；考虑 BE 的逐字节比对 |
| 排序规则 | scb_ordering_check | PCIe Table 2-40，通过 pcie_tl_ordering_engine；RO/IDO 属性处理 |
| Descriptor 正确性 | scb_descriptor_check | Round-trip 验证（encode->decode）；字段合法性；tuser/descriptor 一致性 |

### 10.2 Statistics

total_requests, total_completions, matched, mismatched, unexpected_cpl, timed_out, ordering_violations, desc_format_errors

---

## 11. Coverage

### 11.1 Coverage Groups

| Group | Config Switch | Coverpoints |
|-------|---------------|-------------|
| TLP Type | cov_tlp_type | kind, category, channel, kind x channel cross |
| Descriptor | cov_descriptor | req_type, addr_type, dw_count, first_be, last_be, BE cross, cpl_status, tag range, poisoned |
| tuser | cov_tuser | tph_present, tph_type, discontinue, parity_en, addr_offset |
| Straddling | cov_straddle | straddle_occurred, sop/eof combo, eof_offset, width cross |
| Channel | cov_channel | 各通道 valid/ready 握手状态，多通道同时活跃 cross |
| Flow Control | cov_fc | 各类别 credit 水位分布，credit 耗尽事件 |

---

## 12. Sequence Library

| Sequence | Description |
|----------|-------------|
| `xilinx_pcie_base_seq` | 基类，从 sequencer 获取环境配置 |
| `xilinx_pcie_mem_seq` | Memory Read/Write，addr/length/BE，4KB 边界和 MPS/MRRS 约束 |
| `xilinx_pcie_cfg_seq` | Config Read/Write Type 0/1，目标 BDF，字节使能 |
| `xilinx_pcie_dma_seq` | DMA 读写（EP 发起），自动按 MPS/MRRS/4KB 边界分割 |
| `xilinx_pcie_msi_seq` | MSI/MSI-X/Legacy 中断，通过 cfg_interrupt 侧带接口 |
| `xilinx_pcie_loopback_vseq` | 多阶段 RC<->EP 回环：配置枚举、MWr/MRd、DMA、中断、straddling 压力 |

---

## 13. Testbench

### 13.1 Loopback Testbench (tb_top.sv)

- 实例化 RC 侧和 EP 侧的 `xilinx_pcie_if` + `xilinx_pcie_cfg_if`
- 实例化 `xilinx_pcie_loopback_dut` 进行线对线交叉连接
- 250MHz 用户时钟（4ns 周期），10 周期初始复位
- UVM config_db 注册虚拟接口

### 13.2 Loopback DUT (xilinx_pcie_loopback_dut.sv)

线对线交叉连接：
- RC CQ 输出 -> EP CQ 输入（RC 发送请求给 EP）
- EP CC 输出 -> RC CC 输入（EP 回复 RC）
- EP RQ 输出 -> RC RQ 输入（EP DMA 请求给 RC）
- RC RC 输出 -> EP RC 输入（RC DMA 回复给 EP）

### 13.3 DUT Connection Template (tb_with_dut.sv)

连接真实 Xilinx PCIe IP 或用户网卡 RTL 的模板，包含 m_axis_rq_*, s_axis_rc_*, s_axis_cq_*, m_axis_cc_*, cfg_mgmt_*, cfg_interrupt_* 的端口映射示例。

### 13.4 Test Classes

| Test | Description |
|------|-------------|
| `xilinx_pcie_base_test` | 基类测试，plusarg 解析（+DATA_WIDTH, +STRADDLE_EN, +ROLE, +MPS 等） |
| `xilinx_pcie_sanity_test` | 20 个事务回环，全部 scoreboard 检查使能 |
| `xilinx_pcie_straddle_test` | 200 个小 payload 事务，256/512-bit，背靠背发送，straddling 覆盖 |
| `xilinx_pcie_loopback_test` | 500 个事务，全覆盖，混合每通道背压 |

### 13.5 Compilation

filelist.f 包含 axis_work、pcie_work 和 xilinx_pcie 源文件。Makefile 支持 VCS 和 Xcelium，UVM-1.2。

---

## 14. Key Design Decisions Summary

| Decision | Rationale |
|----------|-----------|
| 组合复用而非继承 | axis_agent 是单通道模型，Xilinx 是 4 通道；继承会导致脆弱基类 |
| desc_codec 使用 static function | 无状态转换，易于单元测试，可跨 agent 共享 |
| Straddling 作为独立引擎 | 通过使能开关隔离复杂度；非 straddling 模式为简单的 1:1 映射 |
| axis_if 中 tkeep 按 per-DW 粒度 | 与 PG213 保持一致；字节级使能通过 tuser byte_en 提供 |
| cfg/interrupt 作为可选模块 | 禁用时零开销；使能时功能完整 |
| plusarg 驱动测试配置 | 运行时灵活性，无需重新编译 |
