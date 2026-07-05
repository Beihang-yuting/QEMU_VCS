# Xilinx adapter 化实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `xilinx_pcie` 收敛为纯 Xilinx 接口 adapter（`xilinx_pcie_if_adapter extends pcie_tl_if_adapter`），承载 PG213 4 通道 AXIS ⟷ `pcie_tl_tlp` 编解码，协议逻辑全部委托外部 `pcie_tl_vip`。

**Architecture:** 方案 A2 —— adapter 内包 4 个 `axis_agent`（复用 axis_vip 握手）+ 吸收现 driver 的 `send_beats`/`encode_*` 与现 monitor 的 `decode_packet`；send() 由 `router.get_tx_channel` 选通道经 MASTER agent sequencer 发；4 通道 monitor 回调 `decode_packet` → `rx_queue`，receive() 非阻塞 pop。test 用 `set_type_override` 把 `pcie_tl_if_adapter` 换成子类，`mode=SV_IF_MODE`。删除旧 xilinx env/agent/seq/scoreboard，激励用 pcie_tl_vip seq 库 + 薄 Xilinx smoke。

**Tech Stack:** SystemVerilog / UVM-1.2 / VCS（Q-2020.03）。依赖外部 `pcie_tl_vip`（锁定 commit）、`axis_vip`、`host_mem`。

**Spec:** `docs/superpowers/specs/2026-06-29-xilinx-adapter-mode-design.md`

---

## 构建/验证约定（每个任务复用）

VCS 只在远程 **ryan@10.11.10.61:2222**（密码 `Ryan@2025`）。本地无 VCS。构建在 `/tmp/xbuild`。分支 `feat/adapter-mode`（从 master 切）。

**一次性搭建（执行 Task 0 前做一次）：** 同步本 repo + pcie_work + axis_work + shm_work 到 `/tmp/xbuild`，并锁定 pcie_tl_vip 当前 commit：
```bash
ssh -p 2222 ryan@10.11.10.61 'cd /tmp/xbuild/pcie_work && git rev-parse HEAD'   # 记到本计划 §依赖锁定
```

**每个任务 BUILD+RUN（先 rsync 改过的文件到 /tmp/xbuild 对应路径，再）：**
```bash
ssh -p 2222 ryan@10.11.10.61 'source ~/set-env.sh >/dev/null 2>&1
  export TMPDIR=/tmp/xbuild/xilinx_pcie/sim/tmp
  cd /tmp/xbuild/xilinx_pcie/sim && mkdir -p work logs tmp
  vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -full64 -Mdir=csrc_ad \
    -l logs/compile_ad.log -o work/simv_ad -f filelist_adapter.f \
    +define+DATA_WIDTH=256 +define+STRADDLE_EN=0 >/dev/null 2>&1
  echo "vcs rc=$?"; grep -iE "Error-\[" logs/compile_ad.log | head
  ./work/simv_ad +UVM_TESTNAME=<TEST> +DATA_WIDTH=256 +STRADDLE_EN=0 +ntb_random_seed=1 2>&1 \
    | grep -iE "UVM_ERROR :|UVM_FATAL :" | tail -2'
```

**依赖锁定：** pcie_tl_vip commit = `<填入 Task 0 记录的 HEAD>`。

**回退闸门：** Task 1 PoC 任一成败点不可解 → 退方案 B（保留 4 axis_agent 当物理层，adapter 仅桥接），不删旧栈。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `src/adapter/xilinx_pcie_if_adapter.sv`（新） | 核心 adapter：4 axis_agent + send/receive override + decode imp |
| `src/adapter/xilinx_pcie_adapter_pkg.sv`（新） | 打包 adapter + 复用的 codec/router（import pcie_tl_pkg + axis_pkg） |
| `tb/tb_adapter_top.sv`（新） | 例化 pcie_tl_env + 4 通道×2 AXIS + host_mem + run_test |
| `tb/xilinx_adapter_connect.svh`（新） | 把每通道 vif 注册到 adapter 内 axis_agent 路径的宏 |
| `tests/xilinx_pcie_adapter_base_test.sv`（新） | 设 set_type_override + cfg，基类 |
| `tests/xilinx_pcie_adapter_smoke_test.sv`（新） | 薄 Xilinx smoke（编解码往返） |
| `sim/filelist_adapter.f`（新） | pcie_tl_vip src + axis + 本 repo codec/adapter + 新 tb/test |
| 删除（Task 6） | `src/env/*`、`src/agent/xilinx_pcie_agent|driver|monitor|mem_responder.sv`、`src/seq/*`、`src/cfg/*`、旧 13 test + 旧 tb/filelist |

