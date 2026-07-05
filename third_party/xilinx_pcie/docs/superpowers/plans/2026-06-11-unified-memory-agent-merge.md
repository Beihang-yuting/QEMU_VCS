# 统一内存接入 + RC/EP Agent 合并 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 接入 host_mem_manager 双实例并让 RC/EP 对称应答访存,同时把 rc/ep agent 合并为单个 role 参数化 agent;全程 `use_unified_mem` 门控默认关,回归不破。

**Architecture:** `base_agent` 重命名演进为 `xilinx_pcie_agent`(role 参数化),吸收 rc/ep 子类逻辑为 `if(role==...)` 分支;新增共享 `xilinx_pcie_mem_responder` 处理 MWr/MRd/MRdLk/Atomic;env 建 host_mem/dev_mem 两实例经 config_db 注入。

**Tech Stack:** SystemVerilog / UVM 1.2 / VCS Q-2020.03;依赖 `shm_work/host_mem`(host_mem_manager)、`axis_vip`、`pcie_tl_vip`。

**Spec:** `docs/superpowers/specs/2026-06-11-unified-memory-agent-merge-design.md`

---

## 执行环境约定(每个验证步骤通用)

- 远程编译/仿真主机:`ryan@10.11.10.61:2222`(pw `Ryan@2025`),`source /home/ryan/set-env.sh` 后有 vcs。
- 本地改完 → `scp` 同步改动文件到远程同路径 → 远程 `cd /home/ryan/xilinx_pcie/sim` 跑 `make`。
- 编译:`make compile DATA_WIDTH=256 STRADDLE_EN=0`(看 `COMPILE_OK` / compile.log 无 Error)。
- 单测:`make sim TEST=<name> SEED=1`,读 `logs/<name>_1.log` 的 scoreboard 摘要 + `UVM_ERROR/UVM_FATAL` 计数。
- 全回归(no-regression 门):sanity/loopback/stress/mega_stress/straddle 五个,期望与基线一致:
  sanity 22/22、loopback 502/502、stress 502/502、mega 10250/10250、straddle 202/202;均 0 未匹配 0 数据错 0 ERROR。
- 提交频率:每个 Task 末提交一次。分支 `feat/unified-memory-agent-merge`(已存在)。

---

## 文件结构(决策锁定)

| 文件 | 职责 |
|---|---|
| `src/agent/xilinx_pcie_agent.sv` | (由 base_agent 改名+演进)唯一 role 参数化 agent,持 4×axis_agent/driver/monitor/共享mgr + 内存实例 + responder + 角色分支 |
| `src/agent/xilinx_pcie_mem_responder.sv` | 共享 responder:收访存请求→访本地内存→发 CplD |
| `src/env/xilinx_pcie_env_config.sv` | +use_unified_mem/mem_access_mode/premap_*/mem_alloc_mode/mem_granule + 枚举 |
| `tb/tb_top.sv` | 在 $unit 作用域创建 host_mem/dev_mem 具体实例,以 host_mem_api 句柄经 config_db 传入 env |
| `src/env/xilinx_pcie_env.sv` | 两同类 agent 实例 + get host_mem/dev_mem 句柄 + init_region/PREMAP + 注入 agent |
| `src/env/xilinx_pcie_virtual_sequencer.sv` | 挂 host_mem/dev_mem 句柄(host_mem_api) |
| `src/seq/xilinx_pcie_dma_seq.sv` | use_unified_mem 时 alloc/free 模式 |
| `src/xilinx_pcie_pkg.sv` | include 调整 + import host_mem_pkg |
| `sim/filelist.f` | +host_mem 两文件 + incdir |
| `tests/xilinx_pcie_unified_mem_test.sv` | demo + 成功标准 |
| 删除 | `xilinx_pcie_rc_agent.sv`、`xilinx_pcie_ep_agent.sv`、`xilinx_pcie_base_agent.sv` |

**实现顺序原则:** 先做"不改行为"的接入(filelist/pkg/config 字段,默认关)→ 再做 agent 合并(用 use_unified_mem=0 回归守住)→ 再叠加内存功能(use_unified_mem=1)→ 最后 demo test。

---

## Task 1: host_mem 编译接入(不改行为)

**Files:**
- Modify: `sim/filelist.f`
- Modify: `src/xilinx_pcie_pkg.sv:13-16`(import 区)

- [ ] **Step 1: filelist 加 host_mem 源 + incdir**

