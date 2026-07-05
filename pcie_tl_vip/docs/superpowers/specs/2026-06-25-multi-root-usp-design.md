# PCIe TL VIP — 多根（多 USP）Switch Fabric 设计

> 日期：2026-06-25 ｜ 状态：设计已评审，待 review → 实现计划

## 1. 目标

让 `pcie_tl_vip` 的 switch fabric 支持**多个上行口（USP / 根 / RC）**，即可配置 N 个 RC + M 个 EP 的**多根不交叠层级**拓扑，替代现状的单 USP（1 RC + N EP）。保留 fabric 的真 TLP 路由与 scoreboard 真校验。

### 拓扑模型（已定）：不交叠层级

```
  RC0      RC1
   |        |
 USP0     USP1
   |  switch |
  +---------+
  | DSP DSP | DSP DSP
  |  0   1  |  2   3
   EP0 EP1   EP2 EP3
RC0↔{EP0,EP1}  RC1↔{EP2,EP3}
```
每个 RC 独占一组 DSP/EP；各根独立 bus 号带 + 内存地址窗；上行按 ingress DSP 的归属根路由；**默认不跨根**。

### 范围内
- `num_usp` 可配（默认 1 = 现单根，向后兼容）。
- DSP→根归属：显式 `dsp_owner[]`，未指定时按 `num_usp` 均匀连续自动分。
- 各根 bus 带 + 内存区由 fabric 自动派**不交叠**域（`enum_mode` 下逐根独立枚举）。
- 跨根流量：drop + 隔离检查器（计数 + 可关的 `uvm_error`）。
- env：`rc_agents[num_usp]`；per-root 共享管理器（tag/FC/排序/cfg 空间）；scoreboard per-root。

### 非目标（本轮不做）
- 共享 any-to-any fabric（MR-IOV / VH 标记）。
- 动态重配归属（运行期改 dsp_owner）。
- 跨根 P2P 允许（默认禁止；跨根一律 drop）。

## 2. 背景（读码确认）

- `pcie_tl_switch`：建 `usp`(1) + `dsp[num_ds_ports]`，flat `all_ports[0]=usp, [1..N]=dsp`，`fabric.ports=all_ports, num_ports=N+1`。per-port forward loop → `route_and_forward(tlp, ingress_port_id)`。
- `pcie_tl_switch_fabric.route()`：completion/config 按 ID（bus 带）、mem/io 按地址窗、message 各类；**所有"上行"硬编死 `SWITCH_ROUTE_USP`（=0）**；`for i=1..num_ports` 假设 DSP 从索引 1 起。
- `pcie_tl_switch_port`：`role`(USP/DSP)、`port_id`、`route_entry.{secondary_bus,subordinate_bus,mem_base,mem_limit}`、`rx_fifo`/`tx_fifo`、`apply_config`、`cfg_read/write`。
- `pcie_tl_switch_config`：`num_ds_ports`(默认 4)、`ds_secondary_bus[]/ds_subordinate_bus[]/ds_mem_base[]/ds_mem_limit[]`、`usp_subordinate_bus`、`p2p_enable`、`enum_mode`、`switch_bdf`。
- `pcie_tl_env`：单 `rc_agent`/`ep_agent`；switch 模式建 `ep_agents[num_ds_ports]`；共享 `tag_mgr/fc_mgr/ord_eng/cfg_mgr/codec/bw_shaper`（单套）；`scb`(单)；`v_seqr`。

## 3. 设计

### 3.1 配置旋钮（`pcie_tl_switch_config`）

```systemverilog
int  num_usp        = 1;          // 上行口/根 数量（默认 1）
int  dsp_owner[];                 // 可选: dsp_owner[i]=DSP i 的 USP 索引; 空=均匀连续分
bit  cross_root_check_enable = 1; // 跨根尝试报 uvm_error（drop 始终）
// per-root 域（自动派或 enum）
int        usp_secondary_bus[];   // [num_usp]
int        usp_subordinate_bus[]; // [num_usp]
bit [63:0] usp_mem_base[];        // [num_usp]
bit [63:0] usp_mem_limit[];       // [num_usp]
```

