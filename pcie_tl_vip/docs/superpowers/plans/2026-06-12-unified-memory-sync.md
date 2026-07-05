# pcie_tl_vip 统一内存接入 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 host_mem 统一内存接入 pcie_tl_vip:ep_driver 存储后端 mem_space→host_mem,rc_driver 新增对称内存应答,`use_unified_mem` 门控默认关,回归不破。

**Architecture:** driver 层换存储后端(保留 ep_driver 的 MPS/RCB 拆分/SR-IOV/Cfg/IO);env 是 TLP 路由中枢(已在 line 276/436 调 `ep_driver.handle_request`),新增把 EP 发起的访存请求路由到 `rc_driver.handle_request`;内存实例在 tb($unit)建、以 `host_mem_api` 句柄经 config_db 注入(每 agent 独立实例)。

**Tech Stack:** SystemVerilog / UVM 1.2 / VCS Q-2020.03;依赖 `shm_work/host_mem`(host_mem_api 已就绪)。

**Spec:** `docs/superpowers/specs/2026-06-12-unified-memory-sync-design.md`

---

## 执行环境

- 远程 VCS:`ryan@10.11.10.61:2222`(pw `Ryan@2025`),`source /home/ryan/set-env.sh`。远程 pcie_tl_vip:`/home/ryan/pcie_work/pcie_tl_vip`(只有 docs/src/tests,**无 sim 构建**)。host_mem 远程:`/home/ryan/shm_work/host_mem`(已含 host_mem_api)。
- 本地 `/home/ubuntu/ryan/pcie_work/pcie_tl_vip`(git 仓 root 为 `/home/ubuntu/ryan/pcie_work`,分支 `feat/unified-memory-sync`)。同步改动文件用 scp 到远程对应路径(本地 `/home/ubuntu/ryan/...`→远程 `/home/ryan/...`)。
- 提交:每 Task 末一次,分支 `feat/unified-memory-sync`。

> **重要前置**:pcie_tl_vip 无构建脚本,Task 1 先建 filelist + 编译/运行,确立回归基线;后续 Task 引用该基线。

---

## 文件结构

| 文件 | 改动 |
|---|---|
| `sim/filelist.f`(新建) + `sim/run.sh`(新建) | pcie_tl_vip 独立构建(if + pkg + host_mem + tb + tests) |
| `src/pcie_tl_pkg.sv` | `import host_mem_pkg::*;` |
| `src/env/pcie_tl_env_config.sv` | +use_unified_mem/mem_access_mode/premap_*/mem_alloc_mode/mem_granule + do_copy |
| `src/agent/pcie_tl_ep_driver.sv` | +`host_mem_api mem`;handle_mem_read/write 后端 mem_space→host_mem(gated) |
| `src/agent/pcie_tl_rc_driver.sv` | +`host_mem_api mem`+`auto_response_enable`;新增 `handle_request`(MWr/MRd/MRdLk/Atomic against host_mem) |
| `src/agent/pcie_tl_ep_agent.sv` / `pcie_tl_rc_agent.sv` | get host_mem_api 句柄,传给 driver.mem |
| `src/env/pcie_tl_env.sv` | 建/注入逻辑 + RC 路由(把 EP 请求也路由到 rc_driver.handle_request,gated) |
| `tests/pcie_tl_tb_top.sv` | 建 host_inst(1)+dev_inst[N] 实例,config_db set as host_mem_api |
| `tests/pcie_tl_unified_mem_test.sv`(新建) | demo:双向 roundtrip + atomic + leak |

**顺序**:先 Task 1 建构建+基线 → Task 2/3 不改行为接入(默认关)→ Task 4/5 接通内存 → Task 6 demo → Task 7 收尾。

---

## Task 1: 建 pcie_tl_vip 独立构建 + host_mem 接入 + 捕获基线

**Files:** Create `sim/filelist.f`, `sim/run.sh`; Modify `src/pcie_tl_pkg.sv`

- [ ] **Step 1: 探明编译所需文件顺序**

读 `src/pcie_tl_pkg.sv`(顶层 package,`include` 全部类)、`src/pcie_tl_if.sv`(接口模块)、`tests/pcie_tl_tb_top.sv`(顶层 module,import pcie_tl_pkg + 实例化)。确定编译顺序:接口 → host_mem_pkg → pcie_tl_pkg → tb_top + 各 test。各 test(smoke/base/advanced)经 `+UVM_TESTNAME` 选,需都进编译或 tb 已 include。

