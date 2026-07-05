# 多根（多 USP）Switch Fabric 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `pcie_tl_vip` switch fabric 支持可配 `num_usp` 个上行口（根/RC），不交叠层级：各 RC 独占一组 DSP/EP，per-root bus/addr 域，上行解析到归属 USP，跨根 drop+隔离检查，per-root 管理器/scoreboard。默认 `num_usp=1` 向后兼容。

**Architecture:** 端口数组重排为 `[USP×N, DSP×M]`；fabric.route() 加 `root_of`/`usp_port_id` 解析 + 根域过滤 + `CROSS_ROOT` sentinel；switch 建 `usps[]` + per-USP forward loop；env 建 `rc_agents[]` + per-root 管理器 + `scb[]`。

**Tech Stack:** SystemVerilog / UVM-1.2 / VCS（Q-2020.03）。依赖 `shm_work/host_mem`。

**Spec:** `docs/superpowers/specs/2026-06-25-multi-root-usp-design.md`

---

## 构建/验证约定（每任务复用）

VCS 只在 **ryan@10.11.10.61:2222**（密码 `Ryan@2025`）。本地无 VCS。`/home/ryan` 盘紧 → 构建在 `/tmp/pbuild`。

**一次性搭建（Task 1 前做一次）：**
```bash
ssh -p 2222 ryan@10.11.10.61 'mkdir -p /tmp/pbuild
  rsync -a --delete --exclude csrc --exclude "simv*" --exclude work --exclude "*.daidir" --exclude "*.log" ~/shm_work/ /tmp/pbuild/shm_work/
  mkdir -p /tmp/pbuild/pcie_work'
cd /home/ubuntu/ryan/pcie_work && rsync -az -e "ssh -p 2222" --exclude csrc --exclude "simv*" --exclude "*.daidir" pcie_tl_vip/ ryan@10.11.10.61:/tmp/pbuild/pcie_work/pcie_tl_vip/
ssh -p 2222 ryan@10.11.10.61 'sed -i "s#/home/ryan#/tmp/pbuild#g; s#/home/ubuntu/ryan#/tmp/pbuild#g" /tmp/pbuild/pcie_work/pcie_tl_vip/sim/filelist.f'
```

**每任务 BUILD+RUN（先 rsync 改过的文件到 `/tmp/pbuild/pcie_work/pcie_tl_vip/<path>`，再）：**
```bash
ssh -p 2222 ryan@10.11.10.61 'source ~/set-env.sh >/dev/null 2>&1
  export TMPDIR=/tmp/pbuild/pcie_work/pcie_tl_vip/sim/tmp
  cd /tmp/pbuild/pcie_work/pcie_tl_vip/sim && mkdir -p tmp
  vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -full64 -Mdir=csrc \
    -l compile.log -o simv -f filelist.f >/dev/null 2>&1; echo "vcs rc=$?"; grep -iE "Error-\[" compile.log | head
  ./simv +UVM_TESTNAME=<TEST> +ntb_random_seed=1 2>&1 | grep -iE "UVM_ERROR :|UVM_FATAL :" | tail -2'
```
> 首次执行前用 `sim/Makefile` 确认 VCS 选项（若有额外 +define/incdir，并入上面命令）。现有 test：`pcie_tl_smoke_test` / `pcie_tl_advanced_test` / `pcie_tl_switch_unified_mem_test` 等。

**回归基线（任务完成判定）：** 现有 test `UVM_ERROR=0/UVM_FATAL=0`，尤其 `pcie_tl_switch_unified_mem_test`（走 switch 路径）。

---

## 文件结构