在 `sim/filelist.f` 的 "1. AXI-Stream VIP" 段之后、"2. PCIe TL VIP" 之前插入:
```
//-----------------------------------------------------------------------------
// 1b. Host Memory Manager（shm_work/host_mem）：统一内存模型
//-----------------------------------------------------------------------------
+incdir+/home/ryan/shm_work/host_mem/src
/home/ryan/shm_work/host_mem/src/host_mem_pkg.sv
/home/ryan/shm_work/host_mem/src/host_mem_manager.sv
```
注意:本地 filelist 用 `/home/ubuntu/ryan/...` 路径,远程用 `/home/ryan/...`。改动两边对应路径(本地 `/home/ubuntu/ryan/shm_work/host_mem/...`,远程 `/home/ryan/shm_work/host_mem/...`)。

- [ ] **Step 2: pkg 导入 host_mem_pkg**

`src/xilinx_pcie_pkg.sv`,在 `import pcie_tl_pkg::*;` 之后加:
```systemverilog
    // 导入 Host Memory Manager package（host_mem_manager 类）
    import host_mem_pkg::*;
```

- [ ] **Step 3: 验证编译**(host_mem 进入编译且无符号冲突)

同步 filelist.f + pkg 到远程,远程跑:
```
make compile DATA_WIDTH=256 STRADDLE_EN=0
```
Expected: `COMPILE_OK`,compile.log 无 Error(尤其无 host_mem_pkg/host_mem_manager 重定义或找不到)。

- [ ] **Step 4: 烟囱回归**(确认接入未破坏现有)

```
make sim TEST=xilinx_pcie_sanity_test SEED=1
```
Expected: sanity 22/22 匹配,0 ERROR。

- [ ] **Step 5: Commit**
```bash
git add sim/filelist.f src/xilinx_pcie_pkg.sv
git commit -m "build(xilinx-pcie): 接入 host_mem_manager 编译(filelist + pkg import)"
```

---

## Task 2: env_config 新增配置项(不改行为,默认关)

**Files:**
- Modify: `src/env/xilinx_pcie_env_config.sv`

- [ ] **Step 1: 加枚举(文件内 class 之前或 types 段)**

```systemverilog
// 内存访问模式：PER_BUFFER=序列显式 alloc/free；PREMAP=env 预映射有界窗口
typedef enum bit { XILINX_MEM_PER_BUFFER = 1'b0, XILINX_MEM_PREMAP = 1'b1 } xilinx_mem_access_mode_e;
```
(host_mem 的 `alloc_mode_e`/`MODE_BUDDY` 已由 host_mem_pkg 提供,直接用。)

- [ ] **Step 2: 加配置字段(class 内,与现有 extended_tag_enable 等同区)**

```systemverilog
    // ---- 统一内存接入（默认关，关时走原 sparse mem_space）----
    bit                          use_unified_mem  = 1'b0;
    xilinx_mem_access_mode_e     mem_access_mode  = XILINX_MEM_PER_BUFFER;
    bit [63:0]                   premap_base      = 64'h0;     // PREMAP 窗口基址
    int unsigned                 premap_size      = 32'h0100_0000; // 16MB（有界）
    alloc_mode_e                 mem_alloc_mode   = MODE_BUDDY; // 透传 host_mem
    int unsigned                 mem_granule      = 16;         // 透传 host_mem
```

- [ ] **Step 3: clone 一致性检查**

确认 env_config 有 `do_copy`/clone(现有 clone 已用于 rc_cfg/ep_cfg)。新字段是值类型,默认 `uvm_field` 或现有 copy 机制会带上;若 env_config 用手写 do_copy,在其中补这 6 个字段的复制。打开文件搜索 `do_copy`/`copy`,按现有风格补齐。

- [ ] **Step 4: 验证编译**

同步,远程 `make compile DATA_WIDTH=256 STRADDLE_EN=0`。Expected: `COMPILE_OK`。

- [ ] **Step 5: Commit**
```bash
git add src/env/xilinx_pcie_env_config.sv
git commit -m "feat(xilinx-pcie): env_config 加统一内存配置项（默认关）"
```

---

## Task 3: 新建共享 mem_responder（先独立编译，未接线）

**Files:**
- Create: `src/agent/xilinx_pcie_mem_responder.sv`
- Modify: `src/xilinx_pcie_pkg.sv`（include 新文件，放在 agent include 之前）

- [ ] **Step 1: 写 responder 类**