- [ ] **Step 2: 写 `sim/filelist.f`**

```
// pcie_tl_vip 独立构建文件列表
+incdir+/home/ryan/shm_work/host_mem/src
/home/ryan/shm_work/host_mem/src/host_mem_pkg.sv
/home/ryan/shm_work/host_mem/src/host_mem_manager.sv
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/types
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/shared
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/agent
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/env
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/adapter
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/base
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/constraints
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/scenario
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/seq/virtual
+incdir+/home/ryan/pcie_work/pcie_tl_vip/src/switch
+incdir+/home/ryan/pcie_work/pcie_tl_vip/tests
/home/ryan/pcie_work/pcie_tl_vip/src/pcie_tl_if.sv
/home/ryan/pcie_work/pcie_tl_vip/src/pcie_tl_pkg.sv
/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_tb_top.sv
```
> 实际 incdir/文件以 Step 1 探明为准(若 tb_top 已 `include` tests,不必单列 test 文件;若 test 是独立编译单元则加入)。本地另写一份用 `/home/ubuntu/ryan/...` 路径,或只维护远程版(本 VIP 仅远程跑)。建议:filelist 用远程 `/home/ryan/...` 路径,本地仅留副本。

- [ ] **Step 3: 写 `sim/run.sh`**

```bash
#!/bin/bash
source /home/ryan/set-env.sh
cd /home/ryan/pcie_work/pcie_tl_vip/sim
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelist.f -o simv -l compile.log
TEST=${1:-pcie_tl_smoke_test}
./simv +UVM_TESTNAME=$TEST +UVM_VERBOSITY=UVM_MEDIUM -l run_$TEST.log
```

- [ ] **Step 4: pkg 导入 host_mem_pkg**

`src/pcie_tl_pkg.sv`,在导入区(uvm/其他 import 之后)加:
```systemverilog
    import host_mem_pkg::*;
```

- [ ] **Step 5: 编译 + 捕获基线**

scp filelist.f + run.sh + pkg 到远程(并 `mkdir -p /home/ryan/pcie_work/pcie_tl_vip/sim`)。远程编译并依次跑现有 test:
```
source /home/ryan/set-env.sh; cd /home/ryan/pcie_work/pcie_tl_vip/sim
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelist.f -o simv -l compile.log; grep -c "^Error" compile.log
for T in pcie_tl_smoke_test pcie_tl_base_test pcie_tl_advanced_test; do ./simv +UVM_TESTNAME=$T -l run_$T.log; echo "### $T"; grep -E "UVM_ERROR :|UVM_FATAL :|PASS|FAIL" run_$T.log | tail -5; done
```
**记录每个 test 的 UVM_ERROR/UVM_FATAL 数与 PASS/FAIL —— 这是基线**(后续 Task 不得变差)。host_mem 接入不应改变任何 test 结果。

- [ ] **Step 6: Commit**
```bash
cd /home/ubuntu/ryan/pcie_work
git add pcie_tl_vip/sim/filelist.f pcie_tl_vip/sim/run.sh pcie_tl_vip/src/pcie_tl_pkg.sv
git commit -m "build(pcie_tl): 建独立构建 filelist/run + 接入 host_mem 编译"
```

---

## Task 2: env_config 配置项 + do_copy

**Files:** Modify `src/env/pcie_tl_env_config.sv`

- [ ] **Step 1: 查现有 copy/clone 机制**

读 `src/env/pcie_tl_env_config.sv`。查 `do_copy`/`uvm_field`/`clone`。查 `src/env/pcie_tl_env.sv` 是否 clone cfg 分发给 rc/ep agent(若 clone 且无 do_copy → 字段会丢,xilinx 实证)。记录结论。

- [ ] **Step 2: 加枚举 + 字段**

class 前加:
```systemverilog
typedef enum bit { PCIE_TL_MEM_PER_BUFFER = 1'b0, PCIE_TL_MEM_PREMAP = 1'b1 } pcie_tl_mem_access_mode_e;
```
class 内(与现有字段同区):
```systemverilog
    bit                          use_unified_mem  = 1'b0;
    pcie_tl_mem_access_mode_e    mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;
    bit [63:0]                   premap_base      = 64'h0;
    int unsigned                 premap_size      = 32'h0100_0000; // 16MB
    alloc_mode_e                 mem_alloc_mode   = MODE_BUDDY;
    int unsigned                 mem_granule      = 16;
```
(`alloc_mode_e`/`MODE_BUDDY` 来自 host_mem_pkg,已在 pkg import。)

