# AXIS VIP 外部集成与使用指南

本文档说明如何把 `axis_vip` 集成到外部 DUT 验证环境，并详细举例所有支持的功能：参数化、`axis_config` 配置、激励与约束、内置 sequence / virtual sequence、带宽与流控控制、复位、协议检查与错误注入，以及测试运行。

---

## 目录

1. [核心概念：两层配置](#1-核心概念两层配置必须一致)
2. [信号作用与可选性](#2-各信号的作用与可选性)
3. [外部集成步骤](#3-外部集成步骤)
4. [axis_config 配置参考](#4-axis_config-配置参考)
5. [激励与约束](#5-激励与约束)
6. [内置 sequence 详解（举例）](#6-内置-sequence-详解举例)
7. [virtual sequence 与 test 编排（举例）](#7-virtual-sequence-与-test-编排举例)
8. [带宽与流控控制（举例）](#8-带宽与流控控制举例)
9. [复位功能（举例）](#9-复位功能举例)
10. [协议检查与错误注入（举例）](#10-协议检查与错误注入举例)
11. [运行测试](#11-运行测试)
12. [已知边界与陷阱](#12-已知边界与陷阱)

---

## 1. 核心概念：两层配置必须一致

VIP 的位宽与可选信号由**两层**共同决定，两层必须对齐，否则编译报错或行为错误。

| 层 | 在哪里设 | 形式 | 作用 |
|----|---------|------|------|
| **参数包**（编译期） | `axis_if` 实例、`axis_env` typedef、`virtual axis_if` (vif) typedef | 7 个参数 | 决定信号向量宽度、生成的具体类型 |
| **axis_config**（运行期） | test 里的 `axis_config` 对象 | 类成员字段 | gate driver 驱动 / monitor 采样 / 约束 / 字节通道数 |

### 参数包 7 个参数（顺序固定）

```
axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH, TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST)
            int          int        int          int          bit        bit        bit
```

**约束：**

- 宽度参数（TDATA/TID/TDEST/TUSER）**最小为 1**，不能为 0（`logic [W-1:0]` 在 W=0 时为 `[-1:0]`，SystemVerilog 非法）。
- `HAS_TSTRB / HAS_TKEEP / HAS_TLAST` 是 bit 开关：`axis_if` 仍无条件声明这些信号线，开关只控制 driver 是否驱动、约束是否生效。

---

## 2. 各信号的作用与可选性

| 信号 | 作用 | 本 VIP 用法 | 关 / 最小化方式 |
|------|------|------------|----------------|
| **TDATA** | 数据负载 | scoreboard 按 tkeep 门控逐字节比对 | 必需，设真实位宽 |
| **TKEEP** | 字节有效 | `get_payload` 据此筛字节进比对 | `HAS_TKEEP=0` 时按全有效处理 |
| **TSTRB** | 字节类型（数据/位置） | `cfg.HAS_TSTRB` 门控驱动与约束 | `HAS_TSTRB=0` + `cfg.HAS_TSTRB=0` |
| **TLAST** | 包尾 | 包边界；`HAS_TLAST=0` 时用 `pkt_boundary_mode` 定边界 | 见 §4 |
| **TID** | 流标识 / 源路由 | monitor 包重组 demux key + scoreboard 流 key `{tid,tdest}` | 无 HAS_TID 开关；单流设宽度 1 + 约束 `tid==0` |
| **TDEST** | 目的路由 | 同上，进 scoreboard 流 key | 无开关；单流设宽度 1 + 约束 `tdest==0` |
| **TUSER** | 用户边带 | driver 驱、monitor 采，**不进 scoreboard 比对** | 无开关；不用则设宽度 1 + 约束 `tuser==0` |

**注意点：**

- TID / TDEST / TUSER **没有 HAS_* 开关**，由 driver/monitor 无条件驱采。要"不用"只能把宽度设为 1 并把值固定（如 seq 里约束为 0），不能物理删信号。
- `tr.tid / tr.tdest / tr.tuser` 是 `rand`。单流场景务必固定 tid/tdest，否则 monitor 会按不同 tid 把数据拆成多条流，scoreboard 流 key 错乱。
- **TUSER 不进 scoreboard 比对**：仅采样进 transaction。若作为对端就绪等边带流控信号，它是纯激励（VIP master 侧驱入 DUT），需在 seq 里生成时序，scoreboard 不校验它。

---

## 3. 外部集成步骤

`sim/filelist.f` 默认包含 VIP 自带的 `tb/tb_top.sv` 与 `tb/axis_dummy_dut.sv`。外部集成时把这两个替换为你的 tb 与 DUT，保留接口、package、SVA 三项。

### 步骤 1：自有 filelist

```
+incdir+<axis_vip/src 绝对路径>
../src/axis_if.sv                      // 接口（包外编译）
../src/axis_protocol_checker_sva.sv    // SVA 协议检查 module
../src/axis_pkg.sv                     // package（含所有 class）
<你的 DUT>.sv
<你的 tb_top>.sv
```

去掉默认 filelist 里 `tests/*` 与 `tb/*` 行，换成你自己的 test 与 tb。

### 步骤 2：自有 tb_top（以 64-bit、单流、无 tstrb 为例，参数包 `#(64,1,1,1,0,1,1)`）

```systemverilog
`timescale 1ns/1ps
`include "axis_params.svh"

module tb_top;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axis_pkg::*;

  logic aclk = 0, aresetn;
  always #5 aclk = ~aclk;
  initial begin aresetn = 0; repeat(10) @(posedge aclk); aresetn = 1; end

  // 接口实例：参数包须与 env/vif typedef 完全一致
  axis_if #(64,1,1,1,0,1,1) axis_in (.aclk(aclk), .aresetn(aresetn));

  // 接 DUT（按你的端口名连）
  my_dut dut (
    .aclk(aclk), .aresetn(aresetn),
    .s_tvalid(axis_in.tvalid), .s_tready(axis_in.tready),
    .s_tdata (axis_in.tdata),  .s_tlast (axis_in.tlast),
    .s_tuser (axis_in.tuser)
    // tkeep/tid/tdest 按需连接
  );

  // 协议检查：无参 module，宽度自适应
  axis_protocol_checker_sva chk (.aif(axis_in));

  typedef virtual axis_if #(64,1,1,1,0,1,1) my_vif_t;
```

vif 下发**两种写法，按拓扑选用**：

#### 写法 A：单接口全环境 —— 一条通配（最简）

适用：master / slave / checker / handler 全部挂在**同一个**接口上（如本例只有一个 `axis_in`）。

```systemverilog
  initial begin
    uvm_config_db#(my_vif_t)::set(null, "uvm_test_top.env.*", "vif", axis_in);
  end
endmodule
```

`env.*` 匹配 env 下所有需要 `vif` 的子组件，全部拿同一接口。

#### 写法 B：显式逐路径（最清晰、可分接口）

适用：master 与 slave 接**不同**接口（典型 DUT：输入口 + 输出口），或想显式控制每个组件。

```systemverilog
  initial begin
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.master_agent*","vif",axis_in);
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.slave_agent*", "vif",axis_in);
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.rst_handler",  "vif",axis_in);
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.proto_checker","vif",axis_in);
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.bw_checker",   "vif",axis_in);
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.phase_ctrl",   "vif",axis_in);
    uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.cov",          "vif",axis_in);
  end
endmodule
```

env 的 7 个子组件实例名：`master_agent` / `slave_agent` / `rst_handler` / `proto_checker` / `bw_checker` / `phase_ctrl` / `cov`。

#### 双接口拓扑（输入口 + 输出口）—— 写法 B 变体

```systemverilog
  // 默认全给输入接口，slave_agent 单独改输出接口
  uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.*",            "vif", in_if);
  uvm_config_db#(my_vif_t)::set(null,"uvm_test_top.env.slave_agent*", "vif", out_if);
```

> **优先级提示**：双接口下 `env.*` 与 `env.slave_agent*` 对 slave 都匹配，靠 UVM config_db 优先级裁决（更具体路径胜）。保险起见把 slave 那条写明确，或干脆全部显式逐路径（写法 B）。单接口（写法 A）无此问题。

### 步骤 3：自有 test

参照 `tests/axis_base_test.sv`。env 用与参数包一致的 typedef，cfg 与参数包对齐：

```systemverilog
class my_test extends uvm_test;
  `uvm_component_utils(my_test)

  typedef axis_env #(64,1,1,1,0,1,1) env_t;   // 与 tb 参数包一致
  env_t env;
  axis_config m_cfg, s_cfg;

  function new(string n, uvm_component p); super.new(n,p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    m_cfg = axis_config::type_id::create("m_cfg");
    s_cfg = axis_config::type_id::create("s_cfg");

    // 与参数包对齐
    m_cfg.TDATA_WIDTH = 64; m_cfg.HAS_TSTRB = 0; m_cfg.TUSER_WIDTH = 1;
    s_cfg.TDATA_WIDTH = 64; s_cfg.HAS_TSTRB = 0; s_cfg.TUSER_WIDTH = 1;

    m_cfg.agent_mode = AXIS_MASTER; m_cfg.is_active = UVM_ACTIVE;
    s_cfg.agent_mode = AXIS_SLAVE;  s_cfg.is_active = UVM_ACTIVE;

    uvm_config_db#(axis_config)::set(this,"env","master_cfg",m_cfg);
    uvm_config_db#(axis_config)::set(this,"env","slave_cfg", s_cfg);

    env = env_t::type_id::create("env", this);
  endfunction
endclass
```

### 集成铁律

- **参数包三处一致**：tb 里 `axis_if` 实例、`axis_env` typedef、`virtual axis_if` (vif) typedef 的 7 个参数必须完全相同。
- **cfg 跟参数包对齐**：`TDATA_WIDTH / TUSER_WIDTH / HAS_TSTRB / HAS_TKEEP / HAS_TLAST` 等运行期字段须与参数包一致。

---

## 4. axis_config 配置参考

每个 agent 一个 `axis_config`，test 里 create 后通过 `uvm_config_db#(axis_config)::set(this,"env","master_cfg"/"slave_cfg", cfg)` 下发。

### 位宽 / 可选信号（须与参数包对齐）

| 字段 | 默认 | 说明 |
|------|------|------|
| `TDATA_WIDTH` | 32 | 数据位宽，`get_byte_lanes()` = TDATA/8 |
| `TID_WIDTH` / `TDEST_WIDTH` / `TUSER_WIDTH` | 4 / 4 / 1 | 路由 / 边带宽度 |
| `HAS_TSTRB` | 1 | 0 时 driver 不驱 tstrb、约束放开 |
| `HAS_TKEEP` | 1 | 0 时按全字节有效处理 |
| `HAS_TLAST` | 1 | 0 时用 `pkt_boundary_mode` 定包边界 |

### Agent 模式

| 字段 | 取值 |
|------|------|
| `agent_mode` | `AXIS_MASTER` / `AXIS_SLAVE` / `AXIS_MONITOR_ONLY` |
| `is_active` | `UVM_ACTIVE` / `UVM_PASSIVE` |
| `slave_drive_mode` | `SLAVE_AUTO`（driver 自动响应 ready）/ `SLAVE_SEQ_DRIVEN`（ready 由 sequence 驱动） |

### Master 发送节奏（valid 生成）— 详见 §8

| 字段 | 说明 |
|------|------|
| `valid_gen_mode` | `VALID_ZERO_IDLE` / `VALID_FIXED_IDLE` / `VALID_RANDOM_IDLE` / `VALID_WEIGHTED` / `VALID_BURST_PAUSE` / `VALID_PROFILE` |
| `idle_cycles` / `idle_min` / `idle_max` | 固定 / 随机 idle 周期 |
| `valid_weight` | 加权模式 valid 占比（%） |
| `burst_len` / `pause_len` | burst-pause 模式突发 / 暂停长度 |
| `valid_profile[$]` | profile 模式分段序列（`axis_valid_profile_entry_t`） |

### Slave 背压（ready 生成）— 详见 §8

| 字段 | 说明 |
|------|------|
| `ready_gen_mode` | `READY_ALWAYS` / `READY_BEFORE_VALID` / `READY_WITH_VALID` / `READY_AFTER_VALID` / `READY_WEIGHTED` / `READY_TOGGLE` / `READY_PROFILE` |
| `ready_delay` / `ready_delay_min` / `ready_delay_max` | ready 延迟 |
| `ready_advance_cycles` | 提前拉 ready 周期数 |
| `ready_weight` | 加权模式 ready 占比（%） |
| `ready_high` / `ready_low` | toggle 模式高 / 低周期 |
| `ready_profile[$]` | profile 模式分段序列 |

### 包边界（无 TLAST 时）

| 字段 | 说明 |
|------|------|
| `pkt_boundary_mode` | `PKT_BOUNDARY_TLAST` / `PKT_BOUNDARY_TIMEOUT` / `PKT_BOUNDARY_FIXED_LEN` |
| `pkt_boundary_timeout_cycles` | timeout 模式空闲超时周期 |
| `pkt_boundary_fixed_length` | fixed-len 模式固定包长（beat 数） |

### 带宽检查 / 复位 / 协议检查

| 字段 | 说明 |
|------|------|
| `bw_check_enable` / `bw_window_cycles` / `bw_min_threshold` / `bw_max_threshold` / `bw_profile[$]` | 带宽检查，详见 §8 |
| `reset_polarity` / `reset_sync_mode` / `hot_reset_enable` | 复位行为，详见 §9 |
| `checker_cfg`（`axis_protocol_checker_config`） | 逐项协议检查使能，详见 §10 |

### 运行期重配置

修改字段后调用 `cfg.notify_config_changed()` 触发 `config_changed` 事件，让组件在运行中切换行为（带宽扫描即用此机制，见 §8）。

---

## 5. 激励与约束

### transaction 字段（`axis_transfer`）

`tdata / tstrb / tkeep / tlast / tid / tdest / tuser / delay` 全为 `rand`。容器宽度固定为 `AXIS_MAX_*`（512/512/16/16），**实际有效宽度由 `cfg` 约束钳制**。

### 内置约束（仅在调用 `tr.randomize()` 时生效）

| 约束 | 作用 |
|------|------|
| `c_data_width` / `c_strb_width` / `c_keep_width` | 把 tdata/tstrb/tkeep 钳到 `cfg.TDATA_WIDTH` / `get_byte_lanes()` 内 |
| `c_tid_width` / `c_tdest_width` / `c_tuser_width` | 把 tid/tdest/tuser 钳到对应 cfg 宽度内 |
| `c_tkeep_tstrb` | `HAS_TSTRB && HAS_TKEEP` 时强制 `(tstrb & ~tkeep)==0`（合法性） |
| `c_keep_default` | soft：tkeep 默认全字节有效（按 byte lanes） |
| `c_strb_default` | soft：tstrb 默认等于 tkeep |
| `c_delay` | delay ∈ [0:20] |

### 两种驱动风格（重要区别）

**风格 1 — `randomize() with {}`**（推荐，约束自动生效）

```systemverilog
start_item(tr);
if (!tr.randomize() with { tlast == 1; tid == 0; })
    `uvm_error(get_type_name(), "rand failed");
finish_item(tr);
```
此风格下所有 `c_*_width` 约束运行，字段自动钳到 cfg 宽度。

**风格 2 — 直接赋值**（绕过 `randomize`，调用者负责合法性）

```systemverilog
start_item(tr);
tr.tdata = data; tr.tkeep = keep; tr.tlast = 1; tr.tid = 0;  // 不调 randomize
finish_item(tr);
```
`axis_single_transfer_seq` / `axis_idle_seq` 用此风格。**注意**：未调 `randomize` 时 transfer 的宽度约束不运行，赋值超宽要自己保证不溢出。

---

## 6. 内置 sequence 详解（举例）

所有 sequence 继承 `axis_base_seq`（自动从 sequencer 取 `cfg`，提供 `should_stop()` 复位感知）。启动方式：`seq.start(env.master_agent.sqr)`。

### 6.1 单拍传输 `axis_single_transfer_seq`

直接赋值风格，发 1 个 beat。字段：`data/strb/keep/last/id/dest/user/delay`（均 rand，可约束）。

```systemverilog
axis_single_transfer_seq s;
s = axis_single_transfer_seq::type_id::create("s");
if (!s.randomize() with { data == 64'hDEAD_BEEF; last == 1; id == 0; delay == 2; })
    `uvm_error(get_type_name(),"rand failed");
s.start(env.master_agent.sqr);
```

### 6.2 单包多拍 `axis_packet_seq`

发一个完整包（`packet_length` 个 beat，末拍自动 tlast=1，全程同一 tid/tdest）。`data_pattern`：0=随机 / 1=递增 / 2=全 0 / 3=全 1。

```systemverilog
axis_packet_seq p;
p = axis_packet_seq::type_id::create("p");
if (!p.randomize() with {
      packet_length == 32;
      packet_tid == 0; packet_tdest == 0;
      inter_beat_delay == 0;
      data_pattern == 1;          // 递增数据
}) `uvm_error(get_type_name(),"rand failed");
p.start(env.master_agent.sqr);
```

### 6.3 多包突发 `axis_burst_seq`

连发 `num_packets` 个包，每包长度在 `[min_pkt_len:max_pkt_len]` 随机，全部同一 tid/tdest。

```systemverilog
axis_burst_seq b;
b = axis_burst_seq::type_id::create("b");
if (!b.randomize() with {
      num_packets == 16; min_pkt_len == 1; max_pkt_len == 64;
      burst_tid == 0; burst_tdest == 0;
}) `uvm_error(get_type_name(),"rand failed");
b.start(env.master_agent.sqr);
```

### 6.4 空闲 `axis_idle_seq`

发一个全 0、`delay = idle_cycles` 的占位 beat，制造空闲间隙。

```systemverilog
axis_idle_seq idle;
idle = axis_idle_seq::type_id::create("idle");
void'(idle.randomize() with { idle_cycles == 50; });
idle.start(env.master_agent.sqr);
```

### 6.5 多流交织 `axis_interleave_seq`

`num_streams` 条流交替发包（每条流 tid=tdest=流号），验证 monitor 按 tid 并行重组。

```systemverilog
axis_interleave_seq ilv;
ilv = axis_interleave_seq::type_id::create("ilv");
if (!ilv.randomize() with {
      num_streams == 4; total_packets == 16; beats_per_switch == 4;
}) `uvm_error(get_type_name(),"rand failed");
ilv.start(env.master_agent.sqr);
```
> 多流场景 TID_WIDTH 须够大（≥ ceil(log2(num_streams))）。

### 6.6 边界 `axis_boundary_seq`

自动覆盖一组边界用例：1-beat 包、全 0 / 全 1 数据、最大 tid、最大 tdest、256-beat 长包。无需参数：

```systemverilog
axis_boundary_seq bnd;
bnd = axis_boundary_seq::type_id::create("bnd");
bnd.start(env.master_agent.sqr);
```

### 6.7 错误注入 `axis_error_inject_seq`

故意制造协议违规，验证 protocol checker 能否抓到。`error_type`：

| 类型 | 注入的违规 |
|------|-----------|
| `ERR_TKEEP_TSTRB_MISMATCH` | tkeep=0 处 tstrb=1（违反 AXIS 规范） |
| `ERR_MID_PACKET_TID_CHANGE` | 同包内两拍 tid 不同 |
| `ERR_ZERO_BYTE_TRANSFER` | tkeep=tstrb=0 全 null 拍 |

```systemverilog
axis_error_inject_seq err;
err = axis_error_inject_seq::type_id::create("err");
void'(err.randomize() with { error_type == ERR_MID_PACKET_TID_CHANGE; });
err.start(env.master_agent.sqr);
```

### 6.8 传输中复位 `axis_reset_during_transfer_seq`

发包过程中可被外部复位打断（`fork ... join_any`），验证复位健壮性。配合复位 vseq 使用（见 §9）。

---

## 7. virtual sequence 与 test 编排（举例）

virtual sequence 继承 `axis_base_vseq`，持有 `master_sqr / slave_sqr / master_cfg / slave_cfg`，可跨 master/slave 协调、做状态机（`transition_to()`）。

### test 里启动 vseq 的标准接线

```systemverilog
task run_phase(uvm_phase phase);
  axis_full_stress_vseq vseq;
  phase.raise_objection(this);
  vseq = axis_full_stress_vseq::type_id::create("vseq");
  vseq.master_sqr = env.master_agent.sqr;   // 必接
  vseq.slave_sqr  = env.slave_agent.sqr;    // 必接
  vseq.master_cfg = master_cfg;
  vseq.slave_cfg  = slave_cfg;
  vseq.start(null);                         // vseq 用 null sequencer
  #200;
  phase.drop_objection(this);
endtask
```

### 内置 virtual sequence

| vseq | 行为 |
|------|------|
| `axis_master_slave_sync_vseq` | master 发 `num_packets` 个定长包，做主从同步 |
| `axis_bandwidth_sweep_vseq` | 扫 valid_weight=100/80/60/40/20%，每档发 burst（运行期重配置，见 §8） |
| `axis_reset_recovery_vseq` | 发包 → 强制复位 → 解复位 → 再发包验证恢复（见 §9） |
| `axis_full_stress_vseq` | 4 阶段：交织 → 背压 → 边界 → burst，综合压力 |

### 综合压力示例（`axis_full_stress_vseq` body 结构）

```systemverilog
// 阶段1 交织
ilv.randomize() with { num_streams==4; total_packets==16; }; ilv.start(master_sqr);
// 阶段2 背压
bp.randomize() with { num_packets==20; pkt_len==32; };      bp.start(master_sqr);
// 阶段3 边界
bnd.start(master_sqr);
// 阶段4 burst
burst.randomize() with { num_packets==16; min_pkt_len==1; max_pkt_len==64; };
burst.start(master_sqr);
```

---

## 8. 带宽与流控控制（举例）

带宽由 **master 的 valid 节奏** 与 **slave 的 ready 节奏** 共同决定，二者经 `axis_bandwidth_controller` 按 cfg 模式逐周期计算。

### 8.1 Master valid 节奏（吞吐控制）

| `valid_gen_mode` | 行为 | 相关字段 |
|------------------|------|---------|
| `VALID_ZERO_IDLE` | 背靠背，无空闲（满吞吐） | — |
| `VALID_FIXED_IDLE` | 每拍后固定空闲 | `idle_cycles` |
| `VALID_RANDOM_IDLE` | 每拍后随机空闲 | `idle_min` / `idle_max` |
| `VALID_WEIGHTED` | 每周期按概率拉 valid | `valid_weight`（%） |
| `VALID_BURST_PAUSE` | 突发 N 拍后停 M 拍 | `burst_len` / `pause_len` |
| `VALID_PROFILE` | 按时间分段切换 | `valid_profile[$]` |

```systemverilog
// 满吞吐
m_cfg.valid_gen_mode = VALID_ZERO_IDLE;

// 60% 吞吐（加权）
m_cfg.valid_gen_mode = VALID_WEIGHTED;
m_cfg.valid_weight   = 60;

// 突发 8 停 4
m_cfg.valid_gen_mode = VALID_BURST_PAUSE;
m_cfg.burst_len = 8; m_cfg.pause_len = 4;
```

### 8.2 Slave ready 节奏（背压控制）

| `ready_gen_mode` | 行为 | 相关字段 |
|------------------|------|---------|
| `READY_ALWAYS` | 永远就绪（无背压） | — |
| `READY_BEFORE_VALID` | valid 前就拉 ready | — |
| `READY_WITH_VALID` | 见 valid 同拍拉 ready | — |
| `READY_AFTER_VALID` | valid 后延迟拉 ready | `ready_delay_min` / `ready_delay_max` |
| `READY_WEIGHTED` | 每周期按概率拉 ready | `ready_weight`（%） |
| `READY_TOGGLE` | 高 N 拍 / 低 M 拍周期翻转 | `ready_high` / `ready_low` |
| `READY_PROFILE` | 按时间分段切换 | `ready_profile[$]` |

```systemverilog
// 强背压：valid 后延迟 2~10 拍才 ready
s_cfg.ready_gen_mode  = READY_AFTER_VALID;
s_cfg.ready_delay_min = 2; s_cfg.ready_delay_max = 10;

// 周期性背压：ready 高 4 拍、低 2 拍
s_cfg.ready_gen_mode = READY_TOGGLE;
s_cfg.ready_high = 4; s_cfg.ready_low = 2;
```

### 8.3 分段 profile（时间轴上切换节奏）

```systemverilog
m_cfg.valid_gen_mode = VALID_PROFILE;
m_cfg.valid_profile.push_back('{start_cycle:0,   end_cycle:999,  mode:VALID_ZERO_IDLE,
                                idle_cycles:0, idle_min:0, idle_max:0,
                                valid_weight:100, burst_len:8, pause_len:4});
m_cfg.valid_profile.push_back('{start_cycle:1000,end_cycle:2000, mode:VALID_WEIGHTED,
                                idle_cycles:0, idle_min:0, idle_max:0,
                                valid_weight:30, burst_len:8, pause_len:4});
```

### 8.4 带宽检查

```systemverilog
m_cfg.bw_check_enable  = 1;
m_cfg.bw_window_cycles = 500;
m_cfg.bw_min_threshold = 0.1;    // 窗口内利用率下限
m_cfg.bw_max_threshold = -1.0;   // <0 表示不设上限
```
`axis_bandwidth_checker` 在窗口内统计利用率，越界报错。

### 8.5 运行期带宽扫描（`notify_config_changed`）

```systemverilog
foreach (weights[i]) begin
  master_cfg.valid_gen_mode = VALID_WEIGHTED;
  master_cfg.valid_weight   = weights[i];
  master_cfg.notify_config_changed();   // 通知组件切换
  burst.randomize() with { num_packets==8; min_pkt_len==16; max_pkt_len==16; };
  burst.start(master_sqr);
end
```

---

## 9. 复位功能（举例）

### 配置

```systemverilog
m_cfg.reset_polarity   = AXIS_RESET_ACTIVE_LOW;   // 或 ACTIVE_HIGH
m_cfg.reset_sync_mode  = AXIS_RESET_SYNC;         // 或 ASYNC
m_cfg.hot_reset_enable = 1;                       // 允许传输中热复位
```

### 复位感知（组件级，直接采样 aresetn）

数据通路组件除响应 env 级 `axis_reset_handler` 翻转的软标志外，**还直接采样 `vif.aresetn`**（按 `cfg.reset_polarity` 判定有效电平）：

- `axis_master_driver`：复位有效期间不拉 `tvalid`；解复位后第一拍前对齐到时钟沿再驱动（见 §12 首拍对齐）。
- `axis_slave_driver`：复位有效期间压低 `tready`。
- `axis_monitor`：复位有效期间不采样，避免抓到复位中的垃圾拍。
- `axis_bandwidth_checker`：复位期间清空当前统计窗口，避免复位周期稀释带宽、误报 `BW_MIN`。

**外部集成意义**：即使你**不实例化 / 不接 `rst_handler`**（自有 tb 自管复位），上述组件也能据 `aresetn` 自行门控，不会在复位中误驱动或误采样。

### 复位恢复 vseq（`axis_reset_recovery_vseq`）

流程：发 `pre_reset_packets` → 强制复位 `reset_duration_cycles` → 解复位 → 发 `post_reset_packets`，并走状态机 `NORMAL → RECOVERY → DONE`。

```systemverilog
rst_vseq.master_sqr = env.master_agent.sqr;
rst_vseq.slave_sqr  = env.slave_agent.sqr;
rst_vseq.master_cfg = master_cfg;
rst_vseq.vif        = vif;                  // 需要 vif 取时钟
rst_vseq.randomize() with {
  pre_reset_packets == 4; post_reset_packets == 4; reset_duration_cycles == 10; };
rst_vseq.start(null);
```

> **外部集成关键**：该 vseq 用 `uvm_hdl_force("tb_top.aresetn", ...)` 强制复位线，**层次路径写死为 `tb_top.aresetn`**。若你的顶层模块名/复位信号名不同，需改这个路径，否则 force 失败。

### Phase jump（drain 验证，`axis_phase_controller`）

```systemverilog
env.phase_ctrl.request_phase_jump(phase, phase);   // 跳回自身，触发 drain
```

---

## 10. 协议检查与错误注入（举例）

### SVA 协议检查（`axis_protocol_checker_sva`）

tb 里 bind 到接口（无参，宽度自适应）：

```systemverilog
axis_protocol_checker_sva chk (.aif(axis_in));
```

### 逐项使能（`cfg.checker_cfg`）

`axis_protocol_checker_config` 含各项开关：tvalid 稳定性、tdata 稳定性、tlast 完整性、tid/tdest 一致性、tkeep/tstrb 关系、复位检查、X/Z 检查、握手超时（`chk_handshake_timeout_cycles`）等。按需置位即可。

### 用错误注入验证 checker

发 `axis_error_inject_seq`（见 §6.7），制造违规，确认 checker 报出对应 UVM_ERROR。

---

## 11. 运行测试

```bash
cd axis_vip/sim

# 单测（默认 VCS）
make run TEST=axis_sanity_test SEED=random VERBOSITY=UVM_MEDIUM

# 切工具
make run TEST=axis_sanity_test TOOL=xcelium    # 或 questa

# 回归（7 个内置测试）
make regression

# 首拍对齐回归（验证未对齐零延时不丢首拍，见 §12）
make run TEST=axis_misalign_test

# 清理
make clean
```

> `axis_misalign_test`：故意让首个 sequence item 在非时钟沿到达（`#203` 偏 3ns）且零延时驱动，统计 master monitor 实抓拍数 == 序列意图拍数（16）。**注意**：loopback + monitor 比对的 scoreboard 看不到"均匀丢拍"（master/slave 同步丢仍 match），故此测试改用"意图 vs master monitor 实抓"计数来暴露首拍吞没。

外部集成时把 `FILELIST` 指向你的 filelist（编辑 Makefile 的 `FILELIST` 变量，或自建 Makefile 复用相同选项）。

### 判定 PASS

`run.log` 中：

- `UVM_ERROR` = 0 且 `UVM_FATAL` = 0
- scoreboard summary：`mismatches 0` 且 master/slave `pending 0`

### 写自有测试模板

```systemverilog
class my_traffic_test extends my_test;   // 继承 §3 的 my_test
  `uvm_component_utils(my_traffic_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // 按需调流控：60% 吞吐 + toggle 背压
    m_cfg.valid_gen_mode = VALID_WEIGHTED; m_cfg.valid_weight = 60;
    s_cfg.ready_gen_mode = READY_TOGGLE;   s_cfg.ready_high = 4; s_cfg.ready_low = 2;
  endfunction

  task run_phase(uvm_phase phase);
    axis_burst_seq b;
    phase.raise_objection(this);
    b = axis_burst_seq::type_id::create("b");
    void'(b.randomize() with { num_packets == 10; min_pkt_len == 8; max_pkt_len == 32;
                               burst_tid == 0; burst_tdest == 0; });
    b.start(env.master_agent.sqr);
    #500;
    phase.drop_objection(this);
  endtask
endclass
```

---

## 12. 已知边界与陷阱

- **straddle 类测试需 `DATA_WIDTH >= 256`**：低于该宽度时 env 配置校验会主动 FATAL（设计如此）。
- TID/TDEST/TUSER 无 HAS_* 开关，单流务必固定其值，避免 monitor 误拆流；多流则保证 TID_WIDTH 够大。
- TUSER 不进 scoreboard 比对，作为边带流控信号时只能在激励侧生成，需自行校验。
- 直接赋值风格的 seq（single_transfer / idle）绕过宽度约束，赋值不要超 cfg 宽度。
- `axis_reset_recovery_vseq` 的 `uvm_hdl_force` 路径写死 `tb_top.aresetn`，外部 tb 顶层名/信号名不同需改。
- **首拍对齐**：sequence item 经 sequencer 交给 master driver 的时刻**未必对齐时钟上升沿**；零延时（`VALID_ZERO_IDLE` / `inter_beat_delay==0`）下，未对齐会导致首拍 `tvalid` 落在非沿时刻而被吞。`axis_master_driver` 在每次"从空闲起步"（`tvalid` 当前为低）时会先对齐到时钟沿再驱动；背靠背（`tvalid` 已高）则跳过，不插气泡、不损满吞吐。回归由 `axis_misalign_test` 守护。
- **丢拍的可观测性**：loopback 拓扑下若首拍根本未驱动，master monitor 与 slave 会**同样**漏掉它，scoreboard 仍判 match —— 看不出丢拍。要检出须比"序列意图拍数 vs master monitor 实抓拍数"（见 `axis_misalign_test`）。
- 调试参考 `axis_vip/docs/vcs_debug_guide.md`。
