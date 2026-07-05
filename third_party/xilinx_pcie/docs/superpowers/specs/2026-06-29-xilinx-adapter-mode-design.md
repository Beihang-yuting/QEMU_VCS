# Xilinx PCIe BFM — adapter 化设计（只负责接口侧转换）

**日期:** 2026-06-29
**状态:** 设计已批准，待实现计划
**分支（拟）:** `feat/adapter-mode`

## 1. 背景与目标

当前 `xilinx_pcie` 自带完整 UVM 栈（env / agent / driver / monitor / scoreboard / seq 库 / 中断 agent），其中协议行为层（EP 自动响应、RC completion 追踪/超时、DMA、generate_completion、稀疏内存、seq 库、scoreboard）与上游通用 `pcie_tl_vip` 重复。`pcie_tl_vip` 本身按"TLP 抽象 + 工厂可覆盖 adapter"设计：driver/monitor 全走 `adapter.send/receive`，adapter 之上全部接口无关（agent、scoreboard、seq、switch fabric、multi-root、SR-IOV/PF-VF、link-delay、bw-shaper、coverage）。

**目标终态：** 把 `xilinx_pcie` 收敛为**纯 Xilinx 接口 adapter**——只负责 Xilinx PG213 的 4 通道 AXI-Stream（RQ/RC/CQ/CC）⟷ 抽象 `pcie_tl_tlp` 的编解码与通道路由。所有协议逻辑委托 `pcie_tl_vip`。

**非目标：** 不改 `pcie_tl_vip` 的协议逻辑；不引入新协议特性；不做 TLM 模式（采用 SV_IF 模式）。

**修订（2026-06-29，PoC 后）：** PoC 闸门已**通过**——Xilinx adapter 经工厂覆盖接入 pcie_tl_vip，1RC+1EP MemWr/MemRd 端到端跑通（RC 请求→AXIS→EP 自动响应→CplD→RC，`UVM_FATAL=0`）。PoC 暴露三项需在本实现内处理的事实：
1. **pcie_tl_vip 需最小 hook 补丁**：基类 `pcie_tl_if_adapter::send/receive` 非 virtual，工厂 override 不分派 → 给这两个方法加 `virtual`。已决策：接受此最小补丁，正式提交到 `pcie_work` repo（不改其协议逻辑）。非目标据此放宽为"仅最小 hook 补丁"。
2. **上游 scoreboard 在 SV_IF 模式不工作**：其 completion 匹配靠 `register_pending()`，仅在 env 的 TLM loopback 路径运行（SV_IF 模式关）。已决策：本 repo 保留**薄 Xilinx checker**做端到端校验，不依赖上游 scoreboard 的 TLM 假设（更贴"接口层只管转换"）。
3. **Xilinx desc codec 缺 Config-TLP**：`enum_then_dma` 用 CfgRd/CfgWr，codec 不支持 → PoC 用 MemWr/MemRd 等价证明 gate。已决策：新增 codec Cfg 编解码任务，排在删旧栈之前。

## 2. 决策（已定）

| 维度 | 决定 |
|---|---|
| 终态范围 | **完全替换**：删 xilinx 的 env/agent/driver/monitor/scoreboard/seq/collector/中断 agent，协议层委托 pcie_tl_vip |
| pcie_tl_vip 消费 | **外部引用维现状**：filelist include 外部 `pcie_work/pcie_tl_vip` 源，本 repo 不拷贝 |
| 测试策略 | **pcie_tl_vip seq 库激励 + 薄 Xilinx checker**（PoC 后修订：上游 scoreboard 依赖 TLM loopback，SV_IF 模式不可用，故用薄 checker；见修订 2） |
| 集成方案 | **方案 A：子类吸收式** —— `xilinx_pcie_if_adapter extends pcie_tl_if_adapter`，吸收 codec+router+4 通道驱动/采样；pcie_tl_vip agent/driver/monitor 原样复用 |

## 3. 上游约束（来自 pcie_tl_vip，已核实）

