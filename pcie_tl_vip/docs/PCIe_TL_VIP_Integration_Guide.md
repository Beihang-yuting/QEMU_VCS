# PCIe TL VIP — 集成测试指南

> 面向**拿 VIP 去对接自己设计/DUT 做集成测试**的用户。深入的组件/字段细节见 [PCIe_TL_VIP_User_Guide.md](./PCIe_TL_VIP_User_Guide.md)；本文只讲「怎么接进来、怎么配、怎么跑、怎么判过」。

---

## 1. 两种集成模式

| 模式 | 用途 | EP/DUT 来源 | 切换方式 |
|------|------|-------------|----------|
| **TLM Loopback**（默认） | 纯 VIP 自验、回归基线、参考模型 | VIP 内置 EP/Switch 行为模型 | 默认即是 |
| **SV Interface** | 连真实 RTL DUT 做集成测试 | 用户 RTL（经 `pcie_tl_if`） | `set_mode(SV_IF_MODE)` |

集成测试通常用 **SV Interface 模式**：VIP 当 Root Complex（出激励 + 协议检查 + scoreboard），用户 DUT 当 Endpoint/Switch。

---

## 2. 集成步骤（SV Interface 模式）

### 2.1 编译：把 VIP 源码加进你的 filelist

VIP 用 `sim/filelist.f` 管理编译顺序（host_mem_pkg → pcie_tl_if → pcie_tl_pkg → test → tb_top）。集成时把 VIP 的 `src/` + 你的 DUT RTL 一起喂给仿真器：

```bash
vcs -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -full64 \
    -f pcie_tl_vip/sim/filelist.f \
    -f your_dut/dut_filelist.f \
    -o simv
```

> filelist.f 里路径若与你的目录不同，按需 `sed` 重写前缀（见 User Guide §3.1 incdir 列表）。

### 2.2 顶层：例化 interface + 绑 DUT + 注册 vif

```systemverilog
module tb_top;
    logic clk, rst_n;
    pcie_tl_if tl_if(.clk(clk), .rst_n(rst_n));

    // 你的 DUT 接 VIP interface
    my_pcie_dut dut (
        .clk(clk), .rst_n(rst_n),
        .tlp_data (tl_if.tlp_data),  .tlp_valid(tl_if.tlp_valid),
        .tlp_ready(tl_if.tlp_ready), .tlp_sop  (tl_if.tlp_sop),
        .tlp_eop  (tl_if.tlp_eop),   .tlp_strb (tl_if.tlp_strb)
    );

    initial begin
        uvm_config_db#(virtual pcie_tl_if)::set(null, "*", "vif", tl_if);
    end
    // clk/rst 生成 + run_test() 略
endmodule
```

### 2.3 测试：切到 SV Interface 模式

```systemverilog
class my_integ_test extends pcie_tl_base_test;
    `uvm_component_utils(my_integ_test)
    function new(string name="my_integ_test", uvm_component parent=null);
        super.new(name, parent); endfunction

    virtual function void configure_test();
        super.configure_test();
        set_mode(SV_IF_MODE);          // 关键：连 RTL 而非 TLM loopback
        cfg.fc_enable     = 1;
        cfg.scb_enable    = 1;         // 打开 scoreboard 做真校验
        cfg.cpl_timeout_ns = 200000;
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        // 出激励到 DUT —— 见 §4
        phase.drop_objection(this);
    endtask