| 文件 | 职责 |
|---|---|
| `src/types/pcie_tl_types.sv`（改） | +`SWITCH_ROUTE_CROSS_ROOT` |
| `src/switch/pcie_tl_switch_config.sv`（改） | +`num_usp`/`dsp_owner`/`cross_root_check_enable`/`usp_*[]`；`init_defaults` 多根域 |
| `src/switch/pcie_tl_switch_port.sv`（改） | +`owner_usp`/`root_id` |
| `src/switch/pcie_tl_switch_fabric.sv`（改） | `root_of`/`usp_port_id`/`cross_root_violations`；route 根域过滤 |
| `src/switch/pcie_tl_switch.sv`（改） | `usps[]`；all_ports 重排；per-USP loop；CROSS_ROOT |
| `src/env/pcie_tl_env.sv`（改） | `rc_agents[]`；per-root 管理器；`scb[]`；接线 |
| `src/env/pcie_tl_virtual_sequencer.sv`（改） | seqr 数组 + 别名 |
| `tests/`（新 4 个） | multi_root_route / cross_root_isolation / uneven_ownership / per_root_tag_independence |
| `sim/filelist.f`（改） | +新 test |

---

## Task 1: route 常量 + switch_port 字段

**Files:**
- Modify: `src/types/pcie_tl_types.sv`（route enum ~240-243）
- Modify: `src/switch/pcie_tl_switch_port.sv`（字段区）

- [ ] **Step 1: 加 CROSS_ROOT 常量**（在 `SWITCH_ROUTE_BCAST = -3` 后）
```systemverilog
    SWITCH_ROUTE_BCAST  = -3,
    SWITCH_ROUTE_CROSS_ROOT = -4
```

- [ ] **Step 2: switch_port 加字段**（读文件确认字段区；在 `port_id` 附近加）
```systemverilog
    int owner_usp = 0;   // DSP 专用: 归属的 USP 索引
    int root_id   = 0;   // USP 专用: 自身根索引
```

- [ ] **Step 3: BUILD smoke**（纯加字段/常量，行为不变）。Expected `vcs rc=0`，`pcie_tl_smoke_test` `UVM_ERROR : 0`。

- [ ] **Step 4: Commit**
```bash
git add src/types/pcie_tl_types.sv src/switch/pcie_tl_switch_port.sv
git commit -m "feat(pcie-tl): add CROSS_ROOT route const + port owner_usp/root_id"
```

---

## Task 2: switch_config 多根域划分

**Files:**
- Modify: `src/switch/pcie_tl_switch_config.sv`（字段 + `init_defaults`）

- [ ] **Step 1: 加字段**（在 `num_ds_ports` 附近）
```systemverilog
    int  num_usp = 1;                  // 上行口/根 数量（默认 1）
    int  dsp_owner[];                  // 可选: dsp_owner[i]=DSP i 的 USP 索引; 空=均匀连续
    bit  cross_root_check_enable = 1;  // 跨根尝试报 uvm_error
    // per-root 域
    bit [7:0]  usp_sec_bus[];          // [num_usp]
    bit [7:0]  usp_sub_bus[];          // [num_usp]
    bit [31:0] usp_mem_base_a[];       // [num_usp]
    bit [31:0] usp_mem_limit_a[];      // [num_usp]
```

