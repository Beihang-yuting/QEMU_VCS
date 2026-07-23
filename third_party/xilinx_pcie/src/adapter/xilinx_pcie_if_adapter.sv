//=============================================================================
// Xilinx PCIe Interface Adapter (adapter-mode, method A2)
//
// extends the upstream pcie_tl_if_adapter and is installed into the upstream
// pcie_tl_env via factory override of pcie_tl_if_adapter::type_id.
//
// One adapter per BFM agent (rc_adapter_0 / ep_adapter). Each adapter WRAPS the
// 4 PG213 AXI-Stream channels (RQ/RC/CQ/CC) as axis_agents and ABSORBS the
// Xilinx encode/decode logic (lifted verbatim from xilinx_pcie_driver /
// xilinx_pcie_monitor, minus the protocol checks which now live in the upstream
// pcie_tl monitor).
//
//   send(tlp)    : route -> encode descriptor -> pack beats -> drive on the
//                  MASTER sequencer of the tx channel (blocking, serial).
//   receive(tlp) : non-blocking pop of decoded TLPs from rx_queue (null if empty)
//
// Only the SLAVE (receive-direction) channel monitors are connected to rx_queue,
// so the adapter never re-ingests its own transmitted TLPs (no self-echo).
//=============================================================================

// analysis_imp suffixes (unique to this pkg)
`uvm_analysis_imp_decl(_xrq)
`uvm_analysis_imp_decl(_xrc)
`uvm_analysis_imp_decl(_xcq)
`uvm_analysis_imp_decl(_xcc)