- [ ] **Step 3: do_copy(若 Step 1 判定需要)**

若 env clone cfg 且无 do_copy:加 `virtual function void do_copy(uvm_object rhs)`,`super.do_copy(rhs)` 后 `$cast` 并复制**所有**字段(含新 6 个)。逐字段 `this.x = o.x;`,定宽/动态数组 foreach。若 env 不 clone(直接传同一 cfg),跳过但在 commit message 注明。

- [ ] **Step 4: 编译验证**

scp,远程 `vcs ... -f filelist.f`(同 Task1 Step5 编译命令)。Expected: 0 Error。跑 smoke_test,结果同基线。

- [ ] **Step 5: Commit**
```bash
cd /home/ubuntu/ryan/pcie_work
git add pcie_tl_vip/src/env/pcie_tl_env_config.sv
git commit -m "feat(pcie_tl): env_config 加统一内存配置项 + do_copy（默认关）"
```

---

## Task 3: ep_driver 内存后端换 host_mem（gated）

**Files:** Modify `src/agent/pcie_tl_ep_driver.sv`, `src/agent/pcie_tl_ep_agent.sv`

- [ ] **Step 1: ep_driver 加内存句柄 + byte 转换 helper**

`pcie_tl_ep_driver` 加成员:
```systemverilog
    host_mem_api mem;  // use_unified_mem 时由 ep_agent 注入；为 null 时走原 mem_space
```
加私有 helper(类内):
```systemverilog
    function void um_write(bit [63:0] a, bit [7:0] data[], bit [3:0] fbe, bit [3:0] lbe);
        int total_dw = (data.size()+3)/4; int idx=0;
        for (int dw=0; dw<total_dw; dw++) begin
            bit [3:0] be = (dw==0)?fbe : (dw==total_dw-1 && total_dw>1)?lbe : 4'hF;
            for (int b=0;b<4;b++) begin
                if (idx<data.size()) begin
                    if (be[b]) begin byte one[]; one=new[1]; one[0]=byte'(data[idx]); mem.write_mem(a+idx, one); end
                    idx++;
                end
            end
        end
    endfunction
    function void um_read(bit [63:0] a, int len, output bit [7:0] data[]);
        byte rd[]; mem.read_mem(a, len, rd); data=new[len]; foreach(rd[i]) data[i]=rd[i];
    endfunction
```

- [ ] **Step 2: handle_mem_write 换后端(gated)**

读现 `handle_mem_write`(约 line 183-195,写 `mem_space[mem_req.addr+i]=req.payload[i]`)。改为:
```systemverilog
    if (cfg != null && cfg.use_unified_mem && mem != null) begin
        um_write(mem_req.addr, mem_req.payload, mem_req.first_be, mem_req.last_be);
    end else begin
        // 原 sparse 写（保持不变）
        ... mem_space[mem_req.addr+i] = req.payload[i]; ...
    end
```
> 注:ep_driver 是否有 `cfg` 引用?若无,需让 ep_agent 把 cfg 注入 driver(加 `pcie_tl_env_config cfg;` 成员 + agent connect 赋值)。Step 4 处理注入。

- [ ] **Step 3: handle_mem_read 换数据来源(gated)**

读现 `handle_mem_read`(约 line 126-169,完成数据 `cpl.payload[i]=mem_space.exists(a)?mem_space[a]:0`)。**保留 MPS/RCB 拆分逻辑不变**,只把取数据处改为:gated 时先 `um_read(base_addr, total_len, all_bytes)` 取整段,再按拆分切片填各 CplD;非 gated 走原 mem_space。最小改动:在每个 split 填 payload 处,gated 时用 `mem.read_mem(a, n, rdbytes)` 取该段。

- [ ] **Step 4: ep_agent 注入 cfg + mem 到 driver**

`src/agent/pcie_tl_ep_agent.sv` build_phase(UVM_ACTIVE,$cast ep_driver 后):
```systemverilog
    // 注入 cfg（若 driver 需要 use_unified_mem 判定）
    if (cfg != null) ep_driver.cfg = cfg;          // ep_agent 需先有 cfg 句柄（见下）
    // 注入内存句柄（env 经 config_db set 到 ep_agent*）
    if (cfg != null && cfg.use_unified_mem) begin
        host_mem_api m;
        if (uvm_config_db#(host_mem_api)::get(this, "", "mem", m)) ep_driver.mem = m;
    end
```
> ep_agent 是否有 `cfg`?查 `pcie_tl_ep_agent`/`base_agent`。若 agent 无 cfg 句柄,需让 env 经 config_db set cfg 到 agent,agent build 时 get;或 env 直接赋 `ep_agent.ep_driver.cfg`。按现有 cfg 分发方式(Task 2 Step 1 已查)接。