- `pcie_tl_base_driver.run_phase`：`forever { get_next_item(tlp); send_tlp(tlp); item_done(); }`。`send_tlp` 内顺序：tag 分配 → ordering enqueue → 等 FC/BW → `codec.encode(tlp,bytes)`（通用字节 codec，输出仅用于 BW 字节计数）→ `adapter.send(tlp)`（阻塞）→ 消费 FC/BW credit。**单线程串行**：一 agent 一次仅一个 TLP 在途。
- `pcie_tl_base_monitor.run_phase`：`forever { monitor_tlp(); }`，内 `adapter.receive(tlp); if (tlp==null) { #1ns; return; }` 再做协议检查、`tlp_ap.write`。**单线程**：receive 须非阻塞，无包返回 null。
- adapter **每 agent 一个**：`pcie_tl_env` 建 `rc_adapter`/`ep_adapter`（多 root/switch 时数组化），`connect_phase` 注入 `agent.adapter` 并设 `adapter.codec`/`adapter.fc_mgr`。
- adapter 创建走工厂：`pcie_tl_if_adapter::type_id::create(...)` → **可 `set_type_override` 覆盖**。
- adapter 双模 `pcie_tl_if_mode_e {TLM_MODE, SV_IF_MODE}`；`send`/`receive` 按 mode 分派，SV_IF 走 `drive_to_interface`/`sample_from_interface`（基类为单流 `pcie_tl_if`）。

## 4. 架构

### 4.1 终态文件构成（本 repo）

**保留 / 复用（Xilinx 资产）：**
- `src/codec/xilinx_desc_codec.sv`、`xilinx_tuser_codec.sv`、`xilinx_straddle_engine.sv` —— PG213 descriptor + tuser + straddle 编解码
- `src/agent/xilinx_pcie_channel_router.sv` —— role + TLP 类 → 通道映射
- `src/xilinx_pcie_params.svh`、`xilinx_pcie_types.sv` —— DATA_WIDTH / 各通道 TUSER 宽度 / 通道枚举
- `src/interface/xilinx_pcie_if.sv`、`xilinx_pcie_cfg_if.sv` —— 接口定义
- 4 通道 `axis_if`（依赖 axis_vip）

**新增：**
- `src/adapter/xilinx_pcie_if_adapter.sv` —— 核心，见 §4.2
- `tb/xilinx_pcie_connect.svh`（改造）—— 把 4 axis vif 注册到 adapter config_db 路径（替代原注册到 xilinx agent 路径）
- `tb/tb_adapter_top.sv` —— 例化 pcie_tl_env + 4 通道 AXIS + 工厂覆盖
- `tests/xilinx_pcie_adapter_smoke_test.sv` —— 薄 Xilinx smoke

**删除（协议层，委托 pcie_tl_vip）：**
- `src/env/*`（env、scoreboard、collector_tap、error_tap、virtual_sequencer、coverage、env_config 中协议字段、error_item）
- `src/agent/xilinx_pcie_agent.sv`、`xilinx_pcie_driver.sv`、`xilinx_pcie_monitor.sv`、`xilinx_pcie_mem_responder.sv`
- `src/seq/*`（mem/cfg/dma/atomic/msi/loopback/unified_mem/mega_stress 等 xilinx seq）
- `src/cfg/xilinx_pcie_interrupt_agent.sv`、`xilinx_pcie_cfg_agent.sv`
- 现有 13 个 xilinx test + 多 agent tb/filelist（PoC 通过、新栈回归绿后删）

> 删除分阶段：实现计划里旧栈先保留到新栈 smoke + 关键场景在远程 VCS 跑绿，再删，保证任何节点可回退。

### 4.2 xilinx_pcie_if_adapter（核心组件）

`class xilinx_pcie_if_adapter extends pcie_tl_if_adapter`

**职责：** 一个实例服务一个 pcie_tl agent，承载该 agent 的全部 4 个 Xilinx AXIS 通道，做 `pcie_tl_tlp` ⟷ Xilinx AXIS beat 的双向转换。

**集成方式（已定）：方案 A2 —— adapter 内包 4 个 `axis_agent`**，复用 axis_vip 的 master/slave 驱动（tready 握手 + 复位）与现有编解码逻辑，而非裸 vif 驱动。

