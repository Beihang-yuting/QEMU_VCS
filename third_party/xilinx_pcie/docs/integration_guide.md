# Xilinx PCIe 接口 Adapter 集成与使用指南

本文档说明如何把 `xilinx_pcie` 接入仿真环境并使用。**自 adapter 化重构起**，本项目已收敛为**纯 Xilinx 接口 adapter**：只负责 PG213 的 4 通道 AXI-Stream（RQ/RC/CQ/CC）⟷ 抽象 `pcie_tl_tlp` 的编解码与通道路由；所有协议逻辑（agent / driver / EP 自动响应 / completion 追踪 / seq 库 / scoreboard）全部委托外部 `pcie_tl_vip`。旧的 **xilinx 侧**多 agent 协议栈 / 老 WIRE_RC-WIRE_EP 宏 / xilinx scoreboard 已删除;多 agent 能力现由上游 `pcie_tl_env` 的 `num_rc`/`num_ep` 提供(见 §2.3),配套新的按下标连线宏 `XILINX_ADAPTER_WIRE_RC/EP`。

> 设计原理（adapter 子类吸收、codec / tuser / straddle、SV_IF 模式、与 pcie_tl_vip 的接缝）见
> `docs/superpowers/specs/2026-06-29-xilinx-adapter-mode-design.md` 与实现计划
> `docs/superpowers/plans/2026-06-29-xilinx-adapter-mode.md`。本文只讲**怎么用**。

---

## 目录