- [ ] **Step 5: 编译 + 回归(默认关，不变)**

scp,远程编译 + smoke/base/advanced。Expected: 同基线(use_unified_mem=0,mem=null,走原 sparse)。

- [ ] **Step 6: Commit**
```bash
cd /home/ubuntu/ryan/pcie_work
git add pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv pcie_tl_vip/src/agent/pcie_tl_ep_agent.sv
git commit -m "feat(pcie_tl): ep_driver 内存后端可换 host_mem（gated，默认 sparse）"
```

---

## Task 4: rc_driver 对称内存应答 + env 路由

**Files:** Modify `src/agent/pcie_tl_rc_driver.sv`, `src/agent/pcie_tl_rc_agent.sv`, `src/env/pcie_tl_env.sv`

- [ ] **Step 1: rc_driver 加内存句柄 + handle_request**

`pcie_tl_rc_driver` 加:
```systemverilog
    host_mem_api          mem;
    pcie_tl_env_config    cfg;
    bit                   auto_response_enable = 1;
```
加 `handle_request`(镜像 ep 的 mem 处理,只管访存;无 Cfg/IO/SR-IOV):
```systemverilog
    virtual task handle_request(pcie_tl_tlp req);
        if (cfg == null || !cfg.use_unified_mem || mem == null || !auto_response_enable) return;
        case (req.kind)
            TLP_MEM_WR: begin
                pcie_tl_mem_tlp w; if ($cast(w, req)) um_write(w.addr, w.payload, w.first_be, w.last_be);
            end
            TLP_MEM_RD, TLP_MEM_RD_LK: begin
                pcie_tl_mem_tlp r; if ($cast(r, req)) send_mem_completion(r,
                    (req.kind==TLP_MEM_RD_LK)?TLP_CPLD_LK:TLP_CPLD);
            end
            TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS: begin
                pcie_tl_atomic_tlp a; if ($cast(a, req)) send_atomic_completion(a);
            end
            default: ; // RC 不应答 Cfg/IO
        endcase
    endtask
```
加 `um_write`/`um_read`(同 ep_driver Step 1 的 helper),`send_mem_completion`(读 host_mem,按 MPS/RCB 生成 CplD 经 `send_tlp` 发出 —— 复用 base send_tlp + tag/reqid 回填),`send_atomic_completion`(RMW + CplD 回原值)。
> 完成拆分:若 ep_driver 的拆分逻辑可复用,提炼为 `pcie_tl_base_driver` 的 protected 方法供 rc/ep 共用;否则在 rc_driver 内镜像同款拆分。实施时择一(优先提炼到 base_driver)。

- [ ] **Step 2: rc_agent 注入 cfg + mem**

`pcie_tl_rc_agent` build_phase($cast rc_driver 后):
```systemverilog
    if (cfg != null) rc_driver.cfg = cfg;
    if (cfg != null && cfg.use_unified_mem) begin
        host_mem_api m;
        if (uvm_config_db#(host_mem_api)::get(this, "", "mem", m)) rc_driver.mem = m;
    end
```

- [ ] **Step 3: env 路由 EP 请求到 rc_driver**

读 `src/env/pcie_tl_env.sv` 现有路由(line ~276 单 EP、~436 switch)。那里把 RX TLP 路由到 `ep_agent.ep_driver.handle_request`。新增:**EP 发起的访存请求(MWr/MRd/Atomic 且来源为 EP→host 方向)**路由到 `rc_agent.rc_driver.handle_request`,仅 `cfg.use_unified_mem` 时。判定方向:按 TLP 来自 EP 的 monitor / requester_id,沿用 env 现有的方向判定方式。最小实现:在 env 处理 EP→RC 方向 TLP 的分支里(若已有),gated 时调 `rc_agent.rc_driver.handle_request(t)`;若 env 当前无 EP→RC 请求分支,按现 ep 路由对称加一条。

- [ ] **Step 4: 编译 + 回归(默认关，不变)**

scp,远程编译 + smoke/base/advanced。Expected: 同基线(gated off,RC 路由不触发)。