`src/agent/xilinx_pcie_mem_responder.sv`(普通 class,非 component;宿主 agent 提供内存句柄;返回 CplD 由宿主发送):
```systemverilog
//=============================================================================
// 共享内存应答器：收访存请求 → 访本地 host_mem_manager → 返回 CplD（宿主发送）
// MWr(posted,无回复) / MRd / MRdLk / Atomic(FetchAdd/Swap/CAS)
//=============================================================================
class xilinx_pcie_mem_responder;

    host_mem_manager mem;            // 本 agent 的内存实例（host_mem 或 dev_mem）
    bit [15:0]       completer_id;   // 完成者 BDF（宿主注入）

    function new(host_mem_manager mem = null, bit [15:0] completer_id = 16'h0);
        this.mem          = mem;
        this.completer_id = completer_id;
    endfunction

    // byte[] <-> bit[7:0][] 转换（同位宽）
    function void from_bytearr(input byte src[], output bit [7:0] dst[]);
        dst = new[src.size()];
        foreach (src[i]) dst[i] = src[i];
    endfunction

    // 处理一个收到的请求；返回需要发出的 CplD（无需回复时返回 null）
    function pcie_tl_cpl_tlp handle_mem_request(pcie_tl_tlp req);
        pcie_tl_mem_tlp    mem_req;
        pcie_tl_atomic_tlp atm_req;
        if (mem == null) return null;

        if (req.kind == TLP_MEM_WR) begin
            if ($cast(mem_req, req)) write_with_be(mem_req);
            return null; // posted，无 completion
        end
        if (req.kind == TLP_MEM_RD || req.kind == TLP_MEM_RD_LK) begin
            if (!$cast(mem_req, req)) return null;
            return build_read_cpl(mem_req,
                (req.kind == TLP_MEM_RD_LK) ? TLP_CPLD_LK : TLP_CPLD);
        end
        if (req.kind inside {TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS}) begin
            if ($cast(atm_req, req)) return build_atomic_cpl(atm_req);
            return null;
        end
        return null; // Cfg/IO 等由 EP 分支单独处理
    endfunction

    // 按 first_be/last_be 仅写使能字节
    protected function void write_with_be(pcie_tl_mem_tlp r);
        int total_dw = (r.payload.size() + 3) / 4;
        int idx = 0;
        for (int dw = 0; dw < total_dw; dw++) begin
            bit [3:0] be = (dw==0) ? r.first_be :
                           (dw==total_dw-1 && total_dw>1) ? r.last_be : 4'hF;
            for (int b = 0; b < 4; b++) begin
                if (idx < r.payload.size()) begin
                    if (be[b]) begin
                        byte one[]; one = new[1]; one[0] = byte'(r.payload[idx]);
                        mem.write_mem(r.addr + idx, one, `__FILE__, `__LINE__);
                    end
                    idx++;
                end
            end
        end
    endfunction

    protected function pcie_tl_cpl_tlp build_read_cpl(pcie_tl_mem_tlp r, tlp_kind_e k);
        pcie_tl_cpl_tlp cpl;
        byte rd[];
        int  len = (r.length == 0) ? 4096 : r.length * 4;
        mem.read_mem(r.addr, len, rd, `__FILE__, `__LINE__);
        cpl = pcie_tl_cpl_tlp::type_id::create("mem_cpl");
        cpl.kind         = k;
        cpl.fmt          = FMT_3DW_WITH_DATA;
        cpl.requester_id = r.requester_id;
        cpl.tag          = r.tag;
        cpl.completer_id = completer_id;
        cpl.cpl_status   = CPL_STATUS_SC;
        cpl.length       = r.length;
        cpl.byte_count   = len[11:0];
        cpl.lower_addr   = r.addr[6:0];
        from_bytearr(rd, cpl.payload);
        return cpl;
    endfunction

    // FetchAdd/Swap/CAS：读 old → 计算 new → 写回 → CplD 回 old
    protected function pcie_tl_cpl_tlp build_atomic_cpl(pcie_tl_atomic_tlp r);
        pcie_tl_cpl_tlp cpl;
        byte oldb[]; byte newb[];
        int  sz = r.is_64bit ? 8 : 4;
        mem.read_mem(r.addr, sz, oldb, `__FILE__, `__LINE__);
        compute_atomic(r, oldb, sz, newb);     // output newb
        mem.write_mem(r.addr, newb, `__FILE__, `__LINE__);
        cpl = pcie_tl_cpl_tlp::type_id::create("atomic_cpl");
        cpl.kind = TLP_CPLD; cpl.fmt = FMT_3DW_WITH_DATA;
        cpl.requester_id = r.requester_id; cpl.tag = r.tag;
        cpl.completer_id = completer_id; cpl.cpl_status = CPL_STATUS_SC;
        cpl.length = sz/4; cpl.byte_count = sz; cpl.lower_addr = r.addr[6:0];
        from_bytearr(oldb, cpl.payload); // 回原值
        return cpl;
    endfunction

    // operand/compare/swap 取自 r.payload（小端）；结果写 output newb
    protected function void compute_atomic(pcie_tl_atomic_tlp r, input byte oldb[],
                                           input int sz, output byte newb[]);
        longint unsigned oldv = 0, opnd = 0, cmp = 0, swp = 0, nv = 0;
        newb = new[sz];
        for (int i = 0; i < sz; i++) oldv |= (longint'(oldb[i]) & 'hFF) << (8*i);
        // payload 字节 → operand（和 CAS 的 compare/swap）
        for (int i = 0; i < sz; i++)
            if (i < r.payload.size()) opnd |= (longint'(r.payload[i]) & 'hFF) << (8*i);
        case (r.kind)
            TLP_ATOMIC_FETCHADD: nv = oldv + opnd;
            TLP_ATOMIC_SWAP:     nv = opnd;
            TLP_ATOMIC_CAS: begin
                for (int i = 0; i < sz; i++) begin
                    if (i < r.payload.size())          cmp |= (longint'(r.payload[i])      & 'hFF) << (8*i);
                    if (sz+i < r.payload.size())        swp |= (longint'(r.payload[sz+i])   & 'hFF) << (8*i);
                end
                nv = (oldv == cmp) ? swp : oldv;
            end
            default: nv = oldv;
        endcase
        for (int i = 0; i < sz; i++) newb[i] = byte'((nv >> (8*i)) & 'hFF);
    endfunction

endclass
```

