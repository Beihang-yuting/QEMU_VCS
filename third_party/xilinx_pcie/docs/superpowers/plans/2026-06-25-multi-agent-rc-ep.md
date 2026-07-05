# 可配置多 RC/EP Agent 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 让 `xilinx_pcie` 环境运行期可配 N 个 RC + M 个 EP agent，连线用宏由用户在 tb 里逐 agent 连，检查只做协议类型+错误类型，默认 1+1 向后兼容。

**Architecture:** env_config 加 `num_rc/num_ep`；env 循环建 `rc_agent_<i>`/`ep_agent_<i>` 数组（+别名）；新 `xilinx_pcie_connect.svh` 提供 `WIRE_RC/WIRE_EP` 宏（编译期例化 axis_if + 桥接 + config_db 注册）；`scoreboard` 改造为协议/错误中心收集器（per-agent tap 订阅，去数据配对）；v_sqr / 中断 / cfg agent 数组化。

**Tech Stack:** SystemVerilog / UVM-1.2 / VCS（Q-2020.03）。依赖 `axis_vip`(更新版) + `pcie_tl_vip` + `host_mem`。

**Spec:** `docs/superpowers/specs/2026-06-25-multi-agent-rc-ep-design.md`

---

## 构建/验证约定（每个任务复用）

VCS 只在远程 **ryan@10.11.10.61:2222**（密码 `Ryan@2025`）。本地无 VCS。`/home/ryan` 盘紧，构建在 `/tmp/xbuild`。

**一次性搭建（执行 Task 1 前做一次）：**
```bash
ssh -p 2222 ryan@10.11.10.61 '
  rm -rf /tmp/xbuild && mkdir -p /tmp/xbuild
  for d in pcie_work shm_work xilinx_pcie; do
    rsync -a --exclude csrc --exclude "simv*" --exclude work --exclude logs \
      --exclude "*.daidir" --exclude "*.vpd" --exclude "*.vdb" --exclude "*.log" ~/$d/ /tmp/xbuild/$d/
  done
  mkdir -p /tmp/xbuild/axis_work/axis_vip'
# 推更新版 axis（含本会话首拍/复位修复）
cd /home/ubuntu/ryan/axis_work && rsync -az -e "ssh -p 2222" \
  --exclude csrc --exclude "simv*" axis_vip/ ryan@10.11.10.61:/tmp/xbuild/axis_work/axis_vip/
# 路径 sed（两种根都替）
ssh -p 2222 ryan@10.11.10.61 '
  for f in /tmp/xbuild/xilinx_pcie/sim/filelist.f /tmp/xbuild/axis_work/axis_vip/sim/filelist_lib.f; do
    sed -i "s#/home/ubuntu/ryan#/tmp/xbuild#g; s#/home/ryan#/tmp/xbuild#g" "$f"
  done'
```

**每个任务的 BUILD+RUN（把改过的文件先 rsync 到 /tmp/xbuild 对应路径，再）：**
```bash
ssh -p 2222 ryan@10.11.10.61 'source ~/set-env.sh >/dev/null 2>&1
  export TMPDIR=/tmp/xbuild/xilinx_pcie/sim/tmp
  cd /tmp/xbuild/xilinx_pcie/sim && mkdir -p work logs tmp
  vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -full64 -Mdir=csrc \
    -l logs/compile.log -o work/simv -f filelist.f +define+DATA_WIDTH=256 +define+STRADDLE_EN=0 \
    >/dev/null 2>&1; echo "vcs rc=$?"; grep -iE "Error-\[" logs/compile.log | head
  ./work/simv +UVM_TESTNAME=<TEST> +DATA_WIDTH=256 +STRADDLE_EN=0 +ntb_random_seed=1 2>&1 \
    | grep -iE "UVM_ERROR :|UVM_FATAL :" | tail -2'
```
推改动文件示例：`rsync -az -e "ssh -p 2222" src/env/xilinx_pcie_env.sv ryan@10.11.10.61:/tmp/xbuild/xilinx_pcie/src/env/`。

