/* cosim-platform/vcs-tb/cosim_xrc_driver.sv
 *
 * Multi-RC cosim adapter driver for the Xilinx PG213 AXIS datapath.
 *
 * One instance lives inside each pcie_tl env rc_agent_<N>. It bridges a
 * per-RC QEMU host (over a cosim transport, DPI _rc(rc_index)) to a real
 * xilinx-pcie EP DUT reached through this RC's xilinx_pcie_if_adapter:
 *
 *   QEMU MMIO/Cfg  --poll_tlp_scalar_rc--> build TLP --send_tlp--> adapter
 *                    --> CQ channel --> DUT
 *   DUT CplD       --> CC channel --> adapter.rx_queue --adapter.receive-->
 *                    handle + send_cpl_scalar_rc --> QEMU
 *
 * Scope: MMIO (BAR read/write) + config-space bypass. DUT-initiated DMA
 * (RQ inbound) + MSI are logged as TODO here — that's the next increment.
 *
 * Isolation: this is the multi-RC cosim adapter driver. rc_index defaults
 * to 0; the C _rc(0) path is byte-equivalent to the legacy single-RC DPI.
 */

`ifndef COSIM_XRC_DRIVER_SV
`define COSIM_XRC_DRIVER_SV

class cosim_xrc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(cosim_xrc_driver)

    // DPI-C TLP type constants (kept in sync with bridge_vcs.sv)
    localparam byte unsigned BV_TLP_MWR    = 8'd0;
    localparam byte unsigned BV_TLP_MRD    = 8'd1;
    localparam byte unsigned BV_TLP_CFGWR0 = 8'd2;
    localparam byte unsigned BV_TLP_CFGRD0 = 8'd3;
    localparam byte unsigned BV_TLP_CPL    = 8'd4;
    localparam byte unsigned BV_TLP_ATS_INVAL = 8'd17;  // RC->device ATS Invalidation

    // ---- Which RC this driver serves (its slot in the C-side g_rc[]) ----
    int rc_index = 0;

    // ---- +REAL_DUT: attach a real RTL DUT instead of the stand-in EP model ----
    // When set: config is answered by the DUT (config_proxy bypass off), VF-BAR
    // MMIO flows through to the DUT (no ep_vf_mmio_write intercept), the doorbell
    // synthesis / stand-in ATC are dead, and ATS Invalidation returns the DUT's
    // real Completion (no synthesized one). The RC-bridge half is unchanged.
    bit real_dut = 0;

    // ---- Config-space bypass proxy (answers enumeration in SV) ----
    pcie_tl_config_proxy config_proxy;

    // ---- 统一 config space: func_mgr(num_pfs=1 即单func, 多func/SR-IOV 同一套)----
    pcie_tl_func_manager func_mgr;

    // ---- EP data-plane model (stand-in DUT) ------------------------------
    // A minimal behavioral EP that exercises the VF DMA/MSI-X data plane. The
    // guest programs a per-VF doorbell in the VF BAR0 register file; a write to
    // the CTRL doorbell makes the EP initiate DMA (to/from guest memory) and/or
    // an MSI-X (memory-write to the APIC), all sourced by that VF. Replaceable
    // by a real DUT later — the RC/bridge path is unchanged.
    //   BAR0 offset map (32-bit regs):
    //     0x00 DMA_ADDR_LO   0x04 DMA_ADDR_HI   0x08 DMA_PATTERN
    //     0x0C CTRL: bit0=DMA-write pattern, bit1=DMA-read, bit2=MSI-X
    bit [63:0] ep_dma_addr    [bit [15:0]];   // per-VF DMA target guest addr
    bit [31:0] ep_dma_pattern [bit [15:0]];   // per-VF DMA-write pattern
    // ATS device-side ATC (Address Translation Cache): per-VF cached translation
    // {iova -> translated PA}. Filled on ATS grant, used on ATC hit (no re-
    // translate), flushed by an RC ATS-Invalidation. exists(vf_bdf) = valid.
    bit [63:0] ep_atc_iova [bit [15:0]];
    bit [63:0] ep_atc_pa   [bit [15:0]];
    // Current PASID per VF (0 = none), set by the guest via a BAR0 doorbell reg
    // (0x14). A PASID-tagged ATS translation carries this + requires PASID enable.
    bit [15:0] ep_pasid    [bit [15:0]];
    // Pending ATS Invalidations awaiting the DUT's Invalidation Completion.
    // Keyed by the Invalidate Message tag; value = the QEMU tag to ACK once the
    // DUT completion returns (bridged by rx_loop). Real DUT closes this loop by
    // returning an Invalidation Completion; the stand-in synthesizes one.
    int        pend_inval_qtag [bit [9:0]];
    bit [15:0] pend_inval_bdf  [bit [9:0]];
    localparam bit [63:0] EP_MSIX_APIC_ADDR = 64'h0000_0000_FEE0_0000;

    // Per-VF MSI-X table entry 0 (captured from guest writes to VF BAR0+0x1000).
    // The guest driver / VFIO programs msg addr/data + vector control; the EP
    // fires the captured addr/data on a MSI-X doorbell so the interrupt lands on
    // the guest-chosen vector route (vs the old hard-coded APIC poke).
    localparam bit [63:0] EP_MSIX_TABLE_OFF = 64'h1000;  // matches cfg cap Table Offset
    localparam int        EP_MSIX_NVEC      = 8;         // matches cfg cap table_size
    // Per-(VF,vector) MSI-X table entries. Key = {vf_bdf[15:0], vector[2:0]}.
    bit [63:0] ep_msix_addr [bit [18:0]];     // msg addr (hi<<32|lo)
    bit [31:0] ep_msix_data [bit [18:0]];     // msg data
    bit        ep_msix_mask [bit [18:0]];     // vector control bit0 (1=masked)
    bit [2:0]  ep_msix_sel  [bit [15:0]];     // per-VF selected vector for doorbell

    // ---- Tag mapping: QEMU 8-bit tag <-> VIP tag ----
    bit [9:0] vip_tag_to_qemu_tag[int];        // 10-bit QEMU tag (extended tag)
    int       qemu_tag_to_vip_tag[bit [9:0]];

    // ---- DPI scratch (class members = static storage; VCS Q-2020 safe) ----
    byte unsigned    dpi_type;
    longint unsigned dpi_addr;
    int unsigned     dpi_data[16];
    int              dpi_len;
    int              dpi_tag;

    // ---- Coordination ----
    bit   bridge_ready = 0;
    event shutdown_event;
    int   polling_interval_ns = 10;

    // ---- 两阶段切换控制(cosim 替换 VIP 的运行时开关)----
    //   阶段1: VIP 主导(super.run_phase 驱动真实 DUT)。
    //   UCLI 敲 start_cosim -> notify_start -> drain -> 阶段2 连 QEMU, QEMU 主导。
    static cosim_xrc_driver s_registry[$];   // 全实例表, 供 UCLI 入口广播触发
    bit   cosim_active = 0;                  // 0=VIP阶段, 1=QEMU主导(rx_loop 分流依据)
    event start_cosim_ev;                    // UCLI notify_start 触发切换

    // rx_loop 的 completion 来源: 订阅本 agent monitor 的 tlp_ap(CC/RX: DUT->RC),
    // 不与 monitor 争抢同一 adapter rx_queue(否则 monitor 抢走 cpl 不释放 tag -> 超时)。
    uvm_tlm_analysis_fifo #(pcie_tl_tlp) m_rx_fifo;

    // ---- Stats ----
    int unsigned total_tlp_count;
    int unsigned total_cpl_count;
    int unsigned unknown_type_count;
    int unsigned inbound_req_count;   // DUT-initiated (DMA) — TODO next increment

    function new(string name = "cosim_xrc_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // -----------------------------------------------------------------------
    // build_phase: resolve rc_index, create the config proxy.
    //   rc_index source (in priority order):
    //     1. uvm_config_db#(int) "rc_index" set by the test on this agent path
    //     2. parsed from the hierarchical name (".rc_agent_<N>.")
    //     3. default 0
    // -----------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(int)::get(this, "", "rc_index", rc_index))
            rc_index = parse_rc_index_from_name(get_full_name());

        config_proxy = pcie_tl_config_proxy::type_id::create("config_proxy", this);
        s_registry.push_back(this);   // 注册实例, 供 UCLI notify_start 广播
        m_rx_fifo = new("m_rx_fifo", this);

        // 统一 config space: 建 func_mgr(num_pfs=1 即单func), 走 _bdf 应答 QEMU 枚举。
        // plusarg 可配: +NUM_PFS +MAX_VFS +NUM_VFS +VENDOR_ID +DEVICE_ID +VF_DEVICE_ID
        begin
            int n_pfs, max_vfs, n_vfs, ven, dev, vfdev, topo;
            if (!$value$plusargs("NUM_PFS=%d", n_pfs))      n_pfs   = 1;
            if (!$value$plusargs("MAX_VFS=%d", max_vfs))    max_vfs = 0;
            if (!$value$plusargs("NUM_VFS=%d", n_vfs))      n_vfs   = 0;
            if (!$value$plusargs("TOPO=%d", topo))          topo    = 0;  // 0=ep_direct 1=switch 2=multi_layer
            if (!$value$plusargs("VENDOR_ID=%h", ven))      ven     = 32'h1AF4;
            if (!$value$plusargs("DEVICE_ID=%h", dev))      dev     = 32'h1041;
            if (!$value$plusargs("VF_DEVICE_ID=%h", vfdev)) vfdev   = 32'h1041;
            real_dut = $test$plusargs("REAL_DUT");
            func_mgr = pcie_tl_func_manager::type_id::create("func_mgr");
            func_mgr.build_topology(topo, n_pfs, max_vfs, ven[15:0], dev[15:0], vfdev[15:0]);
            config_proxy.func_mgr            = func_mgr;
            config_proxy.multi_function_mode = 1;
            // Real DUT owns its config space -> don't let the SV stand-in answer.
            config_proxy.bypass_enable       = real_dut ? 1'b0 : 1'b1;
            // Pre-enable VFs only for the stand-in; a real DUT drives SR-IOV itself.
            if (!real_dut && n_vfs > 0)
                for (int pf = 0; pf < n_pfs; pf++)
                    func_mgr.enable_vfs(pf, n_vfs);
            `uvm_info(get_name(), $sformatf("RC%0d mode: %s", rc_index,
                real_dut ? "REAL_DUT (config+MMIO->DUT, stand-in EP off)"
                         : "stand-in EP (config-bypass, synthesized DUT)"), UVM_LOW)
        end

        `uvm_info(get_name(), $sformatf("cosim_xrc_driver bound to RC index %0d", rc_index),
                  UVM_LOW)
    endfunction

    // -----------------------------------------------------------------------
    // connect_phase: 把本 agent monitor 的 tlp_ap(CC/RX: DUT->RC 的 TLP)接到
    //   m_rx_fifo。rx_loop 从 fifo 取, 让 monitor 当 adapter rx_queue 唯一消费者,
    //   消除 monitor/driver 争抢导致的 completion 丢失(tag 不释放 -> 超时)。
    // -----------------------------------------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        pcie_tl_base_agent ag;
        super.connect_phase(phase);
        if ($cast(ag, get_parent()) && ag.monitor != null)
            ag.monitor.tlp_ap.connect(m_rx_fifo.analysis_export);
        else
            `uvm_fatal(get_name(),
                "cosim_xrc_driver: 无法连接 monitor.tlp_ap(parent 非 pcie_tl_base_agent 或 monitor 为空)")
    endfunction

    // Parse "...rc_agent_<N>..." -> N ; returns 0 if not found.
    protected function int parse_rc_index_from_name(string full);
        int idx = 0;
        byte c;
        int  pos;
        string key = "rc_agent_";
        for (int i = 0; i + key.len() < full.len(); i++) begin
            if (full.substr(i, i + key.len() - 1) == key) begin
                pos = i + key.len();
                idx = 0;
                while (pos < full.len()) begin
                    c = full[pos];
                    if (c >= "0" && c <= "9") begin
                        idx = idx * 10 + (c - "0");
                        pos++;
                    end else break;
                end
                return idx;
            end
        end
        return 0;
    endfunction

    // -----------------------------------------------------------------------
    // UCLI 触发入口(供 aip_cmd 命令壳调用)。rc<0 = 全部 RC; 否则只切指定 RC。
    // 广播 start_cosim_ev, 各 driver run_phase 从阶段1(VIP)切阶段2(QEMU)。
    // 与 aip 解耦: aip 命令壳只需 new + cmd_exec 调本函数, driver 侧零 aip 依赖。
    // -----------------------------------------------------------------------
    static function void notify_start(int rc = -1);
        foreach (s_registry[i])
            if (rc < 0 || s_registry[i].rc_index == rc)
                -> s_registry[i].start_cosim_ev;
    endfunction

    // -----------------------------------------------------------------------
    // 自初始化开关。默认 1:driver 自己连 QEMU(读 +REMOTE_HOST/+PORT_BASE),
    // 无需外部 test 调 init —— 这样集成进现有环境只要一行工厂 override。
    // 若某 test 想自己管 init,先设 bridge_ready=1 即跳过。
    // -----------------------------------------------------------------------
    bit self_init_bridge_en = 1;

    // -----------------------------------------------------------------------
    // run_phase: 两阶段 ——
    //   阶段1  VIP 主导: super.run_phase 的 get_next_item/send_tlp 驱动真实 DUT。
    //   触发   UCLI 敲 start_cosim -> notify_start -> start_cosim_ev。
    //   drain  停发 VIP + 等 in-flight completion 收干净(rx_loop 走 VIP 路径)。
    //   阶段2  连 QEMU, cosim_active=1, request_loop 由 QEMU 主导发包。
    // rx_loop 全程运行, 按 cosim_active 分流 DUT 回来的 completion。
    // -----------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        // 全程 hold objection: 交互式 cosim 期望"不敲 start_cosim 就一直跑等你",
        // 结束由 UCLI finish 或 request_loop shutdown 决定。
        phase.raise_objection(this, "cosim_xrc_driver holding run");
        `uvm_info(get_name(), $sformatf("run_phase started (RC%0d)", rc_index), UVM_MEDIUM)

        // rx_loop 全程跑: 阶段1 收 DUT cpl 回 VIP, 阶段2 回 QEMU
        fork
            rx_loop(phase);
        join_none

        // ---- 阶段1: VIP 主导, 等 UCLI 触发 ----
        // +COSIM_AUTOSTART: 批量运行(无 UCLI)跳过阶段1, 直接连 QEMU。
        if (!bridge_ready && !$test$plusargs("COSIM_AUTOSTART")) begin
            fork : vip_stage
                super.run_phase(phase);   // 基类 forever get_next_item/send_tlp/item_done
            join_none

            @start_cosim_ev;              // UCLI notify_start 触发
            `uvm_info(get_name(), $sformatf("RC%0d start_cosim: stop VIP, draining", rc_index),
                      UVM_LOW)
            disable vip_stage;                    // 停止 VIP 发新包
            wait (get_pending_count() == 0);      // drain: rx_loop 收干净 in-flight cpl
            `uvm_info(get_name(), $sformatf("RC%0d drained, switch to QEMU", rc_index),
                      UVM_LOW)
        end

        // ---- 阶段2: 连 QEMU + QEMU 主导 ----
        if (self_init_bridge_en && !bridge_ready)
            self_init_bridge();
        cosim_active = 1;                 // rx_loop 切到 forward_to_qemu
        request_loop(phase);              // QEMU poll → DUT, 阻塞直到 shutdown

        bridge_vcs_cleanup_ex_rc(rc_index);
        phase.drop_objection(this, "cosim_xrc_driver done");
    endtask

    // 连本 RC 对应的 QEMU(client)。host/port 从 plusarg,instance_id=rc_index。
    protected task self_init_bridge();
        string remote_host;
        int    port_base;
        if (!$value$plusargs("REMOTE_HOST=%s", remote_host)) remote_host = "10.11.10.53";
        if (!$value$plusargs("PORT_BASE=%d", port_base))     port_base   = 9100;
        if (bridge_vcs_init_ex_rc(rc_index, "tcp", "", "", remote_host, port_base, rc_index) != 0)
            `uvm_fatal(get_name(), $sformatf(
                "RC%0d bridge_vcs_init_ex_rc(tcp %s:%0d inst=%0d) failed",
                rc_index, remote_host, port_base, rc_index))
        `uvm_info(get_name(), $sformatf(
            "RC%0d bridge up: tcp %s:%0d inst=%0d", rc_index, remote_host, port_base, rc_index),
            UVM_LOW)
        bridge_ready = 1;
    endtask

    // -----------------------------------------------------------------------
    // request_loop: poll this RC's QEMU, forward MMIO to the DUT (via adapter
    // -> CQ), answer config-space reads/writes locally via the proxy.
    // -----------------------------------------------------------------------
    // EP model: handle a VF BAR0 register write (doorbell protocol). A CTRL
    // write drives DMA and/or MSI-X sourced by this VF, through the same cosim
    // bridge the guest reached over MMIO.
    task ep_vf_mmio_write(int rc, bit [15:0] vf_bdf, bit [63:0] addr, bit [31:0] val);
        int off = int'(addr & 64'hFFFF);   // offset within the 64KB VF BAR
        int unsigned dbuf[16];
        int unsigned aops[4];
        int unsigned aold[2];
        int rr;
        longint unsigned tpa;   // ATS translated PA (out of ats_translate_rc)
        // MSI-X table region (BAR0 + 0x1000 .. +NVEC*16): capture each vector's
        // msg addr/data/mask as the guest/VFIO programs it. Key = {vf_bdf,vec}.
        if (off >= int'(EP_MSIX_TABLE_OFF) &&
            off <  int'(EP_MSIX_TABLE_OFF) + EP_MSIX_NVEC*16) begin
            int vec = (off - int'(EP_MSIX_TABLE_OFF)) / 16;
            int fld = (off - int'(EP_MSIX_TABLE_OFF)) % 16;
            bit [18:0] k = {vf_bdf, vec[2:0]};
            case (fld)
                0:  ep_msix_addr[k][31:0]  = val;
                4:  ep_msix_addr[k][63:32] = val;
                8:  ep_msix_data[k]        = val;
                12: begin
                    ep_msix_mask[k] = val[0];
                    `uvm_info(get_name(), $sformatf(
                        "EP VF bdf=0x%04h MSI-X table[%0d]: addr=0x%0h data=0x%08h mask=%0d",
                        vf_bdf, vec, ep_msix_addr[k], ep_msix_data[k], val[0]), UVM_LOW)
                end
                default: ;
            endcase
            return;
        end
        case (off)
            16'h0000: ep_dma_addr[vf_bdf][31:0]  = val;
            16'h0004: ep_dma_addr[vf_bdf][63:32] = val;
            16'h0008: ep_dma_pattern[vf_bdf]     = val;
            16'h000C: begin   // CTRL doorbell
                for (int i = 0; i < 16; i++) dbuf[i] = 0;
                if (val & 32'h1) begin        // DMA-write pattern (4B) to guest RAM
                    dbuf[0] = ep_dma_pattern[vf_bdf];
                    rr = bridge_vcs_dma_write_rc_rid(rc, int'(vf_bdf), ep_dma_addr[vf_bdf], dbuf, 4);
                    `uvm_info(get_name(), $sformatf(
                        "EP VF bdf=0x%04h DMA-WRITE pattern=0x%08h -> gpa=0x%0h ret=%0d",
                        vf_bdf, ep_dma_pattern[vf_bdf], ep_dma_addr[vf_bdf], rr), UVM_LOW)
                end
                if (val & 32'h2) begin        // DMA-read 4B from guest RAM
                    rr = bridge_vcs_dma_read_rc_rid(rc, int'(vf_bdf), ep_dma_addr[vf_bdf], dbuf, 4);
                    `uvm_info(get_name(), $sformatf(
                        "EP VF bdf=0x%04h DMA-READ gpa=0x%0h -> 0x%08h ret=%0d",
                        vf_bdf, ep_dma_addr[vf_bdf], dbuf[0], rr), UVM_LOW)
                end
                if (val & 32'h4) begin        // MSI-X: fire the selected vector
                    bit [2:0]  vsel = ep_msix_sel.exists(vf_bdf) ? ep_msix_sel[vf_bdf] : 3'd0;
                    bit [18:0] k    = {vf_bdf, vsel};
                    if (ep_msix_addr.exists(k) && ep_msix_addr[k] != 0 &&
                        !ep_msix_mask[k]) begin
                        // Guest/VFIO programmed this vector — fire its exact addr/data.
                        dbuf[0] = ep_msix_data[k];
                        rr = bridge_vcs_dma_write_rc_rid(rc, int'(vf_bdf),
                                                         ep_msix_addr[k], dbuf, 4);
                        `uvm_info(get_name(), $sformatf(
                            "EP VF bdf=0x%04h MSI-X(programmed) vec=%0d -> addr=0x%0h data=0x%08h ret=%0d",
                            vf_bdf, vsel, ep_msix_addr[k], dbuf[0], rr), UVM_LOW)
                    end else begin
                        // No table programmed (or masked): legacy hard-coded APIC poke.
                        dbuf[0] = 32'h0000_0021;
                        rr = bridge_vcs_dma_write_rc_rid(rc, int'(vf_bdf), EP_MSIX_APIC_ADDR, dbuf, 4);
                        `uvm_info(get_name(), $sformatf(
                            "EP VF bdf=0x%04h MSI-X(fallback) vec=%0d -> apic=0x%0h data=0x%08h ret=%0d",
                            vf_bdf, vsel, EP_MSIX_APIC_ADDR, dbuf[0], rr), UVM_LOW)
                    end
                end
                if (val & 32'h8) begin        // AtomicOp FetchAdd += 1 on DMA target
                    for (int i = 0; i < 4; i++) aops[i] = 0;
                    aops[0] = 1;
                    rr = bridge_vcs_dma_atomic_rc(rc, ep_dma_addr[vf_bdf], 2, 4, aops, aold);
                    `uvm_info(get_name(), $sformatf(
                        "EP VF bdf=0x%04h ATOMIC FetchAdd+1 gpa=0x%0h old=0x%08h ret=%0d",
                        vf_bdf, ep_dma_addr[vf_bdf], aold[0], rr), UVM_LOW)
                end
                if (val & 32'h10) begin       // ATS: (ATC lookup ->) translate, AT=10 write
                    bit atc_hit = (ep_atc_pa.exists(vf_bdf) &&
                                   ep_atc_iova[vf_bdf] == ep_dma_addr[vf_bdf]);
                    rr = -1;
                    if (atc_hit) begin
                        // ATC HIT — reuse the cached translation, no re-translate.
                        tpa = ep_atc_pa[vf_bdf];
                        rr = 0;
                        `uvm_info(get_name(), $sformatf(
                            "EP VF bdf=0x%04h ATS ATC HIT iova=0x%0h -> pa=0x%0h (cached, no re-translate)",
                            vf_bdf, ep_dma_addr[vf_bdf], tpa), UVM_LOW)
                    end else begin
                        // ATC MISS — Translation Request to the RC.
                        tpa = 0;
                        rr = bridge_vcs_ats_translate_rc(rc, int'(vf_bdf), ep_dma_addr[vf_bdf], tpa);
                        if (rr == 0) begin
                            ep_atc_iova[vf_bdf] = ep_dma_addr[vf_bdf];
                            ep_atc_pa[vf_bdf]   = tpa;   // fill ATC
                            `uvm_info(get_name(), $sformatf(
                                "EP VF bdf=0x%04h ATS ATC MISS -> GRANT iova=0x%0h pa=0x%0h (cached)",
                                vf_bdf, ep_dma_addr[vf_bdf], tpa), UVM_LOW)
                        end else begin
                            `uvm_info(get_name(), $sformatf(
                                "EP VF bdf=0x%04h ATS DENY iova=0x%0h (no translation, DMA skipped) ret=%0d",
                                vf_bdf, ep_dma_addr[vf_bdf], rr), UVM_LOW)
                        end
                    end
                    if (rr == 0) begin
                        // AT=10 write with the (cached or freshly-granted) PA.
                        dbuf[0] = ep_dma_pattern[vf_bdf];
                        rr = bridge_vcs_dma_write_rc_rid_at(rc, int'(vf_bdf), tpa, dbuf, 4);
                        `uvm_info(get_name(), $sformatf(
                            "EP VF bdf=0x%04h AT-write pa=0x%0h pattern=0x%08h ret=%0d",
                            vf_bdf, tpa, ep_dma_pattern[vf_bdf], rr), UVM_LOW)
                    end
                end
                if (val & 32'h20) begin       // PRI: page request for the IOVA
                    // Gate: the device may only issue Page Requests once PRI is
                    // enabled (PRI Control.Enable, guest pci_enable_pri / setpci).
                    if (!pri_enabled_for(vf_bdf)) begin
                        `uvm_info(get_name(), $sformatf(
                            "EP VF bdf=0x%04h PRI page-req BLOCKED — PRI not enabled (Control.Enable=0)",
                            vf_bdf), UVM_LOW)
                    end else begin
                        rr = bridge_vcs_ats_page_req_rc(rc, int'(vf_bdf), ep_dma_addr[vf_bdf]);
                        `uvm_info(get_name(), $sformatf(
                            "EP VF bdf=0x%04h PRI page-req iova=0x%0h -> %s ret=%0d",
                            vf_bdf, ep_dma_addr[vf_bdf], (rr == 0) ? "SUCCESS" : "FAIL", rr), UVM_LOW)
                    end
                end
                if (val & 32'h40) begin       // TEST: emit a real DUT Translation Request
                    // TLP through the VIP bridging path (handle_dut_ats_tlp), as a
                    // real RTL DUT's hardware would on its RQ channel (AT=01).
                    pcie_tl_mem_tlp treq = pcie_tl_mem_tlp::type_id::create("ats_treq");
                    treq.kind         = TLP_MEM_RD;
                    treq.at           = 2'b01;                 // Translation Request
                    treq.addr         = ep_dma_addr[vf_bdf];
                    treq.requester_id = vf_bdf;
                    treq.length       = 2;                     // 8B translation
                    treq.tag          = 10'h055;
                    `uvm_info(get_name(), $sformatf(
                        "EP VF bdf=0x%04h emit DUT Translation Request(AT=01) iova=0x%0h -> VIP handler",
                        vf_bdf, ep_dma_addr[vf_bdf]), UVM_LOW)
                    handle_dut_ats_tlp(treq);
                end
                if (val & 32'h80) begin       // TEST: DUT translated(AT=10) READ TLP
                    // through the VIP path -> reads guest memory, returns CplD.
                    pcie_tl_mem_tlp rreq = pcie_tl_mem_tlp::type_id::create("ats_rd");
                    rreq.kind         = TLP_MEM_RD;
                    rreq.at           = 2'b10;                 // translated (pre-authorized PA)
                    rreq.addr         = ep_dma_addr[vf_bdf];
                    rreq.requester_id = vf_bdf;
                    rreq.length       = 1;                     // 4B
                    rreq.tag          = 10'h056;
                    `uvm_info(get_name(), $sformatf(
                        "EP VF bdf=0x%04h emit DUT translated(AT=10) READ pa=0x%0h -> VIP handler",
                        vf_bdf, ep_dma_addr[vf_bdf]), UVM_LOW)
                    handle_dut_ats_tlp(rreq);
                end
            end
            16'h0010: ep_msix_sel[vf_bdf] = val[2:0];  // select MSI-X vector for doorbell
            16'h0014: ep_pasid[vf_bdf]    = val[15:0]; // set current PASID for ATS
            default: ; // other offsets ignored by the EP model
        endcase
    endtask

    // -----------------------------------------------------------------------
    // ats_enabled_for: read the requester's ATS Control Register Enable bit
    // (Control[15] = DW bit31 at ATS-cap-offset+4). The guest sets it via
    // pci_enable_ats / setpci; config-bypass lands it in the func's cfg_mgr.
    // ATS cap is @0x100 on a VF, @0x350 on a PF (see func_manager §6.15).
    // -----------------------------------------------------------------------
    protected function bit ats_enabled_for(bit [15:0] bdf);
        pcie_tl_func_context c;
        bit [11:0] off;
        bit [31:0] ctrl;
        if (real_dut || func_mgr == null) return 1'b1;  // real DUT gates itself
        c = func_mgr.lookup_by_bdf(bdf);
        if (c == null) return 1'b0;
        off  = c.is_vf ? 12'h100 : 12'h350;
        ctrl = c.cfg_mgr.read(off + 4);            // [31:16] = ATS Control Register
        return ctrl[31];                            // Enable = Control bit15
    endfunction

    // -----------------------------------------------------------------------
    // pri_enabled_for: read the requester's PRI Control Register Enable bit
    // (Control[0] = DW bit0 at PRI-cap-offset+4). Guest sets it via
    // pci_enable_pri / setpci. PRI cap @0x110 on a VF, @0x360 on a PF (§6.15).
    // -----------------------------------------------------------------------
    protected function bit pri_enabled_for(bit [15:0] bdf);
        pcie_tl_func_context c;
        bit [11:0] off;
        bit [31:0] ctrl;
        if (real_dut || func_mgr == null) return 1'b1;  // real DUT gates itself
        c = func_mgr.lookup_by_bdf(bdf);
        if (c == null) return 1'b0;
        off  = c.is_vf ? 12'h110 : 12'h360;
        ctrl = c.cfg_mgr.read(off + 4);            // [15:0] = PRI Control Register
        return ctrl[0];                             // Enable = Control bit0
    endfunction

    // -----------------------------------------------------------------------
    // pasid_enabled_for: read the requester's PASID Control Register Enable bit
    // (Control[0] = DW bit16, since PASID Control is [31:16] at cap+4). Guest
    // sets it via pci_enable_pasid / setpci. PASID cap @0x120 VF, @0x370 PF.
    // -----------------------------------------------------------------------
    protected function bit pasid_enabled_for(bit [15:0] bdf);
        pcie_tl_func_context c;
        bit [11:0] off;
        bit [31:0] ctrl;
        if (real_dut || func_mgr == null) return 1'b1;  // real DUT gates itself
        c = func_mgr.lookup_by_bdf(bdf);
        if (c == null) return 1'b0;
        off  = c.is_vf ? 12'h120 : 12'h370;
        ctrl = c.cfg_mgr.read(off + 4);            // [31:16] = PASID Control Register
        return ctrl[16];                            // PASID Enable = Control bit0
    endfunction

    // -----------------------------------------------------------------------
    // handle_dut_ats_tlp: bridge a DUT-initiated ATS TLP (a real RTL DUT emits
    // these on its RQ channel; the monitor decodes them into pcie_tl_mem_tlp
    // with the AT field). This is the VIP-layer seam that makes real DUT ATS
    // work — the functional bridge maps the TLP to QEMU's RC/IOMMU:
    //   AT=01 Translation Request -> ask QEMU to translate, reply a Translation
    //         Completion (CplD carrying the translated PA) back to the DUT.
    //   AT=10 Translated write     -> bridge to QEMU DMA with the AT flag (the
    //         RC bypasses the per-VF window, trusting the pre-authorized PA).
    //   AT=00 Untranslated         -> ordinary DUT-initiated DMA (bridged
    //         elsewhere; logged here).
    // -----------------------------------------------------------------------
    protected task handle_dut_ats_tlp(pcie_tl_mem_tlp mem);
        bit [15:0]       rid = mem.requester_id;
        longint unsigned pa;
        int              trr, wr;
        int unsigned     dbuf[16];
        // ATS must be enabled in the requester's ATS Control Register before it
        // may issue Translation Requests (AT=01) or use translated addresses
        // (AT=10). Untranslated (AT=00) DMA is ungated.
        bit ats_en = (mem.at == 2'b00) ? 1'b1 : ats_enabled_for(rid);
        // Current PASID for this requester (0 = no PASID). A tagged translation
        // additionally requires PASID Control.Enable.
        bit [15:0] pasid    = ep_pasid.exists(rid) ? ep_pasid[rid] : 16'h0;
        bit        pasid_ok = (pasid == 16'h0) || pasid_enabled_for(rid);
        if (mem.at == 2'b01) begin
            pa  = 0;
            // Gate: ATS enabled, and (if PASID-tagged) PASID enabled.
            if (!ats_en) begin
                trr = -1;
                `uvm_info(get_name(), $sformatf(
                    "VIP ATS: bdf=0x%04h Translation Request BLOCKED — ATS not enabled (Control.Enable=0)",
                    rid), UVM_LOW)
            end else if (!pasid_ok) begin
                trr = -1;
                `uvm_info(get_name(), $sformatf(
                    "VIP ATS: bdf=0x%04h pasid=0x%05h Translation Request BLOCKED — PASID not enabled",
                    rid, pasid), UVM_LOW)
            end else begin
                trr = (pasid != 16'h0)
                    ? bridge_vcs_ats_translate_rc_pasid(rc_index, int'(rid), int'(pasid), mem.addr, pa)
                    : bridge_vcs_ats_translate_rc(rc_index, int'(rid), mem.addr, pa);
            end
            begin
                pcie_tl_cpl_tlp cpl = pcie_tl_cpl_tlp::type_id::create("ats_xlate_cpl");
                cpl.kind         = TLP_CPLD;
                cpl.fmt          = FMT_3DW_WITH_DATA;
                cpl.type_f       = TLP_TYPE_CPL;
                cpl.attr         = mem.attr;
                cpl.at           = 2'b10;              // completion carries translated addr
                cpl.tc           = mem.tc;
                cpl.requester_id = rid;
                cpl.tag          = mem.tag;
                cpl.completer_id = 16'h0000;           // RC
                cpl.cpl_status   = (trr == 0) ? CPL_STATUS_SC : CPL_STATUS_UR;
                cpl.length       = 2;                  // 8B translated PA
                cpl.byte_count   = 8;
                cpl.payload      = new[8];
                for (int b = 0; b < 8; b++) cpl.payload[b] = pa[8*b +: 8];
                send_tlp(cpl);
                `uvm_info(get_name(), $sformatf(
                    "VIP ATS: DUT Translation Request bdf=0x%04h pasid=0x%05h iova=0x%0h -> %s pa=0x%0h; sent Translation Completion tag=%0d",
                    rid, pasid, mem.addr, (trr==0)?"GRANT":"DENY", pa, mem.tag), UVM_LOW)
            end
        end else begin
            // AT=00 (untranslated) or AT=10 (translated, pre-authorized) memory
            // access. Translated ops use the *_at DPI (RC bypasses the window).
            bit translated = (mem.at == 2'b10);
            int nbytes = mem.length * 4;
            // Gate: AT=10 requires ATS enabled (a real RC rejects a Translated
            // request from a function whose ATS Control.Enable=0 as UR).
            if (translated && !ats_en) begin
                `uvm_info(get_name(), $sformatf(
                    "VIP ATS: bdf=0x%04h translated(AT=10) %s BLOCKED — ATS not enabled",
                    rid, mem.kind.name()), UVM_LOW)
                return;
            end
            if (nbytes <= 0) nbytes = 4;
            for (int i = 0; i < 16; i++) dbuf[i] = 0;
            if (mem.kind == TLP_MEM_RD) begin
                // DUT read -> read guest memory, return a CplD with the data.
                wr = translated
                   ? bridge_vcs_dma_read_rc_rid_at(rc_index, int'(rid), mem.addr, dbuf, nbytes)
                   : bridge_vcs_dma_read_rc_rid   (rc_index, int'(rid), mem.addr, dbuf, nbytes);
                begin
                    pcie_tl_cpl_tlp cpl = pcie_tl_cpl_tlp::type_id::create("dut_rd_cpl");
                    cpl.kind         = TLP_CPLD;
                    cpl.fmt          = FMT_3DW_WITH_DATA;
                    cpl.type_f       = TLP_TYPE_CPL;
                    cpl.attr         = mem.attr;
                    cpl.at           = mem.at;
                    cpl.tc           = mem.tc;
                    cpl.requester_id = rid;
                    cpl.tag          = mem.tag;
                    cpl.completer_id = 16'h0000;
                    cpl.cpl_status   = (wr == 0) ? CPL_STATUS_SC : CPL_STATUS_UR;
                    cpl.length       = mem.length;
                    cpl.byte_count   = nbytes[11:0];
                    cpl.payload      = new[nbytes];
                    for (int b = 0; b < nbytes; b++)
                        cpl.payload[b] = dbuf[b/4][8*(b%4) +: 8];
                    send_tlp(cpl);
                    `uvm_info(get_name(), $sformatf(
                        "VIP: DUT %s read bdf=0x%04h addr=0x%0h len=%0d ret=%0d -> CplD data[0]=0x%08h",
                        translated?"translated(AT=10)":"untranslated(AT=00)",
                        rid, mem.addr, nbytes, wr, dbuf[0]), UVM_LOW)
                end
            end else begin
                // DUT write -> pack payload, write guest memory.
                for (int i = 0; i < 16 && (i*4) < mem.payload.size(); i++)
                    dbuf[i] = {mem.payload[i*4+3], mem.payload[i*4+2],
                               mem.payload[i*4+1], mem.payload[i*4+0]};
                wr = translated
                   ? bridge_vcs_dma_write_rc_rid_at(rc_index, int'(rid), mem.addr, dbuf, nbytes)
                   : bridge_vcs_dma_write_rc_rid   (rc_index, int'(rid), mem.addr, dbuf, nbytes);
                `uvm_info(get_name(), $sformatf(
                    "VIP: DUT %s write bdf=0x%04h addr=0x%0h len=%0d ret=%0d",
                    translated?"translated(AT=10)":"untranslated(AT=00)",
                    rid, mem.addr, nbytes, wr), UVM_LOW)
            end
        end
    endtask

    protected task request_loop(uvm_phase phase);
        int         ret;
        pcie_tl_tlp vip_tlp;

        wait (bridge_ready);
        `uvm_info(get_name(), $sformatf("RC%0d bridge ready, polling", rc_index), UVM_MEDIUM)

        forever begin
            ret = bridge_vcs_poll_tlp_scalar_rc(rc_index);
            if (ret < 0) begin
                `uvm_info(get_name(), $sformatf("RC%0d poll<0: shutdown", rc_index), UVM_MEDIUM)
                ->shutdown_event;
                break;
            end
            if (ret > 0) begin
                #(polling_interval_ns * 1ns);
                continue;
            end

            // ret == 0: a TLP is available — fetch fields via _rc getters
            dpi_type = bridge_vcs_get_poll_type_rc(rc_index);
            dpi_addr = bridge_vcs_get_poll_addr_rc(rc_index);
            dpi_len  = bridge_vcs_get_poll_len_rc(rc_index);
            dpi_tag  = bridge_vcs_get_poll_tag_rc(rc_index);
            for (int i = 0; i < 16; i++)
                dpi_data[i] = bridge_vcs_get_poll_data_rc(rc_index, i);

            // ---- ATS Invalidation (RC -> device): send an Invalidate Message,
            //      then ACK QEMU ONLY after the DUT returns an Invalidation
            //      Completion (bridged by rx_loop). A real RTL DUT emits that
            //      completion on its CC channel; the stand-in synthesizes one. ----
            if (dpi_type == BV_TLP_ATS_INVAL) begin
                bit [15:0] itgt = bridge_vcs_get_tlp_target_bdf_rc(rc_index);
                bit [9:0]  itag = dpi_tag[9:0];   // Invalidate Message tag (echoed by cpl)
                begin
                    pcie_tl_msg_tlp inv = pcie_tl_msg_tlp::type_id::create("ats_inval_msg");
                    inv.kind         = TLP_MSG;
                    inv.fmt          = FMT_4DW_NO_DATA;
                    inv.type_f       = TLP_TYPE_MSG_ID;       // ID-routed to the device
                    inv.msg_code     = MSG_ATS_INVALIDATION;
                    inv.msg_addr     = dpi_addr;              // window base being invalidated
                    inv.target_id    = itgt;
                    inv.requester_id = 16'h0000;              // RC
                    inv.tag          = itag;
                    send_tlp(inv);
                    `uvm_info(get_name(), $sformatf(
                        "RC%0d sent ATS Invalidate Request Message -> DUT bdf=0x%04h iova=0x%0h tag=0x%03h (await Completion)",
                        rc_index, itgt, dpi_addr, itag), UVM_LOW)
                end
                // Defer the QEMU ACK until the DUT Invalidation Completion returns.
                pend_inval_qtag[itag] = dpi_tag;
                pend_inval_bdf[itag]  = itgt;
                // Stand-in only: flush the model ATC and synthesize the DUT's
                // Invalidation Completion. A real RTL DUT flushes its own ATC and
                // emits the real Completion on its CC channel -> rx_loop matches
                // the pending tag and ACKs QEMU (no synthesis, no double-ACK).
                if (!real_dut) begin
                    if (ep_atc_pa.exists(itgt)) begin
                        ep_atc_pa.delete(itgt);
                        ep_atc_iova.delete(itgt);
                        `uvm_info(get_name(), $sformatf(
                            "EP(stand-in) ATC bdf=0x%04h iova=0x%0h -> FLUSHED, returning Invalidation Completion",
                            itgt, dpi_addr), UVM_LOW)
                    end else begin
                        `uvm_info(get_name(), $sformatf(
                            "EP(stand-in) ATC bdf=0x%04h iova=0x%0h -> clean, returning Invalidation Completion",
                            itgt, dpi_addr), UVM_LOW)
                    end
                    begin
                        pcie_tl_cpl_tlp icpl = pcie_tl_cpl_tlp::type_id::create("ats_inval_cpl");
                        icpl.kind         = pcie_tl_pkg::TLP_CPL; // Invalidation Completion (no data)
                        icpl.fmt          = FMT_3DW_NO_DATA;
                        icpl.type_f       = TLP_TYPE_CPL;
                        icpl.tag          = itag;
                        icpl.requester_id = itgt;
                        icpl.completer_id = itgt;                 // from the device
                        icpl.cpl_status   = CPL_STATUS_SC;
                        icpl.length       = 0;
                        m_rx_fifo.analysis_export.write(icpl);    // feed rx_loop like a DUT cpl
                    end
                end
                total_tlp_count++;
                #1;
                continue;
            end

            // ---- Config-space bypass: func_mgr(_bdf) answers, never reaches DUT ----
            //   target BDF 从 TLP 取(QEMU 已填, DPI getter 现成), 路由到对应 PF/VF。
            if (config_proxy != null && config_proxy.bypass_enable) begin
                bit [15:0] tgt_bdf = bridge_vcs_get_tlp_target_bdf_rc(rc_index);
                if (dpi_type == BV_TLP_CFGRD0) begin
                    bit [31:0] cfg_data;
                    int dw_addr = int'(dpi_addr) >> 2;
                    if (config_proxy.handle_cfg_read_bdf(tgt_bdf, dw_addr, cfg_data)) begin
                        for (int i = 0; i < 16; i++) bridge_vcs_set_cpl_data_rc(rc_index, i, 0);
                        bridge_vcs_set_cpl_data_rc(rc_index, 0, cfg_data);
                        void'(bridge_vcs_send_cpl_scalar_rc(rc_index, dpi_tag, 1));
                        total_tlp_count++;
                        #1;
                        continue;
                    end
                end
                if (dpi_type == BV_TLP_CFGWR0) begin
                    int dw_addr = int'(dpi_addr) >> 2;
                    int byte_off = int'(dpi_addr) & 3;
                    bit [31:0] wr_data = dpi_data[0];
                    if (config_proxy.handle_cfg_write_bdf(tgt_bdf, dw_addr, wr_data, byte_off, dpi_len)) begin
                        // BAR base 同步 C 侧(per-RC, 供 MMIO 解码): 取该 bdf 的 bar_base[0]。
                        // 多 bdf 的 per-bdf BAR 另由 config_proxy 内部 set_bar_base_bdf 同步。
                        if (dw_addr == 4 || dw_addr == 5) begin
                            pcie_tl_func_context ctx = func_mgr.lookup_by_bdf(tgt_bdf);
                            if (ctx != null)
                                bridge_vcs_set_bar_base_rc(rc_index, 0, ctx.bar_base[0]);
                        end
                        // CfgWr is fire-and-forget (QEMU does not wait on completion)
                        total_tlp_count++;
                        #1;
                        continue;
                    end
                end
            end

            // ---- EP data-plane model: intercept VF BAR writes (doorbell) ----
            // A write to an enabled VF's BAR is handled by the stand-in EP model
            // (initiates VF-sourced DMA/MSI-X). Reads still flow to the VIP DUT.
            // Stand-in only: intercept VF-BAR writes as the EP doorbell. With a
            // real DUT the write must flow THROUGH to the DUT (fall to send_tlp).
            if (!real_dut && dpi_type == BV_TLP_MWR && func_mgr != null) begin
                bit [15:0] vf_tgt = bridge_vcs_get_tlp_target_bdf_rc(rc_index);
                pcie_tl_func_context vf_ctx = func_mgr.lookup_by_bdf(vf_tgt);
                if (vf_ctx != null && vf_ctx.is_vf) begin
                    ep_vf_mmio_write(rc_index, vf_tgt, dpi_addr, dpi_data[0]);
                    total_tlp_count++;
                    #1;
                    continue;
                end
            end

            // ---- MMIO to DUT: build a VIP TLP, send through the pipeline ----
            vip_tlp = build_mmio_tlp(dpi_type, dpi_addr, dpi_data, dpi_len, dpi_tag);
            if (vip_tlp == null) begin
                unknown_type_count++;
                `uvm_warning(get_name(),
                    $sformatf("RC%0d unknown/unsupported TLP type 0x%02h, dropping",
                              rc_index, dpi_type))
                continue;
            end

            begin
                bit [9:0] qemu_tag_10 = dpi_tag[9:0];   // 10-bit QEMU tag
                send_tlp(vip_tlp);   // adapter.send -> CQ channel -> DUT
                if (vip_tlp.requires_completion()) begin
                    vip_tag_to_qemu_tag[int'(vip_tlp.tag)] = qemu_tag_10;
                    qemu_tag_to_vip_tag[qemu_tag_10]       = int'(vip_tlp.tag);
                end
            end
            total_tlp_count++;
        end
    endtask

    // -----------------------------------------------------------------------
    // rx_loop: drain decoded TLPs arriving from the DUT via this RC's adapter.
    //   - CplD/Cpl (completions on CC channel) -> forward to QEMU.
    //   - MRd/MWr  (DUT-initiated DMA on RQ channel) -> TODO next increment.
    // -----------------------------------------------------------------------
    protected task rx_loop(uvm_phase phase);
        pcie_tl_tlp     rx_tlp;
        pcie_tl_cpl_tlp cpl;

        // 从 monitor.tlp_ap 订阅(阻塞 get), 不抢 adapter rx_queue。阶段1 就要收 CplD。
        forever begin
            m_rx_fifo.get(rx_tlp);   // 阻塞: 有 TLP(CC/RX)才返回, 永不为 null

            if ($cast(cpl, rx_tlp)) begin
                if (pend_inval_qtag.exists(cpl.tag)) begin
                    // DUT Invalidation Completion -> close the loop: ACK QEMU now.
                    int        qtag = pend_inval_qtag[cpl.tag];
                    bit [15:0] ibdf = pend_inval_bdf[cpl.tag];
                    pend_inval_qtag.delete(cpl.tag);
                    pend_inval_bdf.delete(cpl.tag);
                    for (int i = 0; i < 16; i++) bridge_vcs_set_cpl_data_rc(rc_index, i, 0);
                    void'(bridge_vcs_send_cpl_scalar_rc(rc_index, qtag, 1));
                    `uvm_info(get_name(), $sformatf(
                        "RC%0d ATS Invalidation Completion from DUT bdf=0x%04h tag=0x%03h -> ACK QEMU tag=0x%03h",
                        rc_index, ibdf, cpl.tag, qtag), UVM_LOW)
                end else if (cosim_active)
                    forward_completion_to_qemu(cpl);      // 阶段2: VIP tag→QEMU tag, 回 QEMU
                else
                    void'(super.handle_completion(cpl));  // 阶段1: VIP tag_mgr 匹配+释放, 回 sequence
            end else begin
                // DUT-initiated request (MRd/MWr on RQ). Real DUT ATS traffic
                // (AT=01 Translation Request / AT=10 translated DMA) is bridged
                // to QEMU here; other (AT=00) DMA is logged as TODO.
                pcie_tl_mem_tlp mem;
                inbound_req_count++;
                if ($cast(mem, rx_tlp)) begin
                    handle_dut_ats_tlp(mem);
                end else begin
                    `uvm_info(get_name(),
                        $sformatf("RC%0d inbound DUT request %s (non-mem, dropping)",
                                  rc_index, rx_tlp.kind.name()), UVM_MEDIUM)
                end
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // forward_completion_to_qemu: VIP tag -> QEMU tag, push CplD payload back
    // over this RC's bridge. Also lets the base class free the VIP tag.
    // -----------------------------------------------------------------------
    protected function void forward_completion_to_qemu(pcie_tl_cpl_tlp cpl);
        int        vip_tag_int = int'(cpl.tag);
        int        qemu_tag;
        bit [31:0] rdata = 0;

        void'(super.handle_completion(cpl));   // base: tag match + release

        if (!vip_tag_to_qemu_tag.exists(vip_tag_int)) begin
            `uvm_warning(get_name(),
                $sformatf("RC%0d completion with no QEMU tag map: vip_tag=0x%03h",
                          rc_index, cpl.tag))
            return;
        end
        qemu_tag = int'(vip_tag_to_qemu_tag[vip_tag_int]);
        vip_tag_to_qemu_tag.delete(vip_tag_int);
        qemu_tag_to_vip_tag.delete(qemu_tag[9:0]);

        // First dword of payload, PCIe big-endian -> little-endian word for QEMU
        if (cpl.payload.size() >= 4)
            rdata = {cpl.payload[0], cpl.payload[1], cpl.payload[2], cpl.payload[3]};
        else
            for (int i = 0; i < cpl.payload.size(); i++)
                rdata[((3-i)*8) +: 8] = cpl.payload[i];

        for (int i = 0; i < 16; i++) bridge_vcs_set_cpl_data_rc(rc_index, i, 0);
        bridge_vcs_set_cpl_data_rc(rc_index, 0, rdata);
        if (bridge_vcs_send_cpl_scalar_rc(rc_index, qemu_tag, 1) != 0)
            `uvm_error(get_name(),
                $sformatf("RC%0d send_cpl failed qemu_tag=0x%03h", rc_index, qemu_tag))
        total_cpl_count++;

        `uvm_info(get_name(),
            $sformatf("RC%0d Cpl->QEMU vip_tag=0x%03h qemu_tag=0x%03h data=0x%08h",
                      rc_index, cpl.tag, qemu_tag, rdata), UVM_HIGH)
    endfunction

    // -----------------------------------------------------------------------
    // build_mmio_tlp: MMIO subset (MWr / MRd). Config types are bypassed
    // before this point; Cpl-out is not produced by the RC host.
    // -----------------------------------------------------------------------
    protected function pcie_tl_tlp build_mmio_tlp(
        input byte unsigned    t,
        input longint unsigned addr,
        input int unsigned     d[16],
        input int              len,
        input int              tag);

        pcie_tl_mem_tlp m;
        int payload_bytes;

        case (t)
            BV_TLP_MWR: begin
                m = pcie_tl_mem_tlp::type_id::create("mwr");
                m.kind     = TLP_MEM_WR;
                m.addr     = addr;
                m.is_64bit = (addr[63:32] != 0);
                m.fmt      = m.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
                m.type_f   = TLP_TYPE_MEM_RD;   // MEM_WR shares encoding
                m.first_be = 4'hF;
                m.last_be  = (len > 4) ? 4'hF : 4'h0;
                payload_bytes = (len > 0) ? len : 4;
                m.length   = (payload_bytes + 3) / 4;
                unpack_words_to_bytes(d, payload_bytes, m.payload);
                return m;
            end
            BV_TLP_MRD: begin
                m = pcie_tl_mem_tlp::type_id::create("mrd");
                m.kind     = TLP_MEM_RD;
                m.addr     = addr;
                m.is_64bit = (addr[63:32] != 0);
                m.fmt      = m.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
                m.type_f   = TLP_TYPE_MEM_RD;
                m.first_be = 4'hF;
                m.last_be  = (len > 4) ? 4'hF : 4'h0;
                m.length   = (len > 0) ? (len + 3) / 4 : 1;
                m.tag      = 10'(tag[9:0]);
                return m;
            end
            default: return null;
        endcase
    endfunction

    // int[16] words (LE within each word) -> VIP byte payload
    protected function void unpack_words_to_bytes(
        input  int unsigned d[16],
        input  int          byte_count,
        output bit [7:0]    payload[]);
        int words;
        if (byte_count <= 0) begin payload = new[0]; return; end
        payload = new[byte_count];
        words = (byte_count + 3) / 4;
        for (int i = 0; i < words && i < 16; i++)
            for (int b = 0; b < 4; b++)
                if (i*4 + b < byte_count)
                    payload[i*4 + b] = d[i][(b*8) +: 8];
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_name(), $sformatf(
            "=== cosim_xrc_driver RC%0d: tlp=%0d cpl=%0d unknown=%0d inbound(DMA-todo)=%0d ===",
            rc_index, total_tlp_count, total_cpl_count, unknown_type_count, inbound_req_count),
            UVM_NONE)
    endfunction

endclass

// -----------------------------------------------------------------------
// UCLI 命令注册(aip_core): start_cosim [rc=<n>] -> notify_start。
//   start_cosim         全部 RC        start_cosim rc=0   只切 RC0
// 宏内 static __inst 自动注册, 无需 initial。
// AIP_CORE_PKG_SV 由 aip_core_pkg.sv 定义 —— 编了 aip(filelist 中 aip 在前)
// 才启用本段; 未集成时天然跳过, driver 两阶段逻辑不受影响(仅无 UCLI 命令)。
// -----------------------------------------------------------------------
`ifdef AIP_CORE_PKG_SV
`aip_cmd_1i(start_cosim, cosim_xrc_driver::notify_start, int, rc, -1)
`endif

`endif // COSIM_XRC_DRIVER_SV