- [ ] **Step 2: 重写 `init_defaults()`**（替换现单根版；num_usp=1 时逐路径等价现行为）
```systemverilog
    function void init_defaults();
        int per;
        ds_secondary_bus   = new[num_ds_ports];
        ds_subordinate_bus = new[num_ds_ports];
        ds_mem_base        = new[num_ds_ports];
        ds_mem_limit       = new[num_ds_ports];
        usp_sec_bus      = new[num_usp];
        usp_sub_bus      = new[num_usp];
        usp_mem_base_a   = new[num_usp];
        usp_mem_limit_a  = new[num_usp];

        // 归属: 空 dsp_owner → 均匀连续
        if (dsp_owner.size() != num_ds_ports) begin
            dsp_owner = new[num_ds_ports];
            per = (num_ds_ports + num_usp - 1) / num_usp;  // ceil
            foreach (dsp_owner[i]) dsp_owner[i] = (i / per) < num_usp ? (i / per) : (num_usp - 1);
        end

        // per-root 域 + 根内 DSP 细分（bus: 每根 256/num_usp 带; mem: 每根 0x2000_0000 区）
        for (int r = 0; r < num_usp; r++) begin
            bit [7:0]  rbus = 8'(r * (256 / num_usp)) + 1;   // 根 r 起始 bus
            bit [31:0] rbase = 32'h8000_0000 + r * 32'h2000_0000;
            int k = 0;
            usp_sec_bus[r]     = rbus;
            usp_mem_base_a[r]  = rbase;
            foreach (dsp_owner[i]) if (dsp_owner[i] == r) begin
                ds_secondary_bus[i]   = rbus + 1 + 8'(k);
                ds_subordinate_bus[i] = ds_secondary_bus[i];
                ds_mem_base[i]  = rbase + (k * 32'h0400_0000);   // 64MB/DSP
                ds_mem_limit[i] = ds_mem_base[i] + 32'h03FF_FFFF;
                k++;
            end
            usp_sub_bus[r]     = rbus + 8'(k);
            usp_mem_limit_a[r] = rbase + 32'h1FFF_FFFF;
        end
        usp_subordinate_bus = usp_sub_bus[0];  // 兼容旧单值字段

        // 不交叠自检
        for (int a = 0; a < num_usp; a++) for (int b = a+1; b < num_usp; b++) begin
            if (!(usp_sub_bus[a] < usp_sec_bus[b] || usp_sub_bus[b] < usp_sec_bus[a]))
                `uvm_fatal("SWCFG", $sformatf("root %0d/%0d bus 带重叠", a, b))
            if (!(usp_mem_limit_a[a] < usp_mem_base_a[b] || usp_mem_limit_a[b] < usp_mem_base_a[a]))
                `uvm_fatal("SWCFG", $sformatf("root %0d/%0d 内存区重叠", a, b))
        end
    endfunction
```
> 读现 `init_defaults` 确认旧字段名（`ds_*`、`usp_secondary_bus/usp_subordinate_bus`）保持赋值，使旧消费方不破。num_usp=1：rbus=1、rbase=0x8000_0000、per=num_ds_ports → 与旧版数值一致。

- [ ] **Step 3: BUILD switch test**。Expected `vcs rc=0`，`pcie_tl_switch_unified_mem_test` `UVM_ERROR : 0`（num_usp=1 等价）。

- [ ] **Step 4: Commit**
```bash
git add src/switch/pcie_tl_switch_config.sv
git commit -m "feat(pcie-tl): multi-root domain partition in switch_config init_defaults"
```

---

## Task 3: fabric 路由（root_of / 根域过滤 / 上行解析 / CROSS_ROOT）

**Files:**
- Modify: `src/switch/pcie_tl_switch_fabric.sv`

- [ ] **Step 1: 加成员 + 辅助**（类内）
```systemverilog
    int num_usp = 1;                 // 由 switch 建时设
    int cross_root_violations = 0;
    function int root_of(int port_id);
        if (port_id < num_usp) return port_id;
        return ports[port_id].owner_usp;
    endfunction
    function int usp_port_id(int root); return root; endfunction
```

- [ ] **Step 2: 改 `route_by_id`**（DSP 从 num_usp 起 + 根域过滤）
```systemverilog
    protected function int route_by_id(bit [7:0] target_bus, int ingress_port_id);
        int ir = root_of(ingress_port_id);
        for (int i = num_usp; i < num_ports; i++) begin
            if (target_bus >= ports[i].route_entry.secondary_bus &&
                target_bus <= ports[i].route_entry.subordinate_bus) begin
                if (ports[i].owner_usp != ir) return SWITCH_ROUTE_CROSS_ROOT;
                if (ingress_port_id >= num_usp && i != ingress_port_id && !p2p_enable)
                    return usp_port_id(ir);
                return i;
            end
        end
        if (ingress_port_id >= num_usp) return usp_port_id(ir);
        return SWITCH_ROUTE_DROP;
    endfunction
```

