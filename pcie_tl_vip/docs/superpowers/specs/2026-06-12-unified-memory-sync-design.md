# pcie_tl_vip — 统一内存接入（与 xilinx_pcie 同步）设计

**日期:** 2026-06-12
**状态:** 待评审
**范围:** 把 xilinx_pcie BFM 的"统一内存(host_mem)"模式同步到 pcie_tl_vip。**只做统一内存,不动 agent 结构、不动 switch/多 EP 接线。**

---

## 1. 目标

1. 用 `host_mem_manager`(`shm_work/host_mem`,经 `host_mem_api` 抽象层)替代 `pcie_tl_ep_driver` 的稀疏 `mem_space`。
2. 给 RC 侧(`pcie_tl_rc_driver`)新增**对称**内存应答能力 —— RC 当前完全无内存模型/无请求应答,无法应答 EP 发起的 host DMA。
3. 多 EP(switch 模式 N 个 EP)下每 agent 独立内存实例。
4. 全程 `cfg.use_unified_mem` 门控(默认关),pcie_tl 现有回归零影响。

### 非目标
- agent 合并 / driver-override 角色结构重构(pcie_tl 角色分离在 driver 层,本就清晰,不动)。
- switch/多 EP 接线逻辑改动(已存在,只是顺带每 EP 注入独立 dev_mem)。
- 修改 host_mem 业务逻辑(`host_mem_api` 抽象层已在 xilinx 工作中就绪并合入 host_mem 仓)。
- Config(Type0/Type1)/IO/SR-IOV 处理改动(ep_driver 原逻辑保留)。

---

## 2. 背景

### 现状(读码确认)
- **角色分离在 driver 层**:`pcie_tl_base_agent` 角色无关,只建 `base_driver`,经 instance override 换成 `rc_driver`/`ep_driver`。
- **内存 + 自动应答在 `ep_driver`**:`bit[7:0] mem_space[bit[63:0]]`(稀疏);`handle_request` 分发 Cfg/IO/Mem + SR-IOV + config_proxy;`handle_mem_read` 含 MPS/RCB 完成拆分。
- **`rc_driver` 无内存**:只有 send_tlp + completion 追踪/超时 + BAR 分配 + 中断计数。**RC 不应答任何 EP 发来的访存请求**(EP→host DMA 当前无人回数据)。
- **多 EP/switch 已存在**:`switch_enable` + N 个 ep_agent + `pcie_tl_switch`。
- **env_config 极简**:`rc_is_active`/`ep_is_active`,无 role 字段、无 mem 开关。

### 与 xilinx_pcie 的复用关系
xilinx 只复用 pcie_tl 的 **TLP 类型(`pcie_tl_tlp` 及子类)+ 共享管理器(tag/fc/ordering/cfg_space)**;不复用 pcie_tl 的 agent/driver/memory。故本同步对 xilinx 零影响,纯为 pcie_tl 自身一致性与新增 RC 应答能力。

---

## 3. 关键设计决策(brainstorm 已定)

| # | 决策 | 选择 |
|---|---|---|
| D1 | 同步范围 | 只统一内存;不动 agent 结构/switch 接线 |
| D2 | 多 EP 内存拓扑 | **每 agent 独立实例**:RC 1×host_mem;每 EP 各 1×dev_mem(N 个) |
| D3 | 接入方式 | **driver 内换存储后端 + RC 对称**:ep_driver mem_space→host_mem(保留拆分/SR-IOV/Cfg/IO);rc_driver 新增对称 handle |
| D4 | 分配纪律 | 同 xilinx:PER_BUFFER(序列 alloc/free)+ PREMAP(env 预映射有界窗口) |
| D5 | 门控 | `cfg.use_unified_mem`(默认 0);关=原 sparse mem_space;开=host_mem |
| D6 | host_mem 引用 | 复用已就绪的 `host_mem_api` 抽象层;实例在 pcie_tl tb($unit)创建,config_db 以 host_mem_api 注入 |

---

## 4. 架构

```
pcie_tl tb($unit，可命名 host_mem_manager)
 ├── host_mem_manager host_inst         ← RC
 └── host_mem_manager dev_inst[0..N-1]  ← 每个 EP 一个
        │ config_db set as host_mem_api（per-agent 路径）
        ▼
 pcie_tl_env (use_unified_mem 时)
   get 句柄 → init_region / PREMAP 预 alloc → 注入:
     host_mem_api → rc_agent
     dev_mem_api[i] → ep_agent[i]（switch 模式按 N）
        ▼
 rc_agent / ep_agent: 拿 host_mem_api 句柄，传给各自 driver
        ▼
 ep_driver.handle_mem_read/write:  use_unified_mem 时 mem_space[a] → mem.read/write_mem
                                   （MPS/RCB 拆分、SR-IOV、config_proxy、Cfg/IO 全不动）
 rc_driver: 新增 gated 请求应答路径（handle_request 分发 + handle_mem_read/write against host_mem）
```

### 4.1 ep_driver(换后端)
- 加成员 `host_mem_api mem;`(由 agent 注入)。
- `handle_mem_write`:`use_unified_mem` 时按 first_be/last_be 逐段 `mem.write_mem`(替代 `mem_space[a]=`);否则原 sparse。
- `handle_mem_read`:读数据来源 `mem.read_mem`(替代 `mem_space.exists(a)?mem_space[a]:0`);MPS/RCB 完成拆分逻辑不变。
- 类型转换:host_mem 用 `byte`,pcie 用 `bit[7:0]`,同位宽转。

