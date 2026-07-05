# Xilinx PCIe TL-Layer BFM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Xilinx PG213 PCIe TL-layer BFM that converts standard PCIe TLPs to/from Xilinx 4-channel AXIS descriptors, reusing axis_work and pcie_work VIPs via composition.

**Architecture:** Layered composition — user sequences produce `pcie_tl_tlp` objects, a codec layer converts them to Xilinx descriptors, and 4 reused `axis_agent` instances drive the AXIS interface. RC/EP roles are configurable, with optional cfg_mgmt and cfg_interrupt sideband agents.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS/Xcelium. Reuses axis_work (`/home/ubuntu/ryan/axis_work/axis_vip/`) and pcie_work (`/home/ubuntu/ryan/pcie_work/pcie_tl_vip/`).

**Spec:** `docs/superpowers/specs/2026-04-27-xilinx-pcie-bfm-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `src/xilinx_pcie_pkg.sv` | 顶层 package |
| `src/xilinx_pcie_types.sv` | 枚举、结构体、类型定义 |
| `src/interface/xilinx_pcie_if.sv` | 4 通道 AXIS 顶层接口 |
| `src/interface/xilinx_pcie_cfg_if.sv` | cfg_mgmt + cfg_interrupt 接口 |
| `src/codec/xilinx_desc_codec.sv` | Descriptor <-> TLP 转换 |
| `src/codec/xilinx_tuser_codec.sv` | tuser 字段编解码 |
| `src/codec/xilinx_straddle_engine.sv` | Straddling 组包/拆包 |
| `src/agent/xilinx_pcie_channel_router.sv` | TLP -> 通道路由 |
| `src/agent/xilinx_pcie_driver.sv` | 发送：TLP -> descriptor -> AXIS |
| `src/agent/xilinx_pcie_monitor.sv` | 接收：AXIS -> descriptor -> TLP |
| `src/agent/xilinx_pcie_base_agent.sv` | 基类 agent |
| `src/agent/xilinx_pcie_rc_agent.sv` | RC 角色 agent |
| `src/agent/xilinx_pcie_ep_agent.sv` | EP 角色 agent |
| `src/cfg/xilinx_pcie_cfg_agent.sv` | cfg_mgmt 驱动/监控 |
| `src/cfg/xilinx_pcie_interrupt_agent.sv` | cfg_interrupt 驱动/监控 |
| `src/env/xilinx_pcie_env_config.sv` | 配置对象 |
| `src/env/xilinx_pcie_env.sv` | 顶层环境 |
| `src/env/xilinx_pcie_virtual_sequencer.sv` | 多 agent 协调 |
| `src/env/xilinx_pcie_scoreboard.sv` | 校验器 |
| `src/env/xilinx_pcie_coverage.sv` | 功能覆盖 |
| `src/seq/xilinx_pcie_base_seq.sv` | 基类 sequence |
| `src/seq/xilinx_pcie_mem_seq.sv` | Memory Read/Write |
| `src/seq/xilinx_pcie_cfg_seq.sv` | Config Read/Write |
| `src/seq/xilinx_pcie_dma_seq.sv` | DMA 读写 |
| `src/seq/xilinx_pcie_msi_seq.sv` | MSI/MSI-X/Legacy 中断 |
| `src/seq/xilinx_pcie_loopback_vseq.sv` | 回环虚拟序列 |
| `tb/tb_top.sv` | ���层 testbench |
| `tb/xilinx_pcie_loopback_dut.sv` | 回环 DUT |
| `tb/tb_with_dut.sv` | 真实 DUT 连接模板 |
| `tests/xilinx_pcie_base_test.sv` | 基类测试 |
| `tests/xilinx_pcie_sanity_test.sv` | 冒烟测试 |
| `tests/xilinx_pcie_straddle_test.sv` | Straddling 测试 |
| `tests/xilinx_pcie_loopback_test.sv` | 全面回环测试 |
| `sim/filelist.f` | 编译文件列表 |
| `sim/Makefile` | 构建自动化 |

---

## Task 1: Project Skeleton and Types

**Files:**
- Create: `src/xilinx_pcie_types.sv`
- Create: `src/xilinx_pcie_pkg.sv`
- Create: `sim/filelist.f`
- Create: `sim/Makefile`

- [ ] **Step 1: Create directory structure**

```bash
cd /home/ubuntu/ryan/xilinx_pcie
mkdir -p src/interface src/codec src/agent src/cfg src/env src/seq tb tests sim
```

- [ ] **Step 2: Create xilinx_pcie_types.sv with all enums, structs, helper functions**

See spec Section 7.1 for exact type definitions. Key types:
- `xilinx_pcie_role_e` (RC/EP)
- `xilinx_channel_e` (RQ/RC/CQ/CC)
- `xilinx_pcie_speed_e` (GEN1-4)
- `xilinx_interrupt_mode_e` (LEGACY/MSI/MSIX)
- `xilinx_req_type_e` (MRD/MWR/IORD/IOWR/MRD_LK/FETCH_ADD/SWAP/CAS)
- `xilinx_cpl_status_e` (SC/UR/CRS/CA)
- `xilinx_addr_type_e` (UNTRANSLATED/TRANS_REQ/TRANSLATED)
- `xilinx_bar_config_t` struct
- `xilinx_channel_bw_config_t` struct
- `xilinx_interrupt_item` class
- `xilinx_desc_item` class
- `xilinx_get_rq/rc/cq/cc_tuser_width()` functions

- [ ] **Step 3: Create initial xilinx_pcie_pkg.sv**

```systemverilog
package xilinx_pcie_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axis_pkg::*;
  import pcie_tl_pkg::*;
  `include "xilinx_pcie_types.sv"
  // More includes added in subsequent tasks
endpackage
```