**成员：**
- 4 个 `axis_agent`（rq/rc/cq/cc，类型按通道 TUSER 宽度参数化，即现 `axis_agent_rq_t` 等），master/slave 模式由 role+channel 决定（沿用 `create_axis_config`）
- `xilinx_tuser_codec` / `xilinx_straddle_engine` / `xilinx_pcie_channel_router`
- `xilinx_pcie_role_e role`（RC/EP）—— 由实例名判定
- 复用现 driver 的 `send_beats`/`encode_descriptor`/`encode_tuser_for_beat` 与现 monitor 的 `decode_packet` 逻辑（吸收进 adapter，调用相同 codec 静态/实例方法）
- `pcie_tl_tlp rx_queue[$]` —— 4 个 SLAVE 通道 monitor 解码出的 TLP 缓冲，receive() 从此 pop

**build_phase：**
1. 取 cfg（DATA_WIDTH/role 相关）；由 `get_name()` 含 `rc_adapter`/`ep_adapter` 判 role。
2. 建 4 个 axis_agent（各通道 `create_axis_config(channel)` 设 master/slave）。
3. 建 tuser_codec/straddle_eng/router。
4. `mode = SV_IF_MODE`。

**connect_phase：**
- 4 个 axis_agent 的 monitor `packet_ap` 连到 adapter 的 4 个 analysis_imp（rq/rc/cq/cc），回调内 `decode_packet(pkt,ch)` → `pcie_tl_tlp` → `rx_queue.push_back`。
- MASTER 通道 agent 的 sequencer 句柄存下，供 send() 用。

**send(tlp)（override task）：**
1. `channel = router.get_tx_channel(tlp)`（RC: cpl→RC,else→CQ；EP: cpl→CC,else→RQ）。
2. `encode_descriptor` + `straddle_eng.pack_single_tlp` + 逐 beat `encode_tuser_for_beat`。
3. `send_beats` 经该通道 MASTER agent 的 sequencer 发 `axis_transfer`（axis_vip 处理 tready）。
- base_driver 串行调用，同 agent 两出通道串行——功能 BFM 可接受。

**receive(tlp)（override task）：**
- 非阻塞 `if (rx_queue.size()>0) tlp = rx_queue.pop_front(); else tlp = null;`。
- rx_queue 由 axis monitor 回调（SVA 事件驱动）填充，与 base_monitor 的 receive 轮询解耦，自然解决"单 receive 盯 2 入通道"。

**role → 通道方向（按 `xilinx_pcie_channel_router`，权威）：**

| role | MASTER（驱动/send） | SLAVE（采样/receive→rx_queue） |
|---|---|---|
| RC | RC（完成）、CQ（请求） | RQ（收到请求）、CC（收到完成） |
| EP | RQ（请求）、CC（完成） | CQ（收到请求）、RC（收到完成） |

> send 通道由 `router.get_tx_channel(tlp)` 按类别选；receive 侧 4 个通道 monitor 都连 imp，但仅 SLAVE 通道有入流量。

### 4.3 env / tb 接线

- tb 例化 pcie_tl_vip 的 `pcie_tl_env`（非 xilinx env）。
- 每 agent 4 个 `axis_if`；RC 的出口总线物理上即 EP 的入口总线（沿用现 `connect.svh` 的 4 通道交叉接线：RC.RQ↔EP.CQ、EP.CC↔RC.RC 等）。
- 连线宏改为把每个通道 vif 注册到 adapter 内 axis_agent 的 config_db 路径，例如 `uvm_config_db#(virtual axis_if#(...))::set(null,"uvm_test_top.env.rc_adapter*.cq_agent*","vif",...)`（沿用 axis_agent 取 vif 的既有机制）。
- test `build_phase` 顶部：`set_type_override_by_type(pcie_tl_if_adapter::get_type(), xilinx_pcie_if_adapter::get_type())`。
- `codec` 注入：env 已设 `adapter.codec = codec`（通用 codec，用于 base_driver 的 BW 计数）；Xilinx 帧编解码在 adapter 内部独立完成，二者不冲突。

### 4.4 数据流（端到端，1RC+1EP MRd 为例）