- [ ] **Step 3: 改 `route_by_address`**（同样 num_usp 起 + 根域过滤 + 上行解析）
```systemverilog
    protected function int route_by_address(bit [63:0] addr, int ingress_port_id);
        int ir = root_of(ingress_port_id);
        for (int i = num_usp; i < num_ports; i++) begin
            if (addr >= {32'h0, ports[i].route_entry.mem_base} &&
                addr <= {32'h0, ports[i].route_entry.mem_limit}) begin
                if (ports[i].owner_usp != ir) return SWITCH_ROUTE_CROSS_ROOT;
                if (ingress_port_id >= num_usp && i != ingress_port_id && !p2p_enable)
                    return usp_port_id(ir);
                return i;
            end
        end
        if (ingress_port_id >= num_usp) return usp_port_id(ir);
        return SWITCH_ROUTE_DROP;
    endfunction
```

- [ ] **Step 4: 改 `route()` 上行/BCAST/config-local/default**（读现 route 全文，逐处把 `SWITCH_ROUTE_USP` 改 `usp_port_id(root_of(ingress_port_id))`；config 命中"switch 自身"原 `ports[0].route_entry.secondary_bus` 改成遍历各 USP `ports[0..num_usp-1]`，命中本根 USP secondary_bus → LOCAL；default 分支改下）：
```systemverilog
        // 5. Default: upstream if from DSP, drop if from USP
        if (ingress_port_id >= num_usp)
            return usp_port_id(root_of(ingress_port_id));
        return SWITCH_ROUTE_DROP;
```

- [ ] **Step 5: BUILD switch test（num_usp=1 等价）**。Expected `pcie_tl_switch_unified_mem_test` `UVM_ERROR : 0`。

- [ ] **Step 6: Commit**
```bash
git add src/switch/pcie_tl_switch_fabric.sv
git commit -m "feat(pcie-tl): fabric multi-USP routing (root filter + upstream resolve + cross-root)"
```

---

## Task 4: switch.sv 多 USP 端口 + forward + CROSS_ROOT

**Files:**
- Modify: `src/switch/pcie_tl_switch.sv`

- [ ] **Step 1: 替 usp 单端口为 `usps[]`**（声明）
```systemverilog
    pcie_tl_switch_port    usps[];   // [num_usp]
    pcie_tl_switch_port    dsp[];
    pcie_tl_switch_port    all_ports[];
```

- [ ] **Step 2: build_phase 重排端口**（替换现 usp/dsp/all_ports 构建）
```systemverilog
    int nu = sw_cfg.num_usp; int nd = sw_cfg.num_ds_ports;
    usps = new[nu];
    for (int r=0;r<nu;r++) begin
        usps[r] = pcie_tl_switch_port::type_id::create($sformatf("usp_%0d",r), this);
        usps[r].role=SWITCH_USP; usps[r].port_id=r; usps[r].root_id=r;
    end
    dsp = new[nd];
    for (int i=0;i<nd;i++) begin
        dsp[i] = pcie_tl_switch_port::type_id::create($sformatf("dsp_%0d",i), this);
        dsp[i].role=SWITCH_DSP; dsp[i].port_id=nu+i; dsp[i].owner_usp=sw_cfg.dsp_owner[i];
    end
    all_ports = new[nu+nd];
    for (int r=0;r<nu;r++) all_ports[r]=usps[r];
    for (int i=0;i<nd;i++) all_ports[nu+i]=dsp[i];
    fabric = pcie_tl_switch_fabric::type_id::create("fabric");
    fabric.ports=all_ports; fabric.num_ports=nu+nd; fabric.num_usp=nu;
    fabric.p2p_enable=sw_cfg.p2p_enable;
```

