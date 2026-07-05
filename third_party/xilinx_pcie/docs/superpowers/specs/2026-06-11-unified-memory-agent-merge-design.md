# Xilinx PCIe BFM — 统一内存接入 + RC/EP Agent 合并 设计

**日期:** 2026-06-11
**状态:** 待评审
**范围:** 单实例 feature(统一内存 + agent 合并)。多 EP 留作后续独立 spec。

---

## 1. 目标

1. 引入 `shm_work/host_mem` 的 `host_mem_manager` 作为统一内存管理单元,替代 EP 现有的临时稀疏 `mem_space`。
2. 让 RC 与 EP 在**数据通路上对称**:两者都能用自己的内存实例应答收到的访存请求(MWr/MRd/MRdLk/Atomic),并都能主动发起请求。
3. 把 `rc_agent` / `ep_agent` 合并为**单个 role 参数化 agent**(`cfg.role` 作 mode 开关 RC/EP)。
4. 全程 `cfg.use_unified_mem` 门控(默认关),保证现有 5 个测试回归不变。

### 非目标(本轮不做)
- 多 EP / switch 路由(后续独立 spec)。
- 把 Config(Type0/Type1)搬到 AXIS TLP 通路 —— config 仍走 `cfg_mgmt` 侧带(`cfg_agent`),与本 feature 解耦。
- 修改 `host_mem_manager` 业务逻辑(按依赖原样复用)。**例外(实现期发现,已批准)**:SV 禁止 package 引用 `$unit` 作用域类,故必须在 `host_mem_pkg` 内加一个最小抽象基类 `host_mem_api`(pure virtual `write_mem`/`read_mem`),`host_mem_manager extends host_mem_api`。向后兼容(仍 IS-A uvm_object),host_mem 自带 23-test tb 全过。本 feature 的 responder/agent 持 `host_mem_api` 句柄。已在 host_mem 仓提交(commit 8ef6b7f)。

---

## 2. 背景与动机

### 现状不对称(读码确认)
| 能力 | ep_agent 现状 | rc_agent 现状 |
|---|---|---|
| 自己的内存模型 | ✅ 稀疏 `mem_space[bit[63:0]]` | ❌ 无 |
| 应答收到的访存请求 | ✅ `handle_rx_tlp`(MWr/MRd/IO/Cfg) | ❌ 无 responder |
| 主动发起请求 | ✅ RQ master | ✅ CQ master |
| 完成追踪 / 释放 tag | (DMA 需要) | ✅ `handle_completion` |
| BAR 地址分配 | — | ✅ `allocate_bar_address` |

后果:真实 USP DUT 接到 ep-agent 时,ep-agent 已能应答其访存(`mem_space`);但若需要 RC 侧也应答(回环验证、或 RC 侧接 DUT),RC 当前**无内存、无 responder**,EP 发起的 DMA 读在 RC 侧拿不到完成。

### 合并动机
对称化后,RC 与 EP 在数据通路上的真正差异收敛为:
- **① 通道映射(router)**:RQ/RC/CQ/CC 的 TX/RX 角色按 role 相反 —— 已由 `channel_router` 按 `cfg.role` 参数化。
- **② per-channel 主从**:已由 `create_axis_config` 按 role 决定。
- **③ BAR 处理**:RC 分配 BAR 地址;EP 在 CQ 描述符按 bar_id/bar_aperture 命中应答。
- **④ Config 发起**:RC 发 Type0/Type1 —— 但走 `cfg_agent` 侧带,不在数据通路。

`base_agent` 本就按 role 参数化核心;`rc_agent`/`ep_agent` 只是薄子类。故把 `base_agent` 重命名演进为单个 role 参数化 agent(`xilinx_pcie_agent`),把 rc/ep 子类逻辑吸收进来,角色差异降为类内 `if(role==...)` 分支;不再保留独立 base_agent。

---

## 3. 关键设计决策(brainstorm 已定)