- [ ] **Step 4: Create filelist.f**

Include paths for axis_work, pcie_work, and xilinx_pcie. Compilation order: axis VIP filelist -> pcie_tl_if.sv -> pcie_tl_pkg.sv -> xilinx_pcie interfaces -> xilinx_pcie_pkg.sv -> tb -> tests.

- [ ] **Step 5: Create Makefile**

Targets: `compile`, `sim`, `sanity`, `straddle`, `loopback`, `clean`. Supports `TEST`, `DATA_WIDTH`, `STRADDLE_EN`, `SEED` variables. VCS with `-sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps`.

- [ ] **Step 6: Init git repo and commit**

```bash
git init && git add -A && git commit -m "feat: project skeleton with types, package, filelist, and Makefile"
```

---

## Task 2: SV Interfaces

**Files:**
- Create: `src/interface/xilinx_pcie_if.sv`
- Create: `src/interface/xilinx_pcie_cfg_if.sv`

- [ ] **Step 1: Create xilinx_pcie_if.sv**

Parameterized interface with `DATA_WIDTH`, `RQ/RC/CQ/CC_TUSER_WIDTH`. Contains:
- 4 AXIS channels: `{rq,rc,cq,cc}_{tdata,tkeep,tlast,tvalid,tready,tuser}`
- `KEEP_WIDTH = DATA_WIDTH / 32` (per-DW granularity per PG213)
- 3 clocking blocks: `ep_drv_cb`, `rc_drv_cb`, `mon_cb`
- 3 modports: `ep_mp`, `rc_mp`, `mon_mp`

See spec Section 8.1 for exact signal definitions and clocking block directions.

- [ ] **Step 2: Create xilinx_pcie_cfg_if.sv**

Contains cfg_mgmt signals (addr, byte_enable, read, write, write_data, read_data, read_write_done, debug_access) and all cfg_interrupt signals (Legacy int/pending/sent, MSI enable/mmenable/mask_update/data/select/int/pending_status/sent/fail, MSI-X enable/mask/data/address/int/vec_pending/vec_pending_status).
- 2 clocking blocks: `user_cb` (EP view), `pcie_ip_cb` (RC view)
- 2 modports: `user_mp`, `pcie_ip_mp`

See spec Section 8.2 for complete signal list.

- [ ] **Step 3: Commit**

```bash
git add src/interface/ && git commit -m "feat: add xilinx_pcie_if and xilinx_pcie_cfg_if"
```

---

## Task 3: Configuration Object

**Files:**
- Create: `src/env/xilinx_pcie_env_config.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_pcie_env_config.sv**

14 parameter groups per spec Section 7. Key methods:
- `get_{rq,rc,cq,cc}_tuser_width()` — delegates to `xilinx_get_*` functions
- `validate()` — checks DATA_WIDTH, straddle_enable, MPS, MRRS, RCB legality
- `create_axis_config(xilinx_channel_e ch)` — generates `axis_config` with correct TDATA_WIDTH, TUSER_WIDTH, agent_mode (per role/channel table), bandwidth settings

The `create_axis_config()` method is critical — it maps:
- Role RC: RQ=SLAVE, RC=MASTER, CQ=MASTER, CC=SLAVE
- Role EP: RQ=MASTER, RC=SLAVE, CQ=SLAVE, CC=MASTER

- [ ] **Step 2: Add include to xilinx_pcie_pkg.sv**

```systemverilog
  `include "xilinx_pcie_env_config.sv"
```