- [ ] **Step 2: pkg include**

`src/xilinx_pcie_pkg.sv`,在 `` `include "agent/xilinx_pcie_channel_router.sv" `` 之后、driver include 之前加:
```systemverilog
    // 共享内存应答器（被统一 agent 复用）
    `include "agent/xilinx_pcie_mem_responder.sv"
```

- [ ] **Step 3: 验证编译**

同步,远程 `make compile`。Expected: `COMPILE_OK`。(此时 responder 未被引用,仅验证类本身编译。)

- [ ] **Step 4: Commit**
```bash
git add src/agent/xilinx_pcie_mem_responder.sv src/xilinx_pcie_pkg.sv
git commit -m "feat(xilinx-pcie): 新建共享 mem_responder（MWr/MRd/MRdLk/Atomic）"
```

---

## Task 4: base_agent 改名为 xilinx_pcie_agent（纯重命名，零行为变更）

**Files:**
- Rename: `src/agent/xilinx_pcie_base_agent.sv` → `src/agent/xilinx_pcie_agent.sv`
- Modify: `src/xilinx_pcie_pkg.sv`(include 路径)
- Modify: `src/agent/xilinx_pcie_rc_agent.sv`, `src/agent/xilinx_pcie_ep_agent.sv`(extends 改名)

- [ ] **Step 1: 重命名文件 + 类名**

```bash
git mv src/agent/xilinx_pcie_base_agent.sv src/agent/xilinx_pcie_agent.sv
```
文件内类名 `xilinx_pcie_base_agent` 全部改为 `xilinx_pcie_agent`(class 声明、`endclass : ...`、构造/工厂宏)。

- [ ] **Step 2: 更新引用**