| # | 决策 | 选择 |
|---|---|---|
| D1 | 排期 | 先统一内存 + agent 合并;多 EP 后续 |
| D2 | 分配纪律 | 序列显式 `alloc/free`(真实 DMA 模型 + 全安全检查) |
| D3 | 实例拓扑 | **双实例**:`host_mem`(RC 实例)+ `dev_mem`(EP 实例),独立管理 |
| D4 | Responder 结构 | 抽**公共 `mem_responder` 基类**,两 role 共用 |
| D5 | 迁移/兼容 | `cfg.use_unified_mem` 开关,默认 0;新旧并存,回归不破 |
| D6 | RC 应答范围 | MWr/MRd/MRdLk/**Atomic**(打到内存的全部上行请求);Cfg/IO 不在内存 responder |
| D7 | 对称化范围 | 两 agent 都对称化 |
| D8 | Agent 形态 | **合并为单 role 参数化 agent**(`cfg.role` 作 mode 开关) |
| D9 | 访问模式 | per-buffer(序列 alloc)+ pre-mapped(env 预映射有界窗口,面向真实自选地址 DUT) |

---

## 4. 架构

### 4.1 统一 agent(`xilinx_pcie_agent`)
```
xilinx_pcie_agent  (cfg.role = RC | EP  ← mode 开关)
 ├── 4× axis_agent + driver + monitor + 共享 mgr(tag/fc/ord/cfg_space)   [原 base_agent 核心]
 ├── mem_responder(共享)         ── 两 role:应答 MWr/MRd/MRdLk/Atomic
 ├── host_mem_manager 实例         ── role=RC→host_mem;role=EP→dev_mem(use_unified_mem 时)
 ├── 完成追踪(free tag / 超时)    ── 两 role
 ├── if role==EP:  + Cfg/IO 应答  + CQ BAR-aperture decode
 └── if role==RC:  + BAR 地址分配(枚举;config 仍走 cfg_agent 侧带)
```
- `cfg.role` 即 mode 开关。env 建**两个同类实例** `rc_agent`(role=RC)、`ep_agent`(role=EP)。
- 实例名保持 `rc_agent`/`ep_agent` → **tb_top 的 config_db 注册路径不变**。
- 角色对每个实例在 build 期固定(由 env 按实例路径下发的 role config 决定)。

### 4.2 共享 responder(`xilinx_pcie_mem_responder`)
普通 class(非 uvm_component),持内存句柄 + 发送回调:
```
class xilinx_pcie_mem_responder;
  host_mem_manager mem;                 // 本 agent 的内存实例
  // 由宿主 agent 提供:把 CplD 经本 agent 的 sequencer 发出
  // (复用现 ep_agent send_completion 的 oneshot-sequence 模式)
  virtual function send_completion(pcie_tl_cpl_tlp cpl); ... endfunction

  function void handle_mem_request(pcie_tl_tlp req);
    MWr   : mem.write_mem(addr, payload, first_be, last_be)   // 按 BE 逐段写
    MRd   : data = mem.read_mem(addr, len); send CplD(SC, data)
    MRdLk : 同 MRd,CplD.kind = TLP_CPLD_LK
    Atomic: old = mem.read_mem(addr, opsize);
            new = op(old, operand);   // FetchAdd: old+operand; Swap: operand;
                                      // CAS: (old==compare)?swap:old
            mem.write_mem(addr, new); send CplD(回 old 值)
  endfunction
```
- **BE 处理**:写时仅写 first_be/last_be 使能的字节(逐段调用 `write_mem`),保持现 EP 语义。
- **类型转换**:`host_mem` 用 `byte`(有符号 8 位),pcie 用 `bit[7:0]`,同位宽直接转。
- EP 在此基础上额外处理 Cfg/IO(保留现 `handle_rx_tlp` 中对应分支);RC 只用内存四类。

### 4.3 内存实例与注入
- `env.build_phase`:`use_unified_mem=1` 时创建 `host_mem`、`dev_mem` 两个 `host_mem_manager`。
- 经 config_db 注入:`host_mem`→RC 实例,`dev_mem`→EP 实例;两者句柄也挂到 `v_sqr` 供序列 alloc。
- `mem_access_mode == PREMAP` 时,env 启动对相应实例 `init_region` + `alloc` 一段有界窗口(`premap_base`/`premap_size`)。

---

## 5. 数据流

### 5.1 per-buffer(BFM 回环 / 测试控地址)
```
seq:  addr = v_sqr.dev_mem.alloc(256, 64)      // 或 host_mem,视目标
      v_sqr.dev_mem.write_mem(addr, golden)    // 预置(或先 DMA 写)
      mem_tlp.addr = addr; 发 MRd
对端 agent.mem_responder.handle_mem_request(MRd):
      data = mem.read_mem(addr, len)           // 越界/未分配 → host_mem FATAL
      send CplD(tag/reqid 回填)
请求方收 CplD,scoreboard 匹配
seq 末: v_sqr.dev_mem.free(addr); leak_check()
```

### 5.2 pre-mapped(真实 DUT 自选地址)
```
env 启动: dev_mem.init_region(W_BASE, W_END);
          dev_mem.alloc(window_size)            // 预占整窗(有界,密集存储)
DUT 自选地址打入 → 落窗内即由 responder 应答;落窗外 → FATAL(逮野指针)
```
约束:`host_mem` 按块密集存储(`block_data = new[buddy_size]`),预映射窗口须有界(不能映射 4GB 稀疏空间)。窗口大小由 `cfg.premap_size` 控制(如 16MB)。

---

## 6. 配置项(env_config 新增)
| 字段 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `use_unified_mem` | bit | 0 | 关=原 sparse mem_space;开=host_mem/dev_mem + responder |
| `mem_access_mode` | enum | PER_BUFFER | PER_BUFFER \| PREMAP |
| `premap_base` | bit[63:0] | — | PREMAP 窗口基址 |
| `premap_size` | int | — | PREMAP 窗口大小(字节,有界) |
| `mem_alloc_mode` | enum | MODE_BUDDY | 透传 host_mem 的 buddy/linear |
| `mem_granule` | int | 16 | 透传 host_mem granule |

---

## 7. 文件改动清单
| 文件 | 改动 |
|---|---|
| `src/agent/xilinx_pcie_base_agent.sv` → `src/agent/xilinx_pcie_agent.sv` | **重命名 + 演进**:由 base_agent 改名为统一 role 参数化 agent,吸收 rc/ep 角色逻辑(单一文件,不另留 base_agent) |
| `src/agent/xilinx_pcie_mem_responder.sv` | **新建**:共享 responder(MWr/MRd/MRdLk/Atomic + BE + send 回调) |
| `src/agent/xilinx_pcie_rc_agent.sv` | **删除**(逻辑并入 role==RC 分支) |
| `src/agent/xilinx_pcie_ep_agent.sv` | **删除**(逻辑并入 role==EP 分支;Cfg/IO 保留为 EP 分支) |
| `src/env/xilinx_pcie_env.sv` | 两实例改用统一 agent 类;建 host_mem/dev_mem;注入 + 挂 v_sqr;PREMAP 预分配 |
| `src/env/xilinx_pcie_env_config.sv` | 加 §6 配置项 |
| `src/env/xilinx_pcie_virtual_sequencer.sv` | 挂 host_mem/dev_mem 句柄供 seq alloc |
| `src/xilinx_pcie_pkg.sv` | include 调整(去 rc/ep,加 agent + mem_responder);`import host_mem_pkg` |
| `sim/filelist.f` | 加 `host_mem_pkg.sv` + `host_mem_manager.sv`(+incdir) |
| `src/seq/xilinx_pcie_dma_seq.sv` | use_unified_mem 时走 alloc/free 模式 |
| `tests/xilinx_pcie_unified_mem_test.sv` | **新建**:demo + 成功标准 |

---

## 8. 验证 / 成功标准

新建 `xilinx_pcie_unified_mem_test`(`use_unified_mem=1`):
1. **per-buffer roundtrip**:seq alloc buffer → EP DMA MWr 写 → EP DMA MRd 读回 → `mem_compare` golden 一致。
2. **双向应答**:RC/EP 互发 MRd/MWr,各自实例 responder 应答,scoreboard 0 失配、0 未匹配 completion。
3. **Atomic**:FetchAdd/Swap/CAS 各一,验证 RMW 结果 + CplD 回原值。
4. **pre-mapped**:env 预映射 dev_mem 窗口,模拟外部自选地址命中窗内 → 应答成功;窗外 → 预期 FATAL(单独负向用例或文档说明)。
5. **leak_check()** 末态 = 0。
6. **回归不变**:`use_unified_mem=0` 时 sanity / loopback / stress / mega_stress / straddle 全绿,数值与当前一致。

执行环境:VCS,远程 `ryan@10.11.10.61:2222`,`source /home/ryan/set-env.sh`。

---

## 9. 风险与缓解
| 风险 | 缓解 |
|---|---|
| 删 rc/ep agent、合并 → blast radius 大 | `use_unified_mem=0` 默认;合并后**立即跑全 5 回归**确认行为不变;实例名/分析端口/scoreboard 连接全保持 |
| 每实例 role 下发错误(原 rc_agent 有 force-role workaround) | env 按实例路径 set 正确 role config;保留必要 guard |
| host_mem 对未分配地址 FATAL | per-buffer 由 seq 保证 alloc;PREMAP 由 env 预占窗口;窗外 FATAL 是预期行为(逮野指针) |
| host_mem 密集存储,大地址空间 OOM | PREMAP 窗口有界(`premap_size`);文档明确不可映射稀疏大空间 |
| `byte` vs `bit[7:0]` 符号差异 | 同位宽透传,封装转换函数 |

---

## 10. 后续(独立 spec)
- 多 EP:统一 agent 数组化 + 复用 `pcie_tl_switch` 路由 + v_sqr 数组 + scoreboard 按 EP 区分。
- 可选:把 Config(Type0/Type1)纳入 AXIS TLP 通路(当前走 cfg_mgmt 侧带)。