---

## Task 0: 远程构建环境 + filelist_adapter.f（先编译空壳）

**Files:**
- Create: `sim/filelist_adapter.f`
- Create: `src/adapter/xilinx_pcie_adapter_pkg.sv`（暂只 import + 占位）

- [ ] **Step 1: 锁定 pcie_tl_vip commit**

Run（记录输出到本计划 §依赖锁定）:
```bash
ssh -p 2222 ryan@10.11.10.61 'cd /tmp/xbuild/pcie_work && git rev-parse --short HEAD'
```

- [ ] **Step 2: 写 filelist_adapter.f**（顺序：UVM 隐含 → axis pkg → pcie_tl pkg → 本 repo params/types/codec/adapter pkg → tb/test）

```
// ---- include dirs ----
+incdir+/tmp/xbuild/axis_work/axis_vip/src
+incdir+/tmp/xbuild/pcie_work/pcie_tl_vip/src
+incdir+/tmp/xbuild/shm_work/host_mem/src
+incdir+/tmp/xbuild/xilinx_pcie/src
+incdir+/tmp/xbuild/xilinx_pcie/tb
// ---- axis vip ----
-f /tmp/xbuild/axis_work/axis_vip/sim/filelist_lib.f
// ---- host mem ----
/tmp/xbuild/shm_work/host_mem/src/host_mem_pkg.sv
// ---- pcie_tl vip (full pkg: types/codec/managers/agent/env/seq/switch) ----
-f /tmp/xbuild/pcie_work/pcie_tl_vip/sim/filelist.f
// ---- xilinx codec/adapter ----
/tmp/xbuild/xilinx_pcie/src/xilinx_pcie_params.svh
/tmp/xbuild/xilinx_pcie/src/adapter/xilinx_pcie_adapter_pkg.sv
// ---- interfaces ----
/tmp/xbuild/xilinx_pcie/src/interface/xilinx_pcie_if.sv
/tmp/xbuild/xilinx_pcie/src/interface/xilinx_pcie_cfg_if.sv
// ---- tb + tests ----
/tmp/xbuild/xilinx_pcie/tests/xilinx_pcie_adapter_base_test.sv
/tmp/xbuild/xilinx_pcie/tests/xilinx_pcie_adapter_smoke_test.sv
/tmp/xbuild/xilinx_pcie/tb/tb_adapter_top.sv
```
> 注：`pcie_tl_vip/sim/filelist.f` 是否自带顶层 tb / 与本 tb 冲突，Task 0 编译时确认；若它 include 了自己的 `pcie_tl_tb_top.sv`，改为只 include 其 src 列表（去掉它的 tests）。这是 Task 0 的实测点。

- [ ] **Step 3: 写占位 adapter_pkg**（仅验证依赖链能编译）

```systemverilog
`ifndef XILINX_PCIE_ADAPTER_PKG_SV
`define XILINX_PCIE_ADAPTER_PKG_SV
package xilinx_pcie_adapter_pkg;
  import uvm_pkg::*;
  import axis_pkg::*;
  import pcie_tl_pkg::*;
  `include "uvm_macros.svh"
  `include "xilinx_pcie_params.svh"
  // Task 1 起加入 codec/router/adapter include
endpackage
`endif
```

- [ ] **Step 4: 占位 tb + base_test + smoke**（最小可编译，run_test 即返回）

`tb/tb_adapter_top.sv`：
```systemverilog
module tb_adapter_top;
  import uvm_pkg::*; import xilinx_pcie_adapter_pkg::*;
  initial run_test();   // 由 +UVM_TESTNAME 选 test
endmodule
```
`tests/xilinx_pcie_adapter_base_test.sv`：
```systemverilog
class xilinx_pcie_adapter_base_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_base_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this); #100ns; phase.drop_objection(this);
  endtask