**回归基线（Task 完成判定）：** 现有 7 个 test `UVM_ERROR=0/UVM_FATAL=0`（实测 sanity/loopback/stress/unified_mem/straddle/mega_stress 均绿）。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `src/env/xilinx_pcie_env_config.sv`（改） | 加 `num_rc`/`num_ep` + validate + do_copy |
| `src/env/xilinx_pcie_env.sv`（改） | agent/int_agent 数组化、循环建、别名、connect 改引用、tap 接收 |
| `src/env/xilinx_pcie_virtual_sequencer.sv`（改） | `rc_sqr_arr[]`/`ep_sqr_arr[]` + 别名 |
| `src/env/xilinx_pcie_scoreboard.sv`（改） | 改造为协议/错误收集器，去数据配对 |
| `src/env/xilinx_pcie_collector_tap.sv`（新） | per-agent 订阅 tap：(agent_id,role,tlp) 转发收集器 |
| `tb/xilinx_pcie_connect.svh`（新） | tkeep 函数 + `WIRE_RC`/`WIRE_EP` 宏 |
| `tb/tb_top.sv`（改） | 用宏重写 1RC+1EP（demo + 回归基线） |
| `tests/xilinx_pcie_multi_agent_test.sv`（新） | 1RC+3EP demo |
| `tb/tb_multi_agent.sv`（新） | 多 agent demo tb（宏连 1RC+3EP） |
| `sim/filelist.f`（改） | + connect.svh include 路径、新 test、新 tap |

---

## Task 1: env_config 加 num_rc/num_ep

**Files:**
- Modify: `src/env/xilinx_pcie_env_config.sv`（字段区 ~19-29 行附近；`do_copy` ~320；`validate` ~435）

- [x] **Step 1: 加字段**（在 `role` 字段后）

```systemverilog
    // ---- 多 agent 数量（运行期，默认 1 保持向后兼容） ----
    int                         num_rc = 1;   // RC agent 数量
    int                         num_ep = 1;   // EP agent 数量
```

- [x] **Step 2: do_copy 同步**（在 `do_copy` 里 `this.role = o.role;` 之后加）

```systemverilog
        this.num_rc = o.num_rc;
        this.num_ep = o.num_ep;
```

- [x] **Step 3: validate 加约束**（在 `validate()` 内、`return 1` 前加）

```systemverilog
        if (num_rc < 0 || num_ep < 0 || (num_rc + num_ep) < 1) begin
            `uvm_error("CFG", $sformatf("非法 agent 数量: num_rc=%0d num_ep=%0d", num_rc, num_ep))
            return 0;
        end
```

- [x] **Step 4: BUILD+RUN sanity**（默认 1+1，行为不变）。先 rsync 改文件。Expected: `vcs rc=0`，`UVM_ERROR : 0`。

- [x] **Step 5: Commit**
```bash
git add src/env/xilinx_pcie_env_config.sv
git commit -m "feat(xilinx-pcie): add num_rc/num_ep config (default 1)"
```

---

## Task 2: 连线宏 + tkeep 函数（新 .svh，先定义不使用）

**Files:**
- Create: `tb/xilinx_pcie_connect.svh`

- [x] **Step 1: 写 connect.svh**（tkeep 函数 + 两宏）。完整内容：

```systemverilog
`ifndef XILINX_PCIE_CONNECT_SVH
`define XILINX_PCIE_CONNECT_SVH
// 多 agent 连线宏：用户在 tb 里逐 agent 调用。区分 RC/EP（各通道 master/slave 方向相反）。
// 用法: `XILINX_PCIE_WIRE_EP(0, ep_if, ep_cfg_if, clk, rst_n)
// 契约: 调用次数必须 >= env_config.num_<role>，否则 env 取 vif 时 uvm_fatal。

