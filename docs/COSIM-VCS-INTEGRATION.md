# CoSim VCS 侧集成指南 — 转接层 + DPI + DUT 对接

把 cosim 桥集成进你的 VCS/UVM 环境,驱动 xilinx-pcie DUT。C 编库单独见
[COSIM-C-BUILD.md](COSIM-C-BUILD.md)。

---

## 1. 层次栈

```
你的 UVM test / top   (tb_cosim_multirc_top.sv / cosim_xrc_test.sv)
   │
【转接层】cosim_xrc_driver.sv     ← 调 DPI + 转 QEMU-TLP ↔ pcie_tl_vip ↔ AXIS→DUT
   │
【DPI 声明】bridge_vcs.sv (cosim_bridge_pkg)   ← import "DPI-C" 全部 _rc
   │
【C 库】libcosim_bridge.a / inline .c   ← bridge_vcs.c 等,DPI 实现 + TCP transport
   │  TCP
 QEMU (cosim-pcie-rc, server)
```

三层职责:
- **C 库**:DPI 函数实现 + SHM/TCP transport。编库见 COSIM-C-BUILD.md。
- **DPI 声明层** `bridge_vcs.sv`:`package cosim_bridge_pkg`,把 C 符号绑成 SV 可调函数。`import cosim_bridge_pkg::*` 即用。
- **转接层** `cosim_xrc_driver.sv`:每 RC 一个,polling QEMU、转 TLP、发/收 completion。

---

## 2. 你的环境要吃哪些文件

**SV(编进你的 simv):**
```
bridge/vcs/bridge_vcs.sv          # cosim_bridge_pkg (DPI 声明) — 必须先于转接层编
vcs-tb/cosim_env_config.sv        # cosim_env_config (可选,或用你自己的 env cfg)
vcs-tb/cosim_xrc_driver.sv        # 转接层
vcs-tb/cosim_xrc_test.sv          # 每 RC init bridge + 拉起 driver
vcs-tb/cosim_xrc_pkg.sv           # 打包上面三个(import uvm/pcie_tl/xilinx/cosim_bridge)
vcs-tb/tb_cosim_multirc_top.sv    # top:2×4 AXIS 总线 + 连 DUT
```
依赖三库(你已有):`pcie_tl_vip`(要有 num_rc/num_ep + adapter 基类的合并版)、
`xilinx_pcie`(adapter 版,含 xilinx_pcie_adapter_pkg)、`axis_vip`、`host_mem`。

**C 库**:`libcosim_bridge.a`(或 inline 编,见 COSIM-C-BUILD.md)。

编译顺序 + 可直接用的脚本:`scripts/build_cosim_multirc.sh`(filelist 见其 `gen_filelist`)。

---

## 3. 转接层调了哪些 DPI(按 UVM phase)

`cosim_xrc_driver` + `cosim_xrc_test` 实际调用:

| Phase / 时机 | 调用方 | DPI 函数 | 作用 |
|---|---|---|---|
| build_phase | driver | (config_db)`rc_index` | 定本 driver 服务哪个 RC(名字 `rc_agent_<N>` 兜底) |
| run_phase 开头 | test | `bridge_vcs_init_ex_rc(r,"tcp","","",host,port_base,r)` | 每 RC 连一个 QEMU(client) |
| run_phase(每 RC ready) | test | 设 `driver.bridge_ready=1` | 放行 polling |
| request_loop(forever) | driver | `bridge_vcs_poll_tlp_scalar_rc(rc)` | 取 QEMU 来的一个 TLP;>0 空、<0 shutdown |
| 取到 TLP | driver | `get_poll_type/addr/len/tag_rc(rc)` + `get_poll_data_rc(rc,i)` | 拿字段(纯 scalar,VCS Q-2020 安全) |
| config 读(bypass) | driver | `set_cpl_data_rc(rc,i,v)` + `send_cpl_scalar_rc(rc,tag,1)` | proxy 直接回 config completion |
| config 写(bypass) | driver | `set_bar_base_rc(rc,0,addr)` | 同步 BAR base 给 C 侧地址解码 |
| MMIO 请求 → DUT | driver | `send_tlp(vip_tlp)` → `adapter.send` | 走 pcie_tl pipeline → CQ 通道 → DUT |
| DUT completion 回 | driver | `set_cpl_data_rc(rc,i,v)` + `send_cpl_scalar_rc(rc,qemu_tag,1)` | 转发 CplD 回 QEMU |
| run_phase 收尾 | test | `bridge_vcs_cleanup_ex_rc(r)` | 关每 RC transport |