- [ ] **Step 3: connect/run/forward 改用 nu 偏移**：`connect_phase` apply_config 逐 USP（`usps[r].apply_config(sw_cfg, r)` 用 per-root 域）+ 逐 DSP；`run_phase` 起 `nu` 个 usp_forward_loop（ingress=`r`）+ `nd` 个 dsp_forward_loop（ingress=`nu+i`）；`route_and_forward` 的 DSP 自路由重定向改 `usp_port_id(all_ports[ingress_port_id].owner_usp)`，BCAST 限本根（`for i in DSP where owner_usp==root_of(ingress)`）。读现 switch.sv 逐处替换 `usp.`→`usps[r].`、`i+1`/`i=1`→`nu+i`/`i=nu`。

- [ ] **Step 4: 加 CROSS_ROOT case**（`route_and_forward` 的 case）
```systemverilog
            SWITCH_ROUTE_CROSS_ROOT: begin
                total_dropped++; fabric.cross_root_violations++;
                if (sw_cfg.cross_root_check_enable)
                    `uvm_error("CROSS_ROOT", $sformatf("跨根丢弃 from port %0d: %s",
                        ingress_port_id, tlp.convert2string()))
                else `uvm_info("SWITCH", "cross-root dropped", UVM_MEDIUM)
            end
```

- [ ] **Step 5: report_phase** 打印 `nu USP + nd DSP` + `cross_root_violations`。

- [ ] **Step 6: BUILD switch test（num_usp=1）**。**fabric 链路首个完整 num_usp=1 等价验证点 —— 必须绿。** Expected `pcie_tl_switch_unified_mem_test` `UVM_ERROR : 0`。

- [ ] **Step 7: Commit**
```bash
git add src/switch/pcie_tl_switch.sv
git commit -m "feat(pcie-tl): switch multi-USP ports + per-root forward + cross-root handling"
```

---

## Task 5: env per-root（rc_agents / 管理器 / scb / v_seqr）

**Files:**
- Modify: `src/env/pcie_tl_env.sv`、`src/env/pcie_tl_virtual_sequencer.sv`、`src/env/pcie_tl_scoreboard.sv`

- [ ] **Step 1: env 声明数组 + 别名**（替换单 rc_agent/管理器/scb；保留旧名作别名指 [0]）
```systemverilog
    pcie_tl_rc_agent       rc_agents[];
    pcie_tl_if_adapter     rc_adapters[];
    pcie_tl_tag_manager    tag_mgrs[];
    pcie_tl_fc_manager     fc_mgrs[];
    pcie_tl_ordering_engine ord_engs[];
    pcie_tl_cfg_space_manager cfg_mgrs[];
    pcie_tl_scoreboard     scbs[];
    // 旧别名保留: rc_agent / tag_mgr / fc_mgr / ord_eng / cfg_mgr / scb  = [0]
```

- [ ] **Step 2: build_phase 循环建**（num_usp 来自 cfg.switch_cfg.num_usp；非 switch 模式 nu=1）
```systemverilog
    int nu = (cfg.switch_enable && cfg.switch_cfg!=null) ? cfg.switch_cfg.num_usp : 1;
    rc_agents=new[nu]; rc_adapters=new[nu]; tag_mgrs=new[nu]; fc_mgrs=new[nu];
    ord_engs=new[nu]; cfg_mgrs=new[nu]; scbs=new[nu];
    for (int r=0;r<nu;r++) begin
        tag_mgrs[r]=pcie_tl_tag_manager::type_id::create($sformatf("tag_mgr_%0d",r));
        fc_mgrs[r]=pcie_tl_fc_manager::type_id::create($sformatf("fc_mgr_%0d",r));
        ord_engs[r]=pcie_tl_ordering_engine::type_id::create($sformatf("ord_eng_%0d",r));
        cfg_mgrs[r]=pcie_tl_cfg_space_manager::type_id::create($sformatf("cfg_mgr_%0d",r));
        if (cfg.rc_agent_enable) rc_agents[r]=pcie_tl_rc_agent::type_id::create($sformatf("rc_agent_%0d",r),this);
        if (cfg.scb_enable) scbs[r]=pcie_tl_scoreboard::type_id::create($sformatf("scb_%0d",r),this);
    end
    if (nu>0) begin rc_agent=rc_agents[0]; tag_mgr=tag_mgrs[0]; fc_mgr=fc_mgrs[0];
        ord_eng=ord_engs[0]; cfg_mgr=cfg_mgrs[0]; scb=scbs[0]; end
```
> codec/bw_shaper：codec 仍单（无状态共享）；bw_shaper 现单可暂保留单（按根扩为后续可选）。