- [ ] **Step 5: Commit**
```bash
cd /home/ubuntu/ryan/pcie_work
git add pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv pcie_tl_vip/src/agent/pcie_tl_rc_agent.sv pcie_tl_vip/src/env/pcie_tl_env.sv
git commit -m "feat(pcie_tl): rc_driver 对称内存应答 + env 路由 EP 请求（gated）"
```

---

## Task 5: tb 建实例 + env 注入（每 agent 独立，switch N）

**Files:** Modify `tests/pcie_tl_tb_top.sv`, `src/env/pcie_tl_env.sv`

- [ ] **Step 1: tb_top 建实例 + config_db set**

读 `tests/pcie_tl_tb_top.sv`,找 config_db set 区(set 接口/cfg 处)与 env 实例名/路径、switch 下行口数来源(cfg.switch_cfg.num_ds_ports)。加:
```systemverilog
    import host_mem_pkg::*;   // 若未 import
    host_mem_manager host_inst;
    host_mem_manager dev_inst[16];   // 上限按最大 EP 数；实际用 num_ds_ports
    initial begin
        host_inst = new("host_mem");
        uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env", "host_mem", host_inst);
        for (int i=0;i<16;i++) begin
            dev_inst[i] = new($sformatf("dev_mem_%0d", i));
            uvm_config_db#(host_mem_api)::set(null, "uvm_test_top.env",
                $sformatf("dev_mem_%0d", i), dev_inst[i]);
        end
    end
```
> dev_inst 上限取最大 EP 数(switch num_ds_ports 上限;非 switch 用 dev_inst[0])。tb 不知运行时 N,故建固定上限数组,env 按实际 N 取用对应 host_mem_api。

- [ ] **Step 2: env get + init_region/PREMAP + 注入**

`pcie_tl_env` 加成员 `host_mem_api host_mem; host_mem_api dev_mem[16];`。build_phase(use_unified_mem 时,创建 agent 后):
```systemverilog
    if (cfg.use_unified_mem) begin
        int nep = (cfg.switch_enable && cfg.switch_cfg!=null) ? cfg.switch_cfg.num_ds_ports : 1;
        void'(uvm_config_db#(host_mem_api)::get(this, "", "host_mem", host_mem));
        host_mem.init_region(64'h0, 64'hFFFF_FFFF, cfg.mem_alloc_mode, cfg.mem_granule);
        if (cfg.mem_access_mode==PCIE_TL_MEM_PREMAP) void'(host_mem.alloc(cfg.premap_size, cfg.mem_granule));
        uvm_config_db#(host_mem_api)::set(this, "rc_agent*", "mem", host_mem);
        for (int i=0;i<nep;i++) begin
            void'(uvm_config_db#(host_mem_api)::get(this, "", $sformatf("dev_mem_%0d", i), dev_mem[i]));
            dev_mem[i].init_region(64'h0, 64'hFFFF_FFFF, cfg.mem_alloc_mode, cfg.mem_granule);
            if (cfg.mem_access_mode==PCIE_TL_MEM_PREMAP) void'(dev_mem[i].alloc(cfg.premap_size, cfg.mem_granule));
            // 注入到第 i 个 ep_agent（单 EP 用 ep_agent；switch 用 ep_agents[i]）
            uvm_config_db#(host_mem_api)::set(this,
                (cfg.switch_enable)?$sformatf("ep_agents_%0d*", i):"ep_agent*", "mem", dev_mem[i]);
        end
    end
```
> ep_agent 实例名/路径以现 env 实际为准(单 EP `ep_agent`、switch `ep_agents[i]` 的实例名)。Task1/4 已读 env,按真实路径写。

- [ ] **Step 3: 编译 + 回归(默认关，不变)**

scp(tb_top + env),远程编译 + smoke/base/advanced。Expected: 同基线。

- [ ] **Step 4: Commit**
```bash
cd /home/ubuntu/ryan/pcie_work
git add pcie_tl_vip/tests/pcie_tl_tb_top.sv pcie_tl_vip/src/env/pcie_tl_env.sv
git commit -m "feat(pcie_tl): tb 建 host/dev_mem 实例，env 按 N 注入（每 agent 独立）"
```

---

## Task 6: demo 测试（双向 + atomic + leak）

**Files:** Create `tests/pcie_tl_unified_mem_test.sv`; Modify `sim/filelist.f`

- [ ] **Step 1: 写 test**