```
RC seq → rc_agent.sequencer → base_driver.send_tlp(MRd)
  → tag/ordering/FC → codec.encode(BW计数) → rc_adapter.send(MRd)
  → router.get_tx_channel: MRd=request,RC → CQ 通道(MASTER) → desc/tuser/straddle 编码 → 驱 CQ AXIS
        ↓ (物理总线: RC.cq_if ↔ EP.cq_if, EP 侧 SLAVE)
EP cq_agent.monitor → axis_packet → ep_adapter.cq_imp → decode_packet → pcie_tl_tlp(MRd) → ep rx_queue
  → ep base_monitor.receive() pop → 协议检查 → tlp_ap → (pcie_tl_vip ep_driver 自动响应)
  → ep_driver 生成 CplD → ep base_driver.send_tlp(CplD)
  → ep_adapter.send(CplD): router=CC 通道(MASTER) → 编码 → 驱 CC AXIS
        ↓ (物理总线: EP.cc_if ↔ RC.cc_if, RC 侧 SLAVE)
RC cc_agent.monitor → axis_packet → rc_adapter.cc_imp → decode_packet → CplD → rc rx_queue
  → rc base_monitor.receive() pop → pcie_tl_vip 释放 tag/outstanding + scoreboard
```

### 4.5 错误处理

- adapter 解码失败（非法 beat / tuser）：压一个带标记的 TLP 或经 `err_ap` 路径——优先复用 pcie_tl_vip monitor 的协议检查；adapter 只做"忠实编解码"，不自行判协议对错（协议判定归 pcie_tl_vip monitor/scoreboard）。
- vif 未注册：`uvm_fatal`。
- rx_queue 无界增长（采样快于消费）：监控队列深度，超阈值 `uvm_warning`（功能 BFM 下消费由 monitor forever 驱动，预期不积压）。

## 5. 测试

- **薄 Xilinx smoke**（`xilinx_pcie_adapter_smoke_test`）：验 adapter 编解码往返正确（每通道一条代表 TLP：MWr/MRd→CplD/CfgRd→CplD/straddle 多 TLP），4 通道 role 映射正确，straddle 开/关两态。
- **协议激励**：复用 pcie_tl_vip seq 库（`enum_then_dma_vseq`、`rc_ep_rdwr_vseq`、`backpressure_vseq`、`err_*_seq`）做端到端 + 错误注入。
- **端到端校验**：薄 Xilinx checker（订阅两侧 adapter 解码出的 TLP，匹配 req↔cpl + payload）。**不**用上游 scoreboard（其 `register_pending` 仅在 TLM loopback 跑，SV_IF 模式无效）。
- **enum 类场景前置**：需先完成 codec Cfg 编解码任务，`enum_then_dma` 才能跑。
- **回归环境**：远程 VCS `ryan@10.11.10.61:2222`，`/tmp/xbuild`，DATA_WIDTH ∈ {256,512}。
- **判据**：smoke + 选定 pcie_tl_vip 场景 `UVM_ERROR=0 / UVM_FATAL=0`（错误注入场景按其自身判据）。

## 6. PoC 闸门与风险

实现计划 Task 1 = PoC（1RC+1EP，enum+dma 跑通），通过才删旧栈。

**成败点：**
1. **单线程串行 send**：base_driver 一次一个 TLP；同 agent 两出通道串行。pcie_tl_vip 本就串行，预计 OK——但需验 EP 自动响应（收 MRd 时同时可能在发 DMA）不死锁。
2. **2 通道 RX 采样 + 非阻塞 receive 时序**：采样线程与 monitor.receive 之间 rx_queue 交接；背靠背 TLP、跨通道并发到达不丢包（参考 adapter 用 negedge 阻塞驱动避 delta race，采样侧同理需谨慎）。
3. **工厂覆盖 + 4 vif 注入**：`set_type_override` 生效、adapter 路径与 config_db key 对齐、role 判定正确。

**回退：** PoC 任一点不可解 → 退方案 B（保留现 4 个 axis_agent 当物理层，adapter 仅桥接 pcie_tl 口与 axis sqr/mon）。

**依赖风险：** 外部引用 pcie_tl_vip，上游活跃开发（multi-root/pf-vf/link-delay 近期变动）。锁定一个已知能编译的 commit，记录于 plan。

## 7. 自评

- 范围聚焦单一 PoC→替换路径，可单计划承载。
- 接口边界清晰：adapter 唯一职责 = Xilinx 帧 ⟷ pcie_tl_tlp；输入 = 4 vif + tlp，输出 = AXIS beat / rx_queue；依赖 = pcie_tl_vip 类型 + axis_vip。
- 删除分阶段、可回退，不破坏"任何节点能跑"。