### 4.2 rc_driver(新增对称应答)
- 加成员 `host_mem_api mem;`、`bit auto_response_enable=1`。
- 新增 `handle_request(pcie_tl_tlp req)`:`use_unified_mem` 时,对 MWr→`mem.write_mem`(按 BE);MRd/MRdLk→读 host_mem + 生成 CplD(**完成拆分复用 ep_driver 的 MPS/RCB 逻辑**,保证大读一致);Atomic→RMW + CplD 回原值。RC 收到 cpl/中断仍走原 handle_completion/handle_interrupt。为避免重复,可把 ep_driver 的 mem 读写 + 完成拆分提炼为可被两 driver 复用的小工具(static helper 或共享基类方法);若提炼成本高则在 rc_driver 内镜像同款逻辑。
- RC 的 monitor→driver 请求投递路径:确认 base_monitor 是否已把收到的 request 转给 driver;若 rc 侧原本不订阅 request(因 RC 不应答),需在 gated 下接上(参考 ep 侧订阅方式)。

### 4.3 内存实例与注入
- `pcie_tl tb_top`($unit)创建 `host_inst`(1)+ `dev_inst[N]`(switch 模式 N=下行口数,非 switch N=1),config_db 以 `host_mem_api` set 到对应 agent 路径。
- `pcie_tl_env.build_phase`(use_unified_mem 时):get 句柄;`init_region(0, 0xFFFF_FFFF, mem_alloc_mode, mem_granule)`;PREMAP 时预 `alloc(premap_size)`;注入 rc_agent / ep_agent[i]。

---

## 5. 数据流

### 5.1 PER_BUFFER(测试控地址)
```
seq: a = host_mem.alloc(256,64); host_mem.write_mem(a, golden)
     EP 发 MRd a（ep_sqr）→ RC.rc_driver.handle_request(MRd)
        data = host_mem.read_mem(a,len) → 生成 CplD → 发回 EP
     EP 收 CplD；或 seq 直接 host_mem.read_mem 校验
seq 末: host_mem.free(a); leak_check()
反向同理：RC 发 MWr/MRd 到 ep dev_mem，ep_driver 应答。
```

### 5.2 PREMAP(真实自选地址 DUT)
env 启动对相应实例 `init_region` + `alloc(整窗)`,DUT 自选地址落窗内即应答,窗外 FATAL。窗口有界(host_mem 密集存储)。

---

## 6. 配置项（pcie_tl_env_config 新增）
| 字段 | 类型 | 默认 | 含义 |
|---|---|---|---|
| `use_unified_mem` | bit | 0 | 关=sparse mem_space;开=host_mem |
| `mem_access_mode` | enum | PER_BUFFER | PER_BUFFER \| PREMAP |
| `premap_base` | bit[63:0] | 0 | PREMAP 窗口基址 |
| `premap_size` | int unsigned | 16MB | PREMAP 窗口大小(有界) |
| `mem_alloc_mode` | alloc_mode_e | MODE_BUDDY | 透传 host_mem |
| `mem_granule` | int unsigned | 16 | 透传 host_mem |

⚠️ **do_copy 必查**:env 对 cfg 若有 clone(分 rc/ep 配置),且 `pcie_tl_env_config` 无 `do_copy`/`uvm_field` → clone 丢字段(xilinx 实证过此坑)。实施第一步查 `pcie_tl_env_config` 的 copy 机制,无则补全字段 do_copy。

---

## 7. 验证 / 成功标准

新建 pcie_tl 的 `unified_mem` demo test(use_unified_mem=1):
1. **PER_BUFFER 双向**:EP→host_mem(RC 应答)、RC→ep dev_mem(EP 应答)各 MWr+MRd roundtrip,数据一致(host_mem.read_mem / mem_compare 校验 + scoreboard 0 失配)。
2. **Atomic**:FetchAdd/Swap/CAS 对 host_mem,验证 RMW + CplD 回原值。
3. **多 EP**(若 switch 模式可达):至少 2 EP 各自 dev_mem 独立,互不干扰。
4. **leak_check**=0。
5. **回归不变**:use_unified_mem=0 时 pcie_tl 现有全部 test 与基线逐位一致。

执行:VCS,远程 `ryan@10.11.10.61:2222`,`source /home/ryan/set-env.sh`。

---

## 8. 风险与缓解
| 风险 | 缓解 |
|---|---|
| RC 新增应答路径触及 monitor→driver 请求投递(RC 原不订阅 request) | gated;先查 base_monitor/base_driver 的 request 投递机制,按 ep 侧方式接;关时不订阅,行为不变 |
| env_config clone 丢字段 | 实施首步查 do_copy,无则补 |
| host_mem 对未分配地址 FATAL | PER_BUFFER 由 seq alloc;PREMAP 由 env 预占窗口 |
| 多 EP 注入路径(switch N) | 按 switch_cfg.num_ds_ports 循环注入 dev_mem[i] |
| MPS/RCB 拆分 + host_mem 后端交互 | 只换存储读写,拆分逻辑不动;demo 用跨 MPS 的大读验证 |

---

## 9. 后续
- 与 xilinx 共享同一 host_mem 实例的组合 env(真实 host 内存跨 VIP 共享)—— 更强复用形态,后续独立 spec。