- [ ] **Step 3: connect_phase 接线**（读现 inject_shared_components/connect 逐处按根索引）：RC_r ↔ usps[r]（rc_adapters[r] + delay）；RC_r 注入 tag_mgrs[r]/fc_mgrs[r]/ord_engs[r]/cfg_mgrs[r]；EP_i 注入 owner_usp[i] 对应根的管理器；scbs[r] 连 rc_agents[r].mon + 本根 EP（owner_usp==r）mon。

- [ ] **Step 4: v_seqr 数组 + 别名**（类型按现 rc_seqr/ep_seqr）
```systemverilog
    // virtual_sequencer 内:
    <现rc_seqr类型> rc_seqr_arr[$];
    <现ep_seqr类型> ep_seqr_arr[$];
    // 别名 rc_seqr/ep_seqr 保留 = [0]
```
env connect: `foreach(rc_agents[r]) v_seqr.rc_seqr_arr.push_back(rc_agents[r].<seqr>)`；别名 [0]。

- [ ] **Step 5: BUILD smoke + switch test（num_usp=1）**。Expected 全 `UVM_ERROR : 0`，现有回归不回退。

- [ ] **Step 6: Commit**
```bash
git add src/env/pcie_tl_env.sv src/env/pcie_tl_virtual_sequencer.sv src/env/pcie_tl_scoreboard.sv
git commit -m "feat(pcie-tl): per-root agents/managers/scoreboard arrays with [0] aliases"
```

---

## Task 6: multi_root_route_test（2 USP + 4 DSP）

**Files:**
- Create: `tests/pcie_tl_multi_root_route_test.sv`
- Modify: `tests/pcie_tl_tb_top.sv`（若 tb 需按 num_usp 注册多 RC vif/接口 —— 读 tb 确认）
- Modify: `sim/filelist.f`（+test incdir/行）

- [ ] **Step 1: 写 test**（继承 base_test；`cfg.switch_enable=1; cfg.switch_cfg.num_usp=2; cfg.switch_cfg.num_ds_ports=4;`（dsp_owner 空→EP0,1→root0；EP2,3→root1）。run_phase：RC0（`env.v_seqr.rc_seqr_arr[0]`）发 mem_wr 到 root0 EP 的地址（0x8000_0000 区）、RC1 发到 root1（0xA000_0000 区）；check：各 EP 只收本根流量，`env.sw.fabric.cross_root_violations==0`，各 scb 无 mismatch。读 base_test cfg 钩子 + mem_wr seq 字段 + EP mon 计数访问。

- [ ] **Step 2: BUILD+RUN**。Expected `vcs rc=0`，`UVM_ERROR : 0`，`cross_root_violations=0`，2 根各自路由成功。

- [ ] **Step 3: Commit**
```bash
git add tests/pcie_tl_multi_root_route_test.sv tests/pcie_tl_tb_top.sv sim/filelist.f
git commit -m "test(pcie-tl): multi_root_route_test (2 USP + 4 DSP)"
```

---

## Task 7: cross_root_isolation_test

**Files:**
- Create: `tests/pcie_tl_cross_root_isolation_test.sv`
- Modify: `sim/filelist.f`