`init_defaults()` 重排：
1. 解析 `dsp_owner`（空→均匀连续：USP0 拿前 ⌈M/N⌉ 个 DSP…）。校验 owner∈[0,num_usp)、每 USP ≥1 DSP。
2. **bus 带**：256 bus 按 num_usp 切 N 段不交叠，根 r 带 `[r*K+1 .. (r+1)*K]`（K=256/num_usp）；根内各 DSP 细分 secondary/subordinate（沿用现逻辑，局限本根带）。
3. **内存区**：根 r 区 `BASE + r*ROOT_STRIDE`（ROOT_STRIDE 足够大不重叠）；根内 DSP 细分 mem_base/limit。
4. `usp_*[r]` = 根 r 的总 bus 带 + 内存区（DSP 并集/上界）。
5. **自检**：各根 bus 带、内存区两两不交叠（`assert`）。

`enum_mode=1`：不自动派，DUT 枚举逐根写各 USP/DSP 的 route_entry（保持现 enum 语义）。

### 3.2 端口数组重排（`pcie_tl_switch`）

```
all_ports = [ USP_0 .. USP_{num_usp-1},  DSP_0 .. DSP_{num_ds_ports-1} ]
              索引 0..num_usp-1            索引 num_usp..num_usp+M-1
```
- `usps[num_usp]` 替代单 `usp`；`dsp[num_ds_ports]` 不变。
- `pcie_tl_switch_port` 加 `int owner_usp`（DSP 用）、`int root_id`（USP=自身索引）。
- 每 USP / 每 DSP 各一 forward loop；ingress_port_id 用新索引。
- `report_phase` 打印 N USP + M DSP + per-root 统计 + `cross_root_violations`。

### 3.3 fabric 路由（核心，`pcie_tl_switch_fabric`）

新增辅助 + sentinel：
```systemverilog
function int root_of(int port_id);  // port<num_usp→port; else ports[port_id].owner_usp
function int usp_port_id(int root);  // = root
// 新 sentinel: SWITCH_ROUTE_CROSS_ROOT
```

`route()` 改写：
- `ingress_root = root_of(ingress_port_id)`；DSP 遍历 `for i=num_usp..num_ports`。
- ID 路由（completion/config）/ 地址路由（mem/io）命中某 DSP 或 USP-band 时按其根：
  - 根 `==ingress_root` → 返回该端口索引（根内正常路由）。
  - 根 `!=ingress_root` → `SWITCH_ROUTE_CROSS_ROOT`。
  - 无命中 + ingress 是 DSP → `usp_port_id(ingress_root)`（上行到自己的根）。
  - 无命中 + ingress 是 USP → DROP。
- config 命中本根 USP 的 secondary_bus → LOCAL（逐根）。
- message BCAST → 仅本根 DSP。
- default：DSP → `usp_port_id(ingress_root)`；USP → DROP。

`route_and_forward()` 改：
- 废弃固定 `SWITCH_ROUTE_USP=0`；"上行"由 route() 返回具体 USP 索引，走 default case 投递。
- 自路由重定向（`dst==ingress`）：DSP→self 重定向到 `usp_port_id(owner_usp)`。
- 新 `SWITCH_ROUTE_CROSS_ROOT`：`total_dropped++` + `cross_root_violations++` + 若 `cross_root_check_enable` → `uvm_error("CROSS_ROOT",...)`，否则 `uvm_info`。

### 3.4 env / agent / scoreboard（`pcie_tl_env`）

- **RC 数组化**：`rc_agents[num_usp]`，循环建，每个绑 `usps[r]`（经 `rc_adapters[num_usp]` + per-root link delay `rc2ep_delay[]`/`ep2rc_delay[]`）。
- `ep_agents[num_ds_ports]` 已有；`ep_agents[i]` 绑 `dsp[i]`，根属 = `owner_usp[i]`。
- **per-root 共享管理器**：`tag_mgr[num_usp]`、`fc_mgr[num_usp]`、`ord_eng[num_usp]`、`cfg_mgr[num_usp]`、`bw_shaper[num_usp]`（各根 tag/FC/排序/配置空间独立）；`codec` 无状态共享。RC_r 与其根的 EP 注入第 r 套管理器。
- **scoreboard per-root**：`scb[num_usp]`，每根连 `rc_agents[r].mon` + 本根 EP（owner_usp==r）的 mon，独立校验数据/completion（保留真校验）。
- **v_seqr**：`rc_seqr_arr[$]`/`ep_seqr_arr[$]` + 别名 `rc_seqr=rc_seqr_arr[0]`/`ep_seqr=ep_seqr_arr[0]`。
- 兼容：`num_usp=1` → `rc_agents[0]`=旧、per-root 退化为一套、`scb[0]`=旧、别名=[0]。

