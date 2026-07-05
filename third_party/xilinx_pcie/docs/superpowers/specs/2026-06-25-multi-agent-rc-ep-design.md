# Xilinx PCIe BFM — 可配置多 RC/EP Agent 设计

> 日期：2026-06-25 ｜ 状态：设计已评审，待 review → 实现计划

## 1. 目标

让 `xilinx_pcie` 环境支持**运行期自由配置 RC agent 与 EP agent 的数量**（含"全 EP"特例），而非现状写死的 1 RC + 1 EP。

### 范围内

- `env_config` 增 `num_rc` / `num_ep`，env 据此运行期建对应数量的 agent。
- 提供**连线宏**（区分 RC/EP），用户在自己的 tb 里逐 agent 例化接口并注册；附 demo。
- 检查只做**协议类型 + 错误类型**（中转层），分两层：agent 本地查 + 中心收集器聚合。
- 中断 / cfg agent 随 agent 数量与角色一并扩展。
- **原地泛化 + 向后兼容**：默认 `num_rc=1/num_ep=1` 复现现行为，现有 7 个 test 与回归不破。

### 非目标（本轮不做）

- 数据/内存读写正确性比对（payload compare、completion 数据配对）——交用户自查。
- RC↔EP 路由矩阵 / 交换语义。
- 真实 DUT 多端口拓扑的具体接线（由用户用宏自接，仅给 demo）。

## 2. 背景

现状（读码确认）：

- `xilinx_pcie_env` 写死 `rc_agent` + `ep_agent` 两个，角色由 env clone cfg 后强制 `role=RC/EP`。
- `env_config.role` 字段存在（默认 EP）但对 stock env 无效。
- `xilinx_pcie_agent` 是**角色无关**单一类，RC/EP 功能用 `if(cfg.role==…)` 守护 —— 多 agent 在底层可行。
- `virtual_sequencer` 聚合 `rc_sqr`+`ep_sqr`；`scoreboard` 做 RC↔EP 数据配对；`tb_top` 显式例化 8 条 axis_if（RC/EP×4）+ tkeep 桥接 + config_db 注册。
- SV 接口是 elaboration 期静态实体，**不能运行期创建** → 接口必须编译期由 tb 例化；agent 运行期由 env 按 config 建；两者靠 config_db 索引路径对接。

## 3. 关键设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 数量设定 | 运行期 `env_config.num_rc/num_ep` | 不重编可改数量 |
| 接口例化 | 编译期，用户用**宏**逐 agent 连 | SV 接口静态；宏区分 RC/EP 方向 |
| 配对/检查 | 仅协议类型 + 错误类型，无数据配对 | 数据正确性用户自查 |
| 检查分层 | agent 本地查 + 中心收集器聚合 | 本地即时报 + 全局统计报表 |
| 中断/cfg | 随 agent 数量与角色扩 | 每端点独立 MSI / cfg 空间 |
| 兼容 | 原地泛化，默认 1+1 | 保住已验证回归 |

## 4. 架构

### 4.1 env_config（新增字段）

```systemverilog
int num_rc = 1;   // RC agent 数量（默认 1）
int num_ep = 1;   // EP agent 数量（默认 1）
```

`validate()` 增：`num_rc>=0 && num_ep>=0 && (num_rc+num_ep)>=1`。
运行期取不到第 i 个 agent 的 vif 时 `uvm_fatal`，提示"config 要 N 个但 tb 只连了 K 个"。

per-agent 带宽/角色细调暂不引入（YAGNI）：所有 RC 继承全局 `rx_*`、所有 EP 继承全局 `tx_*`；需要时后续加 `agent_bw_cfg[]`。

### 4.2 env（数组化）

```systemverilog
xilinx_pcie_agent            rc_agents[$];
xilinx_pcie_agent            ep_agents[$];
xilinx_pcie_interrupt_agent  rc_int_agents[$];
xilinx_pcie_interrupt_agent  ep_int_agents[$];
// 向后兼容别名（num>=1 时）：rc_agent => rc_agents[0]，ep_agent => ep_agents[0]
```