`tests/pcie_tl_unified_mem_test.sv` 继承 `pcie_tl_base_test`。build_phase 后设 `cfg.use_unified_mem=1; cfg.mem_access_mode=PCIE_TL_MEM_PER_BUFFER;`(+开 scoreboard 若有)。run_phase:经 env 的 host_mem/dev_mem 句柄(若 test 可达 env.host_mem;否则经 v_sequencer 句柄)做:
1. **EP→host**:`a=env.host_mem.alloc(256,64); env.host_mem.write_mem(a, golden)`;EP 发 MRd a → RC 应答;`env.host_mem.read_mem` 校验;free。
2. **RC→ep dev**:`b=env.dev_mem[0].alloc(256,64)`;RC 发 MWr golden2 到 b → EP 应答存;`env.dev_mem[0].read_mem` 校验;free。
3. **Atomic**:host_mem 预置 old,EP 发 FetchAdd/Swap/CAS,校验 new + CplD。
4. `env.host_mem.leak_check(); env.dev_mem[0].leak_check();`
> 序列发 TLP 的方式沿用 pcie_tl 现有 seq(mem_rd/mem_wr/atomic seq 在 src/seq/base)。test 经 sequencer 启动,目标 addr 用 alloc 出的地址。

- [ ] **Step 2: filelist 加 test**

`sim/filelist.f` 加 `/home/ryan/pcie_work/pcie_tl_vip/tests/pcie_tl_unified_mem_test.sv`(若 test 独立编译)。

- [ ] **Step 3: 跑 demo**

scp,远程编译 + `./simv +UVM_TESTNAME=pcie_tl_unified_mem_test -l run_um.log`。Expected: 0 UVM_ERROR/FATAL;各校验 PASS;`Leak check passed`。失败则 DEBUG(参考 xilinx 同类经验:requester_id/completer_id、send 路径、host_mem alloc),迭代或报 BLOCKED。

- [ ] **Step 4: Commit**
```bash
cd /home/ubuntu/ryan/pcie_work
git add pcie_tl_vip/tests/pcie_tl_unified_mem_test.sv pcie_tl_vip/sim/filelist.f
git commit -m "test(pcie_tl): unified_mem demo（双向 roundtrip + atomic + leak）"
```

---

## Task 7: 全回归双模式 + memory 归档

- [ ] **Step 1: OFF 回归**

远程跑 smoke/base/advanced(use_unified_mem=0)。Expected: 与 Task 1 基线逐项一致。

- [ ] **Step 2: ON demo**

`pcie_tl_unified_mem_test` 全绿 + leak 0。

- [ ] **Step 3: 更新 memory**

`/home/ubuntu/.claude/projects/-home-ubuntu-ryan-xilinx-pcie/memory/` 记:pcie_tl 统一内存接入完成(driver 后端换 host_mem + rc 对称 + 每 EP 独立 dev_mem);分支 feat/unified-memory-sync。更新 MEMORY.md 指针。

- [ ] **Step 4: Commit 收尾**
```bash
cd /home/ubuntu/ryan/pcie_work
git add -A
git commit -m "chore(pcie_tl): 统一内存 feature 双模式回归通过收尾"
```

---

## 自检

- **Spec 覆盖:** D1(只内存,Task3-5)✓ D2(每 EP 独立 dev_mem,Task5)✓ D3(driver 换后端 + RC 对称,Task3/4)✓ D4(PER_BUFFER+PREMAP,Task5/6)✓ D5(use_unified_mem 默认关 + 各 Task 回归门,Task2)✓ D6(host_mem_api + tb 建实例,Task5)✓。RC 对称应答(spec §2 核心)→ Task4 ✓。
- **类型一致:** `host_mem_api mem`(Task3/4/5)、`um_write/um_read`(Task3 def,Task4 复用)、`use_unified_mem`/`mem_access_mode`/`PCIE_TL_MEM_PREMAP`(Task2)、`handle_request`(Task4,env 调 Task4 Step3)全程一致。
- **执行期裁决(已标注):** Task1 filelist 实际文件以探明为准;Task2 do_copy 视 env 是否 clone;Task3/4 cfg 注入路径按现有分发方式;Task4 完成拆分优先提炼到 base_driver;Task5 ep_agent 实例名(单 EP vs switch ep_agents[i])按真实 env。
- **占位符扫描:** 无 TBD/TODO;改代码步骤均含具体代码或精确探查指令(pcie_tl 无构建/RC 无 mem,Task1/4 含必要 discovery,已注明)。