endclass
```
`tests/xilinx_pcie_adapter_smoke_test.sv`：暂 `extends xilinx_pcie_adapter_base_test`，空。

- [ ] **Step 5: BUILD**（`filelist_adapter.f`，TEST=`xilinx_pcie_adapter_base_test`）。Expected: `vcs rc=0`。失败多半是 pcie_tl_vip filelist 顶层冲突 / include 顺序 → 按 Step 2 注解修。

- [ ] **Step 6: Commit**
```bash
git add sim/filelist_adapter.f src/adapter/xilinx_pcie_adapter_pkg.sv tb/tb_adapter_top.sv tests/xilinx_pcie_adapter_base_test.sv tests/xilinx_pcie_adapter_smoke_test.sv
git commit -m "build(xilinx-pcie): adapter-mode filelist + compilable skeleton"
```

---

## Task 1: PoC 闸门 —— adapter 骨架 + 1RC+1EP enum+dma 跑通

> 这是**成败闸门**。目标：证明 RC seq 发请求经 adapter→AXIS→对端 adapter→pcie_tl_vip agent 自动响应→completion 回到 RC。通过才做后续；不通过退方案 B。

**Files:**
- Modify: `src/adapter/xilinx_pcie_if_adapter.sv`（新建，核心）
- Modify: `src/adapter/xilinx_pcie_adapter_pkg.sv`（include codec/router/adapter）
- Modify: `tb/tb_adapter_top.sv`（例化 pcie_tl_env + 8 个 axis_if + 交叉接线）
- Create: `tb/xilinx_adapter_connect.svh`
- Modify: `tests/xilinx_pcie_adapter_base_test.sv`（set_type_override + cfg）

- [ ] **Step 1: adapter_pkg 纳入 codec/router/adapter**

在 `xilinx_pcie_adapter_pkg.sv` 的 `endpackage` 前加：
```systemverilog
  `include "xilinx_pcie_types.sv"
  `include "codec/xilinx_tuser_codec.sv"
  `include "codec/xilinx_straddle_engine.sv"
  `include "codec/xilinx_desc_codec.sv"
  `include "agent/xilinx_pcie_channel_router.sv"
  `include "adapter/xilinx_pcie_if_adapter.sv"