`build_phase`：

- `for i in [0,num_rc)`：clone cfg → `role=RC`（索引由实例名 `rc_agent_<i>` 携带，cfg 可选存 `agent_index=i` 仅供收集器报表标签）→ `uvm_config_db#(cfg)::set(this,"rc_agent_<i>*",...)` → create `rc_agent_<i>` → push `rc_agents`。
- EP 同理建 `ep_agent_<i>`。
- `interrupt_enable` 时，**逐 agent**建 `rc_int_agent_<i>` / `ep_int_agent_<i>`（行为随所属 agent 角色），并把 ep 侧 int agent 句柄注册供 msi_seq 获取（按索引）。
- `connect_phase` 内原 `rc_agent.tag_mgr` 等引用改走 `rc_agents[0]` 别名。

实例命名：`rc_agent_0/1/…`、`ep_agent_0/1/…`、`rc_int_agent_<i>`、`ep_int_agent_<i>`。

### 4.3 连线宏（`tb/xilinx_pcie_connect.svh`，tb 包含一次）

含共享的 tkeep 字节↔DW 转换 `automatic` 函数（定义一次），及两个宏：

```systemverilog
`XILINX_PCIE_WIRE_RC(IDX, PCIE_IF, CFG_IF, CLK, RSTN)
`XILINX_PCIE_WIRE_EP(IDX, PCIE_IF, CFG_IF, CLK, RSTN)
```

每个宏展开（以 `WIRE_RC(0, rc_if, rc_cfg_if, clk, rst_n)` 为例）：

1. **声明 4 条 axis_if**（token 拼接保证唯一名）：
   `rc_agent_0_rq_if / _rc_if / _cq_if / _cc_if`，各按 `XILINX_<CH>_TUSER_W` 参数化，`#(DATA_W,4,4,TUSER,0,1,1)`。

2. **按角色方向桥接** axis_if ⇄ PCIE_IF：
   - RC 版：RQ/CC = axis SLAVE（pcie→axis）；RC/CQ = axis MASTER（axis→pcie，含 tkeep byte→dw）。
   - EP 版：方向相反（RQ/CC master，RC/CQ slave）。

3. **按索引路径注册 config_db**（initial 块，路径与 env 建的实例名对齐）：
   - 4 个 axis vif → `uvm_test_top.env.<role>_agent_<IDX>.<ch>_agent*`。
   - CFG_IF → `env.<role>_cfg_agent_<IDX>*` 与 `env.<role>_int_agent_<IDX>*` 的 `cfg_vif`。

**契约**：tb 中 `WIRE_RC/EP` 调用次数必须 ≥ `cfg.num_rc/num_ep`；少则 env 取 vif 时 fatal。

### 4.4 virtual sequencer（数组化）

```systemverilog
uvm_sequencer #(pcie_tl_tlp) rc_sqr_arr[$];
uvm_sequencer #(pcie_tl_tlp) ep_sqr_arr[$];
// 别名：rc_sqr => rc_sqr_arr[0]，ep_sqr => ep_sqr_arr[0]（兼容现 vseq）
```

`connect_phase` 逐 agent 接 sequencer。vseq 发往指定端点用 `v_sqr.ep_sqr_arr[i]`；不带下标的旧 vseq 走别名 = 索引 0。

### 4.5 中心协议/错误收集器（`xilinx_pcie_protocol_collector`，就地改造 `scb`）

- 订阅**所有** agent monitor 的 analysis port（N×RC + M×EP）。
- **协议类型统计**：每 TLP 按类型（MWr/MRd/CplD/Cfg/MSI/Atomic…）归类计数，逐 agent + 汇总。
- **错误类型聚合**：归并各 agent 本地查出的违规（格式/UR/CA/ECRC/desc 格式/tuser 不一致/payload 对齐…），记录 (哪个 agent, 错误类型, 次数)。
- `report_phase` 打印逐 agent + 全局：协议类型直方图 + 错误类型清单。
- **移除**：RC↔EP completion 配对、payload 比对、内存校验。
- **保留**：agent 本地逐通道协议检查（`rq/rc/cq/cc_protocol_check_enable`、`desc_format_check`、`tuser_consistency`、`payload_alignment`）。
- `scb_enable` 改为"启用收集器"；`scb_data_integrity`/`scb_completion_check` 保留字段但退化为 no-op（兼容现 test 配置，不破坏）。