// 共享 tkeep 转换（automatic 可重入，整个编译单元定义一次）
function automatic logic [(`XILINX_KEEP_W)-1:0] xilinx_byte_keep_to_dw(
    input logic [(`XILINX_DATA_W/8)-1:0] bk);
  for (int dw=0; dw<`XILINX_KEEP_W; dw++) xilinx_byte_keep_to_dw[dw] = |bk[dw*4 +: 4];
endfunction
function automatic logic [(`XILINX_DATA_W/8)-1:0] xilinx_dw_keep_to_byte(
    input logic [(`XILINX_KEEP_W)-1:0] dk);
  xilinx_dw_keep_to_byte = '0;
  for (int dw=0; dw<`XILINX_KEEP_W; dw++) if (dk[dw]) xilinx_dw_keep_to_byte[dw*4 +: 4] = 4'hF;
endfunction

// ---- RC: RQ/CC = axis SLAVE(pcie->axis), RC/CQ = axis MASTER(axis->pcie) ----
`define XILINX_PCIE_WIRE_RC(IDX, PCIE_IF, CFG_IF, CLK, RSTN)                                       \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) rc_agent_``IDX``_rq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) rc_agent_``IDX``_rc_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) rc_agent_``IDX``_cq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) rc_agent_``IDX``_cc_if(.aclk(CLK),.aresetn(RSTN)); \
  /* RQ slave: pcie->axis */                                                                      \
  assign rc_agent_``IDX``_rq_if.tdata=PCIE_IF.rq_tdata; assign rc_agent_``IDX``_rq_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.rq_tkeep); \
  assign rc_agent_``IDX``_rq_if.tlast=PCIE_IF.rq_tlast; assign rc_agent_``IDX``_rq_if.tvalid=PCIE_IF.rq_tvalid; \
  assign rc_agent_``IDX``_rq_if.tuser=PCIE_IF.rq_tuser; assign PCIE_IF.rq_tready=rc_agent_``IDX``_rq_if.tready; \
  /* CC slave: pcie->axis */                                                                      \
  assign rc_agent_``IDX``_cc_if.tdata=PCIE_IF.cc_tdata; assign rc_agent_``IDX``_cc_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.cc_tkeep); \
  assign rc_agent_``IDX``_cc_if.tlast=PCIE_IF.cc_tlast; assign rc_agent_``IDX``_cc_if.tvalid=PCIE_IF.cc_tvalid; \
  assign rc_agent_``IDX``_cc_if.tuser=PCIE_IF.cc_tuser; assign PCIE_IF.cc_tready=rc_agent_``IDX``_cc_if.tready; \
  /* RC master: axis->pcie */                                                                     \
  assign PCIE_IF.rc_tdata=rc_agent_``IDX``_rc_if.tdata; assign PCIE_IF.rc_tkeep=xilinx_byte_keep_to_dw(rc_agent_``IDX``_rc_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.rc_tlast=rc_agent_``IDX``_rc_if.tlast; assign PCIE_IF.rc_tvalid=rc_agent_``IDX``_rc_if.tvalid; \
  assign PCIE_IF.rc_tuser=rc_agent_``IDX``_rc_if.tuser; assign rc_agent_``IDX``_rc_if.tready=PCIE_IF.rc_tready; \
  /* CQ master: axis->pcie */                                                                     \
  assign PCIE_IF.cq_tdata=rc_agent_``IDX``_cq_if.tdata; assign PCIE_IF.cq_tkeep=xilinx_byte_keep_to_dw(rc_agent_``IDX``_cq_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.cq_tlast=rc_agent_``IDX``_cq_if.tlast; assign PCIE_IF.cq_tvalid=rc_agent_``IDX``_cq_if.tvalid; \
  assign PCIE_IF.cq_tuser=rc_agent_``IDX``_cq_if.tuser; assign rc_agent_``IDX``_cq_if.tready=PCIE_IF.cq_tready; \
  initial begin                                                                                   \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.rq_agent*",IDX),"vif",rc_agent_``IDX``_rq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.rc_agent*",IDX),"vif",rc_agent_``IDX``_rc_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.cq_agent*",IDX),"vif",rc_agent_``IDX``_cq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.rc_agent_%0d.cc_agent*",IDX),"vif",rc_agent_``IDX``_cc_if); \
    uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,$sformatf("uvm_test_top.env.rc_cfg_agent_%0d*",IDX),"cfg_vif",CFG_IF); \
    uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,$sformatf("uvm_test_top.env.rc_int_agent_%0d*",IDX),"cfg_vif",CFG_IF); \
  end

// ---- EP: RQ/CC = axis MASTER(axis->pcie), RC/CQ = axis SLAVE(pcie->axis) ----
`define XILINX_PCIE_WIRE_EP(IDX, PCIE_IF, CFG_IF, CLK, RSTN)                                       \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1) ep_agent_``IDX``_rq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1) ep_agent_``IDX``_rc_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1) ep_agent_``IDX``_cq_if(.aclk(CLK),.aresetn(RSTN)); \
  axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1) ep_agent_``IDX``_cc_if(.aclk(CLK),.aresetn(RSTN)); \
  /* RQ master: axis->pcie */                                                                     \
  assign PCIE_IF.rq_tdata=ep_agent_``IDX``_rq_if.tdata; assign PCIE_IF.rq_tkeep=xilinx_byte_keep_to_dw(ep_agent_``IDX``_rq_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.rq_tlast=ep_agent_``IDX``_rq_if.tlast; assign PCIE_IF.rq_tvalid=ep_agent_``IDX``_rq_if.tvalid; \
  assign PCIE_IF.rq_tuser=ep_agent_``IDX``_rq_if.tuser; assign ep_agent_``IDX``_rq_if.tready=PCIE_IF.rq_tready; \
  /* CC master: axis->pcie */                                                                     \
  assign PCIE_IF.cc_tdata=ep_agent_``IDX``_cc_if.tdata; assign PCIE_IF.cc_tkeep=xilinx_byte_keep_to_dw(ep_agent_``IDX``_cc_if.tkeep[(`XILINX_DATA_W/8)-1:0]); \
  assign PCIE_IF.cc_tlast=ep_agent_``IDX``_cc_if.tlast; assign PCIE_IF.cc_tvalid=ep_agent_``IDX``_cc_if.tvalid; \
  assign PCIE_IF.cc_tuser=ep_agent_``IDX``_cc_if.tuser; assign ep_agent_``IDX``_cc_if.tready=PCIE_IF.cc_tready; \
  /* RC slave: pcie->axis */                                                                      \
  assign ep_agent_``IDX``_rc_if.tdata=PCIE_IF.rc_tdata; assign ep_agent_``IDX``_rc_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.rc_tkeep); \
  assign ep_agent_``IDX``_rc_if.tlast=PCIE_IF.rc_tlast; assign ep_agent_``IDX``_rc_if.tvalid=PCIE_IF.rc_tvalid; \
  assign ep_agent_``IDX``_rc_if.tuser=PCIE_IF.rc_tuser; assign PCIE_IF.rc_tready=ep_agent_``IDX``_rc_if.tready; \
  /* CQ slave: pcie->axis */                                                                      \
  assign ep_agent_``IDX``_cq_if.tdata=PCIE_IF.cq_tdata; assign ep_agent_``IDX``_cq_if.tkeep=xilinx_dw_keep_to_byte(PCIE_IF.cq_tkeep); \
  assign ep_agent_``IDX``_cq_if.tlast=PCIE_IF.cq_tlast; assign ep_agent_``IDX``_cq_if.tvalid=PCIE_IF.cq_tvalid; \
  assign ep_agent_``IDX``_cq_if.tuser=PCIE_IF.cq_tuser; assign PCIE_IF.cq_tready=ep_agent_``IDX``_cq_if.tready; \
  initial begin                                                                                   \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.rq_agent*",IDX),"vif",ep_agent_``IDX``_rq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_RC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.rc_agent*",IDX),"vif",ep_agent_``IDX``_rc_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CQ_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.cq_agent*",IDX),"vif",ep_agent_``IDX``_cq_if); \
    uvm_config_db#(virtual axis_if #(`XILINX_DATA_W,4,4,`XILINX_CC_TUSER_W,0,1,1))::set(null,$sformatf("uvm_test_top.env.ep_agent_%0d.cc_agent*",IDX),"vif",ep_agent_``IDX``_cc_if); \
    uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,$sformatf("uvm_test_top.env.ep_cfg_agent_%0d*",IDX),"cfg_vif",CFG_IF); \
    uvm_config_db#(virtual xilinx_pcie_cfg_if)::set(null,$sformatf("uvm_test_top.env.ep_int_agent_%0d*",IDX),"cfg_vif",CFG_IF); \
  end
`endif
```

- [x] **Step 2:** 不单独编译（宏未被调用，下个任务起用）。直接 Commit。
```bash
git add tb/xilinx_pcie_connect.svh
git commit -m "feat(xilinx-pcie): add WIRE_RC/WIRE_EP connect macros"
```

> 注意：`virtual axis_if #(...)` 在 config_db 的类型参数必须与 env 内 `axis_agent_xx_t` 的 `vif_t` 完全一致（DATA_W + 各通道 TUSER）。`IDX` 为编译期字面量；实例名 token 拼接，config_db 路径用 `$sformatf` 与运行期实例名对齐。

---

## Task 3: env agent 数组化 + tb_top 用宏（协同落地，保回归）

> 关键：env 实例名 `rc_agent`→`rc_agent_0`，tb_top 的 config_db 路径必须同步用宏改成 `_0`。两者同一任务落地，sanity 才能过。

**Files:**
- Modify: `src/env/xilinx_pcie_env.sv`（声明区 ~37-56；build_phase 步骤2/3/4 ~90-135；connect_phase 引用 ~188+）
- Modify: `tb/tb_top.sv`（接线区 93-205；config_db 区 224-243）
- Modify: `sim/filelist.f`（加 `+incdir+/home/ubuntu/ryan/xilinx_pcie/tb`）

- [x] **Step 1: env 声明数组 + 别名**（替换 `rc_agent`/`ep_agent` 声明）
```systemverilog
    xilinx_pcie_agent rc_agents[$];
    xilinx_pcie_agent ep_agents[$];
    // 别名（兼容内部引用，build 后指向 [0]）
    xilinx_pcie_agent rc_agent;   // = rc_agents[0]
    xilinx_pcie_agent ep_agent;   // = ep_agents[0]
```

- [x] **Step 2: build_phase 循环建 agent**（替换原步骤2/3/4 的 clone+set+create）
```systemverilog
    for (int i = 0; i < cfg.num_rc; i++) begin
      xilinx_pcie_env_config c; xilinx_pcie_agent a;
      $cast(c, cfg.clone()); c.set_name($sformatf("rc_cfg_%0d",i)); c.role = XILINX_PCIE_RC;
      uvm_config_db#(xilinx_pcie_env_config)::set(this, $sformatf("rc_agent_%0d*",i), "cfg", c);
      a = xilinx_pcie_agent::type_id::create($sformatf("rc_agent_%0d",i), this);
      rc_agents.push_back(a);
    end
    for (int i = 0; i < cfg.num_ep; i++) begin
      xilinx_pcie_env_config c; xilinx_pcie_agent a;
      $cast(c, cfg.clone()); c.set_name($sformatf("ep_cfg_%0d",i)); c.role = XILINX_PCIE_EP;
      uvm_config_db#(xilinx_pcie_env_config)::set(this, $sformatf("ep_agent_%0d*",i), "cfg", c);
      a = xilinx_pcie_agent::type_id::create($sformatf("ep_agent_%0d",i), this);
      ep_agents.push_back(a);
    end
    if (rc_agents.size()>0) rc_agent = rc_agents[0];
    if (ep_agents.size()>0) ep_agent = ep_agents[0];
```
（统一内存 step3b 的 `rc_agent*`/`ep_agent*` config_db set 路径改为对每个 i 循环 set `rc_agent_%0d*`/`ep_agent_%0d*`。）

- [x] **Step 3: connect_phase 引用改别名**：`rc_agent.tag_mgr` 等保持（别名已指向 [0]）。逐 agent 接 v_sqr 在 Task 4 完成；本任务先保证 [0] 路径如旧。

- [x] **Step 4: tb_top 用宏**：删 93-205 的 8 路 axis_if 显式例化+桥接，及 224-243 的 axis config_db set；在 `rc_if/ep_if/rc_cfg_if/ep_cfg_if` 与 loopback_dut 之后插入：
```systemverilog
`include "xilinx_pcie_connect.svh"
// rc_if/ep_if/rc_cfg_if/ep_cfg_if + loopback_dut 保持
`XILINX_PCIE_WIRE_RC(0, rc_if, rc_cfg_if, clk, rst_n)
`XILINX_PCIE_WIRE_EP(0, ep_if, ep_cfg_if, clk, rst_n)
```
（cfg_if 的 config_db set 由宏接管；host_mem set 与 run_test 不动。）

- [x] **Step 5: filelist 加 incdir**
```
+incdir+/home/ubuntu/ryan/xilinx_pcie/tb
```

- [x] **Step 6: BUILD+RUN sanity + loopback**。Expected: `vcs rc=0`，两 test `UVM_ERROR : 0`。若取不到 vif → 检查宏路径 `rc_agent_0` 与 env 实例名一致。

- [x] **Step 7: Commit**
```bash
git add src/env/xilinx_pcie_env.sv tb/tb_top.sv sim/filelist.f
git commit -m "feat(xilinx-pcie): array-ize RC/EP agents; tb_top uses WIRE macros"
```

---

## Task 4: virtual_sequencer 数组化

**Files:**
- Modify: `src/env/xilinx_pcie_virtual_sequencer.sv`（rc_sqr/ep_sqr 声明）
- Modify: `src/env/xilinx_pcie_env.sv`（connect_phase 接 sqr）

- [x] **Step 1: v_sqr 加数组 + 别名**
```systemverilog
    uvm_sequencer #(pcie_tl_tlp) rc_sqr_arr[$];
    uvm_sequencer #(pcie_tl_tlp) ep_sqr_arr[$];
    uvm_sequencer #(pcie_tl_tlp) rc_sqr;   // = rc_sqr_arr[0]
    uvm_sequencer #(pcie_tl_tlp) ep_sqr;   // = ep_sqr_arr[0]
```

- [x] **Step 2: env connect_phase 填数组**（在设置 v_sqr 引用处）
```systemverilog
    foreach (rc_agents[i]) v_sqr.rc_sqr_arr.push_back(rc_agents[i].tlp_sqr);
    foreach (ep_agents[i]) v_sqr.ep_sqr_arr.push_back(ep_agents[i].tlp_sqr);
    if (v_sqr.rc_sqr_arr.size()>0) v_sqr.rc_sqr = v_sqr.rc_sqr_arr[0];
    if (v_sqr.ep_sqr_arr.size()>0) v_sqr.ep_sqr = v_sqr.ep_sqr_arr[0];
```
> 注：`agent.tlp_sqr` 为 agent 内 TLP sequencer 句柄名 — 实现时读 `xilinx_pcie_agent.sv` 确认实际成员名，替换之。

- [x] **Step 3: BUILD+RUN sanity**。Expected: `UVM_ERROR : 0`（现 vseq 用别名 = [0]）。

- [x] **Step 4: Commit**
```bash
git add src/env/xilinx_pcie_virtual_sequencer.sv src/env/xilinx_pcie_env.sv
git commit -m "feat(xilinx-pcie): array-ize virtual sequencer with [0] aliases"
```

---

## Task 5: 协议/错误中心收集器（改造 scoreboard + tap）

**Files:**
- Create: `src/env/xilinx_pcie_collector_tap.sv`
- Modify: `src/env/xilinx_pcie_scoreboard.sv`（去 4 路固定 imp + 数据配对，改 record 接口 + 统计/报表）
- Modify: `src/env/xilinx_pcie_env.sv`（每 agent monitor → tap → scb）
- Modify: `src/xilinx_pcie_pkg.sv`、`sim/filelist.f`（include tap）

- [x] **Step 1: 写 tap**（`src/env/xilinx_pcie_collector_tap.sv`）
```systemverilog
class xilinx_pcie_collector_tap extends uvm_subscriber #(pcie_tl_tlp);
  `uvm_component_utils(xilinx_pcie_collector_tap)
  int agent_id; xilinx_pcie_role_e role; xilinx_pcie_scoreboard collector;
  function new(string name, uvm_component parent); super.new(name,parent); endfunction
  function void write(pcie_tl_tlp t);
    if (collector != null) collector.record(agent_id, role, t);
  endfunction
endclass
```
（在 `xilinx_pcie_pkg.sv` 的 scoreboard include 后加 `` `include "xilinx_pcie_collector_tap.sv" ``。）

- [x] **Step 2: scoreboard 改造**：删 `rc_tx_imp`/`rc_rx_imp`/`ep_tx_imp`/`ep_rx_imp` 与数据配对；加：
```systemverilog
  protected int unsigned proto_count[string][string];   // [agent_key][tlp_type]
  protected int unsigned err_count[string][string];     // [agent_key][err_type]

  function void record(int agent_id, xilinx_pcie_role_e role, pcie_tl_tlp t);
    string ak = $sformatf("%s_%0d", role.name(), agent_id);
    proto_count[ak][t.get_tlp_type_name()]++;              // 用 pcie_tl_tlp 实际类型名方法
    if (t.has_error()) err_count[ak][t.get_error_name()]++; // 若 TLP 带错误标记
  endfunction

  function void report_phase(uvm_phase phase);
    foreach (proto_count[ak]) foreach (proto_count[ak][ty])
      `uvm_info("PROTO", $sformatf("[%s] %s = %0d", ak, ty, proto_count[ak][ty]), UVM_LOW)
    foreach (err_count[ak]) foreach (err_count[ak][et])
      `uvm_error("PROTO_ERR", $sformatf("[%s] %s x%0d", ak, et, err_count[ak][et]))
  endfunction
```
> `get_tlp_type_name()`/`has_error()`/`get_error_name()` 为示意 — 实现时读 `pcie_tl_tlp` 类，用其实际类型枚举/错误字段替换。`scb_data_integrity`/`scb_completion_check` 字段保留不用（no-op）。

- [x] **Step 3: env 接 tap**（connect_phase，每 agent monitor TLP analysis port → 独立 tap → scb，tap 存数组防 GC）
```systemverilog
    if (cfg.scb_enable) begin
      foreach (rc_agents[i]) begin
        xilinx_pcie_collector_tap tp = xilinx_pcie_collector_tap::type_id::create($sformatf("rc_tap_%0d",i), this);
        tp.agent_id=i; tp.role=XILINX_PCIE_RC; tp.collector=scb; taps.push_back(tp);
        rc_agents[i].tlp_mon_ap.connect(tp.analysis_export);   // monitor TLP 输出端口名,实现时确认
      end
      foreach (ep_agents[i]) begin
        xilinx_pcie_collector_tap tp = xilinx_pcie_collector_tap::type_id::create($sformatf("ep_tap_%0d",i), this);
        tp.agent_id=i; tp.role=XILINX_PCIE_EP; tp.collector=scb; taps.push_back(tp);
        ep_agents[i].tlp_mon_ap.connect(tp.analysis_export);
      end
    end
```
（env 加成员 `xilinx_pcie_collector_tap taps[$];`。`tlp_mon_ap` 名读 monitor 确认。）

- [x] **Step 4: BUILD+RUN sanity + loopback + stress**。Expected: `UVM_ERROR : 0`（无数据配对误报），report 出 PROTO 直方图。

- [x] **Step 5: Commit**
```bash
git add src/env/xilinx_pcie_collector_tap.sv src/env/xilinx_pcie_scoreboard.sv src/env/xilinx_pcie_env.sv src/xilinx_pcie_pkg.sv sim/filelist.f
git commit -m "feat(xilinx-pcie): protocol/error collector via per-agent taps (drop data pairing)"
```

---

## Task 6: 中断 / cfg agent 按数量扩

**Files:**
- Modify: `src/env/xilinx_pcie_env.sv`（int agent 数组化）

- [x] **Step 1: 声明数组**
```systemverilog
    xilinx_pcie_interrupt_agent rc_int_agents[$];
    xilinx_pcie_interrupt_agent ep_int_agents[$];
```

- [x] **Step 2: build_phase 循环建**（替换原 rc_int_agent/ep_int_agent 单建，`interrupt_enable` 内）
```systemverilog
    if (cfg.interrupt_enable) begin
      for (int i=0;i<cfg.num_rc;i++) rc_int_agents.push_back(
        xilinx_pcie_interrupt_agent::type_id::create($sformatf("rc_int_agent_%0d",i), this));
      for (int i=0;i<cfg.num_ep;i++) ep_int_agents.push_back(
        xilinx_pcie_interrupt_agent::type_id::create($sformatf("ep_int_agent_%0d",i), this));
      uvm_config_db#(xilinx_pcie_interrupt_agent)::set(this,"*","int_agent",ep_int_agents[0]); // 旧 key 兼容
      foreach (ep_int_agents[i])
        uvm_config_db#(xilinx_pcie_interrupt_agent)::set(this,"*",$sformatf("int_agent_%0d",i),ep_int_agents[i]);
    end
```

- [x] **Step 3: BUILD+RUN sanity（interrupt_enable=1 默认）**。Expected: `UVM_ERROR : 0`，MSI 阶段正常。

- [x] **Step 4: Commit**
```bash
git add src/env/xilinx_pcie_env.sv
git commit -m "feat(xilinx-pcie): scale interrupt agents per RC/EP count"
```

---

## Task 7: 多 agent demo tb + test

**Files:**
- Create: `tb/tb_multi_agent.sv`（1 RC + 3 EP，宏连）
- Create: `tests/xilinx_pcie_multi_agent_test.sv`
- Create: `sim/filelist_multi.f`（顶层换 tb_multi_agent + 加新 test）

- [x] **Step 1: 写 demo tb**（`tb/tb_multi_agent.sv`）：clk/rst 同 tb_top；声明 1 个 RC + 3 个 EP 的 `xilinx_pcie_if` + `xilinx_pcie_cfg_if`（各 PCIE_IF 不接 DUT，tready 由 axis 侧驱，未连端口悬空）；调用：
```systemverilog
`include "xilinx_pcie_connect.svh"
`XILINX_PCIE_WIRE_RC(0, rc_if,  rc_cfg_if,  clk, rst_n)
`XILINX_PCIE_WIRE_EP(0, ep0_if, ep0_cfg_if, clk, rst_n)
`XILINX_PCIE_WIRE_EP(1, ep1_if, ep1_cfg_if, clk, rst_n)
`XILINX_PCIE_WIRE_EP(2, ep2_if, ep2_cfg_if, clk, rst_n)
// host_mem set + run_test 同 tb_top
```

- [x] **Step 2: 写 test**（`tests/xilinx_pcie_multi_agent_test.sv`）
```systemverilog
class xilinx_pcie_multi_agent_test extends xilinx_pcie_base_test;
  `uvm_component_utils(xilinx_pcie_multi_agent_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction
  function void build_phase(uvm_phase phase);
    // base_test 创建 cfg 后、env build 前设数量（实现时确认 base_test 的 cfg 钩子）
    super.build_phase(phase);
    cfg.num_rc = 1; cfg.num_ep = 3;
  endfunction
  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    foreach (env.v_sqr.ep_sqr_arr[i]) begin
      xilinx_pcie_mem_seq s = xilinx_pcie_mem_seq::type_id::create($sformatf("s%0d",i));
      void'(s.randomize());
      s.start(env.v_sqr.ep_sqr_arr[i]);
    end
    #50us;
    phase.drop_objection(this);
  endtask
endclass
```
> base_test 暴露 cfg 的方式读 `xilinx_pcie_base_test.sv` 确认；`xilinx_pcie_mem_seq` 字段按实际。

- [x] **Step 3: filelist_multi.f**：复制 filelist.f，把 `tb/tb_top.sv` 换 `tb/tb_multi_agent.sv`，加 `tests/xilinx_pcie_multi_agent_test.sv`。BUILD（`-f filelist_multi.f`）+RUN multi_agent_test。Expected: `vcs rc=0`，4 agent 建成，`UVM_ERROR : 0`，report 见 `[EP_0]/[EP_1]/[EP_2]` proto 计数。

- [x] **Step 4: 回归不回退**：用 `filelist.f`（tb_top）跑现 7 个 test，全 `UVM_ERROR : 0`。

- [x] **Step 5: Commit**
```bash
git add tb/tb_multi_agent.sv tests/xilinx_pcie_multi_agent_test.sv sim/filelist_multi.f
git commit -m "test(xilinx-pcie): multi-agent demo tb + 1RC+3EP test"
```

---

## Task 8: 文档 + 全回归矩阵

**Files:**
- Modify: `docs/integration_guide.md`（加"多 agent 配置 + 连线宏"节）

- [x] **Step 1: integration_guide 加节**：`num_rc/num_ep` 用法、`WIRE_RC/WIRE_EP` 宏签名与契约、collector 报表说明、多 agent demo 指向 `tb_multi_agent.sv`。

- [x] **Step 2: 全回归矩阵**（61）：DATA_WIDTH ∈ {256,512} × {现 7 test（tb_top）, multi_agent_test（tb_multi_agent）}，全 `UVM_ERROR=0/UVM_FATAL=0`。记录结果。

  **回归结果（2026-06-26，远程 10.11.10.61 /tmp/xbuild，4 个 TB simv × DW∈{256,512}，seed=1，STRADDLE_EN=0）：**
  - 4 个 filelist（filelist / _multi / _rc_multi_ep / _allep）在 DW=256 与 DW=512 均 `vcs rc=0`。
  - 12 个 test × 2 宽度 = **24/24 通过**：
    - 10 个功能 test（sanity, straddle, loopback, stress, mega_stress, unified_mem, multi_agent, multi_ep, rc_multi_ep, allep）均 `UVM_ERROR=0 / UVM_FATAL=0`。
    - 2 个注入 test 按设计产错（PASS 判据非 UVM_ERROR==0）：
      - `err_inject`：16 UVM_ERROR（每注入 1 个 monitor 本地错误）/ 0 FATAL — 符合设计。
      - `errtype`：17 UVM_ERROR / 0 FATAL，`check_phase` 断言全 OK，打印 `ERRTYPE TEST PASSED — 各错误类型均被正确识别、归属正确、互不串扰`（9 类型 RC_0 各计 1，EP_0/1/2 隔离为 0）。

- [x] **Step 3: Commit**
```bash
git add docs/integration_guide.md
git commit -m "docs(xilinx-pcie): document multi-agent config + connect macros"
```

---

## Self-Review

- Spec 覆盖：§4.1→Task1；§4.3→Task2；§4.2→Task3/6；§4.4→Task4；§4.5→Task5；§8 验证→Task7/8。无缺口。
- 实现期需读确认的真实成员名（计划已在对应步骤标注"实现时确认"）：`xilinx_pcie_agent` 的 TLP sequencer（`tlp_sqr`）/ monitor analysis port（`tlp_mon_ap`）；`pcie_tl_tlp` 的类型枚举/错误字段（`get_tlp_type_name`/`has_error`）；`xilinx_pcie_base_test` 的 cfg 钩子。
- 类型一致：`num_rc/num_ep`(int)、`rc_agents/ep_agents`(queue)、`rc_sqr_arr/ep_sqr_arr`(queue)、`record(int,role,tlp)` 全程一致。