endclass
```

---

## 3. 拓扑配置配方

### 3.1 单 RC + 单 EP（点对点）

```systemverilog
// configure_test() 内 —— switch 不开，env 建单 RC + 单 EP
cfg.rc_agent_enable = 1;
cfg.ep_agent_enable = 1;   // SV_IF 模式下 EP 即你的 DUT
```

### 3.2 单根 Switch（1 RC + N EP）

```systemverilog
pcie_tl_switch_config sw_cfg = new("sw_cfg");
sw_cfg.num_ds_ports = 4;
sw_cfg.p2p_enable   = 1;
sw_cfg.init_defaults();
cfg.switch_enable = 1;
cfg.switch_cfg    = sw_cfg;
```

### 3.3 多根 Switch（N RC + M EP，不交叠层级）

```systemverilog
pcie_tl_switch_config sw_cfg = new("sw_cfg");
sw_cfg.num_usp      = 2;             // 2 个根 RC0/RC1
sw_cfg.num_ds_ports = 4;            // dsp_owner 留空 → EP0/1→root0, EP2/3→root1
// 自定义归属: sw_cfg.dsp_owner = '{0,0,0,1};  // EP0-2→root0, EP3→root1
sw_cfg.init_defaults();             // 自动派不交叠 bus 带 + 内存区
cfg.switch_enable = 1;
cfg.switch_cfg    = sw_cfg;
```

> 各根 EP 内存窗 = `cfg.switch_cfg.ds_mem_base[i]`；按此地址出激励即落到对应 EP。多根细节见 User Guide §8.4.1。

### 3.4 非-Switch 多 agent（N RC + M EP 独立链路，num_rc/num_ep）

不建 switch，直接起**任意 N RC + M EP 独立链路**，每个 agent 独占一套 4 通道 adapter + per-pair manager/scoreboard。主用于把多个 BFM 直接对接真实 DUT（每链路一条物理 AXIS，不需建模 switch）。

```systemverilog
cfg.rc_agent_enable = 1;
cfg.ep_agent_enable = 0;   // 或 1
cfg.num_rc          = 2;   // 2 个独立 RC host 链路（对接真实 EP DUT 时 BFM 用 RC role）
cfg.num_ep          = 0;   // 或 M 个独立 EP 链路
cfg.switch_enable   = 0;   // switch 关；开则 num_rc/num_ep 被忽略（取 num_usp/num_ds_ports）
```

- 默认 `num_rc=num_ep=1` == 旧点对点（§3.1），`env.rc_agent`/`ep_agent` 别名保留。
- `num_rc>1` → per-root manager 隔离照旧（`tag_mgrs[i]`/`fc_mgrs[i]`/…/`scbs[i]` 按 num_rc sizing）。
- **TLM 模式** + `num_rc==num_ep>1`：env 为每对 `RC[i]↔EP[i]` fork 独立回环，可纯 sim 跑 N 条独立链路、不接 DUT（大流量回归 `pcie_tl_multipair_heavy_test`，`+NUM_PAIRS`）。
- **SV_IF 模式**：每链路独立物理 AXIS，接真实 DUT；连线约定见 `xilinx_pcie` 集成指南 §2.3。

> 句柄 `env.rc_agents[i]` / `env.ep_agents[i]`（`[0]` 别名单数）。出激励：`env.rc_agents[i].sequencer`。详见 User Guide §8.5。

---

## 4. 出激励 / 取句柄

| 操作 | 单根 / 别名 | 多根 |
|------|-------------|------|
| RC 发 TLP | `env.rc_agent.sequencer` 或 `env.v_seqr.rc_seqr_arr[0]` | `env.v_seqr.rc_seqr_arr[r]` |
| EP 主动 DMA | `env.ep_agents[i].ep_driver.initiate_dma(addr,len,flag)` | 同左 |
| Scoreboard | `env.scb` | `env.scbs[r]` |
| Switch 统计 | `env.sw.total_routed/total_dropped/total_p2p` | + `env.sw.fabric.cross_root_violations`, `env.sw.dsp[i].forwarded_count` |

发 MWr 示例（合法性要求见 §6）：

```systemverilog
pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
wr.addr     = {32'h0, cfg.switch_cfg.ds_mem_base[0]};  // 目标 EP0 窗口
wr.length   = 16;          // DW 数 (16 DW = 64B)
wr.first_be = 4'hF;
wr.last_be  = 4'hF;        // length==1 时必须 4'h0 (见 §6)
wr.is_64bit = (wr.addr[63:32] != 0);
wr.start(env.v_seqr.rc_seqr_arr[0]);
```

---

## 5. 判过标准（集成测试 check_phase）

`base_test` 已在 `check_phase` 汇总 UVM_ERROR/FATAL。集成时建议额外断言：

```systemverilog
function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    // 数据/completion 真校验
    if (env.scb.mismatched != 0 || env.scb.unexpected != 0 ||
        env.scb.timed_out != 0)
        `uvm_error("INTEG", "scoreboard 不干净")
    // 多根: 隔离
    if (cfg.switch_cfg != null && cfg.switch_cfg.num_usp > 1)
        if (env.sw.fabric.cross_root_violations != 0)  // 若你的流量本应全在根内
            `uvm_error("INTEG", "意外跨根流量")
endfunction
```

**基线通过 = `UVM_ERROR=0 && UVM_FATAL=0` + scoreboard `mismatched/unexpected/timed_out=0`。** 故意注入错误的用例除外（按 violation 计数断言，参考 `pcie_tl_multi_root_stress_test`）。

---

## 6. 集成常见坑（VIP 会按 PCIe 规则拒绝非法 TLP → randomize 失败 `CNST-CIF`）

| 坑 | 规则 | 正确做法 |
|----|------|----------|
| 单 DW 传输 | `length==1` 时 `last_be` 必须为 `4'h0` | `last_be = (length==1) ? 4'h0 : 4'hF;` |
| 4KB 边界 | 单个 TLP 不得跨 4KB 页 | 保证 `(addr & 0xFFF) + bytes <= 0x1000`，否则按页 clamp |
| first_be | 不可为 0 | `first_be != 0`（满 DW 用 `4'hF`） |
| 多根跨根 | 跨根目标一律 drop | 出激励地址落本根 EP 窗口 `ds_mem_base[owned]` |

> 上述合法性约束在 `pcie_tl_mem_wr_seq`/`pcie_tl_mem_rd_seq` 的 `CONSTRAINT_LEGAL` 模式强制；随机激励违反即 `Error-[CNST-CIF]`，该 TLP 不会发出。参考 `pcie_tl_multi_root_stress_test.sv` 的 `clamp_4kb()` 辅助。

---

## 7. 跑测试 + 收结果

```bash
# 单个用例
./simv +UVM_TESTNAME=my_integ_test +ntb_random_seed=1

# 调日志
./simv +UVM_TESTNAME=my_integ_test +UVM_VERBOSITY=UVM_LOW

# 关协议检查（只跑功能，临时）
./simv +UVM_TESTNAME=my_integ_test +UVM_VERBOSITY=UVM_NONE
```

判过：日志尾 `UVM_ERROR : 0` / `UVM_FATAL : 0` + 你的 check_phase PASS 打印。

---

## 8. 参考用例（可直接抄改）

| 场景 | 参考 test |
|------|-----------|
| 单 EP 读写 | `pcie_tl_smoke_mem_test` |
| 单根 Switch 路由 | `pcie_tl_switch_basic_test` |
| 多根路由/隔离 | `pcie_tl_multi_root_route_test` / `pcie_tl_cross_root_isolation_test` |
| 多根重压混错 | `pcie_tl_multi_root_stress_test` |
| 大流量稳定性 | `pcie_tl_switch_heavy_traffic_test` |

完整测试清单与结果见 User Guide §14。