- [ ] **Step 1: 写 test**：2 根；RC0 发 mem_wr 到 **root1 地址域**（0xA000_0000 区）；check：该 TLP 被 drop，`env.sw.fabric.cross_root_violations==1`，root1 的 EP **未收到**（mon 计数==0）。判定不以总 UVM_ERROR=0（`CROSS_ROOT` 是预期 uvm_error），而以 `cross_root_violations==1` + root1 EP 收包==0 的专用断言（仅断言失败时 `uvm_error("ISO_FAIL")`）。

- [ ] **Step 2: BUILD+RUN**。Expected `vcs rc=0`，`cross_root_violations=1`，root1 EP 0 收包，`ISO test PASSED`。

- [ ] **Step 3: Commit**
```bash
git add tests/pcie_tl_cross_root_isolation_test.sv sim/filelist.f
git commit -m "test(pcie-tl): cross_root_isolation_test"
```

---

## Task 8: uneven_ownership + per_root_tag_independence

**Files:**
- Create: `tests/pcie_tl_uneven_ownership_test.sv`、`tests/pcie_tl_per_root_tag_test.sv`
- Modify: `sim/filelist.f`

- [ ] **Step 1: uneven_ownership_test**：`cfg.switch_cfg.dsp_owner='{0,0,0,1}`（num_usp=2）→ RC0 拥 EP0-2、RC1 拥 EP3。run：RC0 触达 EP0-2、RC1 触达 EP3；check 归属被尊重（RC0 发往 EP3 域 → CROSS_ROOT 计数），`init_defaults` 不交叠 assert 不 fatal。

- [ ] **Step 2: per_root_tag_test**：2 根并发，RC0 与 RC1 各发 mem_rd **用相同 tag**（如都 tag=5）；check：per-root tag_mgr 独立 → 无 tag 冲突告警，两根 completion 各回各根、数据对，`UVM_ERROR : 0`。

- [ ] **Step 3: BUILD+RUN 两 test**。Expected per_root_tag `UVM_ERROR : 0`；uneven 里 CROSS_ROOT 为预期，按计数断言 PASS。

- [ ] **Step 4: Commit**
```bash
git add tests/pcie_tl_uneven_ownership_test.sv tests/pcie_tl_per_root_tag_test.sv sim/filelist.f
git commit -m "test(pcie-tl): uneven ownership + per-root tag independence"
```

---

## Task 9: 全回归 + 文档

- [ ] **Step 1: 全回归**（61）：现有 test（smoke/advanced/switch_unified_mem/unified_mem）+ 4 新 test 全 `UVM_ERROR=0/FATAL=0`（隔离类按 violation 计数断言）。记录结果表。

- [ ] **Step 2: Commit**（文档更新）
```bash
git add -A
git commit -m "docs(pcie-tl): record multi-root regression matrix"
```

---

## Self-Review

- Spec 覆盖：§3.1→T2；§3.2→T1/T4；§3.3→T1/T3/T4；§3.4→T5；§5 兼容→各任务 num_usp=1 验证点（尤其 T4 Step6）；§7 验证→T6-9。无缺口。
- 实现期需读确认的真实名（计划已标"读现…确认"）：env 的 `inject_shared_components`/管理器注入 API、`rc_agent`/`ep_agent` 的 sequencer 与 mon 端口名、base_test cfg 钩子、tb_top 多 RC vif 注册、mem_wr/mem_rd seq 字段、现 `init_defaults` 旧字段名。
- 类型一致：`num_usp`(int)、`dsp_owner[]`、`usps[]`/`rc_agents[]`/`scbs[]`(动态数组)、`SWITCH_ROUTE_CROSS_ROOT`、`root_of`/`usp_port_id`/`cross_root_violations` 全程一致。
- **关键风险**：端口索引重排（DSP 从 `num_usp` 起）—— T3/T4 每处端口循环、`SWITCH_ROUTE_USP=0` 都改；T4 Step6 num_usp=1 等价是兜底验证点，过不了就回查漏改的 `i=1`/`=0`。