- [ ] **Step 3: Commit**

```bash
git add src/env/xilinx_pcie_env_config.sv src/xilinx_pcie_pkg.sv
git commit -m "feat: add xilinx_pcie_env_config with 14 parameter groups"
```

---

## Task 4: Descriptor Codec

**Files:**
- Create: `src/codec/xilinx_desc_codec.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_desc_codec.sv**

All static functions, no state. Implements:

**Mapping helpers:**
- `kind_to_req_type(tlp_kind_e)` — TLP_MEM_RD->XILINX_REQ_MRD, etc.
- `req_type_to_kind(xilinx_req_type_e, bit has_data)` — reverse
- `encode_error_code(bit[2:0] cpl_status)` — SC/UR/CRS/CA mapping
- `get_desc_bits(xilinx_channel_e)` — RQ/CQ=128, RC/CC=96
- `get_payload_dw_offset(channel, data_width)` — RC/CC=3 (DW3), RQ/CQ=0 (next beat)

**Encode functions (TLP -> descriptor):**
- `encode_rq(pcie_tl_tlp)` -> `bit[127:0]` — maps addr, length, req_type, requester_id, tag[7:0], first/last_be, attr, tc, th, force_ecrc per spec Section 3.1
- `encode_rc(pcie_tl_tlp)` -> `bit[95:0]` — maps lower_addr, error_code, byte_count, request_completed, length, cpl_status, requester_id, tag[7:0], completer_id per spec Section 3.2
- `encode_cq(pcie_tl_tlp, bar_id, bar_aperture, target_func)` -> `bit[127:0]` — adds BAR hit info per spec Section 3.3
- `encode_cc(pcie_tl_tlp)` -> `bit[95:0]` — per spec Section 3.4

**Decode functions (descriptor -> TLP):**
- `decode_rq(bit[127:0], payload[])` -> `pcie_tl_tlp`
- `decode_rc(bit[95:0], payload[])` -> `pcie_tl_tlp`
- `decode_cq(bit[127:0], payload[])` -> `pcie_tl_tlp`
- `decode_cc(bit[95:0], payload[])` -> `pcie_tl_tlp`

Each decode creates a `pcie_tl_tlp` via factory, sets all fields, derives `fmt` from address width and data presence, derives `kind` from req_type or locked/data flags.

**Field mapping reference (RQ example):**
```
desc[1:0]     = addr_type (2'b00)
desc[63:2]    = tlp.addr[63:2]
desc[74:64]   = tlp.length
desc[78:75]   = kind_to_req_type(tlp.kind)
desc[79]      = tlp.ep_bit
desc[95:80]   = tlp.requester_id
desc[103:96]  = tlp.tag[7:0]
desc[107:104] = tlp.last_be
desc[111:108] = tlp.first_be
desc[114:112] = tlp.attr
desc[117:115] = tlp.tc
desc[118]     = tlp.th
desc[127]     = tlp.td (Force ECRC)
```

- [ ] **Step 2: Add include, commit**

```bash
git add src/codec/xilinx_desc_codec.sv src/xilinx_pcie_pkg.sv
git commit -m "feat: add xilinx_desc_codec with RQ/RC/CQ/CC encode/decode"
```

---

## Task 5: tuser Codec

**Files:**
- Create: `src/codec/xilinx_tuser_codec.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_tuser_codec.sv**

Instance-based (needs DATA_WIDTH). Implements per spec Section 4:

**Parity:**
- `calc_byte_parity(bit[7:0])` — XOR all bits (odd parity)
- `calc_parity(bit[511:0] tdata)` — per-byte parity vector

**RQ tuser (encode/decode):**
- Fields: first_be[3:0], last_be[3:0], addr_offset[2:0], discontinue, tph_present, tph_type[1:0], tph_st_tag[7:0], seq_num_0[5:0], seq_num_1[5:0], parity, tag_9_8[1:0]
- Layout varies by DATA_WIDTH (62/62/137/285 bits)

**RC tuser (encode/decode):**
- Fields: byte_en, is_sof_0, is_sof_1, is_eof_0, eof_offset_0[2:0], is_eof_1, eof_offset_1[2:0], discontinue, parity
- Layout varies by DATA_WIDTH (75/75/161/321 bits)

**CQ tuser (encode/decode):**
- Fields: first_be, last_be, byte_en, sop, sop_1, discontinue, tph_present, tph_type, tph_st_tag, parity_en, parity, is_eop, eop_offset, is_eop_1, eop_offset_1, tag_9_8
- Layout varies by DATA_WIDTH (88/88/183/375 bits)

**CC tuser (encode/decode):**
- Fields: discontinue, parity
- Layout varies by DATA_WIDTH (33/33/81/161 bits)

Each encode function takes field values + tdata (for parity calculation), returns packed tuser vector. Each decode extracts fields from packed tuser. Width-dependent layout handled via `if (DATA_WIDTH <= 128) / else if (DATA_WIDTH == 256) / else` branches.

- [ ] **Step 2: Add include, commit**

```bash
git add src/codec/xilinx_tuser_codec.sv src/xilinx_pcie_pkg.sv
git commit -m "feat: add xilinx_tuser_codec with per-channel per-width encode/decode"
```

---

## Task 6: Straddle Engine and Channel Router

**Files:**
- Create: `src/codec/xilinx_straddle_engine.sv`
- Create: `src/agent/xilinx_pcie_channel_router.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_straddle_engine.sv**

Fields: `straddle_enable`, `DATA_WIDTH`.

**pack_single_tlp():**
- Input: descriptor bits, payload bytes, channel
- Output: beat queue (tdata), keep queue (per-DW), last queue
- Logic: places descriptor in beat 0. For 128-bit desc (RQ/CQ), payload starts at beat 1. For 96-bit desc (RC/CC), payload starts at beat 0 DW3. Fills remaining DWs in each beat, sets tkeep per active DW, sets tlast on final beat.

**unpack_single_tlp():**
- Input: beat/keep queues, channel
- Output: descriptor bits, payload bytes
- Logic: extracts descriptor DWs from beat 0, collects payload from remaining DWs (accounting for 96-bit vs 128-bit desc offset).

Straddling mode (multi-TLP pack/unpack using sop/eop from tuser) is stubbed with TODO for future iteration.

- [ ] **Step 2: Create xilinx_pcie_channel_router.sv**

Field: `role` (xilinx_pcie_role_e).

**get_tx_channel(pcie_tl_tlp):**
- RC: completion->XILINX_CH_RC, request->XILINX_CH_CQ
- EP: completion->XILINX_CH_CC, request->XILINX_CH_RQ

**get_rx_channel(pcie_tl_tlp):**
- RC: completion->XILINX_CH_CC, request->XILINX_CH_RQ
- EP: completion->XILINX_CH_RC, request->XILINX_CH_CQ

Uses `tlp.get_category()` to distinguish Posted/Non-Posted (both are requests) from Completion.

- [ ] **Step 3: Add includes, commit**

```bash
git add src/codec/xilinx_straddle_engine.sv src/agent/xilinx_pcie_channel_router.sv src/xilinx_pcie_pkg.sv
git commit -m "feat: add straddle engine and channel router"
```

---

## Task 7: Driver and Monitor

**Files:**
- Create: `src/agent/xilinx_pcie_driver.sv`
- Create: `src/agent/xilinx_pcie_monitor.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_pcie_driver.sv**

`class xilinx_pcie_driver extends uvm_driver #(pcie_tl_tlp)`

References (set by parent agent): desc_codec, tuser_codec, straddle_eng, router, tag_mgr, fc_mgr, ord_eng, and per-channel axis_agent sequencer handles.

**run_phase pipeline (11 steps per spec Section 6.5):**
1. `seq_item_port.get_next_item(tlp)`
2. Tag alloc: `if (tlp.requires_completion() && tag_mgr != null) tlp.tag = tag_mgr.alloc_tag(0)`
3. FC check: `if (fc_mgr != null && fc_mgr.fc_enable) wait(fc_mgr.check_credit(tlp))`
4. Ordering: `if (ord_eng != null) ord_eng.enqueue(tlp)`
5. Channel: `channel = router.get_tx_channel(tlp)`
6. Encode descriptor: switch on channel, call `xilinx_desc_codec.encode_{rq,rc,cq,cc}()`
7. Pack beats: `straddle_eng.pack_single_tlp(desc, tlp.payload, channel, beats, keeps, lasts)`
8. Encode tuser per beat: call `tuser_codec.encode_{rq,rc,cq,cc}_tuser()` with appropriate fields
9. Create `axis_transfer` items from beats, set tdata/tkeep/tlast/tuser, send via correct axis_agent sequencer using `axis_single_transfer_seq`
10. Consume FC: `if (fc_mgr != null) fc_mgr.consume_credit(tlp)`
11. Publish: `tlp_tx_ap.write(tlp)` and `item_done()`

- [ ] **Step 2: Create xilinx_pcie_monitor.sv**

`class xilinx_pcie_monitor extends uvm_component`

Uses `uvm_analysis_imp` with suffix macros for 4 channels. Subscribes to each axis_agent's `mon.packet_ap`.

**write_rq/rc/cq/cc(axis_packet pkt):**
1. Collect beat data from `pkt.beats[$]` into tdata/tkeep/tuser arrays
2. Call `straddle_eng.unpack_single_tlp()` to get descriptor + payload
3. Decode tuser to get tag[9:8] and other sideband info
4. Call `xilinx_desc_codec.decode_{rq,rc,cq,cc}()` to create `pcie_tl_tlp`
5. Merge tag[9:8] into `tlp.tag`
6. Publish to `tlp_rx_ap.write(tlp)`

Output: `uvm_analysis_port #(pcie_tl_tlp) tlp_rx_ap`

- [ ] **Step 3: Add includes, commit**

```bash
git add src/agent/xilinx_pcie_driver.sv src/agent/xilinx_pcie_monitor.sv src/xilinx_pcie_pkg.sv
git commit -m "feat: add driver (11-step pipeline) and monitor (4-channel decode)"
```

---

## Task 8: Agent Classes

**Files:**
- Create: `src/agent/xilinx_pcie_base_agent.sv`
- Create: `src/agent/xilinx_pcie_rc_agent.sv`
- Create: `src/agent/xilinx_pcie_ep_agent.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_pcie_base_agent.sv**

`class xilinx_pcie_base_agent extends uvm_agent`

**Members:** driver, monitor, sequencer, desc_codec, tuser_codec, straddle_eng, router, rq/rc/cq/cc_agent (axis_agent), cfg_agent, int_agent, tag_mgr, fc_mgr, ord_eng, cfg_space, tlp_tx_ap, tlp_rx_ap.

**build_phase:**
1. Get `xilinx_pcie_env_config cfg` from config_db
2. Create codec instances: `tuser_codec = new(cfg.DATA_WIDTH)`, `straddle_eng = new(cfg.straddle_enable, cfg.DATA_WIDTH)`, `router = new(cfg.role)`
3. For each channel (RQ/RC/CQ/CC):
   - `axis_config acfg = cfg.create_axis_config(ch)`
   - `uvm_config_db#(axis_config)::set(this, $sformatf("%s_agent*", ch_name), "cfg", acfg)`
   - Create `axis_agent` instance
4. Create sequencer, driver, monitor if `is_active == UVM_ACTIVE`
5. Create cfg_agent if `cfg.cfg_enable`
6. Create int_agent if `cfg.interrupt_enable`

**connect_phase:**
- Connect driver.seq_item_port to sequencer
- Connect axis_agent monitors to xilinx_pcie_monitor imports
- Wire shared service references into driver
- Connect analysis ports

- [ ] **Step 2: Create xilinx_pcie_rc_agent.sv**

`class xilinx_pcie_rc_agent extends xilinx_pcie_base_agent`

Adds:
- Completion timeout tracking: `outstanding_req[bit[9:0]]` map, timeout check task
- BAR address allocation: `allocate_bar_address(int size)` returns next available address
- Interrupt receive: subscribes to int_agent's analysis port

- [ ] **Step 3: Create xilinx_pcie_ep_agent.sv**

`class xilinx_pcie_ep_agent extends xilinx_pcie_base_agent`

Adds:
- Auto-response: subscribes to monitor `tlp_rx_ap`, on CQ request generates CC completion
- Memory model: `bit[7:0] mem_space[bit[63:0]]` associative array
- DMA initiation: `initiate_dma()` task creates TLP and sends via RQ
- MSI/MSI-X: `send_msi()` task uses int_agent
- Completion splitting: honors MPS/RCB boundaries for MRd responses

**Auto-response flow (per spec Section 6.7):**
```
write_tlp_rx(pcie_tl_tlp req):
  case (req.kind)
    TLP_MEM_WR: store payload to mem_space[req.addr]
    TLP_MEM_RD: read from mem_space, generate CplD, send via CC
    TLP_IO_WR:  store, generate Cpl
    TLP_IO_RD:  read, generate CplD
    TLP_CFG_WR0: write cfg_space_manager, generate Cpl
    TLP_CFG_RD0: read cfg_space_manager, generate CplD
```

- [ ] **Step 4: Add includes, commit**

```bash
git add src/agent/xilinx_pcie_{base,rc,ep}_agent.sv src/xilinx_pcie_pkg.sv
git commit -m "feat: add base/RC/EP agent classes with axis_agent composition"
```

---

## Task 9: cfg and Interrupt Agents

**Files:**
- Create: `src/cfg/xilinx_pcie_cfg_agent.sv`
- Create: `src/cfg/xilinx_pcie_interrupt_agent.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_pcie_cfg_agent.sv**

Contains inner driver and monitor classes.

**EP role (user side):**
- Driver: accepts cfg read/write sequence items, drives `cfg_vif.user_cb.cfg_mgmt_{addr,byte_enable,read,write,write_data}`, waits for `cfg_mgmt_read_write_done`, returns `cfg_mgmt_read_data`

**RC role (PCIe IP side):**
- Monitor: watches `cfg_vif.pcie_ip_cb.cfg_mgmt_{read,write}` for assertions
- Driver: on read request, calls `cfg_space.read(addr)`, drives `cfg_mgmt_read_data` and pulses `cfg_mgmt_read_write_done`; on write, calls `cfg_space.write(addr, data, be)`, pulses done

**Timing per PG213:** read/write + done handshake, one operation at a time.

- [ ] **Step 2: Create xilinx_pcie_interrupt_agent.sv**

**EP role (sends interrupts):**
- Legacy: assert `cfg_interrupt_int[vector]`, wait `cfg_interrupt_sent`
- MSI: check `cfg_interrupt_msi_enable`, assert `cfg_interrupt_msi_int[vector]`, wait `sent` or `fail`
- MSI-X: check `msix_enable && !msix_mask`, set `msix_address`/`msix_data`, assert `msix_int`

**RC role (receives interrupts):**
- Drives `cfg_interrupt_msi_enable`, `cfg_interrupt_msix_enable`
- Monitors interrupt assertions, publishes `xilinx_interrupt_item`

- [ ] **Step 3: Add includes, commit**

```bash
git add src/cfg/ src/xilinx_pcie_pkg.sv
git commit -m "feat: add cfg_agent and interrupt_agent"
```

---

## Task 10: Environment, Virtual Sequencer, Scoreboard, Coverage

**Files:**
- Create: `src/env/xilinx_pcie_virtual_sequencer.sv`
- Create: `src/env/xilinx_pcie_scoreboard.sv`
- Create: `src/env/xilinx_pcie_coverage.sv`
- Create: `src/env/xilinx_pcie_env.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create xilinx_pcie_virtual_sequencer.sv**

Holds: `uvm_sequencer #(pcie_tl_tlp) rc_sqr, ep_sqr` + shared service refs (fc_mgr, tag_mgr, ord_eng).

- [ ] **Step 2: Create xilinx_pcie_scoreboard.sv**

4 analysis imports: rc_tx, rc_rx, ep_tx, ep_rx.

**Check 1 — Completion match (scb_completion_check):**
Outstanding map `{tag, req_id} -> {tlp, expected_bytes, received_bytes, time}`. On request TX: register. On completion RX: match by tag, accumulate bytes, free when complete. report_phase: error on unmatched.

**Check 2 — Data integrity (scb_data_integrity):**
Compare MWr payload vs EP memory; MRd CplD vs memory. Byte-accurate with BE masking.

**Check 3 — Ordering (scb_ordering_check):**
Record TX/RX timestamps per category, verify PCIe Table 2-40 rules via `pcie_tl_ordering_engine.check_ordering()`.

**Check 4 — Descriptor round-trip (scb_descriptor_check):**
On TX: record original TLP + encoded descriptor. On RX: decode descriptor, compare all fields with original.

Stats: total_requests, total_completions, matched, mismatched, unexpected_cpl, timed_out, ordering_violations, desc_format_errors.

- [ ] **Step 3: Create xilinx_pcie_coverage.sv**

6 covergroups per spec Section 11, each behind its `cov_*` enable switch:
- `cg_tlp_type`: kind, category, channel, kind x channel cross
- `cg_descriptor`: req_type, addr_type, dw_count bins, first/last_be, BE cross, cpl_status, tag range, poisoned
- `cg_tuser`: tph_present, tph_type, discontinue, parity_en, addr_offset
- `cg_straddle`: straddle_occurred, sop/eof combo, eof_offset, width cross
- `cg_channel`: per-channel {tvalid, tready} state, simultaneous activity cross
- `cg_fc`: per-category credit level bins (empty/low/normal/high), stall events

- [ ] **Step 4: Create xilinx_pcie_env.sv**

**build_phase:**
1. Get/create `xilinx_pcie_env_config` from config_db
2. `cfg.validate()` — fatal on failure
3. Create shared services: `pcie_tl_tag_manager`, `pcie_tl_fc_manager`, `pcie_tl_ordering_engine`, `pcie_tl_cfg_space_manager`
4. Init: `tag_mgr.init_pool(0, cfg.extended_tag_enable)`, `fc_mgr.init_credits(cfg.init_ph_credit, ...)`, `cfg_space.init_type0_header(cfg.vendor_id, cfg.device_id, ...)`
5. Create RC agent (set config_db for it)
6. Create EP agent (set config_db for it)
7. Create virtual_sequencer, scoreboard, coverage

**connect_phase:**
- Wire RC/EP agent `tlp_tx_ap`/`tlp_rx_ap` to scoreboard imports
- Wire to coverage subscriber
- Set virtual_sequencer's sqr references

- [ ] **Step 5: Add includes in dependency order, commit**

```bash
git add src/env/ src/xilinx_pcie_pkg.sv
git commit -m "feat: add env, virtual sequencer, scoreboard, and coverage"
```

---

## Task 11: Sequence Library

**Files:**
- Create: `src/seq/xilinx_pcie_base_seq.sv`
- Create: `src/seq/xilinx_pcie_mem_seq.sv`
- Create: `src/seq/xilinx_pcie_cfg_seq.sv`
- Create: `src/seq/xilinx_pcie_dma_seq.sv`
- Create: `src/seq/xilinx_pcie_msi_seq.sv`
- Create: `src/seq/xilinx_pcie_loopback_vseq.sv`
- Modify: `src/xilinx_pcie_pkg.sv`

- [ ] **Step 1: Create base_seq**

Gets `xilinx_pcie_env_config` from sequencer in `pre_body()`.

- [ ] **Step 2: Create mem_seq**

Rand fields: addr[63:0], length (bytes), is_write, payload[], tc, attr. Constraints: length in [1:4096], no 4KB crossing, MWr<=MPS, MRd<=MRRS. Body creates `pcie_tl_tlp`, computes first_be/last_be from addr alignment and length, sends via `uvm_send`.

- [ ] **Step 3: Create cfg_seq**

Rand fields: reg_addr[11:0], is_write, is_type1, write_data[31:0], first_be[3:0], target_bdf[15:0]. Body creates CfgRd0/CfgWr0/CfgRd1/CfgWr1 TLP.

- [ ] **Step 4: Create dma_seq**

Rand fields: host_addr[63:0], total_length (can exceed MPS), is_write, src_data[]. Auto-splits into multiple TLPs respecting MPS/MRRS/4KB boundaries via `calc_chunk_size()` helper. Loops sending TLPs until total_length consumed.

- [ ] **Step 5: Create msi_seq**

Rand fields: mode (LEGACY/MSI/MSIX), vector_num, msix_addr, msix_data. Creates `xilinx_interrupt_item` and sends to interrupt_agent sequencer.

- [ ] **Step 6: Create loopback_vseq**

5-phase virtual sequence using virtual_sequencer:
1. Config enumeration: RC sends CfgRd0 via CQ, EP auto-responds via CC
2. Memory Write+Read: RC sends MWr then MRd, EP stores and responds
3. DMA: EP sends DMA MWr/MRd via RQ, RC responds via RC channel
4. Interrupt: EP sends MSI, RC receives
5. Straddle stress (if enabled): rapid small TLPs to trigger straddling

- [ ] **Step 7: Add includes, commit**

```bash
git add src/seq/ src/xilinx_pcie_pkg.sv
git commit -m "feat: add sequence library with mem/cfg/dma/msi/loopback"
```

---

## Task 12: Testbench and Tests

**Files:**
- Create: `tb/xilinx_pcie_loopback_dut.sv`
- Create: `tb/tb_top.sv`
- Create: `tb/tb_with_dut.sv`
- Create: `tests/xilinx_pcie_base_test.sv`
- Create: `tests/xilinx_pcie_sanity_test.sv`
- Create: `tests/xilinx_pcie_straddle_test.sv`
- Create: `tests/xilinx_pcie_loopback_test.sv`

- [ ] **Step 1: Create xilinx_pcie_loopback_dut.sv**

Module with two `xilinx_pcie_if` ports (rc_if, ep_if). Wire cross-connections:
```
RC CQ out -> EP CQ in    (request path)
EP CC out -> RC CC in    (completion path)
EP RQ out -> RC RQ in    (DMA request)
RC RC out -> EP RC in    (DMA completion)
```
Each: assign tdata/tkeep/tlast/tvalid/tuser forward, tready backward.

- [ ] **Step 2: Create tb_top.sv**

250MHz clock (4ns period), 10-cycle active-low reset. Instantiate 2x xilinx_pcie_if, 2x xilinx_pcie_cfg_if, loopback_dut. Register all vifs in config_db. Call `run_test()`. Optional FSDB dump on `+DUMP_WAVES`.

- [ ] **Step 3: Create tb_with_dut.sv**

Template showing port mapping for a real NIC DUT: `m_axis_rq_*` -> `bfm_if.rq_*`, `s_axis_rc_*` -> `bfm_if.rc_*`, etc.

- [ ] **Step 4: Create test classes**

**base_test:** Creates env_config, parses plusargs (+DATA_WIDTH, +STRADDLE_EN, +ROLE, +MPS, +CFG_EN, +INT_EN, +INT_MODE), registers in config_db, creates env.

**sanity_test:** 20-tx loopback_vseq, all scb checks on.

**straddle_test:** straddle_enable=1, DATA_WIDTH=256, 200 txns, small payloads (max 16 bytes), VALID_ZERO_IDLE + READY_ALWAYS, cov_straddle on.

**loopback_test:** 500 txns, all coverage on, per-channel mixed backpressure (RQ: READY_WEIGHTED/70, RC: READY_TOGGLE/8/4, CQ: READY_WEIGHTED/80, CC: READY_ALWAYS).

- [ ] **Step 5: Commit**

```bash
git add tb/ tests/
git commit -m "feat: add testbench, loopback DUT, and test classes"
```

---

## Task 13: Compile and First Simulation

- [ ] **Step 1: Compile**

```bash
cd /home/ubuntu/ryan/xilinx_pcie/sim && make compile 2>&1 | tail -20
```

Expected: clean compile or identifiable errors.

- [ ] **Step 2: Fix compilation errors iteratively**

Common issues: missing fields on pcie_tl_tlp (check exact field names: `addr` vs `address`, `first_be`/`last_be` vs `byte_enable`), missing analysis_imp macros, axis_config field name mismatches.

- [ ] **Step 3: Run sanity test**

```bash
make sanity 2>&1 | tail -30
```

Expected: UVM_TEST_DONE, scoreboard reports matched > 0, no UVM_ERROR.

- [ ] **Step 4: Commit fixes**

```bash
git add -A && git commit -m "fix: resolve compilation errors and pass sanity test"
```

---

## Task 14: Regression

- [ ] **Step 1: Straddle test**

```bash
make straddle DATA_WIDTH=256 2>&1 | tail -20
```

- [ ] **Step 2: Loopback test**

```bash
make loopback 2>&1 | tail -20
```

- [ ] **Step 3: 512-bit width**

```bash
make sanity DATA_WIDTH=512 2>&1 | tail -20
```

- [ ] **Step 4: 64-bit width**

```bash
make sanity DATA_WIDTH=64 2>&1 | tail -20
```

- [ ] **Step 5: Fix failures, commit**

```bash
git add -A && git commit -m "fix: pass full regression across all widths"
```

---

## Task 15: Final Package and Cleanup

- [ ] **Step 1: Verify xilinx_pcie_pkg.sv include order**

Final order must be:
```
xilinx_pcie_types.sv
xilinx_pcie_env_config.sv
xilinx_desc_codec.sv
xilinx_tuser_codec.sv
xilinx_straddle_engine.sv
xilinx_pcie_channel_router.sv
xilinx_pcie_driver.sv
xilinx_pcie_monitor.sv
xilinx_pcie_base_agent.sv
xilinx_pcie_rc_agent.sv
xilinx_pcie_ep_agent.sv
xilinx_pcie_cfg_agent.sv
xilinx_pcie_interrupt_agent.sv
xilinx_pcie_virtual_sequencer.sv
xilinx_pcie_scoreboard.sv
xilinx_pcie_coverage.sv
xilinx_pcie_env.sv
xilinx_pcie_base_seq.sv
xilinx_pcie_mem_seq.sv
xilinx_pcie_cfg_seq.sv
xilinx_pcie_dma_seq.sv
xilinx_pcie_msi_seq.sv
xilinx_pcie_loopback_vseq.sv
```

- [ ] **Step 2: Final commit**

```bash
git add -A && git commit -m "feat: complete Xilinx PCIe TL-Layer BFM v1.0"
```
