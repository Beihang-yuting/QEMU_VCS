# PCIe Transaction Layer VIP 用户手册

> 版本: 3.0
> 日期: 2026-04-23
> 基于 PCIe Base Specification Rev 5.0 事务层协议

---

## 目录

1. [概述](#1-概述)
2. [架构总览](#2-架构总览)
3. [快速上手](#3-快速上手)
4. [文件结构](#4-文件结构)
5. [TLP 事务模型](#5-tlp-事务模型)
6. [共享组件详解](#6-共享组件详解)
7. [Agent 架构](#7-agent-架构)
8. [验证环境](#8-验证环境)
9. [Sequence 库](#9-sequence-库)
10. [协议检查器](#10-协议检查器)
11. [覆盖率模型](#11-覆盖率模型)
12. [错误注入](#12-错误注入)
13. [配置参考](#13-配置参考)
14. [测试用例参考](#14-测试用例参考)
15. [扩展指南](#15-扩展指南)
16. [SR-IOV PF/VF 管理](#16-sr-iov-pfvf-管理)
17. [TLP Prefix 支持](#17-tlp-prefix-支持)

---

## 1. 概述

### 1.1 VIP 简介

PCIe Transaction Layer VIP 是一套基于 UVM 的 PCIe 事务层验证 IP，提供完整的 RC (Root Complex) 和 EP (Endpoint) 双侧仿真能力。VIP 实现了 PCIe 规范中事务层的核心功能，包括 TLP 收发、流控 (Flow Control)、标签管理 (Tag Management)、排序引擎 (Ordering Engine)、配置空间建模、带宽整形以及覆盖率收集。

### 1.2 主要特性

| 特性类别 | 具体功能 |
|---------|---------|
| **TLP 类型** | Memory Read/Write, IO Read/Write, Config Read/Write (Type 0/1), Completion, Message, AtomicOp, Vendor Defined, LTR |
| **流控** | 6 类信用（PH/PD/NPH/NPD/CPLH/CPLD），有限/无限信用模式，信用耗尽回压 |
| **标签管理** | 5-bit/8-bit/10-bit 标签，Phantom Function，标签池分配/回收 |
| **排序** | PCIe Table 2-40 排序规则，Relaxed Ordering, ID-Based Ordering |
| **MPS/MRRS/RCB** | Max Payload Size (128-4096B), Max Read Request Size (128-4096B), Read Completion Boundary (64/128B) |
| **Completion 拆分** | EP 自动按 MPS/RCB 边界拆分 CplD |
| **4KB 边界** | 自动拆分避免跨 4KB 地址边界 |
| **配置空间** | 4KB Type 0 Header, PCIe Capability, 可扩展 Capability 链 |
| **Codec** | TLP 与字节流编解码，ECRC 计算与校验 |
| **带宽整形** | 令牌桶算法，可配置速率和突发大小 |
| **No Snoop** | 3-bit attr 支持 \[2\]=NS, \[1\]=IDO, \[0\]=RO |
| **错误注入** | ECRC 错误, Poisoned TLP, 排序违规, 字段翻转, 重复标签 |
| **Scoreboard** | 请求-完成匹配，多 Completion 追踪，数据完整性校验 |
| **覆盖率** | TLP 基本属性, FC 状态, 标签使用, 排序交叉, 错误注入, MPS/MRRS/RCB |
| **接口模式** | TLM 模式（纯事务级）和 SV Interface 模式（256-bit 数据通道） |
| **链路延时** | 可配置 RC→EP / EP→RC 延时，随机范围，流水线保序 |
| **PCIe Switch** | 参数化 1-16 端口，地址/ID/消息路由，P2P 直通，Type 1 配置空间，双配置模式(静态/枚举) |
| **多 EP 支持** | Switch 模式下动态创建 N 个 EP Agent，独立 FC/Tag/地址空间 |
| **SR-IOV** | 完整 SR-IOV Extended Capability 建模，运行时可配 1-8 PF / 1-256 VF，BDF 自动计算，VF Enable/Disable 动态管理，per-Function 独立配置空间 |
| **TLP Prefix** | Local (MR-IOV) + End-to-End (PASID, Extended TPH, IDE, Vendor-Defined)，最多 4 个 Prefix，FC 信用自动包含 Prefix 开销 |
| **Function Manager** | 集中式 PF/VF 管理，BDF 查找表，Config 请求按 BDF 分派，VF 动态启停，UR Completion 自动返回 |

### 1.3 支持的 PCIe 规范要素

- PCIe Base Spec Rev 5.0 Transaction Layer
- TLP Header 格式 (3DW / 4DW)
- Flow Control 初始化与信用管理
- Byte Enable 规则 (first_be / last_be)
- 4KB 地址边界限制
- Completion 拆分规则 (MPS/RCB)
- 排序规则 (Table 2-40)
- ECRC 生成与校验
- SR-IOV Extended Capability (Cap ID 0x0010)
- TLP Prefix (Local + End-to-End, PCIe 5.0 Section 2.2.10)
- PASID Extended Capability (Cap ID 0x001B)

---

## 2. 架构总览

### 2.1 系统架构图

```
+-------------------------------------------------------------+
|                      pcie_tl_env                            |
|                                                             |
|  +--------------+      Shared Components       +----------+|
|  |  rc_agent     |   +---------------------+   | ep_agent  ||
|  | +----------+ |   | codec               |   |+--------+ ||
|  | |rc_driver | |   | fc_mgr              |   ||ep_driver| ||
|  | |  (send)  | |   | tag_mgr             |   ||(respond)| ||
|  | +----+-----+ |   | ord_eng             |   |+----+----+ ||
|  | +----+-----+ |   | cfg_mgr             |   |+----+----+ ||
|  | |sequencer | |   | bw_shaper           |   ||sequencer| ||
|  | +----------+ |   +---------------------+   |+---------+ ||
|  | +----------+ |                              |+---------+ ||
|  | | monitor  |-+--+                     +----+| monitor | ||
|  | +----------+ |  |                     |    |+---------+ ||
|  +--------------+  |                     |    +----------+ ||
|                    |   +-------------+   |                 |
|  +--------------+  +-->| scoreboard  |<--+  +-----------+  |
|  | rc_adapter   |  |   +-------------+   |  | ep_adapter|  |
|  | (TLM / IF)   |  |   +-------------+   |  |(TLM / IF) |  |
|  +------+-------+  +-->|  coverage   |<--+  +-----+-----+  |
|         |              +-------------+             |        |
|  +------+------+     +---------------+    +-------+------+ |
|  | v_seqr      |     |  TLM Loopback |    |              | |
|  |(virtual seq) |     |  RC <-> EP    |    |              | |
|  +-------------+     +---------------+    +--------------+ |
+-------------------------------------------------------------+
         |                                          |
    -----+-------------- pcie_tl_if ----------------+-----
         tlp_data[255:0] / tlp_valid / tlp_ready / FC credits
```

**Switch 模式架构:**

```
+------------------------------------------------------------------+
|                        pcie_tl_env                                |
|                                                                   |
|  +-----------+     +---------------------------+    +-----------+ |
|  | rc_agent  |     |      pcie_tl_switch       |    |ep_agent_0 | |
|  |           |---->| USP --- Fabric --- DSP[0] |--->|           | |
|  |           |<----|         |          DSP[1] |--->|ep_agent_1 | |
|  +-----------+     |         |          DSP[2] |--->|ep_agent_2 | |
|                     |         |          DSP[3] |--->|ep_agent_3 | |
|                     +---------------------------+    +-----------+ |
+------------------------------------------------------------------+
```

### 2.2 数据流

**TLM 模式 (默认):**
```
Test Sequence
  -> RC Sequencer
    -> RC Driver
      -> rc_adapter.tlm_tx_fifo
        -> [env TLM loopback]
          -> ep_adapter.tlm_rx_fifo
            -> EP Driver (auto-response)
              -> ep_adapter.tlm_tx_fifo
                -> [env TLM loopback]
                  -> rc_adapter.tlm_rx_fifo
                    -> RC Driver.handle_completion
```

**SV Interface 模式:**
```
RC Driver
  -> rc_adapter.drive_to_interface
    -> pcie_tl_if (256-bit bus)
      -> ep_adapter.sample_from_interface
        -> EP Driver
```

### 2.3 发送管线 (Base Driver)

每个 TLP 在 `send_tlp()` 中经过 7 步管线:

```
1. Tag 分配 (仅 Non-Posted)
2. 排序引擎入队
3. 等待 FC 信用 + 带宽令牌
4. Codec 编码
5. 通过 Adapter 发送
6. 消耗 FC 信用
7. 消耗 BW 令牌
```

---

## 3. 快速上手

### 3.1 编译命令

```bash
export VCS_HOME=/opt/synopsys/vcs/Q-2020.03-SP2-7
export SNPSLMD_LICENSE_FILE=/opt/synopsys/license/license.dat

cd pcie_tl_vip

$VCS_HOME/bin/vcs -full64 -sverilog -ntb_opts uvm-1.2 \
  +incdir+src +incdir+src/types +incdir+src/shared \
  +incdir+src/agent +incdir+src/adapter +incdir+src/env \
  +incdir+src/seq/base +incdir+src/seq/scenario \
  +incdir+src/seq/virtual +incdir+src/seq/constraints \
  +incdir+tests \
  src/pcie_tl_pkg.sv src/pcie_tl_if.sv \
  tests/pcie_tl_tb_top.sv tests/pcie_tl_base_test.sv \
  tests/pcie_tl_smoke_test.sv tests/pcie_tl_advanced_test.sv \
  -o simv -timescale=1ns/1ps
```

### 3.2 运行测试

```bash
# 基本 Memory 读写测试
./simv +UVM_TESTNAME=pcie_tl_smoke_mem_test

# 压力测试
./simv +UVM_TESTNAME=pcie_tl_stress_test

# 带宽控制测试
./simv +UVM_TESTNAME=pcie_tl_bandwidth_test

# 指定日志级别
./simv +UVM_TESTNAME=pcie_tl_stress_test +UVM_VERBOSITY=UVM_LOW
```

### 3.3 编写第一个测试

```systemverilog
class my_first_test extends pcie_tl_base_test;
    `uvm_component_utils(my_first_test)

    function new(string name = "my_first_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 配置阶段 - 在 build_phase 之前调用
    virtual function void configure_test();
        super.configure_test();
        cfg.max_payload_size = MPS_128;
        cfg.fc_enable = 1;
        cfg.infinite_credit = 0;
        enable_coverage();
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        // 发送一个 Memory Write
        begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
            wr.addr = 64'h0000_0001_0000_0000;
            wr.length = 16;        // 64 字节
            wr.first_be = 4'hF;
            wr.last_be = 4'hF;
            wr.is_64bit = 1;
            wr.start(env.rc_agent.sequencer);
        end

        // 发送一个 Memory Read
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd");
            rd.addr = 64'h0000_0001_0000_0000;
            rd.length = 16;
            rd.first_be = 4'hF;
            rd.last_be = 4'hF;
            rd.is_64bit = 1;
            rd.start(env.rc_agent.sequencer);
        end

        #500ns;
        phase.drop_objection(this);
    endtask
endclass
```

---

## 4. 文件结构

```
pcie_tl_vip/
|-- src/
|   |-- pcie_tl_pkg.sv              # 顶层 Package (包含所有组件)
|   |-- pcie_tl_if.sv               # SystemVerilog 接口定义
|   |
|   |-- types/
|   |   |-- pcie_tl_types.sv        # 枚举、结构体、抽象回调类
|   |   |-- pcie_tl_tlp.sv          # TLP 事务对象层次 (8 个类)
|   |   +-- pcie_tl_prefix.sv       # TLP Prefix 类，字段解析，工厂方法
|   |
|   |-- shared/
|   |   |-- pcie_tl_codec.sv        # TLP 编解码器 + ECRC
|   |   |-- pcie_tl_fc_manager.sv   # 流控信用管理
|   |   |-- pcie_tl_bw_shaper.sv    # 令牌桶带宽整形
|   |   |-- pcie_tl_tag_manager.sv  # 标签池管理
|   |   |-- pcie_tl_ordering_engine.sv  # 排序引擎
|   |   |-- pcie_tl_cfg_space_manager.sv # 配置空间建模
|   |   |-- pcie_tl_link_delay_model.sv # 链路延时模型
|   |   |-- pcie_tl_sriov_cap.sv    # SR-IOV Extended Capability 寄存器模型
|   |   +-- pcie_tl_func_manager.sv # Function Manager，PF/VF Context，BDF 查找
|   |
|   |-- adapter/
|   |   +-- pcie_tl_if_adapter.sv   # TLM / SV Interface 适配器
|   |
|   |-- switch/
|   |   |-- pcie_tl_switch_config.sv    # Switch 配置 (端口数/地址窗口/P2P)
|   |   |-- pcie_tl_switch_port.sv      # Switch 端口 (Type 1 配置空间/FC/延时)
|   |   |-- pcie_tl_switch_fabric.sv    # 路由引擎 (地址/ID/消息路由)
|   |   +-- pcie_tl_switch.sv           # Switch 顶层 (转发循环)
|   |
|   |-- agent/
|   |   |-- pcie_tl_base_driver.sv  # 基类驱动 (7 步管线)
|   |   |-- pcie_tl_base_monitor.sv # 基类监控 (6 项协议检查)
|   |   |-- pcie_tl_base_agent.sv   # 基类 Agent
|   |   |-- pcie_tl_rc_driver.sv    # RC 驱动 (完成匹配/超时)
|   |   |-- pcie_tl_rc_agent.sv     # RC Agent
|   |   |-- pcie_tl_ep_driver.sv    # EP 驱动 (自动应答/Completion 拆分)
|   |   +-- pcie_tl_ep_agent.sv     # EP Agent
|   |
|   |-- env/
|   |   |-- pcie_tl_env_config.sv   # 环境配置类 (30+ 参数)
|   |   |-- pcie_tl_env.sv          # 顶层环境 (组件创建/连接/TLM 回环)
|   |   |-- pcie_tl_virtual_sequencer.sv  # 虚拟 Sequencer
|   |   |-- pcie_tl_scoreboard.sv   # 记分板 (匹配/排序/数据完整性)
|   |   +-- pcie_tl_coverage_collector.sv # 覆盖率收集 (6 个 covergroup)
|   |
|   +-- seq/
|       |-- base/                   # 11 个基础 Sequence
|       |-- constraints/            # 3 种约束模式 (Legal/Illegal/Corner)
|       |-- scenario/               # 8 个场景 Sequence
|       +-- virtual/                # 4 个虚拟 Sequence
|
|-- tests/
|   |-- pcie_tl_tb_top.sv           # Testbench 顶层模块
|   |-- pcie_tl_base_test.sv        # 基类 Test
|   |-- pcie_tl_smoke_test.sv       # 5 个 Smoke Test
|   +-- pcie_tl_advanced_test.sv    # 22 个高级 Test
|
+-- docs/
    +-- PCIe_TL_VIP_User_Guide.md   # 本文档
```

**统计:** 53 个源文件, 10 种 TLP 类型, 7 个共享组件, 22 个 Sequence, 27 个 Test

---

## 5. TLP 事务模型

### 5.1 类层次结构

```
uvm_sequence_item
  +-- pcie_tl_tlp (基类 - 所有 TLP 公共字段)
        |-- pcie_tl_mem_tlp     (Memory Read/Write)
        |-- pcie_tl_io_tlp      (IO Read/Write)
        |-- pcie_tl_cfg_tlp     (Config Read/Write Type 0/1)
        |-- pcie_tl_cpl_tlp     (Completion / Completion with Data)
        |-- pcie_tl_msg_tlp     (Message / Message with Data)
        |-- pcie_tl_atomic_tlp  (AtomicOp: FetchAdd/Swap/CAS)
        |-- pcie_tl_vendor_tlp  (Vendor Defined Message)
        +-- pcie_tl_ltr_tlp     (Latency Tolerance Reporting)
```

### 5.2 基类字段 (pcie_tl_tlp)

| 字段 | 类型 | 描述 |
|-----|------|------|
| `fmt` | `tlp_fmt_e` | TLP 格式 (3DW/4DW, 有/无数据) |
| `type_f` | `tlp_type_e` | TLP 类型编码 |
| `kind` | `tlp_kind_e` | 高级 TLP 类型 (MEM_RD, MEM_WR, ...) |
| `tc` | `bit [2:0]` | Traffic Class |
| `th` | `bit` | TLP Hints |
| `td` | `bit` | TLP Digest (ECRC 存在标志) |
| `ep_bit` | `bit` | Poisoned 标志 |
| `attr` | `bit [2:0]` | 属性: \[0\]=RO, \[1\]=IDO, \[2\]=NS |
| `length` | `bit [9:0]` | 数据长度 (DW)，0 表示 1024 DW |
| `requester_id` | `bit [15:0]` | 请求者 BDF |
| `tag` | `bit [9:0]` | 标签 (最多 10-bit) |
| `payload` | `bit [7:0][]` | 数据负载 (字节数组) |

### 5.3 Memory TLP 扩展字段 (pcie_tl_mem_tlp)

| 字段 | 类型 | 描述 |
|-----|------|------|
| `addr` | `bit [63:0]` | 目标地址 |
| `first_be` | `bit [3:0]` | 第一个 DW 字节使能 |
| `last_be` | `bit [3:0]` | 最后一个 DW 字节使能 |
| `is_64bit` | `bit` | 64-bit 地址标志 |
| `cfg_mps_bytes` | `int` | MPS 配置 (默认 256) |
| `cfg_mrrs_bytes` | `int` | MRRS 配置 (默认 512) |

### 5.4 Completion TLP 扩展字段 (pcie_tl_cpl_tlp)

| 字段 | 类型 | 描述 |
|-----|------|------|
| `completer_id` | `bit [15:0]` | 完成者 BDF |
| `cpl_status` | `cpl_status_e` | SC / UR / CRS / CA |
| `bcm` | `bit` | Byte Count Modified |
| `byte_count` | `bit [11:0]` | 剩余字节数 |
| `lower_addr` | `bit [6:0]` | 低 7-bit 地址 |

### 5.5 内置约束

```systemverilog
// 基类约束
constraint c_no_error_inject;       // LEGAL 模式禁止错误注入
constraint c_max_payload;           // payload <= 4096 字节
constraint c_no_data_no_payload;    // 无数据 TLP payload 为空

// Memory TLP 约束
constraint c_mps_limit;             // MEM_WR payload <= cfg_mps_bytes
constraint c_mrrs_limit;            // MEM_RD 长度 <= cfg_mrrs_bytes
constraint c_4kb_boundary;          // 不跨 4KB 地址边界
constraint c_legal_be;              // Byte Enable 规则
```

### 5.6 关键方法

```systemverilog
function tlp_category_e get_category();     // 返回 Posted/Non-Posted/Completion
function bit requires_completion();          // 是否需要 Completion
function bit has_data();                     // 是否携带数据
function bit is_4dw();                       // 是否 4DW 头
function int get_payload_size();             // 数据负载大小 (字节)
function int get_data_credits();             // FC 数据信用消耗量
function string convert2string();            // 格式化字符串
```

---

## 6. 共享组件详解

### 6.1 Codec (pcie_tl_codec)

TLP 对象与字节流之间的编解码器。

```systemverilog
pcie_tl_codec codec = pcie_tl_codec::type_id::create("codec");

// 编码: TLP -> 字节流
bit [7:0] bytes[];
codec.encode(tlp, bytes);

// 解码: 字节流 -> TLP
pcie_tl_tlp decoded = codec.decode(bytes);

// ECRC 校验
bit ecrc_ok = codec.verify_ecrc(bytes);
```

**编码格式 (DW0):**
```
DW0[31:29] = fmt[2:0]
DW0[28:24] = type[4:0]
DW0[22:20] = tc[2:0]
DW0[19]    = th
DW0[18]    = attr[2] (No Snoop)
DW0[15]    = td
DW0[14]    = ep_bit
DW0[13:12] = attr[1:0] (IDO, RO)
DW0[9:0]   = length[9:0]
```

### 6.2 Flow Control Manager (pcie_tl_fc_manager)

管理 6 类 FC 信用:

| 信用类型 | 缩写 | 对应 TLP 类别 |
|---------|------|-------------|
| Posted Header | PH | Memory Write 头 |
| Posted Data | PD | Memory Write 数据 |
| Non-Posted Header | NPH | Memory Read / Config 头 |
| Non-Posted Data | NPD | Config Write 数据 |
| Completion Header | CPLH | Completion 头 |
| Completion Data | CPLD | CplD 数据 |

```systemverilog
// 初始化信用
fc_mgr.init_credits(
    .ph(32), .pd(256),         // Posted
    .nph(32), .npd(256),       // Non-Posted
    .cplh(32), .cpld(256)      // Completion
);

// 检查信用 (驱动发送前调用)
bit has_credit = fc_mgr.check_credit(tlp);

// 消耗信用
fc_mgr.consume_credit(tlp);

// 返还信用 (TLM 模式: 对端收到后返还)
fc_mgr.return_credit(FC_POSTED_HDR, 1);
fc_mgr.return_credit(FC_POSTED_DATA, data_credits);
```

**无限信用模式:** 设置 `infinite_credit = 1`，`check_credit()` 永远返回 1。

### 6.3 Bandwidth Shaper (pcie_tl_bw_shaper)

基于令牌桶算法的带宽整形器。

```systemverilog
bw_shaper.shaper_enable = 1;
bw_shaper.avg_rate      = 1.0;    // 1 byte/ns = 1 GB/s
bw_shaper.burst_size    = 512;    // 最大突发 512 字节
```

**工作原理:**

1. 初始令牌数 = `burst_size`
2. 每次发送消耗 `TLP 总字节数` 个令牌
3. 令牌以 `avg_rate` bytes/ns 速率补充
4. 令牌数上限为 `burst_size`
5. 令牌不足时，驱动阻塞等待

**实测结果 (rate=1GB/s, burst=512B, TLP=272B):**

| TLP序号 | 发送时间 | 间隔 | 说明 |
|--------|---------|------|------|
| 1 | 0 ns | - | 突发桶有 512B，立即发送 |
| 2 | 46 ns | 46ns | 桶中余量不足，短暂等待 |
| 3 | 318 ns | 272ns | 稳态限速开始 |
| 4+ | +272ns | 272ns | 持续稳态: 272B/272ns = 1B/ns |

实际稳态带宽: ~0.94 GB/s（与目标 1 GB/s 的差异来自 16B 头开销）

### 6.4 Tag Manager (pcie_tl_tag_manager)

Non-Posted TLP 的标签池管理。

```systemverilog
// 初始化标签池
tag_mgr.init_pool(
    .func_id(0),
    .extended(1),      // 1: 10-bit 标签 (1024), 0: 8-bit (256)
    .phantom(0)        // Phantom Function 共享
);

// 分配标签 (驱动自动调用)
bit [9:0] tag = tag_mgr.alloc_tag(func_id);

// 释放标签 (收到 Completion 后)
tag_mgr.free_tag(tag, func_id);

// 查询
int count = tag_mgr.get_outstanding_count();
bit empty = tag_mgr.is_pool_empty(func_id);
```

**标签大小配置:**

| extended_tag_enable | 标签范围 | 最大并发 Non-Posted |
|--------------------|---------|--------------------|
| 0 | 0-255 (8-bit) | 256 |
| 1 | 0-1023 (10-bit) | 1024 |

### 6.5 Ordering Engine (pcie_tl_ordering_engine)

PCIe Table 2-40 排序规则实现。

```systemverilog
// 入队
ord_eng.enqueue(tlp);

// 按优先级出队: Completion > Posted > Non-Posted
pcie_tl_tlp next = ord_eng.dequeue_next();

// 排序检查
bit ok = ord_eng.check_ordering(tlp);
```

**排序优先级:**

1. Completion (最高优先级)
2. Posted (Memory Write)
3. Non-Posted (Memory Read, Config)

**可配置选项:**

- `relaxed_ordering_enable`: 允许 RO 属性的 TLP 乱序
- `id_based_ordering_enable`: 允许不同 Requester ID 的 TLP 乱序
- `bypass_ordering`: 完全跳过排序检查

### 6.6 Config Space Manager (pcie_tl_cfg_space_manager)

4KB PCIe 配置空间建模。

```systemverilog
// 初始化 Type 0 Header
cfg_mgr.init_type0_header(
    .vendor_id(16'h10EE),
    .device_id(16'h9038),
    .revision_id(8'h01),
    .class_code(24'h028000),
    .header_type(8'h00)
);

// 初始化 PCIe Capability
cfg_mgr.init_pcie_capability(
    .cap_offset(8'h40),
    .mps(MPS_256),
    .mrrs(MRRS_512),
    .rcb(RCB_64)
);

// 读写配置空间
bit [31:0] data = cfg_mgr.read(12'h000);   // Vendor/Device ID
cfg_mgr.write(12'h004, 32'h0000_0006, 4'hF); // Command Register

// 读取当前 MPS/MRRS/RCB
int mps  = cfg_mgr.get_mps_bytes();    // 从 Device Control 读
int mrrs = cfg_mgr.get_mrrs_bytes();
int rcb  = cfg_mgr.get_rcb_bytes();

// 注册回调 (配置写触发)
cfg_mgr.register_callback(12'h048, my_callback);
```

**字段属性:**

| 属性 | 行为 |
|------|------|
| `RO` | 只读，写入被忽略 |
| `RW` | 读写 |
| `RW1C` | 写 1 清零 |

### 6.7 链路延时模型 (pcie_tl_link_delay_model)

模拟 PCIe 链路传播延时。

```systemverilog
// 配置
cfg.link_delay_enable          = 1;
cfg.rc2ep_latency_min_ns       = 200;   // RC→EP 最小延时
cfg.rc2ep_latency_max_ns       = 500;   // RC→EP 最大延时
cfg.ep2rc_latency_min_ns       = 200;   // EP→RC 最小延时
cfg.ep2rc_latency_max_ns       = 500;   // EP→RC 最大延时
cfg.link_delay_update_interval = 16;    // 每 16 个 TLP 重新随机延时
```

**特性:**
- 可配置延时范围 (min/max ns)
- 每 N 个 TLP 重新随机化延时值
- 流水线保序：保证 TLP 到达顺序与发送顺序一致
- 运行时可动态调整: `delay.set_latency(min, max)`
- 支持禁用模式: `enable=0` 时零延时直通

---

## 7. Agent 架构

### 7.1 RC Agent (Root Complex)

RC Agent 模拟主机端，负责发起事务和接收 Completion。

```
pcie_tl_rc_agent
  |-- rc_driver    <-- 继承 pcie_tl_base_driver
  |   |-- send_tlp()              # 发送 TLP + 启动 Completion 超时
  |   |-- handle_completion()     # 匹配 Completion, 释放标签
  |   +-- start_cpl_timeout()     # 超时监控 (默认 50us)
  |-- monitor      <-- 继承 pcie_tl_base_monitor
  |   +-- 6 项协议检查
  +-- sequencer
```

**RC Driver 关键功能:**

- 自动分配 Non-Posted 标签
- Completion 超时检测 (`cpl_timeout_ns`, 默认 50000ns)
- BAR 地址分配 (`allocate_bar_address()`)
- MSI/INTx 中断处理

### 7.2 EP Agent (Endpoint)

EP Agent 模拟设备端，自动响应请求。

```
pcie_tl_ep_agent
  |-- ep_driver    <-- 继承 pcie_tl_base_driver
  |   |-- handle_request()        # 请求分发
  |   |-- handle_cfg_read/write() # 配置空间读写
  |   |-- handle_mem_read()       # 读操作 + Completion 拆分
  |   |-- handle_mem_write()      # 写入稀疏内存
  |   |-- initiate_dma()          # EP 主动 DMA
  |   +-- send_msi()              # MSI 中断发送
  |-- monitor
  +-- sequencer
```

**EP Driver Completion 拆分算法:**

```
remaining = total_byte_count
cur_addr = req.addr
cpl_idx = 0

while (remaining > 0):
    if cpl_idx == 0:
        # 首个 CplD: 对齐到 RCB 边界
        chunk = min(bytes_to_rcb, mps_bytes)
    else:
        # 后续 CplD: MPS 大小
        chunk = mps_bytes

    chunk = min(chunk, remaining)
    send CplD(byte_count=remaining, lower_addr=cur_addr[6:0], payload=chunk)
    cur_addr += chunk
    remaining -= chunk
    cpl_idx++
```

**拆分示例 (MPS=128B, RCB=64B, 地址=0x0000, 请求 384B):**

| CplD # | chunk | byte_count | lower_addr | 说明 |
|--------|-------|------------|------------|------|
| 0 | 64B | 384 | 0x00 | 对齐到 RCB: min(64,128)=64B |
| 1 | 128B | 320 | 0x40 | MPS 大小 |
| 2 | 128B | 192 | 0xC0 | MPS 大小 |
| 3 | 64B | 64 | 0x40 | 剩余 |

### 7.3 接口适配器 (pcie_tl_if_adapter)

支持两种传输模式的运行时切换:

```systemverilog
// TLM 模式 (默认 - 纯事务级，无时序)
adapter.mode = TLM_MODE;

// SV Interface 模式 (256-bit 数据通道，时钟驱动)
adapter.mode = SV_IF_MODE;

// 运行时切换
adapter.switch_mode(SV_IF_MODE);
```

**SV Interface 信号:**

| 信号 | 宽度 | 方向 | 描述 |
|------|------|------|------|
| `tlp_data` | 256-bit | master->slave | TLP 数据 |
| `tlp_strb` | 4-bit | master->slave | DW 有效标志 |
| `tlp_valid` | 1-bit | master->slave | 数据有效 |
| `tlp_ready` | 1-bit | slave->master | 接收就绪 |
| `tlp_sop` | 1-bit | master->slave | 包起始 |
| `tlp_eop` | 1-bit | master->slave | 包结束 |

---

## 8. 验证环境

### 8.1 环境组件一览

| 组件 | 类名 | 功能 |
|------|------|------|
| 环境配置 | `pcie_tl_env_config` | 30+ 配置参数 |
| 顶层环境 | `pcie_tl_env` | 创建、连接所有组件 |
| 虚拟 Sequencer | `pcie_tl_virtual_sequencer` | 多 Agent 协调 |
| 记分板 | `pcie_tl_scoreboard` | 请求/完成匹配 |
| 覆盖率 | `pcie_tl_coverage_collector` | 6 个 covergroup |

### 8.2 Scoreboard

**三重检查机制:**

| 检查项 | 开关 | 功能 |
|--------|------|------|
| Completion 匹配 | `completion_check_enable` | 请求-完成配对，多 Completion 追踪 |
| 排序合规 | `ordering_check_enable` | Table 2-40 排序规则 |
| 数据完整性 | `data_integrity_enable` | 写入数据 -> 读回数据比对 |

**多 Completion 追踪 (cpl_tracker_t):**

```systemverilog
typedef struct {
    pcie_tl_tlp orig_req;       // 原始请求
    int         total_bytes;     // 总请求字节
    int         received_bytes;  // 已接收字节
    bit [63:0]  expected_addr;   // 下一个期望地址
    int         cpl_count;       // 已收到 CplD 数量
} cpl_tracker_t;
```

当 `received_bytes >= total_bytes` 时标记为 `matched`。

**Report Phase 输出示例:**

```
========== Scoreboard Report ==========
  Requests:     200
  Completions:  65
  Matched:      50
  Mismatched:   0
  Unexpected:   0
  Timed Out:    0
========================================
```

### 8.3 TLM Loopback (pcie_tl_env)

在 TLM 模式下，env 的 `run_phase` 提供 RC <-> EP 之间的 TLM 回环桥:

```
RC tx_fifo -> EP rx_fifo (环境转发)
  -> EP auto-response (如果启用)
  -> EP tx_fifo -> RC rx_fifo (环境转发)
  -> RC handle_completion
```

每次转发后自动返还 FC 信用 (`replenish_credits`)。

### 8.4 Switch 模式

当 `cfg.switch_enable = 1` 时，env 创建 PCIe Switch + 多个 EP Agent:

```systemverilog
// 测试中配置 Switch
pcie_tl_switch_config sw_cfg = new("sw_cfg");
sw_cfg.num_ds_ports = 4;     // 4 个下行端口
sw_cfg.p2p_enable   = 1;     // 允许 P2P
sw_cfg.init_defaults();       // 自动分配 bus/地址

cfg.switch_enable = 1;
cfg.switch_cfg    = sw_cfg;
```

**数据流:**
```
RC → rc_adapter → Switch USP → Fabric 路由 → DSP[i] → ep_adapter[i] → EP[i]
EP[i] → ep_adapter[i] → DSP[i] → Fabric 路由 → USP → rc_adapter → RC
EP[i] → DSP[i] → Fabric P2P → DSP[j] → EP[j]  (P2P 直通)
```

**路由优先级:** Completion (ID) > Config (ID) > Memory/IO (地址) > Message (类型) > 默认上行

**Switch 统计:** `env.sw.total_routed`, `env.sw.total_p2p`, `env.sw.total_dropped`

---

## 9. Sequence 库

### 9.1 基础 Sequence (src/seq/base/)

| Sequence | 功能 | 关键参数 |
|----------|------|---------|
| `pcie_tl_mem_rd_seq` | Memory Read | addr, length, first_be, last_be, is_64bit |
| `pcie_tl_mem_wr_seq` | Memory Write | addr, length, first_be, last_be, is_64bit |
| `pcie_tl_io_rd_seq` | IO Read | addr, first_be |
| `pcie_tl_io_wr_seq` | IO Write | addr, first_be |
| `pcie_tl_cfg_rd_seq` | Config Read | target_bdf, reg_num, first_be, is_type1 |
| `pcie_tl_cfg_wr_seq` | Config Write | target_bdf, reg_num, wr_data, first_be |
| `pcie_tl_cpl_seq` | Completion | completer_id, tag, status, has_data |
| `pcie_tl_msg_seq` | Message | msg_code, has_data |
| `pcie_tl_atomic_seq` | AtomicOp | addr, op_kind, op_size |
| `pcie_tl_vendor_msg_seq` | Vendor Message | vendor_id, has_data |
| `pcie_tl_ltr_seq` | LTR | (latency values auto-randomized) |

**使用示例:**

```systemverilog
// Memory Write: 在地址 0x1_0000_0000 写入 256B
pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
wr.addr     = 64'h0000_0001_0000_0000;
wr.length   = 64;       // 64 DW = 256 字节
wr.first_be = 4'hF;
wr.last_be  = 4'hF;
wr.is_64bit = 1;
wr.start(env.rc_agent.sequencer);
```

### 9.2 约束模式 (src/seq/constraints/)

| 模式 | 类名 | 用途 |
|------|------|------|
| Legal | `pcie_tl_legal_constraints` | 正常合法 TLP |
| Illegal | `pcie_tl_illegal_constraints` | 协议违规测试 |
| Corner Case | `pcie_tl_corner_constraints` | 边界条件测试 |

**使用方法:**

```systemverilog
// 发送一个非法 TLP (用于错误注入测试)
pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
wr.mode = CONSTRAINT_ILLEGAL;
wr.start(env.rc_agent.sequencer);
```

### 9.3 场景 Sequence (src/seq/scenario/)

| Sequence | 功能 | 说明 |
|----------|------|------|
| `pcie_tl_bar_enum_seq` | BAR 枚举 | 写全 1 -> 读回 -> 分配地址 |
| `pcie_tl_dma_rdwr_seq` | DMA 传输 | 自动按 MPS/4KB 边界拆分 |
| `pcie_tl_msi_seq` | MSI 中断 | MSI/MSI-X 消息写 |
| `pcie_tl_cpl_timeout_seq` | 完成超时 | 发 MEM_RD 无 EP 响应 |
| `pcie_tl_err_malformed_seq` | 畸形 TLP | 非法约束 + 字段翻转 |
| `pcie_tl_err_poisoned_seq` | Poisoned TLP | inject_poisoned=1 |
| `pcie_tl_err_unexpected_cpl_seq` | 意外完成 | tag=0x3FF |
| `pcie_tl_err_tag_conflict_seq` | 标签冲突 | 连续两个相同标签的 MEM_RD |

**DMA Sequence 4KB 边界自动拆分:**

```systemverilog
pcie_tl_dma_rdwr_seq dma = pcie_tl_dma_rdwr_seq::type_id::create("dma");
dma.addr        = 64'h0000_0001_0000_0E00;  // 3584 偏移
dma.xfer_size   = 2048;                      // 2KB 传输
dma.max_payload = 256;                       // MPS = 256B
dma.is_read     = 0;                         // 写操作
dma.start(env.rc_agent.sequencer);
// 自动生成: 512B TLP (到 4KB 边界) + 256B + 256B + ... 共 2KB
```

### 9.4 虚拟 Sequence (src/seq/virtual/)

| Sequence | 功能 |
|----------|------|
| `pcie_tl_base_vseq` | 基类，提取 rc_seqr / ep_seqr |
| `pcie_tl_rc_ep_rdwr_vseq` | 单次 RC 读或写 |
| `pcie_tl_enum_then_dma_vseq` | 先枚举 BAR 再 DMA |
| `pcie_tl_backpressure_vseq` | 突发写耗尽 FC 信用 |

---

## 10. 协议检查器

### 10.1 Monitor 内置检查

Base Monitor 内置 6 项协议检查，均可独立开关:

| 检查项 | 开关 | 检查内容 |
|--------|------|---------|
| TLP 格式 | `tlp_format_check_enable` | fmt 与 payload 一致性 |
| FC 合规 | `fc_check_enable` | 发送时是否有足够信用 |
| Tag 有效性 | `tag_check_enable` | 检测重复标签 |
| 排序合规 | `ordering_check_enable` | Table 2-40 排序规则 |
| 4KB 边界 | `boundary_4kb_check_enable` | TLP 不跨 4KB 地址页 |
| Byte Enable | `byte_enable_check_enable` | first_be / last_be 合法性 |

### 10.2 Byte Enable 规则

```
length == 1:  first_be != 0, last_be == 0
length >= 2:  first_be != 0, last_be != 0
length == 0:  (零长度读) first_be == 0, last_be == 0
```

### 10.3 4KB 边界规则

```
start_addr = mem_tlp.addr
end_addr   = start_addr + byte_len - 1
CHECK: start_addr[63:12] == end_addr[63:12]  // 同一个 4KB 页
```

---

## 11. 覆盖率模型

### 11.1 覆盖率组一览

| Covergroup | 开关 | 覆盖内容 |
|------------|------|---------|
| `tlp_basic_cg` | `tlp_basic_enable` | kind, fmt, length(分段), tc, attr (RO/IDO/NS) |
| `fc_state_cg` | `fc_state_enable` | PH/NPH/CPLH 信用状态 (empty/low/normal/high), infinite_credit |
| `tag_usage_cg` | `tag_usage_enable` | 标签池使用率 (0/1-64/65-256/257-512/513-1023/1024), phantom, extended |
| `ordering_cg` | `ordering_enable` | prev_category x curr_category 交叉覆盖 |
| `error_injection_cg` | `error_inject_enable` | ECRC 错误, Poisoned, 排序违规, 字段翻转 |
| `mps_mrrs_cg` | `mps_mrrs_enable` | MPS (128-4096), MRRS (128-4096), RCB (64/128) |

### 11.2 Length 分段 bins

```systemverilog
cp_length: coverpoint sampled_tlp.length {
    bins len_zero     = {0};           // 0 表示 1024 DW
    bins len_small    = {[1:16]};      // <= 64B
    bins len_medium   = {[17:128]};    // 68B - 512B
    bins len_large    = {[129:512]};   // 516B - 2KB
    bins len_max_half = {[513:1023]};  // 2KB - 4KB
}
```

### 11.3 用户自定义覆盖率

```systemverilog
class my_coverage extends pcie_tl_coverage_callback;
    covergroup my_cg;
        // 自定义 coverpoint
    endgroup

    function void sample(pcie_tl_tlp tlp);
        // 采样逻辑
        my_cg.sample();
    endfunction
endclass

// 注册
my_coverage my_cov = new();
env.cov.register_callback(my_cov);
```

---

## 12. 错误注入

### 12.1 TLP 级错误注入

通过 TLP 基类字段控制:

| 字段 | 类型 | 描述 |
|------|------|------|
| `inject_ecrc_err` | `bit` | 注入 ECRC 校验错误 |
| `inject_lcrc_err` | `bit` | 注入 LCRC 校验错误 |
| `inject_poisoned` | `bit` | 设置 Poisoned 标志 (EP bit) |
| `violate_ordering` | `bit` | 跳过排序引擎 |
| `field_bitmask` | `bit [31:0]` | 对头字段按位翻转 |
| `constraint_mode_sel` | `tlp_constraint_mode_e` | LEGAL / ILLEGAL / CORNER_CASE |

### 12.2 组件级错误注入

```systemverilog
// FC 信用溢出/下溢
fc_mgr.force_credit_overflow();
fc_mgr.force_credit_underflow();

// 标签冲突
bit [9:0] dup_tag = tag_mgr.alloc_duplicate_tag();

// 排序违规
ord_eng.force_ordering_violation(victim_tlp, blocker_tlp);
```

### 12.3 错误注入 Sequence

```systemverilog
// Poisoned TLP
pcie_tl_err_poisoned_seq poison = pcie_tl_err_poisoned_seq::type_id::create("poison");
poison.start(env.rc_agent.sequencer);

// 畸形 TLP (字段翻转)
pcie_tl_err_malformed_seq malform = pcie_tl_err_malformed_seq::type_id::create("malform");
malform.start(env.rc_agent.sequencer);

// 意外 Completion (tag=0x3FF)
pcie_tl_err_unexpected_cpl_seq unexp = pcie_tl_err_unexpected_cpl_seq::type_id::create("unexp");
unexp.start(env.rc_agent.sequencer);
```

---

## 13. 配置参考

### 13.1 pcie_tl_env_config 完整参数表

#### Agent 控制

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `rc_agent_enable` | `bit` | 1 | 启用 RC Agent |
| `ep_agent_enable` | `bit` | 1 | 启用 EP Agent |
| `rc_is_active` | `uvm_active_passive_enum` | ACTIVE | RC Agent 模式 |
| `ep_is_active` | `uvm_active_passive_enum` | ACTIVE | EP Agent 模式 |

#### 接口模式

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `if_mode` | `pcie_tl_if_mode_e` | TLM_MODE | TLM_MODE / SV_IF_MODE |

#### 流控 (Flow Control)

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `fc_enable` | `bit` | 1 | 启用流控 |
| `infinite_credit` | `bit` | 0 | 无限信用模式 |
| `init_ph_credit` | `int` | 32 | Posted Header 初始信用 |
| `init_pd_credit` | `int` | 256 | Posted Data 初始信用 |
| `init_nph_credit` | `int` | 32 | Non-Posted Header 初始信用 |
| `init_npd_credit` | `int` | 256 | Non-Posted Data 初始信用 |
| `init_cplh_credit` | `int` | 32 | Completion Header 初始信用 |
| `init_cpld_credit` | `int` | 256 | Completion Data 初始信用 |

#### 带宽整形

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `shaper_enable` | `bit` | 0 | 启用带宽整形 |
| `avg_rate` | `real` | 0.0 | 令牌补充速率 (bytes/ns) |
| `burst_size` | `int` | 4096 | 令牌桶容量 (bytes) |

#### 标签管理

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `extended_tag_enable` | `bit` | 1 | 10-bit 标签 (1=1024, 0=256) |
| `phantom_func_enable` | `bit` | 0 | Phantom Function 标签共享 |
| `max_outstanding` | `int` | 1024 | 最大并发 Non-Posted |

#### PCIe Capability

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `max_payload_size` | `mps_e` | MPS_256 | 最大负载大小 (128-4096B) |
| `max_read_request_size` | `mrrs_e` | MRRS_512 | 最大读请求大小 (128-4096B) |
| `read_completion_boundary` | `rcb_e` | RCB_64 | 读完成边界 (64/128B) |
| `no_snoop_enable` | `bit` | 0 | No Snoop 属性启用 |

#### 排序

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `relaxed_ordering_enable` | `bit` | 1 | Relaxed Ordering |
| `id_based_ordering_enable` | `bit` | 1 | ID-Based Ordering |
| `bypass_ordering` | `bit` | 0 | 跳过所有排序检查 |

#### 覆盖率

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `cov_enable` | `bit` | 0 | 总开关 |
| `tlp_basic_cov` | `bit` | 0 | TLP 基本属性覆盖率 |
| `fc_state_cov` | `bit` | 0 | FC 状态覆盖率 |
| `tag_usage_cov` | `bit` | 0 | 标签使用覆盖率 |
| `ordering_cov` | `bit` | 0 | 排序交叉覆盖率 |
| `error_inject_cov` | `bit` | 0 | 错误注入覆盖率 |

#### Scoreboard

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `scb_enable` | `bit` | 1 | 启用记分板 |
| `ordering_check_enable` | `bit` | 1 | 排序合规检查 |
| `completion_check_enable` | `bit` | 1 | 完成匹配检查 |
| `data_integrity_enable` | `bit` | 1 | 数据完整性校验 |

#### EP 自动响应

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `ep_auto_response` | `bit` | 1 | EP 自动响应请求 |
| `response_delay_min` | `int` | 0 | 响应延迟下限 (ns) |
| `response_delay_max` | `int` | 10 | 响应延迟上限 (ns) |

#### 超时

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `cpl_timeout_ns` | `int` | 50000 | Completion 超时 (ns) |

#### 链路延时

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `link_delay_enable` | `bit` | 0 | 启用链路延时 |
| `rc2ep_latency_min_ns` | `int` | 0 | RC→EP 最小延时 (ns) |
| `rc2ep_latency_max_ns` | `int` | 0 | RC→EP 最大延时 (ns) |
| `ep2rc_latency_min_ns` | `int` | 0 | EP→RC 最小延时 (ns) |
| `ep2rc_latency_max_ns` | `int` | 0 | EP→RC 最大延时 (ns) |
| `link_delay_update_interval` | `int` | 16 | 延时更新间隔 (TLP数) |

#### Switch

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `switch_enable` | `bit` | 0 | 启用 Switch 模式 |
| `switch_cfg` | `pcie_tl_switch_config` | null | Switch 配置对象 |

**pcie_tl_switch_config 参数:**

| 参数 | 类型 | 默认值 | 描述 |
|------|------|--------|------|
| `num_ds_ports` | `int` | 4 | 下行端口数 (1-16) |
| `switch_bdf` | `bit[15:0]` | 0x0100 | Switch BDF |
| `enum_mode` | `bit` | 0 | 0=静态, 1=枚举 |
| `p2p_enable` | `bit` | 1 | P2P 直通开关 |
| `port_ph_credit` | `int` | 32 | 每端口 PH 信用 |
| `port_pd_credit` | `int` | 256 | 每端口 PD 信用 |

### 13.4 SR-IOV 配置

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `sriov_enable` | bit | 0 | SR-IOV 功能总开关 |
| `num_pfs` | int | 1 | Physical Function 数量 (1-8) |
| `max_vfs_per_pf` | int | 256 | 每 PF 最大 Virtual Function 数 |
| `default_num_vfs` | int | 0 | 启动时默认激活的 VF 数 (0=不激活) |
| `pf_vendor_id` | bit[15:0] | 16'hABCD | PF Vendor ID |
| `pf_device_id` | bit[15:0] | 16'h1234 | PF Device ID |
| `vf_device_id` | bit[15:0] | 16'h1235 | VF Device ID |
| `ari_enable` | bit | 0 | ARI (Alternative Routing-ID) 使能 |

### 13.5 TLP Prefix 配置

| 参数 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `prefix_enable` | bit | 0 | TLP Prefix 功能总开关 |
| `pasid_enable` | bit | 0 | PASID Prefix 使能 |
| `pasid_width` | int | 20 | PASID 位宽 (1-20) |
| `pasid_exe_supported` | bit | 0 | PASID Execute Permission 支持 |
| `pasid_priv_supported` | bit | 0 | PASID Privilege Mode 支持 |
| `ext_tph_enable` | bit | 0 | Extended TPH Prefix 使能 |
| `ide_enable` | bit | 0 | IDE Prefix 使能 |
| `mriov_enable` | bit | 0 | MR-IOV Local Prefix 使能 |
| `max_e2e_prefix` | int | 4 | 最大 E2E Prefix 数 (1-4) |

### 13.2 Base Test 辅助方法

```systemverilog
class pcie_tl_base_test extends uvm_test;
    virtual function void configure_test();           // 覆盖此方法配置测试
    function void configure_fc(bit enable, bit infinite = 0);
    function void configure_tags(bit extended = 1, bit phantom = 0, int max_out = 1024);
    function void enable_coverage();
    function void set_mode(pcie_tl_if_mode_e mode);
endclass
```

---

## 14. 测试用例参考

### 14.1 Smoke Tests (基本功能验证)

| 测试名 | 描述 | 关键场景 |
|--------|------|---------|
| `pcie_tl_smoke_mem_test` | Memory 读写 | 64-bit 地址写 -> 读，TLM 回环 |
| `pcie_tl_smoke_cfg_test` | Config 空间 | BAR 枚举 (2 个 BAR) |
| `pcie_tl_smoke_err_test` | 错误注入 | Poisoned TLP |
| `pcie_tl_smoke_fc_test` | FC 回压 | 8 次突发写 (信用 PH=16) |
| `pcie_tl_smoke_ordering_test` | 排序合规 | 混合 Posted + Non-Posted |

### 14.2 Advanced Tests (压力/性能/边界测试)

#### 14.2.1 压力测试 (pcie_tl_stress_test)

**目标:** 大量混合 TLP 验证协议合规性

| 阶段 | TLP 数 | 类型 | 大小范围 |
|------|--------|------|---------|
| Phase 1 | 100 | Memory Write | 1-64 DW (4-256B) |
| Phase 2 | 50 | Memory Read | 1-32 DW (4-128B) |
| Phase 3 | 20 | Config Read | 1 DW |
| Phase 4 | 30 | 交替读/写 | 4 DW |
| **总计** | **200** | 混合 | - |

**配置:** FC 有限 (PH=64, PD=512), 覆盖率全开

#### 14.2.2 MPS 扫描测试 (pcie_tl_mps_sweep_test)

**目标:** 验证小 MPS 下的 Completion 拆分

**配置:** MPS=128B, RCB=64B

| 子测试 | 请求大小 | 预期 CplD 数 |
|--------|---------|-------------|
| 512B 读 | 128 DW | ~4 个 |
| 非对齐 256B 读 | 64 DW | ~3 个 |
| 精确 MPS 读 | 32 DW | 1 个 |
| 2KB DMA 写 | 多个 TLP | N/A (写无 CplD) |

#### 14.2.3 4KB 边界测试 (pcie_tl_4kb_boundary_test)

**目标:** 验证 DMA 传输自动 4KB 边界拆分

| 子测试 | 起始偏移 | 传输大小 | 跨页数 |
|--------|---------|---------|--------|
| DMA 写 | 0xE00 (3584) | 1KB | 1 |
| DMA 读 | 0xC00 (3072) | 2KB | 1 |
| 多页 DMA | 0x800 (2048) | 4KB | 1+ |
| 边界边缘写 | 0xFFC | 4B | 0 |

#### 14.2.4 带宽控制测试 (pcie_tl_bandwidth_test)

**目标:** 验证令牌桶限速精度

**配置:** rate=1GB/s, burst=512B

| 阶段 | TLP 数 | 负载 | 结果 |
|------|--------|------|------|
| 突发发送 | 20 | 256B | 第 1 个立即发送; 稳态间隔 ~272ns |
| 等待恢复 | - | - | 1us 后令牌恢复到 burst_size |
| 恢复后发送 | 10 | 128B | 突发 3 个后再次限速; 稳态 ~144ns |

**实测带宽:** ~0.94 GB/s (理论 1 GB/s, 差异因 16B 头开销)

#### 14.2.5 FC 压力测试 (pcie_tl_fc_stress_test)

**目标:** 紧信用下的信用耗尽与恢复

**配置:** PH=4, PD=64 (非常紧张)

| 阶段 | 操作 | 预期 |
|------|------|------|
| Phase 1 | 8 次突发写 | PH 在第 4 次后耗尽，等待回压 |
| Phase 2 | 8 次读 | NPH 在第 4 次后耗尽 |
| Phase 3 | 混合流量 | 信用恢复后继续 |

#### 14.2.6 Completion 拆分测试 (pcie_tl_cpl_split_test)

**目标:** 验证 EP 按 MPS/RCB 拆分 Completion

**配置:** MPS=128B, RCB=64B

| 子测试 | 地址 | 请求大小 |
|--------|------|---------|
| 对齐 256B 读 | 0x...0000 | 256B (2 CplDs) |
| 非对齐 384B 读 | 0x...0020 | 384B (3-4 CplDs) |
| 单 DW 读 | 0x...0100 | 4B (1 CplD) |
| 10 个连续读 | 不同地址 | 128B-416B |

#### 14.2.7 标签压力测试 (pcie_tl_tag_stress_test)

**目标:** 小标签池下的标签分配与回收

**配置:** extended=0 (256 标签), max_outstanding=32

| 阶段 | 操作 | 预期 |
|------|------|------|
| Phase 1 | 快速发送 20 个读 (5ns 间隔) | 快速消耗标签池 |
| Phase 2 | 30 个读 (50ns 间隔) | 标签回收后复用 |

#### 14.2.8 链路延时测试 (pcie_tl_link_delay_test)

**目标:** 验证链路延时模型的各种配置模式

| 子测试 | 配置 | 描述 |
|--------|------|------|
| 固定延时 | min=max=300ns | RC→EP 和 EP→RC 均为 300ns |
| 非对称延时 | RC→EP: 200-500ns, EP→RC: 100-200ns | 双向不同延时范围 |
| 随机延时 | min=50ns, max=1000ns | 大范围随机 |
| 禁用模式 | enable=0 | 零延时直通 |

#### 14.2.9 双向流量测试 (pcie_tl_bidir_traffic_test)

**目标:** RC-EP 双向 10K 大流量压力验证

**配置:** 10000 次读写混合，RC 和 EP 同时发起流量

#### 14.2.10 Switch 基本路由测试 (pcie_tl_switch_basic_test)

**目标:** 验证 Switch 4EP 基本写读路由

**配置:** 4 个下行端口，静态地址分配

| 阶段 | 操作 | 预期 |
|------|------|------|
| Phase 1 | RC 写入 EP0-EP3 各自地址空间 | 路由到正确端口 |
| Phase 2 | RC 读回 EP0-EP3 数据 | Completion 路由回 RC |

#### 14.2.11 P2P 直通测试 (pcie_tl_switch_p2p_test)

**目标:** P2P 直通功能 + P2P 禁用验证

| 子测试 | p2p_enable | 操作 | 预期 |
|--------|-----------|------|------|
| P2P 使能 | 1 | EP0 写 EP1 地址 | Switch P2P 转发 |
| P2P 禁用 | 0 | EP0 写 EP1 地址 | 上行到 RC，RC 不路由，丢弃 |

#### 14.2.12 Switch 枚举模式测试 (pcie_tl_switch_enum_test)

**目标:** 验证 Switch 枚举模式配置空间扫描

**配置:** `enum_mode=1`，模拟 BIOS 枚举流程，通过 Config TLP 发现并配置各端口

#### 14.2.13 Switch 压力测试 (pcie_tl_switch_stress_test)

**目标:** Switch 多EP 并发流量压力

**配置:** 4EP 并发，每 EP 发送 500 次随机读写，共 2000 次事务

#### 14.2.14 Switch FC 隔离测试 (pcie_tl_switch_fc_isolation_test)

**目标:** 验证各下行端口 FC 信用独立，端口间不干扰

**配置:** 对一个端口施加 FC 回压，验证其他端口不受影响

#### 14.2.15 Switch 读 Completion 路由测试 (pcie_tl_switch_read_cpl_test)

**目标:** 验证多EP 大读请求的 Completion 正确路由回 RC

**配置:** 4EP 各发起 256B 读请求，验证所有 Completion 均正确返回

#### 14.2.16 P2P 全连接测试 (pcie_tl_switch_p2p_all_test)

**目标:** 4EP×3目标×200次 P2P 全矩阵验证

**配置:** 每个 EP 向其他 3 个 EP 各发送 200 次写，共 2400 次 P2P 事务

#### 14.2.17 Switch 双向交叉流量测试 (pcie_tl_switch_bidir_test)

**目标:** RC→EP 和 EP→RC 双向同时发起流量，验证 Switch Fabric 无死锁

#### 14.2.18 地址边界测试 (pcie_tl_switch_addr_boundary_test)

**目标:** 地址边界正确路由 + 无效地址丢弃

| 子测试 | 操作 | 预期 |
|--------|------|------|
| 窗口起始 | 写各 EP 地址空间第一个字节 | 正确路由 |
| 窗口末尾 | 写各 EP 地址空间最后一个字节 | 正确路由 |
| 无效地址 | 写未映射地址 | Switch 丢弃，total_dropped++ |

#### 14.2.19 USP 拥塞测试 (pcie_tl_switch_usp_congestion_test)

**目标:** 全部 EP 同时向 RC 上行，验证 USP 拥塞下无数据丢失

**配置:** 4EP 同时发起 DMA 上行，共 1000 次上行事务

#### 14.2.20 8端口扩展测试 (pcie_tl_switch_scale_test)

**目标:** 验证 Switch 8端口配置下的路由正确性

**配置:** `num_ds_ports=8`，8EP 并发读写

#### 14.2.21 Switch Config 空间测试 (pcie_tl_switch_cfg_space_test)

**目标:** 验证 Switch Type 1 配置空间读写

**操作:** 通过 Config Type 1 TLP 读写 Switch 各端口的 Bus Number、Memory Base/Limit 等寄存器

#### 14.2.22 Switch 大流量测试 (pcie_tl_switch_heavy_traffic_test)

**目标:** 20K 全方向大流量，综合验证 Switch 稳定性

**配置:** RC→各EP、各EP→RC、EP间 P2P，共 20000 次混合事务，覆盖率全开

### 14.3 完整测试结果

| # | 测试名 | UVM_ERROR | UVM_WARNING | 状态 |
|---|--------|-----------|-------------|------|
| 1 | pcie_tl_smoke_mem_test | 0 | 0 | **PASS** |
| 2 | pcie_tl_smoke_cfg_test | 0 | 0 | **PASS** |
| 3 | pcie_tl_smoke_err_test | 0 | 181 (预期) | **PASS** |
| 4 | pcie_tl_smoke_fc_test | 0 | 0 | **PASS** |
| 5 | pcie_tl_smoke_ordering_test | 0 | 0 | **PASS** |
| 6 | pcie_tl_stress_test | 0 | 52 | **PASS** |
| 7 | pcie_tl_mps_sweep_test | 0 | 52 | **PASS** |
| 8 | pcie_tl_4kb_boundary_test | 0 | 52 | **PASS** |
| 9 | pcie_tl_bandwidth_test | 0 | 0 | **PASS** |
| 10 | pcie_tl_fc_stress_test | 0 | 0 | **PASS** |
| 11 | pcie_tl_cpl_split_test | 0 | 52 | **PASS** |
| 12 | pcie_tl_tag_stress_test | 0 | 0 | **PASS** |
| 13 | pcie_tl_link_delay_test | 0 | 0 | **PASS** |
| 14 | pcie_tl_bidir_traffic_test | 0 | 0 | **PASS** |
| 15 | pcie_tl_switch_basic_test | 0 | 0 | **PASS** |
| 16 | pcie_tl_switch_p2p_test | 0 | 0 | **PASS** |
| 17 | pcie_tl_switch_enum_test | 0 | 0 | **PASS** |
| 18 | pcie_tl_switch_stress_test | 0 | 0 | **PASS** |
| 19 | pcie_tl_switch_fc_isolation_test | 0 | 0 | **PASS** |
| 20 | pcie_tl_switch_read_cpl_test | 0 | 0 | **PASS** |
| 21 | pcie_tl_switch_p2p_all_test | 0 | 0 | **PASS** |
| 22 | pcie_tl_switch_bidir_test | 0 | 0 | **PASS** |
| 23 | pcie_tl_switch_addr_boundary_test | 0 | 0 | **PASS** |
| 24 | pcie_tl_switch_usp_congestion_test | 0 | 0 | **PASS** |
| 25 | pcie_tl_switch_scale_test | 0 | 0 | **PASS** |
| 26 | pcie_tl_switch_cfg_space_test | 0 | 0 | **PASS** |
| 27 | pcie_tl_switch_heavy_traffic_test | 0 | 0 | **PASS** |

### 14.4 SR-IOV 与 TLP Prefix 测试 (Tests 23-37)

| 编号 | 测试类名 | 验证目标 | TLP 数量 |
|------|---------|---------|---------|
| 23 | `pcie_tl_sriov_basic_test` | SR-IOV 基础：4PF×16VF Config 枚举 + Memory R/W | 10,000 |
| 28 | `pcie_tl_pasid_prefix_test` | PASID Prefix 重流量：6000 写 + 4000 读，覆盖 Exe/PMR 组合 | 10,000 |
| 32 | `pcie_tl_multi_prefix_test` | Multi-Prefix 组合：三前缀 + 双 E2E + 单 IDE + 单 PASID | 10,000 |
| 33 | `pcie_tl_vf_pasid_test` | VF + PASID 联合：4PF×16VF，每 VF 唯一 PASID 范围 | 10,000 |
| 35 | `pcie_tl_sriov_stress_test` | Switch + SR-IOV + Prefix：4DSP 并发，5 阶段全场景 | 21,000 |
| 36 | `pcie_tl_rc_ep_sriov_heavy_test` | RC→EP SR-IOV 重流量：8PF×32VF (264 func)，6 阶段含 VF disable/re-enable | 31,280 |
| 37 | `pcie_tl_rc_ep_sriov_prefix_heavy_test` | RC→EP SR-IOV + 全 Prefix：8PF×32VF，6 阶段覆盖所有 Prefix 类型及组合 | 20,000 |

> **Warning 说明:**
> - err_test (181): 预期的错误注入行为产生的 WARNING
> - stress/mps/4kb/cpl_split (52): v2.0 已修复多 CplD 追踪，RC Driver 通过 cpl_byte_tracker_t 正确处理拆分 Completion，不再产生误报 WARNING。

---

## 15. 扩展指南

### 15.1 添加新的 TLP 类型

1. 在 `pcie_tl_types.sv` 中添加 `tlp_kind_e` 枚举值
2. 在 `pcie_tl_tlp.sv` 中创建新的派生类:

```systemverilog
class pcie_tl_my_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_my_tlp)
    // 自定义字段
    rand bit [15:0] my_field;
    // 约束
    constraint c_my { my_field inside {[0:100]}; }
    function new(string name = "pcie_tl_my_tlp");
        super.new(name);
    endfunction
endclass
```

3. 在 `pcie_tl_codec.sv` 的 `create_tlp_by_type()` 中添加解码支持
4. 创建对应的 Sequence

### 15.2 添加新的覆盖率

```systemverilog
// 方式 1: 扩展 coverage_collector (需修改源码)
// 方式 2: 使用回调机制 (推荐，无需修改源码)

class my_cov_callback extends pcie_tl_coverage_callback;
    covergroup my_cg with function sample(pcie_tl_tlp t);
        cp_my: coverpoint t.length { bins b[] = {[1:10]}; }
    endgroup

    function new();
        my_cg = new();
    endfunction

    virtual function void sample(pcie_tl_tlp tlp);
        my_cg.sample(tlp);
    endfunction
endclass

// 在测试中注册
my_cov_callback cb = new();
env.cov.register_callback(cb);         // 通过覆盖率收集器
env.rc_agent.monitor.register_coverage_callback(cb); // 通过 Monitor
```

### 15.3 添加配置空间 Capability

```systemverilog
// 标准 Capability
pcie_capability msi_cap = new();
msi_cap.cap_id   = CAP_MSI;
msi_cap.offset   = 8'h50;
msi_cap.data     = new[16];
msi_cap.data[0]  = 32'h0000_0005;  // MSI Capability ID
cfg_mgr.register_capability(msi_cap);

// 扩展 Capability
pcie_ext_capability aer_cap = new();
aer_cap.cap_id  = EXT_CAP_AER;
aer_cap.offset  = 12'h100;
aer_cap.cap_ver = 4'h2;
aer_cap.data    = new[48];
cfg_mgr.register_ext_capability(aer_cap);
```

### 15.4 自定义配置空间回调

```systemverilog
class my_cfg_callback extends pcie_cfg_callback;
    virtual function void on_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        // 当写入特定寄存器时触发
        $display("Config write: addr=0x%03h data=0x%08h", addr, data);
    endfunction
    virtual function void on_read(bit [11:0] addr, bit [31:0] data);
        $display("Config read: addr=0x%03h data=0x%08h", addr, data);
    endfunction
endclass

my_cfg_callback cb = new();
cfg_mgr.register_callback(12'h048, cb);  // Device Control 寄存器
```

### 15.5 SV Interface 模式集成

如需连接到 RTL DUT:

```systemverilog
module tb_top;
    pcie_tl_if tl_if(.clk(clk), .rst_n(rst_n));

    // 连接到 DUT
    my_pcie_dut dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .tlp_data   (tl_if.tlp_data),
        .tlp_valid  (tl_if.tlp_valid),
        .tlp_ready  (tl_if.tlp_ready),
        .tlp_sop    (tl_if.tlp_sop),
        .tlp_eop    (tl_if.tlp_eop),
        .tlp_strb   (tl_if.tlp_strb)
    );

    initial begin
        uvm_config_db#(virtual pcie_tl_if)::set(null, "*", "vif", tl_if);
    end
endmodule
```

测试中切换到 SV Interface 模式:

```systemverilog
virtual function void configure_test();
    super.configure_test();
    set_mode(SV_IF_MODE);
endfunction
```

---

## 16. SR-IOV PF/VF 管理

### 16.1 概述

VIP 实现了完整的 SR-IOV (Single Root I/O Virtualization) Extended Capability 建模，支持 EP 侧的多 PF/VF 管理。所有 SR-IOV 功能默认关闭 (`sriov_enable=0`)，不影响现有测试。

### 16.2 架构

```
pcie_tl_func_manager
├── pf_ctx[0..N-1]                    # PF Context 数组
│   ├── cfg_mgr (cfg_space_manager)   # 独立 4KB 配置空间
│   ├── bar_base/size[6]              # BAR 地址空间
│   └── sriov_cap                     # SR-IOV Extended Capability
│       ├── total_vfs / num_vfs
│       ├── first_vf_offset / vf_stride
│       └── vf_bar[6]
└── vf_ctx[pf][0..M-1]               # VF Context 二维数组
    ├── cfg_mgr                       # 独立配置空间
    ├── bdf (自动计算)                # PF_BDF + offset + vf_idx * stride
    └── enabled                       # 由 VF Enable 控制
```

Function Manager 位于 EP Agent 内部，通过 BDF 查找表 (`bdf_lut`) 实现 O(1) 的 Function 定位。

### 16.3 BDF 计算规则

```
PF BDF = {pf_base_bus, pf_base_dev, pf_index[2:0]}
VF BDF = PF_BDF + first_vf_offset + vf_index × vf_stride
```

默认: `pf_base_bus=8'h01`, `pf_base_dev=5'h00`, `first_vf_offset=1`, `vf_stride=1`

示例 (2 PF, 每 PF 4 VF):
- PF0 = 01:00.0 (0x0100), VF0=0x0101, VF1=0x0102, VF2=0x0103, VF3=0x0104
- PF1 = 01:00.1 (0x0108), VF0=0x0109, VF1=0x010A, VF2=0x010B, VF3=0x010C

### 16.4 SR-IOV Extended Capability 寄存器

`pcie_tl_sriov_cap` 建模了完整的 SR-IOV 寄存器集 (64 字节, Cap ID 0x0010):

| 偏移 | 寄存器 | 字段 |
|------|--------|------|
| +0x04 | SR-IOV Capabilities | VF Migration Capable, ARI Capable Hierarchy |
| +0x08 | SR-IOV Control | VF Enable, VF Migration Enable, ARI Capable, VF MSE |
| +0x0A | SR-IOV Status | VF Migration Status |
| +0x0C | InitialVFs | 初始 VF 数 |
| +0x0E | TotalVFs | 最大 VF 数 |
| +0x10 | NumVFs | 当前激活 VF 数 |
| +0x14 | First VF Offset | 第一个 VF 的 RID 偏移 |
| +0x16 | VF Stride | VF 间 RID 步长 |
| +0x1A | VF Device ID | VF 的 Device ID |
| +0x1C | Supported Page Sizes | 支持的页面大小 |
| +0x20 | System Page Size | 系统页面大小 |
| +0x24 | VF BAR[0..5] | VF BAR 寄存器 (6 × 4 字节) |

### 16.5 使用示例

```systemverilog
// 在测试的 configure_test() 中启用 SR-IOV
virtual function void configure_test();
    super.configure_test();
    cfg.sriov_enable     = 1;
    cfg.num_pfs          = 4;       // 4 个 PF
    cfg.max_vfs_per_pf   = 16;     // 每 PF 最多 16 VF
    cfg.default_num_vfs  = 8;      // 启动时激活 8 个 VF
endfunction

// 运行时动态管理 VF
task run_phase(uvm_phase phase);
    // 为 PF0 额外启用到 16 个 VF
    env.func_mgr_sriov.enable_vfs(0, 16);

    // 禁用 PF1 的所有 VF
    env.func_mgr_sriov.disable_vfs(1);

    // 查询活跃 Function 数
    $display("Active functions: %0d", env.func_mgr_sriov.get_active_count());
endtask
```

### 16.6 Config 请求路由

当 `sriov_enable=1` 时，EP Driver 的 Config 请求处理流程：

1. 从 Config TLP 提取目标 BDF (`completer_id`)
2. 在 `func_manager.bdf_lut` 中查找对应 Function Context
3. 如果找到且 `enabled=1`：读写该 Function 的独立配置空间
4. 如果未找到或 `enabled=0`：返回 UR (Unsupported Request) Completion

### 16.7 与 Switch 集成

Switch 模式下无需额外配置。VF 的 BDF 落在 DSP 的 bus number 范围内，Switch 现有的 ID-based routing 和 address-based routing 自然覆盖 VF 流量。

---

## 17. TLP Prefix 支持

### 17.1 概述

VIP 支持 PCIe 5.0 定义的全部 TLP Prefix 类型，包括 Local Prefix 和 End-to-End Prefix。所有 Prefix 功能默认关闭 (`prefix_enable=0`)。

### 17.2 支持的 Prefix 类型

| Fmt/Type Byte | 名称 | 类别 | 用途 |
|---------------|------|------|------|
| 0x80 | MR-IOV Routing ID | Local | 多根虚拟化的 Virtual Hierarchy ID |
| 0x8E | Local Vendor-Defined | Local | 厂商自定义 Local Prefix |
| 0x90 | Extended TPH | E2E | 16-bit Steering Tag 的高 8 位 |
| 0x91 | PASID | E2E | 20-bit 进程地址空间 ID |
| 0x92 | IDE | E2E | 数据完整性与加密 (Stream ID, MAC, PCRC) |
| 0x9E | E2E Vendor-Defined | E2E | 厂商自定义 E2E Prefix |

### 17.3 Prefix DW 位域

**PASID (0x91):**
- [31:24] Fmt/Type, [22] PMR, [21] Exe, [19:0] PASID (20-bit)

**Extended TPH (0x90):**
- [31:24] Fmt/Type, [23:16] ST Upper (Steering Tag 高 8 位)

**MR-IOV (0x80):**
- [31:24] Fmt/Type, [15:8] VHID (Virtual Hierarchy ID)

**IDE (0x92):**
- [31:24] Fmt/Type, [23] TEE, [21:14] Stream ID, [12] PCRC, [11] MAC, [10] Key Set

### 17.4 Prefix 规则

1. 每个 TLP 最多 4 个 Prefix DW
2. Local Prefix 最多 1 个，且必须在 E2E Prefix 之前
3. Prefix 不改变主 TLP Header 的 Fmt 字段
4. FC 信用核算自动包含 Prefix DW 开销

### 17.5 pcie_tl_prefix 类

```systemverilog
class pcie_tl_prefix extends uvm_object;
    rand tlp_prefix_type_e  prefix_type;   // 0x80/0x8E/0x90/0x91/0x92/0x9E
    rand bit [31:0]         raw_dw;        // 原始 32-bit Prefix DW

    // 类型查询
    function bit is_local();     // Type[4] == 0
    function bit is_e2e();       // Type[4] == 1

    // 字段解析 (按 prefix_type 使用)
    function bit [19:0] get_pasid();
    function bit        get_pasid_exe();
    function bit        get_pasid_pmr();
    function bit [7:0]  get_tph_st_upper();
    function bit [7:0]  get_mriov_vhid();
    function bit [7:0]  get_ide_stream_id();
    function bit        get_ide_tee();
    function bit        get_ide_mac();
    function bit        get_ide_pcrc();
    function bit        get_ide_keyset();

    // 工厂方法
    static function pcie_tl_prefix create_pasid(bit [19:0] pasid, bit exe=0, bit pmr=0);
    static function pcie_tl_prefix create_mriov(bit [7:0] vhid);
    static function pcie_tl_prefix create_ext_tph(bit [7:0] st_upper);
    static function pcie_tl_prefix create_ide(bit tee, bit [7:0] stream_id, bit pcrc, bit mac, bit keyset);
endclass
```

### 17.6 使用示例

```systemverilog
// 发送携带 PASID Prefix 的 Memory Write
pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
pcie_tl_prefix pasid_pfx = pcie_tl_prefix::create_pasid(20'h12345, .exe(1), .pmr(0));
wr.addr     = 64'h0000_0001_0000_0000;
wr.length   = 8;
wr.first_be = 4'hF;
wr.last_be  = 4'hF;
wr.is_64bit = 1;
wr.prefixes.push_back(pasid_pfx);
wr.has_prefix = 1;
wr.start(env.rc_agent.sequencer);

// 发送携带多个 Prefix 的 TLP (Local + E2E)
pcie_tl_mem_wr_seq wr2 = pcie_tl_mem_wr_seq::type_id::create("wr2");
pcie_tl_prefix mriov = pcie_tl_prefix::create_mriov(8'h05);     // Local, 必须在前
pcie_tl_prefix pasid = pcie_tl_prefix::create_pasid(20'hABCDE);  // E2E
pcie_tl_prefix ide   = pcie_tl_prefix::create_ide(1, 8'h0A, 0, 1, 0);  // E2E
wr2.prefixes.push_back(mriov);   // Local 在前
wr2.prefixes.push_back(pasid);   // E2E
wr2.prefixes.push_back(ide);     // E2E
wr2.has_prefix = 1;
```

### 17.7 Scoreboard Prefix 检查

当 `prefix_enable=1` 时，Scoreboard 自动执行:

- **格式合法性**: Prefix 数量 ≤ 4，Local ≤ 1，Local 在 E2E 前
- **E2E 完整性**: E2E Prefix 经过 Switch 后内容不变

### 17.8 Coverage

`prefix_cg` 覆盖率组包含:

- `cp_prefix_count`: Prefix 数量 (0-4)
- `cp_has_local` / `cp_has_e2e`: 是否含 Local/E2E
- `cp_prefix_type`: 各 Prefix 类型覆盖
- `cx_type_count`: 类型 × 数量交叉覆盖

### 17.9 Codec 处理

- **编码**: Prefix DW 在主 TLP Header 之前输出 (big-endian)
- **解码**: 逐 DW 扫描 `Fmt[2:0]==100b`，识别为 Prefix；第一个非 Prefix DW 为主 Header 起始
- 主 TLP 的 `fmt` 字段**不受 Prefix 影响**

### 17.10 与 SR-IOV 联合使用

Prefix 与 SR-IOV 是松耦合设计，可独立或联合使用:

```systemverilog
cfg.sriov_enable  = 1;    // 启用 SR-IOV
cfg.prefix_enable = 1;    // 启用 Prefix
cfg.pasid_enable  = 1;    // 启用 PASID
```

VIP 负责 Prefix 的搬运和校验，不负责 PASID 语义解释（如地址翻译）。
用户可在 test sequence 中自由组合 VF 和 PASID 值。

---

## 附录 A: 枚举类型速查

### TLP Kind

```
TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
TLP_IO_RD, TLP_IO_WR,
TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1,
TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK,
TLP_MSG, TLP_MSGD,
TLP_FETCH_ADD, TLP_SWAP, TLP_CAS,
TLP_VENDOR, TLP_LTR
```

### TLP Format

```
FMT_3DW_NO_DATA   = 3'b000
FMT_4DW_NO_DATA   = 3'b001
FMT_3DW_WITH_DATA = 3'b010
FMT_4DW_WITH_DATA = 3'b011
FMT_TLP_PREFIX     = 3'b100
```

### Completion Status

```
CPL_STATUS_SC  = 3'b000   // Successful Completion
CPL_STATUS_UR  = 3'b001   // Unsupported Request
CPL_STATUS_CRS = 3'b010   // Configuration Retry Status
CPL_STATUS_CA  = 3'b100   // Completer Abort
```

### MPS / MRRS / RCB

```
mps_e:  MPS_128, MPS_256, MPS_512, MPS_1024, MPS_2048, MPS_4096
mrrs_e: MRRS_128, MRRS_256, MRRS_512, MRRS_1024, MRRS_2048, MRRS_4096
rcb_e:  RCB_64, RCB_128
```

### TLP Prefix 类型 (tlp_prefix_type_e)

| 枚举值 | 编码 | 说明 |
|--------|------|------|
| `PREFIX_MRIOV` | 8'h80 | Local: MR-IOV Routing ID |
| `PREFIX_LOCAL_VENDOR` | 8'h8E | Local: Vendor-Defined |
| `PREFIX_EXT_TPH` | 8'h90 | E2E: Extended TPH |
| `PREFIX_PASID` | 8'h91 | E2E: PASID |
| `PREFIX_IDE` | 8'h92 | E2E: IDE |
| `PREFIX_E2E_VENDOR` | 8'h9E | E2E: Vendor-Defined |

### Extended Capability IDs (ext_cap_id_e) — 新增

| 枚举值 | 编码 | 说明 |
|--------|------|------|
| `EXT_CAP_ID_PASID` | 16'h001B | PASID Extended Capability |
| `EXT_CAP_ID_TPH` | 16'h0017 | TPH Requester Extended Capability |

---

## 附录 B: 常见问题

### Q1: 为什么会看到 "Unexpected Completion" WARNING?

**原因:** 已在 v2.0 修复。rc_driver.handle_completion() 现在通过 cpl_byte_tracker_t 追踪已接收字节数，
只在所有字节接收完毕后才释放标签。多 CplD 不再报 Unexpected Completion。

### Q2: 如何关闭所有协议检查?

```systemverilog
// 在测试的 configure_test() 中:
cfg.ordering_check_enable = 0;
cfg.completion_check_enable = 0;
cfg.data_integrity_enable = 0;
```

### Q3: 如何调整 Completion 超时?

```systemverilog
cfg.cpl_timeout_ns = 100000;  // 100us
```

### Q4: 如何启用 EP 主动 DMA?

```systemverilog
// 在测试的 run_phase 中:
env.ep_agent.ep_driver.initiate_dma(
    .addr(64'h0000_0001_0000_0000),
    .size(256),
    .is_read(0)
);
```

### Q5: 如何发送 MSI 中断?

```systemverilog
env.ep_agent.ep_driver.send_msi(
    .msi_addr(64'hFEE0_0000),
    .msi_data(32'h0000_0001)
);
```

### Q6: 如何配置 PCIe Switch?

```systemverilog
pcie_tl_switch_config sw_cfg = new("sw_cfg");
sw_cfg.num_ds_ports = 4;
sw_cfg.p2p_enable = 1;
sw_cfg.init_defaults();

cfg.switch_enable = 1;
cfg.switch_cfg = sw_cfg;
```

### Q7: 如何在 Switch 模式下访问特定 EP?

```systemverilog
// 写入 EP2 的地址空间
pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
wr.addr = cfg.switch_cfg.ds_mem_base[2];  // EP2 的起始地址
wr.start(env.rc_agent.sequencer);

// EP0 DMA 写入 EP1 (P2P)
env.ep_agents[0].ep_driver.initiate_dma(
    cfg.switch_cfg.ds_mem_base[1], 64, 0);
```

### Q8: 如何配置链路延时?

```systemverilog
cfg.link_delay_enable    = 1;
cfg.rc2ep_latency_min_ns = 500;
cfg.rc2ep_latency_max_ns = 1000;
cfg.ep2rc_latency_min_ns = 500;
cfg.ep2rc_latency_max_ns = 1000;
```