1. [架构](#1-架构)
2. [接入用法](#2-接入用法)
3. [激励与端到端校验](#3-激励与端到端校验)
4. [构建与运行](#4-构建与运行)
5. [依赖](#5-依赖)
6. [已知限制（诚实记录）](#6-已知限制诚实记录)
7. [回归矩阵](#7-回归矩阵)

---

## 1. 架构

`xilinx_pcie` 的唯一职责是 Xilinx 帧 ⟷ `pcie_tl_tlp` 的双向转换。核心组件：

```
class xilinx_pcie_if_adapter extends pcie_tl_if_adapter
```

通过**工厂覆盖**装进上游 `pcie_tl_env`，替换其基类 adapter。一个 adapter 实例服务一个 pcie_tl agent（`rc_adapter` / `ep_adapter`），内部包 4 个 `axis_agent`（按 PG213 各通道 TUSER 宽度参数化），并吸收原 driver/monitor 的编解码逻辑：

- `send(tlp)`（override）：`router.get_tx_channel(tlp)` 选通道 → `encode_descriptor` + straddle 打包 + 逐 beat `encode_tuser_for_beat` → 经该通道 **MASTER** agent 的 sequencer 驱 AXIS（阻塞、串行）。
- `receive(tlp)`（override）：**非阻塞** pop `rx_queue`（空返回 null）。
- 4 个 axis monitor 的 `packet_ap` 回调 `decode_packet(pkt, ch)` → `pcie_tl_tlp` → `rx_queue.push_back`。**只连 SLAVE（接收方向）通道**，故 adapter 不会重摄自己发出的 TLP。

role 由实例名（`rc_adapter*` / `ep_adapter*`）判定，决定各通道 master/slave 方向（`make_axis_config`）：

| role | MASTER（驱动 / send） | SLAVE（采样 / receive→rx_queue） |
|---|---|---|
| RC | RC（完成）、CQ（请求） | RQ（收到请求）、CC（收到完成） |
| EP | RQ（请求）、CC（完成） | CQ（收到请求）、RC（收到完成） |

### 数据流（端到端，1RC+1EP MRd 为例，参 spec §4.4）

```
RC seq → rc_agent.sequencer → base_driver.send_tlp(MRd)
  → tag/ordering/FC → codec.encode(BW计数) → rc_adapter.send(MRd)
  → router: MRd=request,RC → CQ 通道(MASTER) → desc/tuser/straddle 编码 → 驱 CQ AXIS
        ↓ (物理总线 cq_bus: RC.cq_agent MASTER ↔ EP.cq_agent SLAVE)
EP cq_agent.monitor → axis_packet → ep_adapter.cq_imp → decode_packet → pcie_tl_tlp(MRd) → ep rx_queue
  → ep base_monitor.receive() pop → 协议检查 → tlp_ap → (pcie_tl_vip ep_driver 自动响应)
  → ep_driver 生成 CplD → ep base_driver.send_tlp(CplD) → ep_adapter.send(CplD)
  → router: CC 通道(MASTER) → 编码 → 驱 CC AXIS
        ↓ (物理总线 cc_bus: EP.cc_agent MASTER ↔ RC.cc_agent SLAVE)
RC cc_agent.monitor → axis_packet → rc_adapter.cc_imp → decode_packet → CplD → rc rx_queue
  → rc base_monitor.receive() pop → pcie_tl_vip 释放 tag/outstanding
```

每通道是**一条共享 `axis_if` 总线**：同一 vif 同时注册到 RC 与 EP 两侧的 `<ch>_agent`，一端 MASTER 一端 SLAVE。

---

## 2. 接入用法

### 2.1 test：工厂覆盖 + env_config

在 test 的 `build_phase` 顶部把上游基类 adapter 覆盖为 Xilinx 子类，并把 env 设为 SV 接口模式（关掉 TLM loopback）：

```systemverilog
class xilinx_pcie_adapter_base_test extends uvm_test;
  pcie_tl_env        env;
  pcie_tl_env_config cfg;

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    // 关键：把 pcie_tl_if_adapter 工厂覆盖为 Xilinx 子类
    pcie_tl_if_adapter::type_id::set_type_override(
        xilinx_pcie_if_adapter::get_type());

    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.if_mode          = SV_IF_MODE;   // 关 env TLM loopback，走 SV 接口
    cfg.rc_agent_enable  = 1;
    cfg.ep_agent_enable  = 1;
    cfg.switch_enable    = 0;
    cfg.ep_auto_response = 1;            // EP 自动回 CplD
    cfg.infinite_credit  = 1;            // SV_IF 模式无 FC 补充路径
    cfg.scb_enable       = 0;            // 上游 scoreboard 依赖 TLM loopback，SV_IF 下不可用
    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

    env = pcie_tl_env::type_id::create("env", this);
  endfunction
endclass
```

> env 用上游 `pcie_tl_env`（**不是** xilinx env）。adapter 实例名由上游固定为 `rc_adapter` / `ep_adapter`，role 据此判定，无需额外配置。

### 2.2 tb：用 `XILINX_ADAPTER_WIRE` 宏注册 4 通道 vif

tb（`tb/tb_adapter_top.sv`）声明 4 条共享总线，再用宏把每条 vif 注册到两侧 adapter 内的 `<ch>_agent`。时钟 250 MHz、低有效复位；时钟门控在 `g_xilinx_adapter_quiesce`（`extract_phase` 置位）上，UVM run_phase 一结束即停钟，避免判决后 axis 线程刷屏。

```systemverilog
// 4 条共享通道总线（TUSER 宽度按 PG213 通道）
axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rq_bus(.aclk(clk),.aresetn(rst_n));
axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc_bus(.aclk(clk),.aresetn(rst_n));
axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) cq_bus(.aclk(clk),.aresetn(rst_n));
axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) cc_bus(.aclk(clk),.aresetn(rst_n));

initial begin
  `XILINX_ADAPTER_WIRE(rq, RQ, rq_bus)
  `XILINX_ADAPTER_WIRE(rc, RC, rc_bus)
  `XILINX_ADAPTER_WIRE(cq, CQ, cq_bus)
  `XILINX_ADAPTER_WIRE(cc, CC, cc_bus)
  run_test();
end
```

宏（`tb/xilinx_adapter_connect.svh`）把同一 vif `set` 到 `uvm_test_top.env.rc_adapter*.<ch>_agent*` 与 `ep_adapter*.<ch>_agent*` 两处。master/slave 区分由 adapter 的 `make_axis_config` 按 role+channel 决定，tb 不必区分方向。

### 2.3 多 agent（任意 N RC + M EP，无 switch）+ 对接真实 DUT

上游 `pcie_tl_env` 支持任意数量**独立** agent（非 switch）：`cfg.num_rc` / `cfg.num_ep`（默认 1）。**=1 时沿用旧的无下标名** `rc_adapter` / `ep_adapter`（1RC+1EP 完全向后兼容）；**>1 时建 `rc_adapter_<i>` / `ep_adapter_<i>`**，每个 adapter 有自己独立的 4 通道 link，互不共享。关掉某一类用 `*_agent_enable=0`。

```systemverilog
cfg.if_mode         = SV_IF_MODE;
cfg.rc_agent_enable = 1;
cfg.ep_agent_enable = 0;
cfg.num_rc          = 2;   // N 个独立 RC host link
cfg.num_ep          = 0;   // M 个独立 EP link
cfg.switch_enable   = 0;   // 非 switch；switch 模式下 EP 数由 switch_cfg.num_ds_ports 决定，num_ep 被忽略
```

每个 indexed adapter 用按下标连线宏连自己的 4 条总线（tb 内为每个 link 声明 4 条 `axis_if`）：

```systemverilog
`XILINX_ADAPTER_WIRE_RC(0, rc0_rq, rc0_rc, rc0_cq, rc0_cc)   // BFM host  -> 真实 EP DUT #0
`XILINX_ADAPTER_WIRE_RC(1, rc1_rq, rc1_rc, rc1_cq, rc1_cc)   //                          #1
`XILINX_ADAPTER_WIRE_EP(0, ep0_rq, ep0_rc, ep0_cq, ep0_cc)   // BFM EP    -> 真实 Root/host
```

参考 tb：`tb/tb_adapter_multirc_top.sv`（2 RC host）、`tb/tb_adapter_multiep_top.sv`（2 EP）。

#### 对接真实 DUT（bypass 硬 IP）：角色决定要不要翻译层

真实单个 Xilinx 器件自己的 4 个 pin（器件视角，方向固定）：RQ=出 / RC=入 / CQ=入 / CC=出。BFM 各 role 的 pin 方向与之对比：

| | RQ | RC | CQ | CC | 与真实器件 |
|---|---|---|---|---|---|
| 真实器件自身 | 出 | 入 | 入 | 出 | — |
| **BFM RC-role** | 入 | 出 | 出 | 入 | **镜像**（方向相反、格式同名） |
| BFM EP-role | 出 | 入 | 入 | 出 | 相同（非镜像） |

- **BFM 当 host、DUT 是真实 EP** → BFM 用 **RC-role**（`num_rc=N`）。RC-role pin 是真实器件的镜像，**4 通道同名直连**（BFM.RQ←DUT.RQ、BFM.RC→DUT.RC、BFM.CQ→DUT.CQ、BFM.CC←DUT.CC），格式一一对上，**零描述符翻译**。推荐做法。
- **BFM 当 EP、DUT 是真实 Root/host** → BFM-EP 发 RQ、DUT 在 CQ 收，格式不同（RQ-desc ≠ CQ-desc），同名连会两个 master 打架；需 **RQ↔CQ / RC↔CC 交叉 + 描述符翻译层**（真实硬 IP 干的那一层）——这是额外新代码，当前 adapter 不含。

> 4 通道 TUSER 宽度各异（DW=64：RQ=62 / RC=75 / CQ=88 / CC=33），任何 RQ↔CQ 或 RC↔CC 交叉都需翻译；RC-role 同名直连不跨格式，故免翻译。
> **no-DUT smoke**：总线开路无 `tready` 源，active RC 不能驱流，仅做 build/connect/elaborate + idle 探测（见 `multirc_noep_test` / `multiep_norc_test`）。真实激励在 DUT（或 loopback）提供 `tready` 后，于 `env.rc_agents[i].sequencer` 上 start。

---

## 3. 激励与端到端校验

### 3.1 用 pcie_tl_vip 的 seq 库

激励不再用 xilinx 自己的 seq——直接复用上游 `pcie_tl_vip` 的 seq / vseq 库，在 `env.v_seqr`（virtual sequencer）或 `env.rc_agent.sequencer` 上 start。常用：

| vseq / seq | 场景 |
|---|---|
| `pcie_tl_rc_ep_rdwr_vseq` | posted MemWr + 非 posted MemRd（→CplD） |
| `pcie_tl_enum_then_dma_vseq` | Config 枚举（CfgWr/CfgRd）+ DMA Mem burst |
| `pcie_tl_backpressure_vseq` | 背靠背 posted MemWr 串流压测 |
| `pcie_tl_mem_wr_seq` / `pcie_tl_mem_rd_seq` | 单笔 MWr / MRd（base_test PoC 用） |
| `pcie_tl_err_poisoned_seq` | 注入 poisoned（EP=1）MemWr（诊断用） |

示例（薄 wrapper test）：

```systemverilog
class xilinx_pcie_adapter_rdwr_test extends xilinx_pcie_adapter_base_test;
  task run_phase(uvm_phase phase);
    pcie_tl_rc_ep_rdwr_vseq rd;
    phase.raise_objection(this);
    rd = pcie_tl_rc_ep_rdwr_vseq::type_id::create("rd");
    rd.addr = 64'h1_0000_0000; rd.length = 8; rd.is_read = 1;
    rd.start(env.v_seqr);
    #5000ns;                      // drain：等 EP CplD 回完
    phase.drop_objection(this);
  endtask
endclass
```

### 3.2 薄 `xilinx_pcie_e2e_checker` 做 req↔cpl 匹配

上游 scoreboard 的 completion 匹配靠 `register_pending()`，**仅在 env 的 TLM loopback 路径运行**（SV_IF 模式关），故本 repo 提供薄 checker（`src/check/xilinx_pcie_e2e_checker.sv`）做端到端校验：

- tap 点（在 test 的 `connect_phase` 接）：
  - `req_imp ← env.ep_agent.monitor.tlp_ap`（completer 侧收到的请求）
  - `cpl_imp ← env.rc_agent.monitor.tlp_ap`（requester 侧返回的完成）
- 按 **tag** 把非 posted 请求与其返回的 completion 配对，校验 completion 的 `byte_count` 回显请求长度。
- 判据计数：`n_matched / outstanding / n_unmatched / n_mismatch`（如 `1/0/0/0`）。posted 写无完成，故 `n_req=0`。
- **范围仅 TLP 级**，不做 PG213 协议判定。

base_test 已建好 `e2e_chk` 并接好 tap；自写 test 继承即可。EP 自动响应在 SV_IF 模式下由 base_test 的 `xilinx_adapter_poc_responder`（订阅 `ep_agent.monitor.tlp_ap` → `ep_driver.handle_request`）再接出来，因为 TLM loopback 关闭后上游不会自动驱动 EP 响应。

---

## 4. 构建与运行

### filelist 与编译参数

仿真用 `sim/filelist_adapter.f`，顺序：axis_vip（lib filelist）→ host_mem → pcie_tl_vip（`pcie_tl_if.sv` + `pcie_tl_pkg.sv`）→ 本 repo `xilinx_pcie_params.svh` + `xilinx_pcie_adapter_pkg.sv` + 接口 → 新 tb/tests。

编译期 `+define+` 参数（`src/xilinx_pcie_params.svh`）：

| 宏 | 默认 | 说明 |
|----|------|------|
| `DATA_WIDTH` | 256 | AXI-Stream 数据位宽，合法 **64/128/256/512**，须与真实 PCIe IP 一致 |
| `STRADDLE_EN` | 0 | straddle 使能，仅 `DATA_WIDTH ≥ 256` 有效；adapter 由 `+STRADDLE_EN` 运行期 plusarg 采样接入 straddle 引擎 |

### 远程 VCS 构建（`10.11.10.61:/tmp/xbuild`）

VCS 只在远程 `ryan@10.11.10.61:2222`（构建根 `/tmp/xbuild`，`filelist_adapter.f` 路径硬编码到此根）。改文件后先 rsync 到 `/tmp/xbuild` 对应路径再编译：

```bash
ssh -p 2222 ryan@10.11.10.61 'source ~/set-env.sh >/dev/null 2>&1
  export TMPDIR=/tmp/xbuild/xilinx_pcie/sim/tmp
  cd /tmp/xbuild/xilinx_pcie/sim && mkdir -p work logs tmp
  vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -full64 -Mdir=csrc_ad \
    -l logs/compile_ad.log -o work/simv_ad -f filelist_adapter.f \
    +define+DATA_WIDTH=256 +define+STRADDLE_EN=0
  ./work/simv_ad +UVM_TESTNAME=xilinx_pcie_adapter_rdwr_test \
    +DATA_WIDTH=256 +STRADDLE_EN=0 +ntb_random_seed=1'
```

> **plusarg 与 define 必须一致**：`+define+DATA_WIDTH=N`（编译期）与 `+DATA_WIDTH=N`（运行期）须相同；STRADDLE 同理（`+STRADDLE_EN` 运行期 plusarg 接入 straddle 引擎）。

可用 test：`xilinx_pcie_adapter_base_test`（mem PoC 基类）/ `_smoke_test` / `_rdwr_test` / `_backpressure_test` / `_enum_dma_test` / `_cfg_test` / `_err_poisoned_test`。多 agent（§2.3）：`_multirc_noep_test`（2 RC host，filelist `filelist_multirc.f`）/ `_multiep_norc_test`（2 EP，filelist `filelist_multiep.f`）。

### 判定 PASS

功能场景 `UVM_ERROR = 0` 且 `UVM_FATAL = 0`，且 e2e checker 计数符合预期（如 `1 matched / 0 outstanding / 0 unmatched / 0 mismatch`）。错误注入 / 诊断场景按其自身判据。

---

## 5. 依赖

| 依赖 | 提供 | 备注 |
|---|---|---|
| `pcie_work/pcie_tl_vip` | 协议层全部（agent/driver/monitor/env/seq/scoreboard/base adapter） | 外部引用，本 repo 不拷贝 |
| `axis_work/axis_vip` | AXI-Stream VIP（`axis_if`/`axis_agent`/driver/monitor/`axis_config`） | adapter 内 4 个 axis_agent 的物理层 |
| `shm_work/host_mem` | 统一内存模型 | filelist 编入 |

**pcie_tl_vip 需两处补丁**（已提交 `pcie_work`，commit `d7f1f3c`，只动 hook/bug、不改协议逻辑）：

1. `pcie_tl_if_adapter::send()` / `receive()` 加 `virtual` —— 否则工厂 override 不分派。
2. `pcie_tl_enum_then_dma_vseq` 的 `max_payload=0` → `chunk=0` 死循环，修为 `max_payload=256`。

> **§2.3 多 agent（num_rc/num_ep）需要 `pcie_work` main 含 reconcile**（PR #5，合并 sha `52ea845`）—— 更早的 commit（含上述 `d7f1f3c`）**没有** `num_rc`/`num_ep`，只能跑单 RC+EP 或 switch 多根。集成多-agent 时把 `pcie_work` 锁到 ≥ 该合并点。
> 上游 pcie_tl_vip 活跃开发（multi-root/pf-vf/link-delay），集成/回归前锁定一个已知能编译的 commit。

---

## 6. 已知限制（诚实记录）

- **描述符位域已按 PG213 官方表逐位校准**（2026-07：RQ Table 2-22 / CQ 2-23 / RC 2-26 / CC 2-27 + config RQ）：
  - `first_be`/`last_be` **不在描述符**，仅经 `s_axis_rq_tuser` / `m_axis_cq_tuser` 携带（此前误放 RQ desc `[111:104]`，占用了 Completer ID 区）。
  - RQ：`[119:104]`=Completer ID、`[120]`=Req ID Enable、`[123:121]`=TC、`[126:124]`=Attr、`[127]`=Force ECRC。
  - CQ：`[111:104]`=Target Function(8b)、`[114:112]`=BAR ID、`[120:115]`=BAR Aperture、`[123:121]`=TC、`[126:124]`=Attr。
  - RC：`[11:0]`=Lower Addr、`[15:12]`=Error Code、`[28:16]`=Byte Count、`[91:89]`=TC、`[94:92]`=Attr。
  - CC 独立于 RC（`encode_cc`/`decode_cc` 不再复用 RC）：`[9:8]`=AT、completer_id 拆 `[79:72]`+`[87:80]`、`[88]`=Completer ID Enable、`[95]`=Force ECRC。
  - 回归守卫：`xilinx_pcie_adapter_codec_test`（纯 codec round-trip + PG213 位置断言，无需 vif/DUT）。
  - **仍待硅上验证**：位域按官方文档核对，尚未对接真实 Xilinx 硬 IP 实测；模型侧受限字段（RC lower_addr 仅 7 位、Completer ID Enable/Req ID Enable 恒 0）见 codec 注释。
- **cfg-read completion 的 `byte_count` 在上游被留 0**：PCIe 把 config-read 的 Byte Count 固定为 4，而上游 ep_driver 把 `cpl.byte_count` 留 0，故 e2e checker 对 `TLP_CFG_RD0/RD1` 完成**豁免** byte_count 校验（仍校验 tag 匹配 + 返回数据，证明送达）。
- **adapter 不做协议判定**：注入的 poisoned / malformed 错误由上游 `pcie_tl_base_monitor` 在 EP 侧 `receive()` 路径处理；adapter 只做忠实编解码。`err_poisoned_test` 是**诊断性**的，不断言 pass，只观察上游 EP monitor 的反应。
- **scoreboard 关闭**：SV_IF 模式下上游 scoreboard（`register_pending` 依赖 TLM loopback）不可用，端到端校验改由薄 `xilinx_pcie_e2e_checker` 承担。

---

## 7. 回归矩阵

DATA_WIDTH ∈ {256, 512}，`+ntb_random_seed=1`，远程 VCS。所有功能场景 `UVM_ERROR=0 / UVM_FATAL=0`：

| 场景 | DW256 | DW512 | checker |
|---|---|---|---|
| adapter mem PoC（`base_test` / `smoke`） | UVM_FATAL=0 | UVM_FATAL=0 | 1 matched |
| rdwr（straddle 0/1） | ✅ | ✅ | 1/0/0/0 |
| backpressure | ✅ | ✅ | 0 req（posted） |
| enum_then_dma | ✅ | ✅ | 1/0/0/0 |
| cfg round-trip | ✅ | ✅ | reg_num round-trips |
| err_poisoned | 上游 EP monitor warning（adapter 不判协议） | 同 | — |
| 多 RC host（`multirc_noep`，2 RC 无 EP，无 DUT） | UVM_ERROR=0（build/idle） | — | 无流（无 tready 源） |
| 多 EP（`multiep_norc`，2 EP 无 RC，无 DUT） | UVM_ERROR=0（build/idle） | — | 无流（无 tready 源） |

> checker 列为 `xilinx_pcie_e2e_checker` 计数 `matched/outstanding/unmatched/mismatch`；backpressure 全 posted 写，无非 posted 请求被追踪（`n_req=0`）。
> 多 agent 两行为 build/connect/elaborate + clean-idle 探测（无 DUT 时无 `tready` 源，active RC 不驱流）；接真实 DUT 后于 `env.rc_agents[i].sequencer` 上起激励。