- `src/xilinx_pcie_pkg.sv`:`` `include "agent/xilinx_pcie_base_agent.sv" `` → `xilinx_pcie_agent.sv`。
- rc_agent/ep_agent 的 `extends xilinx_pcie_base_agent` → `extends xilinx_pcie_agent`(下个 Task 才删它们)。

- [ ] **Step 3: 验证编译 + 全回归(关键:零行为变更)**

同步全部改动,远程:
```
make compile DATA_WIDTH=256 STRADDLE_EN=0
make sim TEST=xilinx_pcie_sanity_test SEED=1
make sim TEST=xilinx_pcie_loopback_test SEED=1
make sim TEST=xilinx_pcie_stress_test SEED=1
make sim TEST=xilinx_pcie_mega_stress_test SEED=1
make straddle SEED=1
```
Expected: 五个全绿,数值同基线(见执行环境约定)。

- [ ] **Step 4: Commit**
```bash
git add -A
git commit -m "refactor(xilinx-pcie): base_agent 改名为 xilinx_pcie_agent（零行为变更）"
```

---

## Task 5: 把 rc/ep 角色逻辑吸收进 xilinx_pcie_agent（role 分支，use_unified_mem=0 行为不变）

**Files:**
- Modify: `src/agent/xilinx_pcie_agent.sv`
- Delete: `src/agent/xilinx_pcie_rc_agent.sv`, `src/agent/xilinx_pcie_ep_agent.sv`
- Modify: `src/xilinx_pcie_pkg.sv`(去掉 rc/ep include)
- Modify: `src/env/xilinx_pcie_env.sv`(两实例改用 xilinx_pcie_agent)

- [ ] **Step 1: 把 rc_agent 成员/方法搬入 agent，role==RC 守卫**

将 `xilinx_pcie_rc_agent` 的:`outstanding_reqs`/`outstanding_times`/`next_bar_addr`/`timeout_check_interval_ns` 成员、`rc_rx_imp` 及其 typedef、`register_outstanding_req`/`handle_completion`/`check_completion_timeout`/`allocate_bar_address` 原样搬入 `xilinx_pcie_agent`。`connect_phase` 订阅 + `run_phase` 起 `check_completion_timeout` 后台任务,均以 `if (cfg.role == XILINX_PCIE_RC)` 守卫。**删去原 rc_agent build_phase 里"强制 role=RC"的 workaround**(role 由 env 按实例路径下发,见 Step 4)。

- [ ] **Step 2: 把 ep_agent 成员/方法搬入 agent，role==EP 守卫**

将 `xilinx_pcie_ep_agent` 的:`mem_space`、`rx_imp` 及其 typedef、`write`(回调)、`handle_rx_tlp`、`mem_write`/`mem_read`、`generate_completion`/`send_completion`、DMA 相关搬入。EP 专属订阅与 `handle_rx_tlp` 处理以 `if (cfg.role == XILINX_PCIE_EP)` 守卫。**本 Task 保持 use_unified_mem=0 走原 `mem_space` 路径(不接 host_mem)。**

> 统一 rx 回调:cpl→释放 tag(**两 role 都做**,原 rc 的 handle_completion 通用化);非 cpl 访存请求→ role==EP 时 handle_rx_tlp(原 sparse)。RC 此时不应答请求(use_unified_mem=0 下 RC 本就不需要,与基线一致)。

- [ ] **Step 3: 删除 rc/ep 文件 + pkg include**

```bash
git rm src/agent/xilinx_pcie_rc_agent.sv src/agent/xilinx_pcie_ep_agent.sv
```
`src/xilinx_pcie_pkg.sv` 删除这两行 include。

- [ ] **Step 4: env 改用统一 agent 类**

`src/env/xilinx_pcie_env.sv`:
- `xilinx_pcie_rc_agent rc_agent;` → `xilinx_pcie_agent rc_agent;`
- `xilinx_pcie_ep_agent ep_agent;` → `xilinx_pcie_agent ep_agent;`
- `type_id::create("rc_agent", this)` / `("ep_agent", this)` 类型改 `xilinx_pcie_agent`(**实例名不变**,保 tb_top config_db 路径)。
- 确认 rc_cfg.role=RC / ep_cfg.role=EP 的 config_db set 仍在(已存在)。

- [ ] **Step 5: 验证编译 + 全回归(核心 no-regression 门)**

同步,远程跑五个 test(同 Task 4 Step 3)。Expected: 全绿,数值同基线。**不过则回退排查。**

- [ ] **Step 6: Commit**
```bash
git add -A
git commit -m "refactor(xilinx-pcie): rc/ep agent 合并入 role 参数化 xilinx_pcie_agent"
```

---

## Task 6: 建 host_mem/dev_mem 实例（tb_top）并注入（use_unified_mem 门控）

> **重要(实现期发现):** env/agent/seq 都在 `xilinx_pcie_pkg` 内,SV 禁止 package 引用 `$unit` 作用域类 `host_mem_manager`,故**不能在 env 里 `host_mem_manager::type_id::create`**。改为:在 `tb/tb_top.sv`(`$unit`/module 作用域,可命名 `host_mem_manager`)创建两实例,经 config_db 以 **`host_mem_api`** 句柄类型传入;env/agent/seq/v_sqr 一律持 **`host_mem_api`** 句柄(完整方法集已暴露)。

**Files:**
- Modify: `tb/tb_top.sv`(创建实例 + config_db set)
- Modify: `src/env/xilinx_pcie_env.sv`(get 句柄 + init_region/PREMAP + 挂 v_sqr)
- Modify: `src/env/xilinx_pcie_virtual_sequencer.sv`(host_mem_api 句柄)
- Modify: `src/agent/xilinx_pcie_agent.sv`(host_mem_api 句柄 + responder 成员)

- [ ] **Step 1: v_sqr 挂句柄(host_mem_api 类型)**

`xilinx_pcie_virtual_sequencer` 加:
```systemverilog
    host_mem_api host_mem;  // RC 侧内存（抽象句柄）
    host_mem_api dev_mem;   // EP 侧内存