## 5. 数据流

```
seq → v_sqr.<role>_sqr_arr[i] → agent_<i> driver → axis_if(宏桥接) → PCIE_IF → DUT
DUT → PCIE_IF → axis_if → agent_<i> monitor ──┬─ 本地协议检查（即时 UVM_ERROR）
                                              └─ analysis port → 中心收集器（类型统计 + 错误聚合 → report）
```

数据正确性（写了什么、读回是否一致）不在本环境检查，由用户在外部基于自有内存/参考模型校验。

## 6. 向后兼容

- 默认 `num_rc=1/num_ep=1` → 建 `rc_agent_0`/`ep_agent_0`，别名 `rc_agent`/`ep_agent` 指向之，env 内部引用不变。
- `tb_top` 用宏重写成 1 RC + 1 EP（idx 0），回环行为、时钟/复位不变 → **既是 demo 又保回归**。
- 现有 7 个 test 只用 `env.v_sqr`（不碰 config_db 路径与 agent 实例名），不受改名影响。
- 数据相关 scoreboard 字段保留但 no-op，现 test 配置不报错。

## 7. 文件改动清单

| 文件 | 改动 |
|---|---|
| `src/env/xilinx_pcie_env_config.sv` | +`num_rc`/`num_ep`，`validate()` 约束，`clone` 同步 |
| `src/env/xilinx_pcie_env.sv` | agent/int_agent 数组化 + 循环建 + 别名 + connect 改引用 |
| `src/env/xilinx_pcie_virtual_sequencer.sv` | sqr 数组化 + 别名 |
| `src/env/xilinx_pcie_scoreboard.sv` | 改造为协议/错误收集器（多 agent 订阅、类型统计、错误聚合、移除数据配对） |
| `tb/xilinx_pcie_connect.svh`（新） | tkeep 函数 + `WIRE_RC`/`WIRE_EP` 宏 |
| `tb/tb_top.sv` | 改用宏（1 RC+1 EP）作 demo + 回归基线 |
| `tests/xilinx_pcie_multi_agent_test.sv`（新） | demo tb 连多 agent，验证建成 + 收集器报表 + 无误报 |
| `sim/filelist.f` | +新 test；tb 包含 connect.svh |
| `docs/integration_guide.md` | 补"多 agent 配置 + 连线宏"章节 |

## 8. 验证 / 成功标准

- 默认 1+1：现有 7 个 test 在 61（更新版 axis）回归全绿，`UVM_ERROR=0`，不回退。
- 多 agent：`multi_agent_test`（如 1 RC + 3 EP）建成 N+M 个 agent，各取到 vif，收集器报出逐 agent 协议类型直方图，错误 tally=0。
- 编译矩阵：DATA_WIDTH=256/512 × 多 agent 数 编过。
- 宏契约：故意 `num_ep` > 宏连接口数 → fatal 信息清晰。

## 9. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 接口数（编译期）与 config 数（运行期）不一致 | env 取 vif fatal + 明确提示；integration_guide 写明契约 |
| 改 `scb` 影响现 test 的 scoreboard 断言 | 数据字段 no-op 化，保留配置兼容；现 test 不依赖数据配对结果即可 |
| 实例改名破坏现路径 | 别名 + 现 test 只用 `v_sqr`；tb_top 同步用宏改路径 |
| 多 EP 中断/tag 资源冲突 | 逐 agent 独立 int_agent + tag_mgr（每 agent 自带） |

## 10. 后续（独立 spec，不在本轮）

- per-agent 带宽/角色细调 `agent_bw_cfg[]`。
- RC↔EP 路由/交换语义。
- 可选的数据正确性 hook（让用户挂自有参考模型）。