```
> 确认这些文件不依赖 `xilinx_pcie_env_config`（codec/router/straddle 应只依赖 params/types）。若 desc/tuser codec 引用 env_config，Task 1 需把所需常量挪到 params 或 adapter 内传参——实现时读文件确认。

- [ ] **Step 2: 写 xilinx_pcie_if_adapter（核心骨架）**

`src/adapter/xilinx_pcie_if_adapter.sv`，关键结构（编解码逻辑直接搬现 driver/monitor，下为骨架与接缝）：
```systemverilog
// 复用 axis_oneshot_seq（从现 driver 搬到本文件或 pkg）
class xilinx_pcie_if_adapter extends pcie_tl_if_adapter;
  `uvm_component_utils(xilinx_pcie_if_adapter)

  xilinx_pcie_role_e         role;
  xilinx_tuser_codec         tuser_codec;
  xilinx_straddle_engine     straddle_eng;
  xilinx_pcie_channel_router router;

  // 4 通道 axis_agent（类型同现 agent：按通道 TUSER 宽度）
  axis_agent_rq_t rq_agent;  axis_agent_rc_t rc_agent;
  axis_agent_cq_t cq_agent;  axis_agent_cc_t cc_agent;

  // 4 analysis imp（解码 axis_packet -> rx_queue）；用 `uvm_analysis_imp_decl 区分
  // （宏声明放文件顶，class 外）

  pcie_tl_tlp rx_queue[$];
  int DATA_WIDTH = 256;

  function new(string name="xilinx_pcie_if_adapter", uvm_component parent=null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // role 由实例名判定
    role = (get_name().substr(0,1) == "rc") ? XILINX_PCIE_RC : XILINX_PCIE_EP;
    mode = SV_IF_MODE;
    tuser_codec  = new(DATA_WIDTH);
    straddle_eng = new(/*straddle_en*/ 1'b0, DATA_WIDTH);
    router       = new(role);
    // 建 4 axis_agent：master/slave 由 role+channel 决定（搬 create_axis_config 逻辑）
    //   RC: rc_agent=MASTER cq_agent=MASTER rq_agent=SLAVE cc_agent=SLAVE
    //   EP: rq_agent=MASTER cc_agent=MASTER cq_agent=SLAVE rc_agent=SLAVE
    // （逐通道 set axis_config 到 config_db 后 create，同现 xilinx_pcie_agent 步骤3）
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // 4 个 axis_agent.mon.packet_ap.connect(<对应 imp>)
    // dummy reset events（搬现 agent connect_phase 步骤0）
  endfunction

  // send：base_driver 调。按 router 选通道 -> 编码 -> 经 MASTER agent sqr 发 beats
  virtual task send(pcie_tl_tlp tlp);
    xilinx_channel_e ch = router.get_tx_channel(tlp);
    // encode_descriptor(tlp,ch) + straddle_eng.pack_single_tlp + 逐 beat encode_tuser
    // + send_beats 到 get_master_sqr(ch)（逻辑搬现 driver encode_and_send/send_beats）
  endtask

  // receive：base_monitor 调，非阻塞 pop
  virtual task receive(output pcie_tl_tlp tlp);
    if (rx_queue.size() > 0) tlp = rx_queue.pop_front();
    else                     tlp = null;
  endtask

  // write_rq/_rc/_cq/_cc：imp 回调 -> decode_packet(pkt,ch) -> rx_queue.push_back
  // （decode_packet 逻辑搬现 monitor，去掉 run_protocol_checks——协议检查归 pcie_tl_vip monitor）
endclass
```
> 编解码细节（`encode_descriptor`/`encode_tuser_for_beat`/`send_beats`/`expand_dw_keep_to_byte`/`decode_packet`/`extract_tag_9_8`/`apply_tuser_be`）直接从 `src/agent/xilinx_pcie_driver.sv` 与 `xilinx_pcie_monitor.sv` 搬入本类，签名不变。`compress_byte_keep_to_dw` 作为本类 static 方法保留。

- [ ] **Step 3: tb_adapter_top 例化 env + 8 axis_if + 交叉接线**

```systemverilog
module tb_adapter_top;
  import uvm_pkg::*; import pcie_tl_pkg::*; import xilinx_pcie_adapter_pkg::*;
  `include "uvm_macros.svh"
  bit clk=0, rst_n=0;
  always #2.5 clk = ~clk;
  initial begin rst_n=0; #50 rst_n=1; end

  // 每通道一条共享总线：RC 侧与 EP 侧绑同一 axis_if（一端 master 一端 slave）
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rq_bus(.aclk(clk),.aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc_bus(.aclk(clk),.aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) cq_bus(.aclk(clk),.aresetn(rst_n));
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) cc_bus(.aclk(clk),.aresetn(rst_n));

  // 注册：RC adapter 的 rc/cq = MASTER 端，rq/cc = SLAVE 端；EP adapter 反之。
  // 同一 bus 两端共享 → 同一 vif 注册到 RC.<ch>_agent 与 EP.<ch>_agent。
  `include "xilinx_adapter_connect.svh"
  `XILINX_ADAPTER_WIRE(rq_bus, rc_bus, cq_bus, cc_bus)

  initial run_test();
endmodule
```
> `XILINX_ADAPTER_WIRE` 宏内容：对 4 条 bus，分别 `uvm_config_db#(virtual axis_if#(...))::set(null,"uvm_test_top.env.rc_adapter*.<ch>_agent*","vif",<ch>_bus)` 与 `ep_adapter*` 同 bus。共 8 次 set（每 bus 两端）。

- [ ] **Step 4: base_test 设 set_type_override + cfg**

```systemverilog
class xilinx_pcie_adapter_base_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_base_test)
  pcie_tl_env env;
  pcie_tl_env_config cfg;
  function new(string n, uvm_component p); super.new(n,p); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // 关键：把 pcie_tl_if_adapter 工厂覆盖为 Xilinx 子类
    pcie_tl_if_adapter::type_id::set_type_override(xilinx_pcie_if_adapter::get_type());
    cfg = pcie_tl_env_config::type_id::create("cfg");
    cfg.rc_agent_enable = 1; cfg.ep_agent_enable = 1;
    cfg.rc_is_active = UVM_ACTIVE; cfg.ep_is_active = UVM_ACTIVE;
    // EP 自动响应所需配置（mps/rcb 等）按 pcie_tl_env_config 字段设
    uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
    env = pcie_tl_env::type_id::create("env", this);
  endfunction
endclass
```
> `pcie_tl_env_config` 实际字段名（rc_agent_enable / rc_is_active / ep auto-resp 开关）实现时读 `pcie_tl_vip/src/env/pcie_tl_env_config.sv` 确认。

- [ ] **Step 5: PoC test = 复用 pcie_tl_vip 的 enum_then_dma vseq**

PoC 直接用 base_test，run_phase 起 pcie_tl_vip 的 `pcie_tl_enum_then_dma_vseq`（在 `env.v_seqr` 上 start）。若该 vseq 需要特定 config，读其源确认。

- [ ] **Step 6: BUILD+RUN PoC**。Expected: `vcs rc=0`；enum+dma 完成；RC 收到 EP 的 CplD；`UVM_FATAL=0`。
  - 调试要点（按 §6 成败点）：① 工厂覆盖是否生效（log 里 adapter 类型名）；② 4 vif 是否注入到位（axis_agent 取 vif 不 fatal）；③ rx_queue 是否被填（加 UVM_HIGH log）；④ 背靠背/跨通道丢包（对照现 driver 的首 beat `delay=1` 处理）。

- [ ] **Step 7: 判定闸门**
  - 通过 → 继续 Task 2。
  - 不通过且 ② 或 ③ 时序不可解 → 记录现象，退方案 B（另起计划）。

- [ ] **Step 8: Commit**
```bash
git add src/adapter/ tb/ tests/xilinx_pcie_adapter_base_test.sv
git commit -m "feat(xilinx-pcie): adapter PoC — 1RC+1EP enum+dma through xilinx adapter"
```

---

## Task 2: send() 全类型 + straddle

**Files:**
- Modify: `src/adapter/xilinx_pcie_if_adapter.sv`

- [ ] **Step 1: send 覆盖全 TLP 类型**：确认 `router.get_tx_channel` + `encode_descriptor` 对 MWr/MRd/CfgRd/CfgWr/IORd/IOWr/Atomic/Cpl/CplD 各类都正确选道编码（搬现 driver 的 4 通道 encode 分支，已覆盖）。

- [ ] **Step 2: straddle 开**：adapter `straddle_eng` 由 `+STRADDLE_EN` 注入；`encode_tuser_for_beat` 的 eof/eop offset 路径（现 driver 已实现）随之启用。

- [ ] **Step 3: BUILD+RUN**（STRADDLE_EN=0 与 1 各跑 enum_then_dma + rc_ep_rdwr）。Expected: `UVM_FATAL=0`，completion 正确。

- [ ] **Step 4: Commit**
```bash
git add src/adapter/xilinx_pcie_if_adapter.sv
git commit -m "feat(xilinx-pcie): adapter send all TLP types + straddle"
```

---

## Task 3: receive() 全通道解码稳健化

**Files:**
- Modify: `src/adapter/xilinx_pcie_if_adapter.sv`

- [ ] **Step 1: 4 通道 decode**：确认 write_rq/_rc/_cq/_cc 各调 `decode_packet(pkt,ch)`，tag[9:8] 合并 + tuser BE 回写（搬现 monitor `extract_tag_9_8`/`apply_tuser_be`）。**去掉** `run_protocol_checks`（协议判定归 pcie_tl_vip monitor）。

- [ ] **Step 2: rx_queue 背压观测**：加深度 log，超阈值 `uvm_warning`（验功能流量不积压）。

- [ ] **Step 3: BUILD+RUN backpressure vseq**（pcie_tl_vip 的 `backpressure_vseq`）。Expected: `UVM_FATAL=0`，不丢包。

- [ ] **Step 4: Commit**
```bash
git add src/adapter/xilinx_pcie_if_adapter.sv
git commit -m "feat(xilinx-pcie): adapter receive 4-channel decode hardening"
```

---

## Task 4: 薄 Xilinx smoke（编解码往返）

**Files:**
- Modify: `tests/xilinx_pcie_adapter_smoke_test.sv`

- [ ] **Step 1: 写 smoke**：每通道造一条代表 TLP，经对应 MASTER adapter `send` 发，断言对端 `rx_queue`/scoreboard 收到等价 TLP（kind/addr/length/tag/payload 一致）。覆盖 MWr/MRd→CplD/CfgRd→CplD，straddle 多 TLP。

```systemverilog
class xilinx_pcie_adapter_smoke_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_smoke_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    // 用 pcie_tl_vip 的 mem_wr_seq / mem_rd_seq 在 env.v_seqr 上 start，
    // 经 scoreboard 验 round-trip。逐通道一条。
    #20us;
    phase.drop_objection(this);
  endtask
endclass
```
> 具体 seq 名 / v_seqr 接口读 pcie_tl_vip 确认。

- [ ] **Step 2: BUILD+RUN smoke**（DW 256/512）。Expected: `UVM_ERROR=0 UVM_FATAL=0`。

- [ ] **Step 3: Commit**
```bash
git add tests/xilinx_pcie_adapter_smoke_test.sv
git commit -m "test(xilinx-pcie): thin adapter encode/decode round-trip smoke"
```

---

## Task 5: pcie_tl_vip seq 库场景回归（新栈）

**Files:**
- Modify: `tests/`（薄 wrapper test 各 start 一个 pcie_tl_vip vseq）或直接 `+UVM_TESTNAME` 复用 pcie_tl_vip test（若其 tb 可换）

- [ ] **Step 1: 选定场景**：`enum_then_dma`、`rc_ep_rdwr`、`backpressure`、`err_poisoned`、`err_malformed`、`cpl_timeout`。各写一个薄 wrapper test（`extends xilinx_pcie_adapter_base_test`，run_phase start 对应 vseq）。

- [ ] **Step 2: BUILD+RUN 全场景 × DW{256,512}**。Expected: 功能场景 `UVM_ERROR=0 UVM_FATAL=0`；错误注入场景按其自身判据（产错但不 FATAL）。

- [ ] **Step 3: Commit**
```bash
git add tests/
git commit -m "test(xilinx-pcie): pcie_tl_vip scenario regression on adapter stack"
```

---

## Task 6: 删旧 xilinx 栈 + filelist 收口

> 仅在 Task 1–5 全绿后执行。分多个 commit，每删一批后 `filelist_adapter.f` 重编译保证不依赖旧文件。

**Files:**
- Delete: `src/env/*`、`src/agent/xilinx_pcie_agent.sv`/`xilinx_pcie_driver.sv`/`xilinx_pcie_monitor.sv`/`xilinx_pcie_mem_responder.sv`、`src/seq/*`、`src/cfg/*`
- Delete: 旧 13 test、旧 tb（tb_top/tb_with_dut/tb_multi_agent/tb_rc_multi_ep/tb_allep_smoke/loopback_dut）、旧 filelist（filelist.f/_multi/_rc_multi_ep/_allep）、`src/xilinx_pcie_pkg.sv`（旧总包）
- Keep: codec/router/params/types/interface/adapter

- [ ] **Step 1: 删协议层文件**（env/agent driver+monitor+mem_responder/seq/cfg）。

- [ ] **Step 2: 删旧 tb/test/filelist/旧 pkg**。

- [ ] **Step 3: 核对 `filelist_adapter.f` 不引用任何已删文件**。

- [ ] **Step 4: BUILD+RUN smoke + enum_then_dma**。Expected: `vcs rc=0`，`UVM_FATAL=0`（证明删除未触达 adapter 路径）。

- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "refactor(xilinx-pcie): delete legacy protocol stack; adapter-only repo"
```

---

## Task 7: 文档 + memory + 全回归矩阵

**Files:**
- Modify: `docs/integration_guide.md`（重写为 adapter 用法）
- Modify: memory（`multi-agent-rc-ep-feature` 标 superseded；新增 adapter-mode 记录）

- [ ] **Step 1: integration_guide 重写**：adapter 架构图、`set_type_override` 用法、4 通道接线宏、用 pcie_tl_vip seq 库的方式、依赖锁定 commit。

- [ ] **Step 2: 全回归矩阵**：smoke + 6 个 pcie_tl_vip 场景 × DW{256,512}，记录结果表。

- [ ] **Step 3: memory 更新**（`MEMORY.md` + 文件）。

- [ ] **Step 4: Commit**
```bash
git add docs/integration_guide.md
git commit -m "docs(xilinx-pcie): rewrite guide for adapter mode + regression matrix"
```

---

## 实施修订（2026-06-29，PoC 后）

**进度：** Task 0 ✅（`f9652fa` filelist+骨架，vcs rc=0）。Task 1 PoC ✅ **闸门通过**（`c3d2124`，1RC+1EP MemWr/MemRd 端到端，`UVM_FATAL=0`，CplD 回到 RC 匹配）。

**PoC 暴露的三项事实 + 已批准决策**，据此调整后续任务：

- **新增 Task 1.5 — pcie_tl_vip 最小补丁正式化**（在 Task 2 前）：
  - `pcie_work/pcie_tl_vip/src/adapter/pcie_tl_if_adapter.sv`：`send()`/`receive()` 加 `virtual`（否则工厂 override 不分派）。
  - `pcie_work/pcie_tl_vip/src/seq/virtual/pcie_tl_enum_then_dma_vseq.sv`：`max_payload=0` → `chunk=0` 死循环，设 `max_payload=256`。
  - 这两处目前只在 `/tmp/xbuild`。须正式提交到 `pcie_work` repo（`Beihang-yuting/pcie_work`），并更新本计划 §依赖锁定的 commit。只动 hook/bug，不改协议逻辑。

- **新增 Task 4.5 — codec Config-TLP 支持**（在删旧栈 Task 6 前）：给 `xilinx_desc_codec` + `xilinx_tuser_codec` 加 CfgRd0/CfgWr0/CfgRd1/CfgWr1 编解码（RQ/CQ 通道），使 `enum_then_dma` 可跑。补 smoke 一条 Cfg round-trip。

- **改 Task 4/5 测试策略** → **薄 Xilinx checker**：不用上游 scoreboard（`register_pending` 仅 TLM loopback，SV_IF 无效）。写一个 `xilinx_pcie_e2e_checker`（uvm_subscriber，订阅两侧 adapter 解码 TLP，匹配 req↔cpl + payload），替代 PoC 里临时的 auto-response subscriber。Task 5 场景回归用它判端到端。

- **改 Task 1 收尾（tb 卫生）**：UVM `$finish` 后时钟/driver 不静默致日志暴涨。PoC 已加 200us timeout 兜底；Task 2 顺带加 `final`/`$finish` 后停时钟 + 关 driver fork，使 sim 干净退出（不再 1.2GB 日志）。

**调整后任务顺序：** Task 1.5（vip 补丁正式化）→ Task 2（send 全类型 + tb 卫生）→ Task 3（receive 稳健化）→ Task 4（薄 checker）→ Task 4.5（codec Cfg）→ Task 5（pcie_tl_vip 场景回归，含 enum_then_dma）→ Task 6（删旧栈，**删前向用户确认**）→ Task 7（文档+memory+回归矩阵）。

> 注：Task 6 删整个旧协议栈（30+ 文件），属不可逆大动作，执行前单独向用户确认。

## Self-Review

- **Spec 覆盖**：§4.1 文件构成→Task 0/6；§4.2 adapter→Task 1/2/3；§4.3 接线→Task 1 Step3/4；§4.4 数据流→Task 1 PoC；§5 测试→Task 4/5；§6 PoC 闸门→Task 1。无缺口。
- **实现期须读确认（计划已标）**：codec/router 是否依赖 env_config（Task1 S1）；`axis_agent_xx_t` 类型与 `create_axis_config` 复用（Task1 S2）；`pcie_tl_env_config` 字段名 + EP 自动响应开关（Task1 S4）；pcie_tl_vip vseq/seq 名与 v_seqr 接口（Task1 S5 / Task4 / Task5）；pcie_tl_vip filelist 是否含自带 tb（Task0 S2）。
- **类型一致**：`xilinx_pcie_if_adapter`(send/receive override)、`rx_queue`(pcie_tl_tlp queue)、`router.get_tx_channel`、`decode_packet(pkt,ch)`、`set_type_override` 全程一致。
- **回退**：Task 1 是硬闸门，不过则退方案 B，旧栈未动可随时回退。