```

- [ ] **Step 2: agent 持内存句柄(host_mem_api) + responder 成员**

`xilinx_pcie_agent` 加成员:
```systemverilog
    host_mem_api              mem;       // 本实例内存（RC=host_mem, EP=dev_mem）
    xilinx_pcie_mem_responder mem_resp;  // use_unified_mem 时实例化
```
`build_phase`(use_unified_mem 时,get 到 mem 后):
```systemverilog
    if (cfg.use_unified_mem) begin
        void'(uvm_config_db#(host_mem_api)::get(this, "", "mem", mem));
        mem_resp = new(mem, (cfg.role == XILINX_PCIE_EP) ? 16'h0100 : 16'h0000);
    end
```
注意:`xilinx_pcie_mem_responder` 的成员 `mem` 类型应为 `host_mem_api`(Task 3 已如此 —— 若 Task3 写成 host_mem_manager 需在本 Task 改为 host_mem_api)。completer_id 用常量(RC=16'h0000、EP=16'h0100);若 env_config 已有 BDF 字段则用之。

- [ ] **Step 3: tb_top 创建实例 + config_db set（host_mem_api 类型）**

`tb/tb_top.sv`(module 作用域可命名 host_mem_manager)。在 `run_test()` 之前的 initial 区(与现有 config_db set 同处):
```systemverilog
    // 统一内存：在 $unit 作用域创建具体 host_mem_manager，以 host_mem_api 句柄传入 UVM
    host_mem_manager host_mem_inst;
    host_mem_manager dev_mem_inst;
    initial begin
        host_mem_inst = new("host_mem");
        dev_mem_inst  = new("dev_mem");
        // 以抽象类型 set，env 端以 host_mem_api get（与 package 内代码兼容）
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "host_mem", host_mem_inst);
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "dev_mem",  dev_mem_inst);
    end