> 所有 `_rc(int rc)` 变体 = per-RC;`rc=0` 与 legacy 单 RC 字节等价。

---

## 4. 转接层 ↔ DUT:AXIS 通道 ↔ TLP 映射(RC 角色)

BFM 演 host(RC 角色),面对真 EP DUT。DUT 暴露自己的 PG213 4 通道,**同名对接**
(RQ→RQ / RC→RC / CQ→CQ / CC→CC)。方向由 adapter 的 make_axis_config 定:

| 事务 | 方向 | AXIS 通道 | adapter 角色 | 谁 drive |
|---|---|---|---|---|
| QEMU→DUT MMIO/Cfg 请求 | 出 | **CQ** | MASTER | adapter → DUT |
| DUT→QEMU completion(读返回) | 入 | **CC** | SLAVE | DUT → adapter |
| DUT→QEMU DMA 请求(MRd/MWr) | 入 | **RQ** | SLAVE | DUT → adapter |
| QEMU→DUT DMA completion | 出 | **RC** | MASTER | adapter → DUT |

- 前两行 = **MMIO 通路**(已做:`send_tlp`→CQ;completion 从 `adapter.receive()` drain→`send_cpl_scalar_rc`)。
- 后两行 = **DUT 主动 DMA 通路**(MMIO-first 占位:`rx_loop` 收到 RQ 入向请求只 log,未打 QEMU 主存)。

TUSER 宽度(DATA_WIDTH=256):RQ=137 / RC=161 / CQ=183 / CC=81。

---

## 5. 工厂 override(cosim_xrc_test.build_phase 已做)

```systemverilog
// 基类 adapter → xilinx AXIS adapter
pcie_tl_if_adapter::type_id::set_type_override(xilinx_pcie_if_adapter::get_type());
// 基类 RC driver → cosim 转接层
pcie_tl_rc_driver::type_id::set_type_override(cosim_xrc_driver::get_type());
// 2 个 RC,非 switch,无 EP
cfg.num_rc = 2; cfg.rc_agent_enable = 1; cfg.ep_agent_enable = 0; cfg.switch_enable = 0;
```
env 据此建 `rc_adapter_0/1`(xilinx) + `rc_agent_0/1`(内含 cosim_xrc_driver),
`env.connect_phase` 自动把 `rc_adapters[r]` 塞给 `rc_agents[r].driver.adapter` ——
所以转接层 `send_tlp/adapter.receive` 直连本 RC 的 4 条 AXIS 通道。

---

## 6. 把 DUT 接上(top)

`tb_cosim_multirc_top.sv` 每 RC 声明 4 条 `axis_if`(rcN_rq/rc/cq/cc),现留空。接法:

```systemverilog
// 例:RC0 的 DUT
your_xilinx_ep_dut u_dut0 (
  .clk (clk), .rst_n (rst_n),
  // DUT 的 PG213 口,同名对接(注意方向:CQ/RC 是 DUT 输入,RQ/CC 是 DUT 输出)
  .m_axis_cq (rc0_cq),   // adapter MASTER → DUT 收
  .s_axis_cc (rc0_cc),   // DUT → adapter(completion)
  .m_axis_rq (rc0_rq),   // DUT → adapter(DMA 请求)
  .s_axis_rc (rc0_rc)    // adapter → DUT(DMA completion)
);
```
无 DUT 时总线留空 → 只能 elaborate 空跑(RC build 起来,无 tready 不跑数据)。

---

## 7. 已做 / 待接

| 项 | 状态 |
|---|---|
| C 库对接(.a / inline) | ✅ 61 实测两条都编过 |
| DPI 声明层(_rc 全套) | ✅ |
| 转接层(polling / TLP 转换 / completion 回传 / per-RC index) | ✅ 61 elaborate 实测 2 RC bound |
| MMIO 通路(QEMU 读写 DUT BAR + completion) | ✅ 逻辑完成,待 DUT 接线跑数据 |
| config 空间 bypass(SV proxy 答枚举) | ✅ |
| **DUT-DMA 入向(RQ)+ MSI** | ⬜ 占位,下一增量 |
| **device.* → config_proxy 对齐**(你 DUT 身份 ≠ 默认 1af4:1041 时) | ⬜ 描述符已透传 plusarg,proxy 未消费 |
| **DUT AXIS 接线** | ⬜ 你来接(见 §6) |