// internal one-shot sequence to push a single axis_transfer onto an axis_sequencer
class xilinx_adapter_axis_oneshot_seq extends uvm_sequence #(axis_transfer);
    `uvm_object_utils(xilinx_adapter_axis_oneshot_seq)
    axis_transfer xfer;
    function new(string name = "xilinx_adapter_axis_oneshot_seq");
        super.new(name);
    endfunction
    virtual task body();
        start_item(xfer);
        finish_item(xfer);
    endtask
endclass

class xilinx_pcie_if_adapter extends pcie_tl_if_adapter;

    `uvm_component_utils(xilinx_pcie_if_adapter)

    //=========================================================================
    // Members
    //=========================================================================
    // BFM role, derived from instance name ("rc"->RC else EP)
    xilinx_pcie_role_e          role;

    // AXI-Stream data width (compile-time fixed via XILINX_DATA_W macro; the
    // per-channel axis_agent typedefs and TUSER widths are macro-parameterized,
    // so DATA_WIDTH must match XILINX_DATA_W).
    int                         DATA_WIDTH = `XILINX_DATA_W;

    // Straddle mode enable, sampled once from the +STRADDLE_EN runtime plusarg
    // in build_phase (default 0). Wires the straddle engine so straddle actually
    // engages instead of being hardcoded off.
    int                         STRADDLE_EN = 0;

    // rx_queue depth above which a backpressure warning is issued (drain stall)
    localparam int              RX_QUEUE_WARN_DEPTH = 64;

    // codecs / router (no env_config dependency)
    xilinx_tuser_codec          tuser_codec;
    xilinx_straddle_engine      straddle_eng;
    xilinx_pcie_channel_router  router;

    // 4 wrapped axis_agents (one per PG213 channel)
    axis_agent_rq_t             rq_agent;
    axis_agent_rc_t             rc_agent;
    axis_agent_cq_t             cq_agent;
    axis_agent_cc_t             cc_agent;

    // analysis imps: axis_monitor.packet_ap -> decode -> rx_queue
    uvm_analysis_imp_xrq #(axis_packet, xilinx_pcie_if_adapter) rq_imp;
    uvm_analysis_imp_xrc #(axis_packet, xilinx_pcie_if_adapter) rc_imp;
    uvm_analysis_imp_xcq #(axis_packet, xilinx_pcie_if_adapter) cq_imp;
    uvm_analysis_imp_xcc #(axis_packet, xilinx_pcie_if_adapter) cc_imp;

    // decoded receive queue (non-blocking drain by receive())
    pcie_tl_tlp                 rx_queue[$];

    //=========================================================================
    function new(string name = "xilinx_pcie_if_adapter", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //=========================================================================
    // build_phase
    //=========================================================================
    function void build_phase(uvm_phase phase);
        string nm = get_name();
        super.build_phase(phase);

        // role from instance name (upstream pcie_tl_env names these
        // "rc_adapter" / "ep_adapter" / "ep_adapter_<n>")
        if (nm.len() >= 10 && nm.substr(0,9) == "rc_adapter")
            role = XILINX_PCIE_RC;
        else if (nm.len() >= 10 && nm.substr(0,9) == "ep_adapter")
            role = XILINX_PCIE_EP;
        else
            `uvm_fatal(get_type_name(),
                $sformatf("cannot derive RC/EP role from adapter instance name '%s' (expected rc_adapter*/ep_adapter*)", nm))
        mode = SV_IF_MODE;   // base run_phase guarded by vif!=null (vif stays null)

        // straddle enable from +STRADDLE_EN plusarg (sampled once, default off)
        void'($value$plusargs("STRADDLE_EN=%d", STRADDLE_EN));

        `uvm_info(get_type_name(),
            $sformatf("ADAPTER build: name=%s type=%s role=%s DATA_WIDTH=%0d STRADDLE_EN=%0d",
                nm, get_type_name(), role.name(), DATA_WIDTH, STRADDLE_EN), UVM_LOW)

        // codecs / router
        tuser_codec  = new(DATA_WIDTH);
        straddle_eng = new((STRADDLE_EN != 0), DATA_WIDTH);   // straddle from plusarg
        router       = new(role);

        // create 4 axis_agents, each with its replicated axis_config
        begin
            axis_config acfg_rq = make_axis_config(XILINX_CH_RQ);
            uvm_config_db #(axis_config)::set(this, "rq_agent*", "cfg", acfg_rq);
            rq_agent = axis_agent_rq_t::type_id::create("rq_agent", this);
        end
        begin
            axis_config acfg_rc = make_axis_config(XILINX_CH_RC);
            uvm_config_db #(axis_config)::set(this, "rc_agent*", "cfg", acfg_rc);
            rc_agent = axis_agent_rc_t::type_id::create("rc_agent", this);
        end
        begin
            axis_config acfg_cq = make_axis_config(XILINX_CH_CQ);
            uvm_config_db #(axis_config)::set(this, "cq_agent*", "cfg", acfg_cq);
            cq_agent = axis_agent_cq_t::type_id::create("cq_agent", this);
        end
        begin
            axis_config acfg_cc = make_axis_config(XILINX_CH_CC);
            uvm_config_db #(axis_config)::set(this, "cc_agent*", "cfg", acfg_cc);
            cc_agent = axis_agent_cc_t::type_id::create("cc_agent", this);
        end

        // analysis imps
        rq_imp = new("rq_imp", this);
        rc_imp = new("rc_imp", this);
        cq_imp = new("cq_imp", this);
        cc_imp = new("cc_imp", this);
    endfunction

    //=========================================================================
    // connect_phase
    //=========================================================================
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // dummy reset events for the axis reset_listeners (no axis_env present)
        begin
            uvm_event a = new("dummy_reset_assert");
            uvm_event b = new("dummy_reset_active");
            uvm_event c = new("dummy_reset_deassert");
            set_dummy_reset(rq_agent.rst_listener, a, b, c);
            set_dummy_reset(rc_agent.rst_listener, a, b, c);
            set_dummy_reset(cq_agent.rst_listener, a, b, c);
            set_dummy_reset(cc_agent.rst_listener, a, b, c);
        end

        // Connect ONLY the receive-direction (slave) channel monitors so the
        // adapter never re-ingests its own transmitted TLPs.
        //   RC role: slaves = RQ, CC
        //   EP role: slaves = CQ, RC
        if (role == XILINX_PCIE_RC) begin
            rq_agent.mon.packet_ap.connect(rq_imp);
            cc_agent.mon.packet_ap.connect(cc_imp);
        end else begin
            cq_agent.mon.packet_ap.connect(cq_imp);
            rc_agent.mon.packet_ap.connect(rc_imp);
        end
    endfunction

    //=========================================================================
    // extract_phase: signal the tb clock generator to stop. Runs once the UVM
    // run_phase has ended (objections dropped), halting the free-running clock
    // so no clocked axis threads keep flooding the log post-verdict.
    //=========================================================================
    function void extract_phase(uvm_phase phase);
        super.extract_phase(phase);
        g_xilinx_adapter_quiesce = 1'b1;
    endfunction

    //=========================================================================
    // send(tlp): override base -> drive over AXIS (steps 4-8 of the xilinx driver)
    //=========================================================================
    virtual task send(pcie_tl_tlp tlp);
        xilinx_channel_e channel;
        bit [127:0]      desc;
        bit [511:0]      beats[$];
        bit [15:0]       keeps[$];
        bit              lasts[$];
        axis_sequencer   sqr;

        channel = router.get_tx_channel(tlp);
        sqr     = get_master_sqr(channel);
        if (sqr == null) begin
            `uvm_error(get_type_name(),
                $sformatf("send: no MASTER sqr for channel %s (role=%s)",
                    channel.name(), role.name()))
            return;
        end

        desc = encode_descriptor(tlp, channel);
        straddle_eng.pack_single_tlp(desc, tlp.payload, channel, beats, keeps, lasts);
        send_beats(tlp, channel, beats, keeps, lasts, sqr);

        `uvm_info(get_type_name(),
            $sformatf("send: %s -> channel %s, beats=%0d",
                tlp.kind.name(), channel.name(), beats.size()), UVM_HIGH)
    endtask

    //=========================================================================
    // receive(tlp): non-blocking pop of decoded rx_queue
    //=========================================================================
    virtual task receive(output pcie_tl_tlp tlp);
        if (rx_queue.size() > 0)
            tlp = rx_queue.pop_front();
        else
            tlp = null;
    endtask

    //=========================================================================
    // analysis imp callbacks: decode axis_packet -> rx_queue
    //=========================================================================
    function void write_xrq(axis_packet pkt);
        push_decoded(pkt, XILINX_CH_RQ);
    endfunction
    function void write_xrc(axis_packet pkt);
        push_decoded(pkt, XILINX_CH_RC);
    endfunction
    function void write_xcq(axis_packet pkt);
        push_decoded(pkt, XILINX_CH_CQ);
    endfunction
    function void write_xcc(axis_packet pkt);
        push_decoded(pkt, XILINX_CH_CC);
    endfunction

    protected function void push_decoded(axis_packet pkt, xilinx_channel_e ch);
        pcie_tl_tlp tlp;
        tlp = decode_packet(pkt, ch);
        if (tlp != null) begin
            rx_queue.push_back(tlp);
            `uvm_info(get_type_name(),
                $sformatf("rx %s: %s tag=0x%03h payload=%0dB (rx_queue=%0d)",
                    ch.name(), tlp.kind.name(), tlp.tag, tlp.payload.size(),
                    rx_queue.size()), UVM_MEDIUM)
            if (rx_queue.size() > RX_QUEUE_WARN_DEPTH)
                `uvm_warning(get_type_name(),
                    $sformatf("rx_queue depth %0d exceeds %0d on %s — receive() draining too slowly",
                        rx_queue.size(), RX_QUEUE_WARN_DEPTH, role.name()))
        end
    endfunction

    //=========================================================================
    // Helpers
    //=========================================================================
    protected function void set_dummy_reset(axis_reset_listener rl,
                                            uvm_event a, uvm_event b, uvm_event c);
        if (rl != null) begin
            rl.reset_asserted_evt   = a;
            rl.reset_active_evt     = b;
            rl.reset_deasserted_evt = c;
        end
    endfunction

    protected function axis_sequencer get_master_sqr(xilinx_channel_e channel);
        case (channel)
            XILINX_CH_RQ: return rq_agent.sqr;
            XILINX_CH_RC: return rc_agent.sqr;
            XILINX_CH_CQ: return cq_agent.sqr;
            XILINX_CH_CC: return cc_agent.sqr;
            default:      return null;
        endcase
    endfunction

    //=========================================================================
    // make_axis_config: replicate xilinx_pcie_env_config.create_axis_config
    // (role+channel -> MASTER/SLAVE + per-channel TUSER width), no env_config.
    //=========================================================================
    protected function axis_config make_axis_config(xilinx_channel_e ch);
        axis_config c;
        c = axis_config::type_id::create("axis_cfg");
        c.TDATA_WIDTH = DATA_WIDTH;
        c.TID_WIDTH   = 1;
        c.TDEST_WIDTH = 1;
        c.HAS_TSTRB   = 0;
        c.HAS_TKEEP   = 1;
        c.HAS_TLAST   = 1;
        case (ch)
            XILINX_CH_RQ: c.TUSER_WIDTH = xilinx_get_rq_tuser_width(DATA_WIDTH);
            XILINX_CH_RC: c.TUSER_WIDTH = xilinx_get_rc_tuser_width(DATA_WIDTH);
            XILINX_CH_CQ: c.TUSER_WIDTH = xilinx_get_cq_tuser_width(DATA_WIDTH);
            XILINX_CH_CC: c.TUSER_WIDTH = xilinx_get_cc_tuser_width(DATA_WIDTH);
        endcase
        c.pkt_boundary_mode = PKT_BOUNDARY_TLAST;
        // role+channel -> MASTER/SLAVE
        if (role == XILINX_PCIE_RC) begin
            case (ch)
                XILINX_CH_RQ: c.agent_mode = AXIS_SLAVE;
                XILINX_CH_RC: c.agent_mode = AXIS_MASTER;
                XILINX_CH_CQ: c.agent_mode = AXIS_MASTER;
                XILINX_CH_CC: c.agent_mode = AXIS_SLAVE;
                default:      c.agent_mode = AXIS_MASTER;
            endcase
        end else begin
            case (ch)
                XILINX_CH_RQ: c.agent_mode = AXIS_MASTER;
                XILINX_CH_RC: c.agent_mode = AXIS_SLAVE;
                XILINX_CH_CQ: c.agent_mode = AXIS_SLAVE;
                XILINX_CH_CC: c.agent_mode = AXIS_MASTER;
                default:      c.agent_mode = AXIS_MASTER;
            endcase
        end
        c.is_active = UVM_ACTIVE;
        // default bandwidth: drive valid with zero idle, always ready
        // (identical for MASTER and SLAVE; master/slave distinction is agent_mode above)
        c.valid_gen_mode = VALID_ZERO_IDLE;
        c.idle_cycles    = 0;
        c.valid_weight   = 100;
        c.ready_gen_mode = READY_ALWAYS;
        c.ready_weight   = 100;
        return c;
    endfunction

    //=========================================================================
    // ===== TX encode path (lifted from xilinx_pcie_driver) =====
    //=========================================================================
    protected function bit [127:0] encode_descriptor(pcie_tl_tlp tlp,
                                                     xilinx_channel_e channel);
        bit [127:0] desc;
        case (channel)
            XILINX_CH_RQ: desc = xilinx_desc_codec::encode_rq(tlp);
            XILINX_CH_RC: begin
                bit [95:0] d96 = xilinx_desc_codec::encode_rc(tlp);
                desc = {32'h0, d96};
            end
            XILINX_CH_CQ: desc = xilinx_desc_codec::encode_cq(
                              tlp, .bar_id(3'h0), .bar_aperture(6'h0), .target_func(8'h0));
            XILINX_CH_CC: begin
                bit [95:0] d96 = xilinx_desc_codec::encode_cc(tlp);
                desc = {32'h0, d96};
            end
            default: begin
                `uvm_error(get_type_name(),
                    $sformatf("encode_descriptor: unknown channel %s", channel.name()))
                desc = '0;
            end
        endcase
        return desc;
    endfunction

    protected task send_beats(pcie_tl_tlp tlp, xilinx_channel_e channel,
                              ref bit [511:0] beats[$], ref bit [15:0] keeps[$],
                              ref bit lasts[$], axis_sequencer sqr);
        int num_beats = beats.size();
        for (int i = 0; i < num_beats; i++) begin
            axis_transfer xfer;
            bit [511:0]   tuser_val;
            xfer = axis_transfer::type_id::create(
                $sformatf("xfer_%s_%0d", channel.name(), i));
            tuser_val = encode_tuser_for_beat(tlp, channel, beats[i], i,
                                              num_beats, lasts[i], keeps[i]);
            xfer.tdata = beats[i];
            // PG213: axis_if tkeep 为 per-DWORD (每 DW 1 位)，直接放 per-DW keep。
            // driver 整体赋值 vif.tkeep<=xfer.tkeep 自动取低 TDATA/32 位。
            xfer.tkeep = keeps[i];
            xfer.tlast = lasts[i];
            xfer.tuser = tuser_val;
            // first-beat 1-cycle idle so tvalid drops >=1 cycle after prior tlast
            // (prevents axis_monitor merging back-to-back TLPs across channels)
            xfer.delay = (i == 0) ? 1 : 0;
            begin
                xilinx_adapter_axis_oneshot_seq os;
                os = xilinx_adapter_axis_oneshot_seq::type_id::create(
                    $sformatf("os_%s_%0d", channel.name(), i));
                os.xfer = xfer;
                os.start(sqr);
            end
        end
    endtask

    // build_byte_en: construct m_axis_{cq,rc}_tuser.byte_en for ONE beat.
    // PG213: byte_en marks valid PAYLOAD bytes on tdata and is NOT asserted for
    // descriptor bytes. Returns 0 when the TLP carries no payload (e.g. MemRd /
    // data-less completion). For payload DWs, boundary DWs use first_be/last_be
    // (single-DW payload uses first_be), interior DWs are full (0xF).
    //   desc_dw    : descriptor DW count occupying beat-0 low lanes (RQ/CQ=4, RC/CC=3)
    //   total_pl_dw: total payload length in DW (tlp.length; 0 => 1024)
    protected function bit [63:0] build_byte_en(
        int beat_idx, bit [15:0] dw_keep, bit has_payload, int desc_dw,
        bit [3:0] first_be, bit [3:0] last_be, int total_pl_dw);
        bit [63:0] be;
        int lanes = DATA_WIDTH / 32;         // DW lanes per beat
        int pl_len = (total_pl_dw == 0) ? 1024 : total_pl_dw;
        be = '0;
        if (!has_payload) return be;         // reads / data-less completions -> 0
        for (int j = 0; j < lanes; j++) begin
            int pl_idx;
            bit [3:0] dwbe;
            if (!dw_keep[j]) continue;
            if (beat_idx == 0 && j < desc_dw) continue;   // skip descriptor DWs
            pl_idx = (beat_idx == 0) ? (j - desc_dw)
                                     : ((lanes - desc_dw) + (beat_idx - 1)*lanes + j);
            if (pl_idx < 0) continue;
            if (pl_len <= 1)                   dwbe = first_be;   // single payload DW
            else if (pl_idx == 0)              dwbe = first_be;   // first DW
            else if (pl_idx == pl_len - 1)     dwbe = last_be;    // last DW
            else                               dwbe = 4'hF;       // interior DW
            be[4*j +: 4] = dwbe;
        end
        return be;
    endfunction

    // build_cpl_byte_en: byte_en for a completion beat (RC channel).
    // A completion's valid bytes are CONTIGUOUS; the straddle packer places
    // payload[0] at byte 0 of the first payload DW (DWORD-aligned, no offset),
    // so valid bytes span [0 .. num_bytes-1] across the payload DWs. This marks
    // the exact valid byte count per DW (last DW partial when num_bytes is not a
    // multiple of 4), and 0 for a data-less completion (num_bytes == 0).
    // NOTE: for an UNALIGNED completion (lower_addr[1:0] != 0) PG213 dword-aligned
    // mode would shift the first valid byte to lower_addr[1:0]; the BFM does not
    // model that leading offset in placement, so byte_en mirrors the byte-0
    // placement it actually drives (self-consistent; see report for the limit).
    protected function bit [63:0] build_cpl_byte_en(
        int beat_idx, bit [15:0] dw_keep, int desc_dw, int num_bytes);
        bit [63:0] be;
        int lanes = DATA_WIDTH / 32;
        be = '0;
        if (num_bytes <= 0) return be;         // data-less completion -> 0
        for (int j = 0; j < lanes; j++) begin
            int pl_dw_idx;
            int base_byte;
            if (!dw_keep[j]) continue;
            if (beat_idx == 0 && j < desc_dw) continue;   // skip descriptor DWs
            pl_dw_idx = (beat_idx == 0) ? (j - desc_dw)
                                        : ((lanes - desc_dw) + (beat_idx - 1)*lanes + j);
            if (pl_dw_idx < 0) continue;
            base_byte = pl_dw_idx * 4;                     // global payload byte index
            for (int k = 0; k < 4; k++)
                if (base_byte + k < num_bytes) be[4*j + k] = 1'b1;
        end
        return be;
    endfunction

    protected function bit [511:0] encode_tuser_for_beat(
        pcie_tl_tlp tlp, xilinx_channel_e channel, bit [511:0] tdata,
        int beat_idx, int num_beats, bit is_last, bit [15:0] dw_keep = 16'hFFFF);
        bit [511:0] tuser_truncated;
        case (channel)
            XILINX_CH_RQ: begin
                bit [3:0]   first_be, last_be;
                bit [1:0]   tag_9_8;
                bit [284:0] tuser_full;
                bit [3:0]   eop_off;
                extract_be_from_tlp(tlp, first_be, last_be);
                tag_9_8 = tlp.tag[9:8];
                eop_off = (is_last && straddle_eng.straddle_enable) ?
                          straddle_eng.calc_eop_offset(dw_keep) : 4'h0;
                tuser_full = tuser_codec.encode_rq_tuser(
                    .first_be(beat_idx == 0 ? first_be : 4'h0),
                    .last_be (beat_idx == 0 ? last_be  : 4'h0),
                    .addr_offset(3'h0), .discontinue(1'b0),
                    .tph_present(1'b0), .tph_type(2'h0), .tph_st_tag(8'h0),
                    .seq_num_0(6'h0), .seq_num_1(6'h0),
                    .tag_9_8(beat_idx == 0 ? tag_9_8 : 2'h0),
                    .sop(beat_idx == 0), .is_eop(is_last), .eop_ptr(eop_off),
                    .tdata(tdata));
                tuser_truncated = tuser_full;
            end
            XILINX_CH_RC: begin
                bit [63:0]  byte_en;
                bit [320:0] tuser_full;
                bit [3:0]   eof_off;
                // PG213: RC byte_en marks the contiguous valid completion payload
                // bytes (0 for data-less Cpl); RC descriptor = 3 DW. Exact per-byte
                // mask from the completion payload length (partial last DW handled).
                byte_en = build_cpl_byte_en(beat_idx, dw_keep, 3, tlp.payload.size());
                eof_off = (is_last && straddle_eng.straddle_enable) ?
                          straddle_eng.calc_eop_offset(dw_keep) : 4'h0;
                tuser_full = tuser_codec.encode_rc_tuser(
                    .byte_en(byte_en), .is_sof_0(beat_idx == 0), .is_sof_1(1'b0),
                    .is_eof_0(is_last), .eof_offset_0(eof_off), .is_eof_1(1'b0),
                    .eof_offset_1(4'h0), .discontinue(1'b0), .tdata(tdata));
                tuser_truncated = tuser_full;
            end
            XILINX_CH_CQ: begin
                bit [3:0]   first_be, last_be;
                bit [63:0]  byte_en;
                bit [1:0]   tag_9_8;
                bit [374:0] tuser_full;
                bit [3:0]   eop_off;
                extract_be_from_tlp(tlp, first_be, last_be);
                tag_9_8 = tlp.tag[9:8];
                // PG213: byte_en marks valid payload bytes only (0 for MemRd);
                // CQ descriptor = 4 DW.
                byte_en = build_byte_en(beat_idx, dw_keep, tlp.has_data(),
                                        4, first_be, last_be, tlp.length);
                eop_off = (is_last && straddle_eng.straddle_enable) ?
                          straddle_eng.calc_eop_offset(dw_keep) : 4'h0;
                tuser_full = tuser_codec.encode_cq_tuser(
                    .first_be(beat_idx == 0 ? first_be : 4'h0),
                    .last_be (beat_idx == 0 ? last_be  : 4'h0),
                    .byte_en(byte_en), .sop(beat_idx == 0), .sop_1(1'b0),
                    .discontinue(1'b0), .tph_present(1'b0), .tph_type(2'h0),
                    .tph_st_tag(8'h0), .is_eop(is_last), .eop_offset(eop_off),
                    .is_eop_1(1'b0), .eop_offset_1(4'h0),
                    .tag_9_8(beat_idx == 0 ? tag_9_8 : 2'h0), .tdata(tdata));
                tuser_truncated = tuser_full;
            end
            XILINX_CH_CC: begin
                bit [160:0] tuser_full;
                bit [3:0]   eop_off;
                eop_off = (is_last && straddle_eng.straddle_enable) ?
                          straddle_eng.calc_eop_offset(dw_keep) : 4'h0;
                tuser_full = tuser_codec.encode_cc_tuser(
                    .discontinue(1'b0),
                    .sop(beat_idx == 0), .is_eop(is_last), .eop_ptr(eop_off),
                    .tdata(tdata));
                tuser_truncated = tuser_full;
            end
            default: begin
                `uvm_error(get_type_name(),
                    $sformatf("encode_tuser_for_beat: unknown channel %s", channel.name()))
                tuser_truncated = '0;
            end
        endcase
        return tuser_truncated;
    endfunction

    protected function void extract_be_from_tlp(pcie_tl_tlp tlp,
                                                output bit [3:0] first_be,
                                                output bit [3:0] last_be);
        pcie_tl_mem_tlp mem_tlp;
        pcie_tl_io_tlp  io_tlp;
        first_be = 4'hF;
        last_be  = 4'h0;
        if ($cast(mem_tlp, tlp)) begin
            first_be = mem_tlp.first_be;
            last_be  = mem_tlp.last_be;
        end else if ($cast(io_tlp, tlp)) begin
            first_be = io_tlp.first_be;
            last_be  = 4'h0;
        end
    endfunction

    //=========================================================================
    // ===== RX decode path (lifted from xilinx_pcie_monitor, checks omitted) =====
    //=========================================================================
    protected function pcie_tl_tlp decode_packet(axis_packet pkt,
                                                 xilinx_channel_e channel);
        bit [511:0]  beats[$];
        bit [15:0]   keeps[$];
        bit [127:0]  descriptor;
        bit [7:0]    payload[$];
        bit [7:0]    payload_arr[];
        bit [511:0]  first_tuser;
        bit [1:0]    tag_9_8;
        pcie_tl_tlp  tlp;

        if (pkt.beats.size() == 0) return null;
        first_tuser = pkt.beats[0].tuser;
        foreach (pkt.beats[i]) begin
            beats.push_back(pkt.beats[i].tdata);
            // PG213: tkeep 已为 per-DWORD，monitor 采样进 pkt.beats[i].tkeep 低位，
            // 直接取低 16 位 (最多 16 DW) 作为 per-DW keep。
            keeps.push_back(pkt.beats[i].tkeep[15:0]);
        end

        straddle_eng.unpack_single_tlp(beats, keeps, channel, descriptor, payload);
        payload_arr = new[payload.size()];
        foreach (payload[i]) payload_arr[i] = payload[i];

        tag_9_8 = extract_tag_9_8(first_tuser, channel);

        case (channel)
            XILINX_CH_RQ: tlp = xilinx_desc_codec::decode_rq(descriptor, payload_arr);
            XILINX_CH_RC: tlp = xilinx_desc_codec::decode_rc(descriptor[95:0], payload_arr);
            XILINX_CH_CQ: tlp = xilinx_desc_codec::decode_cq(descriptor, payload_arr);
            XILINX_CH_CC: tlp = xilinx_desc_codec::decode_cc(descriptor[95:0], payload_arr);
            default:      tlp = null;
        endcase

        if (tlp != null) begin
            tlp.tag[9:8] = tag_9_8;
            apply_tuser_be(tlp, first_tuser, channel);
        end
        return tlp;
    endfunction

    protected function bit [1:0] extract_tag_9_8(bit [511:0] tuser,
                                                 xilinx_channel_e channel);
        bit [1:0] tag_9_8 = 2'b00;
        case (channel)
            XILINX_CH_RQ: begin
                bit [3:0] fb, lb; bit [2:0] ao; bit dis, tp; bit [1:0] tt;
                bit [7:0] tst; bit [5:0] s0, s1;
                tuser_codec.decode_rq_tuser(.tuser(tuser[284:0]),
                    .first_be(fb), .last_be(lb), .addr_offset(ao),
                    .discontinue(dis), .tph_present(tp), .tph_type(tt),
                    .tph_st_tag(tst), .seq_num_0(s0), .seq_num_1(s1),
                    .tag_9_8(tag_9_8));
            end
            XILINX_CH_CQ: begin
                bit [3:0] fb, lb; bit [63:0] be; bit sop, sop1, dis, tp;
                bit [1:0] tt; bit [7:0] tst; bit eop, eop1; bit [3:0] eo, eo1;
                tuser_codec.decode_cq_tuser(.tuser(tuser[374:0]),
                    .first_be(fb), .last_be(lb), .byte_en(be), .sop(sop),
                    .sop_1(sop1), .discontinue(dis), .tph_present(tp),
                    .tph_type(tt), .tph_st_tag(tst), .is_eop(eop),
                    .eop_offset(eo), .is_eop_1(eop1), .eop_offset_1(eo1),
                    .tag_9_8(tag_9_8));
            end
            default: tag_9_8 = 2'b00;
        endcase
        return tag_9_8;
    endfunction

    // be_to_byte_offset: byte offset (0..3) within the first DW = index of the
    // lowest set bit of first_be. PG213/PCIe put the byte-level start of a
    // request in first_be, not in the DW-aligned descriptor address; used to
    // rebuild addr[1:0] on decode so downstream sees the exact byte address.
    protected function bit [1:0] be_to_byte_offset(bit [3:0] fb);
        casez (fb)
            4'b???1: return 2'd0;
            4'b??10: return 2'd1;
            4'b?100: return 2'd2;
            4'b1000: return 2'd3;
            default: return 2'd0;   // fb == 0 (e.g. zero-length): offset 0
        endcase
    endfunction

    protected function void apply_tuser_be(pcie_tl_tlp tlp, bit [511:0] tuser,
                                           xilinx_channel_e channel);
        pcie_tl_mem_tlp mem_tlp;
        pcie_tl_io_tlp  io_tlp;
        case (channel)
            XILINX_CH_RQ: begin
                bit [3:0] fb, lb; bit [2:0] ao; bit dis, tp; bit [1:0] tt;
                bit [7:0] tst; bit [5:0] s0, s1; bit [1:0] t98;
                tuser_codec.decode_rq_tuser(.tuser(tuser[284:0]),
                    .first_be(fb), .last_be(lb), .addr_offset(ao),
                    .discontinue(dis), .tph_present(tp), .tph_type(tt),
                    .tph_st_tag(tst), .seq_num_0(s0), .seq_num_1(s1),
                    .tag_9_8(t98));
                if ($cast(mem_tlp, tlp)) begin
                    mem_tlp.first_be = fb; mem_tlp.last_be = lb;
                    // restore byte offset lost by DW-aligned descriptor addr
                    // (PG213: header addr is DW-aligned, byte offset in first_be)
                    mem_tlp.addr[1:0] = be_to_byte_offset(fb);
                end else if ($cast(io_tlp, tlp)) begin
                    io_tlp.first_be = fb;
                    io_tlp.addr[1:0] = be_to_byte_offset(fb);
                end
            end
            XILINX_CH_CQ: begin
                bit [3:0] fb, lb; bit [63:0] be; bit sop, sop1, dis, tp;
                bit [1:0] tt; bit [7:0] tst; bit eop, eop1; bit [3:0] eo, eo1;
                bit [1:0] t98;
                tuser_codec.decode_cq_tuser(.tuser(tuser[374:0]),
                    .first_be(fb), .last_be(lb), .byte_en(be), .sop(sop),
                    .sop_1(sop1), .discontinue(dis), .tph_present(tp),
                    .tph_type(tt), .tph_st_tag(tst), .is_eop(eop),
                    .eop_offset(eo), .is_eop_1(eop1), .eop_offset_1(eo1),
                    .tag_9_8(t98));
                if ($cast(mem_tlp, tlp)) begin
                    mem_tlp.first_be = fb; mem_tlp.last_be = lb;
                    // restore byte offset lost by DW-aligned descriptor addr
                    // (PG213: header addr is DW-aligned, byte offset in first_be)
                    mem_tlp.addr[1:0] = be_to_byte_offset(fb);
                end else if ($cast(io_tlp, tlp)) begin
                    io_tlp.first_be = fb;
                    io_tlp.addr[1:0] = be_to_byte_offset(fb);
                end
            end
            default: ;
        endcase
    endfunction

endclass : xilinx_pcie_if_adapter