## 4. 数据流

```
RC_r seq → rc_agents[r] → usps[r].rx_fifo → fabric.route(ingress=r)
  根内目标 → dsp[owned].tx_fifo → ep_agents[owned]
  跨根目标 → CROSS_ROOT → drop + cross_root_violations++ (+uvm_error)
EP_i → dsp[i].rx_fifo → fabric.route(ingress=num_usp+i)
  上行 → usps[owner_usp[i]].tx_fifo → rc_agents[owner_usp[i]]
per-root: tag/FC/order/cfg 各根独立; scb[r] 校验根 r 的 RC↔EP
```

## 5. 向后兼容

`num_usp=1`：`all_ports[0]=USP,[1..M]=DSP`，`root_of≡0`，`usp_port_id(0)=0`，DSP 从索引 1 起，永不跨根，per-root 组件单套，别名=[0] → 与现 fabric/env **逐路径等价**，现有 pcie_tl test/回归不变。

## 6. 文件改动清单

| 文件 | 改动 |
|---|---|
| `src/switch/pcie_tl_switch_config.sv` | +`num_usp`/`dsp_owner`/`cross_root_check_enable`/`usp_*[]`；`init_defaults` 多根域划分 + 不交叠自检 |
| `src/switch/pcie_tl_switch_port.sv` | +`owner_usp`/`root_id` |
| `src/switch/pcie_tl_switch.sv` | `usps[num_usp]`；all_ports 重排；per-USP forward loop；route_and_forward CROSS_ROOT；report |
| `src/switch/pcie_tl_switch_fabric.sv` | `root_of`/`usp_port_id`；route 根域过滤 + 上行解析；CROSS_ROOT |
| `src/types/pcie_tl_types.sv` | +`SWITCH_ROUTE_CROSS_ROOT` |
| `src/env/pcie_tl_env.sv` | `rc_agents[]`/`rc_adapters[]`；per-root 管理器；`scb[]`；接线 |
| `src/env/pcie_tl_env_config.sv` | 透传 num_usp 等（若 env 级旋钮） |
| `src/env/pcie_tl_virtual_sequencer.sv` | seqr 数组 + 别名 |
| `src/env/pcie_tl_scoreboard.sv` | 支持 per-root 实例化（构造/连接） |
| `tests/`（新） | multi_root_route / cross_root_isolation / uneven_ownership / per_root_tag_independence |
| `sim/filelist.f` | +新 test |

## 7. 验证 / 成功标准

- 兼容：`num_usp=1` 现有 pcie_tl 回归全绿（host 61，`pcie_tl_vip/sim/filelist.f`）。
- `multi_root_route_test`（2 USP+4 DSP）：各 RC 只达本根 EP，completion 回对根，`cross_root_violations=0`。
- `cross_root_isolation_test`：RC0 发 root1 域 → drop + 计数 + `CROSS_ROOT`；root1 EP 从未收到。
- `uneven_ownership_test`（`dsp_owner='{0,0,0,1}`）：归属被尊重。
- `per_root_tag_independence_test`：两根并发同 tag 无冲突，completion 各回各根。
- 域不交叠 `assert` 任一多根编译/跑覆盖。

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 端口索引重排（DSP 从 num_usp 起）漏改某处 `i=1`/`=0` | 全量 grep fabric/switch 的端口循环与 USP 常量；num_usp=1 回归逐路径等价兜底 |
| per-root 管理器接线遗漏致 tag/FC 串根 | per_root_tag_independence_test 专测；注入按根索引 |
| 自动域划分溢出（num_usp 大 / bus 不够分） | init_defaults 校验 num_usp≤合理上限、每根 ≥1 bus/DSP，越界 fatal |
| enum_mode 与自动派冲突 | enum_mode 下跳过自动派，逐根枚举；二者互斥 |

## 9. 后续（独立 spec，不在本轮）

- 跨根 P2P（可控允许）。
- 共享 any-to-any / VH 标记 MR-IOV。
- 运行期动态重配归属。