```
> tb_top 顶部需可见 `host_mem_pkg`/`host_mem_manager`:tb_top 已 `import` 相关 pkg(确认有 `import host_mem_pkg::*;`;host_mem_manager 经 filelist 在 $unit 编译,tb_top 直接可名)。若 tb_top 未 import,补 `import host_mem_pkg::*;`。

- [ ] **Step 4: env get 句柄 + init_region/PREMAP + 挂 v_sqr**

`xilinx_pcie_env` 加成员 `host_mem_api host_mem, dev_mem;`。`build_phase`(use_unified_mem 时):
```systemverilog
    if (cfg.use_unified_mem) begin
        if (!uvm_config_db#(host_mem_api)::get(this, "", "host_mem", host_mem))
            `uvm_fatal(get_type_name(), "use_unified_mem=1 但未从 tb 拿到 host_mem 句柄")
        if (!uvm_config_db#(host_mem_api)::get(this, "", "dev_mem", dev_mem))
            `uvm_fatal(get_type_name(), "use_unified_mem=1 但未从 tb 拿到 dev_mem 句柄")
        host_mem.init_region(64'h0, 64'hFFFF_FFFF, cfg.mem_alloc_mode, cfg.mem_granule);
        dev_mem.init_region (64'h0, 64'hFFFF_FFFF, cfg.mem_alloc_mode, cfg.mem_granule);
        if (cfg.mem_access_mode == XILINX_MEM_PREMAP) begin
            void'(host_mem.alloc(cfg.premap_size, cfg.mem_granule));
            void'(dev_mem.alloc (cfg.premap_size, cfg.mem_granule));
        end
        uvm_config_db#(host_mem_api)::set(this, "rc_agent*", "mem", host_mem);
        uvm_config_db#(host_mem_api)::set(this, "ep_agent*", "mem", dev_mem);
    end
```
`connect_phase`(use_unified_mem 时):`v_sqr.host_mem = host_mem; v_sqr.dev_mem = dev_mem;`
> `init_region(0, 0xFFFF_FFFF)` 仅建 free 结构,不开销密集内存;密集分配在 alloc()。

- [ ] **Step 5: 验证编译 + 回归(默认关，行为不变)**

同步(含 tb_top.sv),远程 `make compile` + sanity + loopback。Expected: 全绿同基线(开关默认关,responder/mem 未启用)。

- [ ] **Step 6: Commit**
```bash
git add -A
git commit -m "feat(xilinx-pcie): tb_top 建 host_mem/dev_mem 实例，env 经 host_mem_api 注入（门控）"
```

---

## Task 7: agent 在 use_unified_mem 时走 responder（接通内存应答）

**Files:**
- Modify: `src/agent/xilinx_pcie_agent.sv`

- [ ] **Step 1: rx 回调按开关分流**

在 agent 的 rx TLP 回调(收到非 cpl 访存请求时):
```systemverilog
    if (cfg.use_unified_mem) begin
        // EP 仍先处理 Cfg/IO（不在 responder 管辖），内存类交 responder
        if (cfg.role == XILINX_PCIE_EP &&
            t.kind inside {TLP_CFG_RD0,TLP_CFG_WR0,TLP_CFG_RD1,TLP_CFG_WR1,
                           TLP_IO_RD,TLP_IO_WR}) begin
            handle_rx_tlp(t);  // 复用现有 Cfg/IO 分支
        end else begin
            pcie_tl_cpl_tlp cpl;
            cpl = mem_resp.handle_mem_request(t);  // MWr→null；读/原子→CplD
            if (cpl != null) send_completion(cpl); // 经本 agent sequencer 发出
        end
    end else begin
        if (cfg.role == XILINX_PCIE_EP) handle_rx_tlp(t); // 原 sparse 路径
    end
```
> 说明:use_unified_mem=1 时 RC 也经 responder 应答(mem=host_mem);EP 内存类经 responder(mem=dev_mem),Cfg/IO 仍走原 handle_rx_tlp 分支。

- [ ] **Step 2: send_completion 两 role 可用**

确认 `send_completion`(从 ep_agent 搬入的 oneshot-sequence 发送)用本 agent 的 sequencer;完成包目标通道由 router 按 cfg.role 决定(RC→RC 通道,EP→CC 通道),无需角色特判。

- [ ] **Step 3: 验证编译 + 回归(默认关仍绿)**

同步,远程 `make compile` + 五个回归。Expected: 全绿同基线(use_unified_mem=0)。

- [ ] **Step 4: Commit**
```bash
git add -A
git commit -m "feat(xilinx-pcie): agent 在 use_unified_mem 时经 mem_responder 应答访存"
```

---

## Task 8: dma_seq 支持 alloc/free 模式

**Files:**
- Modify: `src/seq/xilinx_pcie_dma_seq.sv`

- [ ] **Step 1: seq 在 use_unified_mem 时 alloc 目标地址**

dma_seq 加字段 `host_mem_api target_mem;`(由上层 vseq 赋值:EP 发起→对端是 host,赋 `v_sqr.host_mem`)。body:
```systemverilog
    if (cfg.use_unified_mem && target_mem != null) begin
        host_addr = target_mem.alloc(total_length, 64);
    end
    // ... 现有：按 MPS/4KB 分片发 DMA TLP ...
    // body 末（确认相关 completion 已收齐 / 或由上层 vseq drain 后）:
    if (cfg.use_unified_mem && target_mem != null) begin
        target_mem.free(host_addr);
    end
```
> free 时机:DMA 写无 completion,可在 body 末 free;DMA 读需等 CplD 收齐再 free。简化:本 seq 只负责 alloc + 发起;free 交由上层 vseq 在 drain 后统一调用(在 demo test 的 vseq 里 free)。执行时按此简化 —— dma_seq 只 alloc(若未分配)并暴露 `host_addr`,free 由 vseq 负责。

- [ ] **Step 2: 验证编译**

同步,远程 `make compile`。Expected: `COMPILE_OK`(use_unified_mem=0 时分支不执行,回归不受影响)。

- [ ] **Step 3: Commit**
```bash
git add src/seq/xilinx_pcie_dma_seq.sv
git commit -m "feat(xilinx-pcie): dma_seq 支持 use_unified_mem 的 alloc 模式"
```

---

## Task 9: demo 测试 + 成功标准（use_unified_mem=1）

**Files:**
- Create: `tests/xilinx_pcie_unified_mem_test.sv`
- Create: `src/seq/xilinx_pcie_unified_mem_vseq.sv`
- Modify: `sim/filelist.f`、`src/xilinx_pcie_pkg.sv`（include vseq）

- [ ] **Step 1: 写 vseq（per-buffer + 双向 + atomic + leak）**

`src/seq/xilinx_pcie_unified_mem_vseq.sv`,body 顺序(经 v_sqr 拿 host_mem/dev_mem):
1. **per-buffer roundtrip**:`addr = v_sqr.dev_mem.alloc(256, 64)`;在 rc_sqr 发 MWr(golden)到 addr(EP 经 dev_mem 应答存)→ 发 MRd 到 addr → 收 CplD;比 CplD payload == golden。`v_sqr.dev_mem.free(addr)`。
2. **host 方向**:`haddr = v_sqr.host_mem.alloc(256,64)`;在 ep_sqr 发 MWr/MRd 到 haddr(RC 经 host_mem 应答);校验;free。
3. **Atomic**:`v_sqr.host_mem.write_mem` 预置 old;ep_sqr 发 FetchAdd/Swap/CAS 各一到该地址;校验 CplD 回 old + `v_sqr.host_mem.read_mem` 得 new。
4. 末:`v_sqr.host_mem.leak_check(); v_sqr.dev_mem.leak_check();`

- [ ] **Step 2: 写 test 类**

`tests/xilinx_pcie_unified_mem_test.sv` 继承 `xilinx_pcie_base_test`,build_phase:
```systemverilog
    cfg.use_unified_mem = 1'b1;
    cfg.mem_access_mode = XILINX_MEM_PER_BUFFER;
    cfg.scb_enable = 1; cfg.scb_completion_check = 1; cfg.scb_data_integrity = 1;
    cfg.interrupt_enable = 0;
```
run_phase: raise objection → 跑 `xilinx_pcie_unified_mem_vseq` → drain(等在途 completion) → drop。

- [ ] **Step 3: filelist + pkg include**

`sim/filelist.f` 测试段加 test 文件(本地/远程对应路径);`src/xilinx_pcie_pkg.sv` 在 seq include 区加 vseq。

- [ ] **Step 4: 验证 —— 跑 demo test**

同步,远程:
```
make compile DATA_WIDTH=256 STRADDLE_EN=0
make sim TEST=xilinx_pcie_unified_mem_test SEED=1
```
Expected: scoreboard 全匹配、0 未匹配、0 数据错;`UVM_ERROR:0 UVM_FATAL:0`;日志含 host_mem `Leak check passed`。

- [ ] **Step 5: PREMAP 子用例**

加 plusarg 或第二 test:`cfg.mem_access_mode = XILINX_MEM_PREMAP; cfg.premap_base/size` 设好,vseq 用窗口内地址(不 alloc,直接发请求)→ 应答成功。窗外访问的负向(FATAL)以注释说明,不纳入自动 PASS 判定。

- [ ] **Step 6: Commit**
```bash
git add tests/xilinx_pcie_unified_mem_test.sv src/seq/xilinx_pcie_unified_mem_vseq.sv sim/filelist.f src/xilinx_pcie_pkg.sv
git commit -m "test(xilinx-pcie): unified_mem demo（per-buffer + 双向 + atomic + leak_check）"
```

---

## Task 10: 全回归双模式收尾

- [ ] **Step 1: use_unified_mem=0 全回归**

远程跑五个老 test。Expected: sanity 22/22、loopback 502/502、stress 502/502、mega 10250/10250、straddle 202/202;全 0 未匹配 0 错。

- [ ] **Step 2: use_unified_mem=1 demo**

`make sim TEST=xilinx_pcie_unified_mem_test SEED=1` 全绿 + leak 0。

- [ ] **Step 3: 更新 memory 归档**

在 `/home/ubuntu/.claude/projects/-home-ubuntu-ryan-xilinx-pcie/memory/` 记:统一内存 feature 完成、agent 已合并(rc/ep→xilinx_pcie_agent)、use_unified_mem 开关语义、双实例 host_mem/dev_mem。更新 MEMORY.md 指针。

- [ ] **Step 4: Commit 收尾**
```bash
git add -A
git commit -m "chore(xilinx-pcie): 统一内存 feature 双模式回归通过收尾"
```

---

## 自检(写完计划后)

- **Spec 覆盖:** D1(单 feature,Task1-10)✓ D2(per-buffer alloc,Task8/9)✓ D3(双实例,Task6)✓ D4(共享 responder,Task3)✓ D5(开关默认关 + 各 Task 回归门,Task2)✓ D6(MWr/MRd/MRdLk/Atomic,Task3)✓ D7(两 role 对称,Task5/7)✓ D8(单 agent 合并,Task4/5)✓ D9(per-buffer+PREMAP,Task6/9)✓。
- **类型一致:** `xilinx_pcie_agent`(Task4 起)、`mem_resp`/`mem`(Task6/7)、`host_mem`/`dev_mem`(Task6/9)、`use_unified_mem`/`mem_access_mode`/`XILINX_MEM_PREMAP`/`XILINX_MEM_PER_BUFFER`(Task2)、`handle_mem_request`/`compute_atomic(output newb)`(Task3)全程一致。
- **执行期裁决(已在步骤标注):** Task3 `compute_atomic` 用 output 形参版;Task6 completer_id 来源(查 env_config BDF 字段,无则常量);Task8 free 交由 vseq;Task6 env 把 host_mem/dev_mem 存为成员供 connect 阶段。
- **占位符扫描:** 无 TBD/TODO;每个改代码步骤含具体代码或精确指令。
