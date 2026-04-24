//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Top-level Environment
//-----------------------------------------------------------------------------

class pcie_tl_env extends uvm_env;
    `uvm_component_utils(pcie_tl_env)

    //--- Configuration ---
    pcie_tl_env_config     cfg;

    //--- Agents ---
    pcie_tl_rc_agent       rc_agent;
    pcie_tl_ep_agent       ep_agent;

    //--- Shared components ---
    pcie_tl_codec              codec;
    pcie_tl_fc_manager         fc_mgr;
    pcie_tl_tag_manager        tag_mgr;
    pcie_tl_ordering_engine    ord_eng;
    pcie_tl_cfg_space_manager  cfg_mgr;
    pcie_tl_bw_shaper          bw_shaper;

    //--- Verification components ---
    pcie_tl_scoreboard         scb;
    pcie_tl_coverage_collector cov;

    //--- Adapters ---
    pcie_tl_if_adapter         rc_adapter;
    pcie_tl_if_adapter         ep_adapter;

    //--- Link Delay Models ---
    pcie_tl_link_delay_model   rc2ep_delay;
    pcie_tl_link_delay_model   ep2rc_delay;

    //--- Multi-EP (switch mode) ---
    pcie_tl_switch         sw;
    pcie_tl_ep_agent       ep_agents[];
    pcie_tl_if_adapter     ep_adapters[];

    //--- Function Manager (SR-IOV) ---
    pcie_tl_func_manager   func_mgr_sriov;

    //--- Virtual Sequencer ---
    pcie_tl_virtual_sequencer  v_seqr;

    function new(string name = "pcie_tl_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //=========================================================================
    // Build Phase
    //=========================================================================
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // 1. Get or create config
        if (!uvm_config_db#(pcie_tl_env_config)::get(this, "", "cfg", cfg)) begin
            cfg = pcie_tl_env_config::type_id::create("cfg");
            `uvm_info("ENV", "No config found in config_db, using defaults", UVM_MEDIUM)
        end

        // 2. Create shared components
        codec     = pcie_tl_codec::type_id::create("codec");
        fc_mgr    = pcie_tl_fc_manager::type_id::create("fc_mgr");
        tag_mgr   = pcie_tl_tag_manager::type_id::create("tag_mgr");
        ord_eng   = pcie_tl_ordering_engine::type_id::create("ord_eng");
        cfg_mgr   = pcie_tl_cfg_space_manager::type_id::create("cfg_mgr");
        bw_shaper = pcie_tl_bw_shaper::type_id::create("bw_shaper", this);

        // 3. Create adapters
        rc_adapter = pcie_tl_if_adapter::type_id::create("rc_adapter", this);
        ep_adapter = pcie_tl_if_adapter::type_id::create("ep_adapter", this);

        // 3b. Create link delay models
        rc2ep_delay = pcie_tl_link_delay_model::type_id::create("rc2ep_delay", this);
        ep2rc_delay = pcie_tl_link_delay_model::type_id::create("ep2rc_delay", this);

        // 4. Create agents
        if (cfg.rc_agent_enable) begin
            uvm_config_db#(uvm_active_passive_enum)::set(this, "rc_agent", "is_active", cfg.rc_is_active);
            rc_agent = pcie_tl_rc_agent::type_id::create("rc_agent", this);
        end

        if (cfg.ep_agent_enable) begin
            uvm_config_db#(uvm_active_passive_enum)::set(this, "ep_agent", "is_active", cfg.ep_is_active);
            ep_agent = pcie_tl_ep_agent::type_id::create("ep_agent", this);
        end

        // 4c. SR-IOV mode: create function manager
        if (cfg.sriov_enable) begin
            func_mgr_sriov = pcie_tl_func_manager::type_id::create("func_mgr_sriov");
            func_mgr_sriov.build(cfg.num_pfs, cfg.max_vfs_per_pf,
                                  cfg.pf_vendor_id, cfg.pf_device_id, cfg.vf_device_id);
            if (cfg.default_num_vfs > 0) begin
                for (int pf = 0; pf < cfg.num_pfs; pf++)
                    func_mgr_sriov.enable_vfs(pf, cfg.default_num_vfs);
            end
        end

        // 4b. Switch mode: create switch + N EP agents
        if (cfg.switch_enable && cfg.switch_cfg != null) begin
            int n = cfg.switch_cfg.num_ds_ports;
            cfg.switch_cfg.init_defaults();

            sw = pcie_tl_switch::type_id::create("sw", this);
            sw.sw_cfg = cfg.switch_cfg;

            ep_agents  = new[n];
            ep_adapters = new[n];
            for (int i = 0; i < n; i++) begin
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("ep_agent_%0d", i), "is_active", cfg.ep_is_active);
                ep_agents[i]  = pcie_tl_ep_agent::type_id::create(
                    $sformatf("ep_agent_%0d", i), this);
                ep_adapters[i] = pcie_tl_if_adapter::type_id::create(
                    $sformatf("ep_adapter_%0d", i), this);
            end
        end

        // 5. Create verification components
        if (cfg.scb_enable)
            scb = pcie_tl_scoreboard::type_id::create("scb", this);

        cov = pcie_tl_coverage_collector::type_id::create("cov", this);

        // 6. Virtual sequencer
        v_seqr = pcie_tl_virtual_sequencer::type_id::create("v_seqr", this);

        // 7. Apply configuration
        apply_config();
    endfunction

    //=========================================================================
    // Connect Phase
    //=========================================================================
    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // 1. Inject shared components into agents
        if (rc_agent != null) begin
            rc_agent.fc_mgr    = fc_mgr;
            rc_agent.tag_mgr   = tag_mgr;
            rc_agent.ord_eng   = ord_eng;
            rc_agent.cfg_mgr   = cfg_mgr;
            rc_agent.bw_shaper = bw_shaper;
            rc_agent.codec     = codec;
            rc_agent.adapter   = rc_adapter;
            rc_agent.inject_shared_components();
        end

        if (ep_agent != null) begin
            ep_agent.fc_mgr    = fc_mgr;
            ep_agent.tag_mgr   = tag_mgr;
            ep_agent.ord_eng   = ord_eng;
            ep_agent.cfg_mgr   = cfg_mgr;
            ep_agent.bw_shaper = bw_shaper;
            ep_agent.codec     = codec;
            ep_agent.adapter   = ep_adapter;
            ep_agent.inject_shared_components();
            if (ep_agent.ep_driver != null) begin
                ep_agent.ep_driver.mps_bytes = int'(cfg.max_payload_size);
                ep_agent.ep_driver.rcb_bytes = int'(cfg.read_completion_boundary);
                if (cfg.sriov_enable && func_mgr_sriov != null) begin
                    ep_agent.func_manager = func_mgr_sriov;
                    ep_agent.ep_driver.func_manager = func_mgr_sriov;
                end
            end
        end

        // 2. Adapter codec injection
        rc_adapter.codec  = codec;
        rc_adapter.fc_mgr = fc_mgr;
        ep_adapter.codec  = codec;
        ep_adapter.fc_mgr = fc_mgr;

        // 3. Monitor -> Scoreboard
        if (rc_agent != null && scb != null)
            rc_agent.monitor.tlp_ap.connect(scb.rc_imp);
        if (ep_agent != null && scb != null)
            ep_agent.monitor.tlp_ap.connect(scb.ep_imp);

        // 4. Monitor -> Coverage
        if (rc_agent != null)
            rc_agent.monitor.tlp_ap.connect(cov.analysis_export);
        if (ep_agent != null)
            ep_agent.monitor.tlp_ap.connect(cov.analysis_export);

        // 5. Virtual sequencer bindings
        if (rc_agent != null)
            v_seqr.rc_seqr = rc_agent.sequencer;
        if (ep_agent != null)
            v_seqr.ep_seqr = ep_agent.sequencer;
        v_seqr.fc_mgr  = fc_mgr;
        v_seqr.tag_mgr = tag_mgr;

        // 6. Coverage shared component references
        cov.fc_mgr  = fc_mgr;
        cov.tag_mgr = tag_mgr;

        // 7. Switch mode wiring
        if (cfg.switch_enable && sw != null) begin
            for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                ep_agents[i].fc_mgr    = sw.dsp[i].fc_mgr;
                ep_agents[i].tag_mgr   = tag_mgr;
                ep_agents[i].ord_eng   = ord_eng;
                ep_agents[i].cfg_mgr   = cfg_mgr;
                ep_agents[i].bw_shaper = bw_shaper;
                ep_agents[i].codec     = codec;
                ep_agents[i].adapter   = ep_adapters[i];
                ep_agents[i].inject_shared_components();
                if (ep_agents[i].ep_driver != null) begin
                    ep_agents[i].ep_driver.mps_bytes = int'(cfg.max_payload_size);
                    ep_agents[i].ep_driver.rcb_bytes = int'(cfg.read_completion_boundary);
                    if (cfg.sriov_enable && func_mgr_sriov != null)
                        ep_agents[i].ep_driver.func_manager = func_mgr_sriov;
                end
                ep_adapters[i].mode   = cfg.if_mode;
                ep_adapters[i].codec  = codec;
                ep_adapters[i].fc_mgr = sw.dsp[i].fc_mgr;
            end
        end

        // 8. Completion timeout
        if (rc_agent != null && rc_agent.rc_driver != null)
            rc_agent.rc_driver.cpl_timeout_ns = cfg.cpl_timeout_ns;
    endfunction

    //=========================================================================
    // Run Phase: TLM loopback bridge
    //=========================================================================
    task run_phase(uvm_phase phase);
        if (cfg.if_mode == TLM_MODE && rc_agent != null) begin
            if (cfg.switch_enable && sw != null) begin
                // Switch mode: RC <-> Switch <-> EP[N]
                fork
                    rc_to_switch_loopback();
                    switch_to_rc_loopback();
                    for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                        automatic int idx = i;
                        fork
                            switch_to_ep_loopback(idx);
                            ep_to_switch_loopback(idx);
                        join_none
                    end
                join_none
            end else if (ep_agent != null) begin
                // Direct mode: RC <-> EP (existing)
                fork
                    tlm_loopback_rc_to_ep();
                    tlm_loopback_ep_to_rc();
                join_none
            end
        end
    endtask

    //=========================================================================
    // TLM Loopback: RC tx -> EP rx, then EP auto-responds
    //=========================================================================
    protected task tlm_loopback_rc_to_ep();
        pcie_tl_tlp tlp;
        forever begin
            rc_adapter.tlm_tx_fifo.get(tlp);
            `uvm_info("ENV_LOOP", $sformatf("RC->EP: %s", tlp.convert2string()), UVM_HIGH)

            // Register non-posted requests in scoreboard IMMEDIATELY (before delay)
            // so completions can match even if they arrive before the EP monitor sees the request
            if (scb != null && tlp.requires_completion())
                scb.register_pending(tlp);

            rc2ep_delay.forward(tlp, ep_adapter.tlm_rx_fifo);
            replenish_credits(tlp);
            if (cfg.ep_auto_response && ep_agent.ep_driver != null) begin
                fork
                    begin
                        pcie_tl_tlp tlp_copy = tlp;
                        ep_agent.ep_driver.handle_request(tlp_copy);
                    end
                join_none
            end
        end
    endtask

    //=========================================================================
    // TLM Loopback: EP tx -> RC rx (completions and DMA)
    //=========================================================================
    protected task tlm_loopback_ep_to_rc();
        pcie_tl_tlp tlp;
        forever begin
            ep_adapter.tlm_tx_fifo.get(tlp);
            `uvm_info("ENV_LOOP", $sformatf("EP->RC: %s", tlp.convert2string()), UVM_HIGH)
            ep2rc_delay.forward(tlp, rc_adapter.tlm_rx_fifo);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                // Write completion to scoreboard IMMEDIATELY (before tag is freed/reused)
                if (scb != null)
                    scb.write_rc(tlp);
                // Then handle in RC driver (may free tag)
                if (rc_agent.rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agent.rc_driver.handle_completion(cpl));
                end
            end
            // RC auto-response for EP-originated non-posted requests (DMA reads)
            // Symmetric to EP auto-response in tlm_loopback_rc_to_ep
            else if (tlp.requires_completion()) begin
                // Register in scoreboard for completion matching (before delay/tag reuse)
                if (scb != null)
                    scb.register_pending(tlp);
                fork
                    begin
                        pcie_tl_tlp req_copy = tlp;
                        rc_auto_respond(req_copy);
                    end
                join_none
            end
        end
    endtask

    //=========================================================================
    // RC auto-response: generate completion for EP DMA reads
    //=========================================================================
    protected task rc_auto_respond(pcie_tl_tlp req);
        pcie_tl_mem_tlp mem_req;
        pcie_tl_cpl_tlp cpl;
        int total_bytes, chunk, remaining, cpl_idx, received;
        bit [63:0] cur_addr;
        int mps_bytes, rcb_bytes;

        if (!$cast(mem_req, req)) return;
        if (req.kind != TLP_MEM_RD && req.kind != TLP_MEM_RD_LK) return;

        // Free EP's tag IMMEDIATELY so it can be reused
        // (scoreboard tracks via pending_requests independently of tag_mgr)
        tag_mgr.free_tag(req.tag, req.requester_id[2:0]);

        mps_bytes = int'(cfg.max_payload_size);
        rcb_bytes = int'(cfg.read_completion_boundary);
        total_bytes = (req.length == 0) ? 4096 : req.length * 4;
        remaining   = total_bytes;
        cur_addr    = mem_req.addr;
        cpl_idx     = 0;
        received    = 0;

        while (remaining > 0) begin
            int bytes_to_rcb, len_dw;

            if (cpl_idx == 0) begin
                bytes_to_rcb = rcb_bytes - (cur_addr % rcb_bytes);
                if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
                chunk = (bytes_to_rcb < mps_bytes) ? bytes_to_rcb : mps_bytes;
            end else begin
                chunk = mps_bytes;
            end
            if (chunk > remaining) chunk = remaining;
            len_dw = (chunk + 3) / 4;

            cpl = pcie_tl_cpl_tlp::type_id::create("rc_auto_cpl");
            cpl.kind         = TLP_CPLD;
            cpl.fmt          = FMT_3DW_WITH_DATA;
            cpl.type_f       = TLP_TYPE_CPL;
            cpl.tc           = req.tc;
            cpl.attr         = req.attr;
            cpl.length       = (len_dw == 1024) ? 0 : len_dw[9:0];
            cpl.requester_id = req.requester_id;
            cpl.tag          = req.tag;
            cpl.completer_id = 16'h0000;  // RC BDF
            cpl.cpl_status   = CPL_STATUS_SC;
            cpl.bcm          = 0;
            cpl.byte_count   = remaining[11:0];
            cpl.lower_addr   = cur_addr[6:0];
            cpl.payload      = new[chunk];
            foreach (cpl.payload[i])
                cpl.payload[i] = 8'hAA;  // Fill pattern

            // Write to scoreboard directly (avoids tag-reuse race through delay path)
            if (scb != null)
                scb.write_ep(cpl);

            cur_addr  += chunk;
            remaining -= chunk;
            received  += chunk;
            cpl_idx++;
        end
    endtask

    //=========================================================================
    // Switch Mode Loopback Tasks
    //=========================================================================

    // RC tx -> Switch USP rx
    protected task rc_to_switch_loopback();
        pcie_tl_tlp tlp;
        forever begin
            rc_adapter.tlm_tx_fifo.get(tlp);
            if (scb != null && tlp.requires_completion())
                scb.register_pending(tlp);
            replenish_credits(tlp);  // Return RC-side FC credits (TLP delivered to switch)
            sw.usp.rx_fifo.put(tlp);
        end
    endtask

    // Switch USP tx -> RC rx
    protected task switch_to_rc_loopback();
        pcie_tl_tlp tlp;
        forever begin
            sw.usp.tx_fifo.get(tlp);
            rc_adapter.tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                if (scb != null)
                    scb.write_rc(tlp);
                if (rc_agent.rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agent.rc_driver.handle_completion(cpl));
                end
            end
        end
    endtask

    // Switch DSP[i] tx -> EP[i] rx (+ EP auto-response)
    protected task switch_to_ep_loopback(int idx);
        pcie_tl_tlp tlp;
        forever begin
            sw.dsp[idx].tx_fifo.get(tlp);
            ep_adapters[idx].tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (cfg.ep_auto_response && ep_agents[idx].ep_driver != null) begin
                if (tlp.kind inside {TLP_MEM_RD, TLP_MEM_RD_LK, TLP_MEM_WR,
                                     TLP_CFG_RD0, TLP_CFG_WR0, TLP_IO_RD, TLP_IO_WR}) begin
                    fork
                        begin
                            automatic pcie_tl_tlp t = tlp;
                            automatic int i = idx;
                            ep_agents[i].ep_driver.handle_request(t);
                        end
                    join_none
                end
            end
        end
    endtask

    // EP[i] tx -> Switch DSP[i] rx
    protected task ep_to_switch_loopback(int idx);
        pcie_tl_tlp tlp;
        forever begin
            ep_adapters[idx].tlm_tx_fifo.get(tlp);
            // Replenish EP's per-port FC credits (TLP delivered to switch)
            replenish_port_credits(sw.dsp[idx].fc_mgr, tlp);
            sw.dsp[idx].rx_fifo.put(tlp);
        end
    endtask

    //=========================================================================
    // Replenish FC credits after TLP delivery (TLM mode only)
    //=========================================================================
    protected function void replenish_credits(pcie_tl_tlp tlp);
        int data_credits;
        if (!cfg.fc_enable || cfg.infinite_credit) return;
        data_credits = tlp.get_data_credits();
        case (tlp.get_category())
            TLP_CAT_POSTED: begin
                fc_mgr.return_credit(FC_POSTED_HDR, 1);
                fc_mgr.return_credit(FC_POSTED_DATA, data_credits);
            end
            TLP_CAT_NON_POSTED: begin
                fc_mgr.return_credit(FC_NONPOSTED_HDR, 1);
                fc_mgr.return_credit(FC_NONPOSTED_DATA, data_credits);
            end
            TLP_CAT_COMPLETION: begin
                fc_mgr.return_credit(FC_CPL_HDR, 1);
                fc_mgr.return_credit(FC_CPL_DATA, data_credits);
            end
        endcase
    endfunction

    //=========================================================================
    // Replenish per-port FC credits (for switch mode)
    //=========================================================================
    protected function void replenish_port_credits(pcie_tl_fc_manager port_fc, pcie_tl_tlp tlp);
        int data_credits;
        if (!port_fc.fc_enable || port_fc.infinite_credit) return;
        data_credits = tlp.get_data_credits();
        case (tlp.get_category())
            TLP_CAT_POSTED: begin
                port_fc.return_credit(FC_POSTED_HDR, 1);
                port_fc.return_credit(FC_POSTED_DATA, data_credits);
            end
            TLP_CAT_NON_POSTED: begin
                port_fc.return_credit(FC_NONPOSTED_HDR, 1);
                port_fc.return_credit(FC_NONPOSTED_DATA, data_credits);
            end
            TLP_CAT_COMPLETION: begin
                port_fc.return_credit(FC_CPL_HDR, 1);
                port_fc.return_credit(FC_CPL_DATA, data_credits);
            end
        endcase
    endfunction

    //=========================================================================
    // Apply configuration to all components
    //=========================================================================
    function void apply_config();
        // FC
        fc_mgr.fc_enable       = cfg.fc_enable;
        fc_mgr.infinite_credit = cfg.infinite_credit;
        fc_mgr.init_credits(cfg.init_ph_credit, cfg.init_pd_credit,
                            cfg.init_nph_credit, cfg.init_npd_credit,
                            cfg.init_cplh_credit, cfg.init_cpld_credit);

        // BW Shaper
        bw_shaper.shaper_enable = cfg.shaper_enable;
        bw_shaper.avg_rate      = cfg.avg_rate;
        bw_shaper.burst_size    = cfg.burst_size;

        // Tag
        tag_mgr.extended_tag_enable = cfg.extended_tag_enable;
        tag_mgr.phantom_func_enable = cfg.phantom_func_enable;
        tag_mgr.max_outstanding     = cfg.max_outstanding;
        tag_mgr.init_pool(0, cfg.extended_tag_enable, cfg.phantom_func_enable);

        // Ordering
        ord_eng.relaxed_ordering_enable  = cfg.relaxed_ordering_enable;
        ord_eng.id_based_ordering_enable = cfg.id_based_ordering_enable;
        ord_eng.bypass_ordering          = cfg.bypass_ordering;

        // Coverage
        cov.cov_enable          = cfg.cov_enable;
        cov.tlp_basic_enable    = cfg.tlp_basic_cov;
        cov.fc_state_enable     = cfg.fc_state_cov;
        cov.tag_usage_enable    = cfg.tag_usage_cov;
        cov.ordering_enable     = cfg.ordering_cov;
        cov.error_inject_enable = cfg.error_inject_cov;
        cov.sriov_enable      = cfg.sriov_enable;
        cov.prefix_cov_enable = cfg.prefix_enable;

        // Scoreboard
        if (scb != null) begin
            scb.ordering_check_enable   = cfg.ordering_check_enable;
            scb.completion_check_enable = cfg.completion_check_enable;
            scb.data_integrity_enable   = cfg.data_integrity_enable;
            scb.prefix_check_enable = cfg.prefix_enable;
        end

        // Adapter mode
        rc_adapter.mode = cfg.if_mode;
        ep_adapter.mode = cfg.if_mode;

        // Config space init
        cfg_mgr.init_type0_header();
        cfg_mgr.init_pcie_capability(8'h40, cfg.max_payload_size, cfg.max_read_request_size, cfg.read_completion_boundary);

        // Link Delay
        rc2ep_delay.enable          = cfg.link_delay_enable;
        rc2ep_delay.latency_min_ns  = cfg.rc2ep_latency_min_ns;
        rc2ep_delay.latency_max_ns  = cfg.rc2ep_latency_max_ns;
        rc2ep_delay.update_interval = cfg.link_delay_update_interval;

        ep2rc_delay.enable          = cfg.link_delay_enable;
        ep2rc_delay.latency_min_ns  = cfg.ep2rc_latency_min_ns;
        ep2rc_delay.latency_max_ns  = cfg.ep2rc_latency_max_ns;
        ep2rc_delay.update_interval = cfg.link_delay_update_interval;

    endfunction

endclass
