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

        // 4. Create agents
        if (cfg.rc_agent_enable) begin
            uvm_config_db#(uvm_active_passive_enum)::set(this, "rc_agent", "is_active", cfg.rc_is_active);
            rc_agent = pcie_tl_rc_agent::type_id::create("rc_agent", this);
        end

        if (cfg.ep_agent_enable) begin
            uvm_config_db#(uvm_active_passive_enum)::set(this, "ep_agent", "is_active", cfg.ep_is_active);
            ep_agent = pcie_tl_ep_agent::type_id::create("ep_agent", this);
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
    endfunction

    //=========================================================================
    // Run Phase: TLM loopback bridge
    //=========================================================================
    task run_phase(uvm_phase phase);
        if (cfg.if_mode == TLM_MODE && rc_agent != null && ep_agent != null) begin
            fork
                tlm_loopback_rc_to_ep();
                tlm_loopback_ep_to_rc();
            join_none
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
            ep_adapter.tlm_rx_fifo.put(tlp);
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
            rc_adapter.tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION && rc_agent.rc_driver != null) begin
                pcie_tl_cpl_tlp cpl;
                if ($cast(cpl, tlp)) begin
                    void'(rc_agent.rc_driver.handle_completion(cpl));
                end
            end
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

        // Scoreboard
        if (scb != null) begin
            scb.ordering_check_enable   = cfg.ordering_check_enable;
            scb.completion_check_enable = cfg.completion_check_enable;
            scb.data_integrity_enable   = cfg.data_integrity_enable;
        end

        // Adapter mode
        rc_adapter.mode = cfg.if_mode;
        ep_adapter.mode = cfg.if_mode;

        // Config space init
        cfg_mgr.init_type0_header();
        cfg_mgr.init_pcie_capability(8'h40, cfg.max_payload_size, cfg.max_read_request_size, cfg.read_completion_boundary);
    endfunction

endclass
