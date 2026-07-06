//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Top-level Environment
//-----------------------------------------------------------------------------

class pcie_tl_env extends uvm_env;
    `uvm_component_utils(pcie_tl_env)

    //--- Configuration ---
    pcie_tl_env_config     cfg;

    //--- Agents ---
    pcie_tl_rc_agent       rc_agent;     // alias -> rc_agents[0]
    pcie_tl_ep_agent       ep_agent;

    //--- Per-root agents/managers/scoreboards (multi-USP). [0] aliases above. ---
    pcie_tl_rc_agent          rc_agents[];
    pcie_tl_if_adapter        rc_adapters[];
    pcie_tl_tag_manager       tag_mgrs[];
    pcie_tl_fc_manager        fc_mgrs[];
    pcie_tl_ordering_engine   ord_engs[];
    pcie_tl_cfg_space_manager cfg_mgrs[];
    pcie_tl_scoreboard        scbs[];

    //--- Shared components (codec/bw_shaper stay single/shared) ---
    pcie_tl_codec              codec;
    pcie_tl_fc_manager         fc_mgr;    // alias -> fc_mgrs[0]
    pcie_tl_tag_manager        tag_mgr;   // alias -> tag_mgrs[0]
    pcie_tl_ordering_engine    ord_eng;   // alias -> ord_engs[0]
    pcie_tl_cfg_space_manager  cfg_mgr;   // alias -> cfg_mgrs[0]
    pcie_tl_bw_shaper          bw_shaper;

    //--- Verification components ---
    pcie_tl_scoreboard         scb;       // alias -> scbs[0]
    pcie_tl_coverage_collector cov;

    //--- Adapters ---
    pcie_tl_if_adapter         rc_adapter;  // alias -> rc_adapters[0]
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

    //--- Unified Memory handles (host_mem_api base; populated from config_db when use_unified_mem=1) ---
    host_mem_api    host_mem;
    host_mem_api    dev_mem[16];

    function new(string name = "pcie_tl_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    //=========================================================================
    // Build Phase
    //=========================================================================
    function void build_phase(uvm_phase phase);
        int nu;
        super.build_phase(phase);

        // 1. Get or create config
        if (!uvm_config_db#(pcie_tl_env_config)::get(this, "", "cfg", cfg)) begin
            cfg = pcie_tl_env_config::type_id::create("cfg");
            `uvm_info("ENV", "No config found in config_db, using defaults", UVM_MEDIUM)
        end

        // 2pre. Switch enabled: init switch_cfg defaults FIRST so num_usp/dsp_owner
        //       are valid before per-root managers/agents are created below.
        if (cfg.switch_enable && cfg.switch_cfg != null)
            cfg.switch_cfg.init_defaults();

        // num_usp (number of roots). Non-switch / null cfg => 1 (alias path).
        nu = (cfg.switch_enable && cfg.switch_cfg != null) ? cfg.switch_cfg.num_usp : 1;

        // 2. Create shared components (codec/bw_shaper single; managers per-root below)
        codec     = pcie_tl_codec::type_id::create("codec");
        bw_shaper = pcie_tl_bw_shaper::type_id::create("bw_shaper", this);

        // 2b. Per-root managers + RC adapters (+ aliases assigned after the loop)
        tag_mgrs    = new[nu];
        fc_mgrs     = new[nu];
        ord_engs    = new[nu];
        cfg_mgrs    = new[nu];
        rc_adapters = new[nu];
        for (int r = 0; r < nu; r++) begin
            tag_mgrs[r] = pcie_tl_tag_manager::type_id::create($sformatf("tag_mgr_%0d", r));
            fc_mgrs[r]  = pcie_tl_fc_manager::type_id::create($sformatf("fc_mgr_%0d", r));
            ord_engs[r] = pcie_tl_ordering_engine::type_id::create($sformatf("ord_eng_%0d", r));
            cfg_mgrs[r] = pcie_tl_cfg_space_manager::type_id::create($sformatf("cfg_mgr_%0d", r));
            rc_adapters[r] = pcie_tl_if_adapter::type_id::create($sformatf("rc_adapter_%0d", r), this);
        end
        // Aliases -> [0] (back-compat for run_phase loopback + apply_config + connect)
        tag_mgr    = tag_mgrs[0];
        fc_mgr     = fc_mgrs[0];
        ord_eng    = ord_engs[0];
        cfg_mgr    = cfg_mgrs[0];
        rc_adapter = rc_adapters[0];

        // 3. Create EP adapter (single direct-mode EP path)
        ep_adapter = pcie_tl_if_adapter::type_id::create("ep_adapter", this);

        // 3b. Create link delay models
        rc2ep_delay = pcie_tl_link_delay_model::type_id::create("rc2ep_delay", this);
        ep2rc_delay = pcie_tl_link_delay_model::type_id::create("ep2rc_delay", this);

        // 4. Create RC agents (one per root). Alias rc_agent -> rc_agents[0].
        if (cfg.rc_agent_enable) begin
            rc_agents = new[nu];
            for (int r = 0; r < nu; r++) begin
                uvm_config_db#(uvm_active_passive_enum)::set(
                    this, $sformatf("rc_agent_%0d", r), "is_active", cfg.rc_is_active);
                rc_agents[r] = pcie_tl_rc_agent::type_id::create(
                    $sformatf("rc_agent_%0d", r), this);
            end
            rc_agent = rc_agents[0];
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
            // init_defaults() already called at top of build_phase (2pre).

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

        // 5. Create verification components (one scoreboard per root; alias scb -> scbs[0])
        if (cfg.scb_enable) begin
            scbs = new[nu];
            for (int r = 0; r < nu; r++)
                scbs[r] = pcie_tl_scoreboard::type_id::create($sformatf("scb_%0d", r), this);
            scb = scbs[0];
        end

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

        // 1. Inject shared components into RC agents (one per root, indexed managers/adapters)
        foreach (rc_agents[r]) begin
            if (rc_agents[r] == null) continue;
            rc_agents[r].fc_mgr    = fc_mgrs[r];
            rc_agents[r].tag_mgr   = tag_mgrs[r];
            rc_agents[r].ord_eng   = ord_engs[r];
            rc_agents[r].cfg_mgr   = cfg_mgrs[r];
            rc_agents[r].bw_shaper = bw_shaper;
            rc_agents[r].codec     = codec;
            rc_agents[r].adapter   = rc_adapters[r];
            rc_agents[r].inject_shared_components();
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
                ep_agent.ep_driver.use_unified_mem = cfg.use_unified_mem;
                // mem assignment deferred to unified-mem distribution block below
                if (cfg.sriov_enable && func_mgr_sriov != null) begin
                    ep_agent.func_manager = func_mgr_sriov;
                    ep_agent.ep_driver.func_manager = func_mgr_sriov;
                end
            end
        end

        // 2. Adapter codec injection (per-root RC adapter; single EP adapter)
        foreach (rc_adapters[r]) begin
            rc_adapters[r].codec  = codec;
            rc_adapters[r].fc_mgr = fc_mgrs[r];
        end
        ep_adapter.codec  = codec;
        ep_adapter.fc_mgr = fc_mgr;

        // 3. RC monitor -> per-root scoreboard + coverage; v_seqr per-root arrays
        foreach (rc_agents[r]) begin
            if (rc_agents[r] == null) continue;
            if (scbs.size() > r && scbs[r] != null)
                rc_agents[r].monitor.tlp_ap.connect(scbs[r].rc_imp);
            rc_agents[r].monitor.tlp_ap.connect(cov.analysis_export);
            v_seqr.rc_seqr_arr.push_back(rc_agents[r].sequencer);
        end
        if (rc_agents.size() > 0 && rc_agents[0] != null)
            v_seqr.rc_seqr = rc_agents[0].sequencer;

        // 4. Direct-mode EP monitor -> scb[0] + coverage (non-switch path)
        if (ep_agent != null && scb != null)
            ep_agent.monitor.tlp_ap.connect(scb.ep_imp);
        if (ep_agent != null) begin
            ep_agent.monitor.tlp_ap.connect(cov.analysis_export);
            v_seqr.ep_seqr_arr.push_back(ep_agent.sequencer);
            v_seqr.ep_seqr = ep_agent.sequencer;
        end

        // 5. Virtual sequencer shared refs (alias managers -> root 0)
        v_seqr.fc_mgr  = fc_mgr;
        v_seqr.tag_mgr = tag_mgr;

        // 6. Coverage shared component references
        cov.fc_mgr  = fc_mgr;
        cov.tag_mgr = tag_mgr;

        // 7. Switch mode wiring: each EP[i] uses the managers of its owning root,
        //    and its monitor feeds the owning root's scoreboard.
        if (cfg.switch_enable && sw != null) begin
            for (int i = 0; i < cfg.switch_cfg.num_ds_ports; i++) begin
                int owner = cfg.switch_cfg.dsp_owner[i];   // owning USP/root index
                ep_agents[i].fc_mgr    = sw.dsp[i].fc_mgr;
                ep_agents[i].tag_mgr   = tag_mgrs[owner];
                ep_agents[i].ord_eng   = ord_engs[owner];
                ep_agents[i].cfg_mgr   = cfg_mgrs[owner];
                ep_agents[i].bw_shaper = bw_shaper;
                ep_agents[i].codec     = codec;
                ep_agents[i].adapter   = ep_adapters[i];
                ep_agents[i].inject_shared_components();
                if (ep_agents[i].ep_driver != null) begin
                    ep_agents[i].ep_driver.mps_bytes        = int'(cfg.max_payload_size);
                    ep_agents[i].ep_driver.rcb_bytes        = int'(cfg.read_completion_boundary);
                    ep_agents[i].ep_driver.use_unified_mem  = cfg.use_unified_mem;
                    // mem handle assigned in unified-mem distribution block below
                    if (cfg.sriov_enable && func_mgr_sriov != null)
                        ep_agents[i].ep_driver.func_manager = func_mgr_sriov;
                end
                ep_adapters[i].mode   = cfg.if_mode;
                ep_adapters[i].codec  = codec;
                ep_adapters[i].fc_mgr = sw.dsp[i].fc_mgr;

                // EP[i] monitor -> owning root's scoreboard + coverage; v_seqr ep arr
                if (scbs.size() > owner && scbs[owner] != null)
                    ep_agents[i].monitor.tlp_ap.connect(scbs[owner].ep_imp);
                ep_agents[i].monitor.tlp_ap.connect(cov.analysis_export);
                v_seqr.ep_seqr_arr.push_back(ep_agents[i].sequencer);
            end
        end

        // 8. Completion timeout (per-root RC drivers)
        foreach (rc_agents[r])
            if (rc_agents[r] != null && rc_agents[r].rc_driver != null)
                rc_agents[r].rc_driver.cpl_timeout_ns = cfg.cpl_timeout_ns;

        // 9. RC driver scalar injection (per-root)
        foreach (rc_agents[r]) begin
            if (rc_agents[r] == null || rc_agents[r].rc_driver == null) continue;
            rc_agents[r].rc_driver.mps_bytes       = int'(cfg.max_payload_size);
            rc_agents[r].rc_driver.rcb_bytes       = int'(cfg.read_completion_boundary);
            rc_agents[r].rc_driver.use_unified_mem = cfg.use_unified_mem;
        end

        // 10. Unified-memory distribution: correct per-agent handles from config_db
        //     Gated by use_unified_mem (default 0) — OFF path leaves mem=null (unchanged)
        if (cfg.use_unified_mem) begin
            int nep;
            nep = (cfg.switch_enable && cfg.switch_cfg != null)
                  ? cfg.switch_cfg.num_ds_ports : 1;

            // RC ← host_mem
            if (uvm_config_db#(host_mem_api)::get(this, "", "host_mem", host_mem)) begin
                host_mem.init_region(64'h0, 64'hFFFF_FFFF,
                                     cfg.mem_alloc_mode, cfg.mem_granule);
                if (cfg.mem_access_mode == PCIE_TL_MEM_PREMAP)
                    void'(host_mem.alloc(cfg.premap_size, cfg.mem_granule));
                if (rc_agent != null && rc_agent.rc_driver != null)
                    rc_agent.rc_driver.mem = host_mem;
            end

            // EP[i] ← dev_mem[i]
            for (int i = 0; i < nep; i++) begin
                host_mem_api dm;
                if (uvm_config_db#(host_mem_api)::get(this, "",
                                                       $sformatf("dev_mem_%0d", i), dm)) begin
                    dm.init_region(64'h0, 64'hFFFF_FFFF,
                                   cfg.mem_alloc_mode, cfg.mem_granule);
                    if (cfg.mem_access_mode == PCIE_TL_MEM_PREMAP)
                        void'(dm.alloc(cfg.premap_size, cfg.mem_granule));
                    dev_mem[i] = dm;
                    if (cfg.switch_enable) begin
                        if (ep_agents[i] != null && ep_agents[i].ep_driver != null)
                            ep_agents[i].ep_driver.mem = dm;
                    end else if (i == 0) begin
                        if (ep_agent != null && ep_agent.ep_driver != null)
                            ep_agent.ep_driver.mem = dm;
                    end
                end
            end
        end
    endfunction

    //=========================================================================
    // Run Phase: TLM loopback bridge
    //=========================================================================
    task run_phase(uvm_phase phase);
        if (cfg.if_mode == TLM_MODE && rc_agent != null) begin
            if (cfg.switch_enable && sw != null) begin
                // Switch mode: RC[r] <-> Switch <-> EP[N]
                fork
                    for (int r = 0; r < rc_agents.size(); r++) begin
                        automatic int rr = r;
                        fork
                            rc_to_switch_loopback(rr);
                            switch_to_rc_loopback(rr);
                        join_none
                    end
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
            // RC auto-response for EP-originated requests.
            // Unified-memory path: handle MRd/MRdLk/Atomic AND posted MWr (the posted-MWr
            // gap fix: MWr is not requires_completion() so the old branch silently dropped it).
            // Legacy path: rc_auto_respond for requires_completion() only (unchanged).
            else if (cfg.use_unified_mem && rc_agent != null && rc_agent.rc_driver != null &&
                     (tlp.requires_completion() || tlp.kind == TLP_MEM_WR)) begin
                // Register in scoreboard only for non-posted (completion will be matched)
                if (scb != null && tlp.requires_completion())
                    scb.register_pending(tlp);
                fork
                    begin
                        pcie_tl_tlp req_copy = tlp;
                        rc_agent.rc_driver.handle_request(req_copy);
                    end
                join_none
            end else if (tlp.requires_completion()) begin
                // Legacy (non-unified) path: rc_auto_respond for EP DMA reads
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

    // RC[r] tx -> Switch USP[r] rx
    protected task rc_to_switch_loopback(int r);
        pcie_tl_tlp tlp;
        forever begin
            rc_adapters[r].tlm_tx_fifo.get(tlp);
            if (scbs[r] != null && tlp.requires_completion())
                scbs[r].register_pending(tlp);
            replenish_credits(tlp);  // Return RC-side FC credits (TLP delivered to switch)
            sw.usps[r].rx_fifo.put(tlp);
        end
    endtask

    // Switch USP[r] tx -> RC[r] rx
    protected task switch_to_rc_loopback(int r);
        pcie_tl_tlp tlp;
        forever begin
            sw.usps[r].tx_fifo.get(tlp);
            rc_adapters[r].tlm_rx_fifo.put(tlp);
            replenish_credits(tlp);
            if (tlp.get_category() == TLP_CAT_COMPLETION) begin
                if (scbs[r] != null)
                    scbs[r].write_rc(tlp);
                if (rc_agents[r].rc_driver != null) begin
                    pcie_tl_cpl_tlp cpl;
                    if ($cast(cpl, tlp))
                        void'(rc_agents[r].rc_driver.handle_completion(cpl));
                end
            end
            // Unified-memory path: route EP->host memory requests to RC responder.
            // Gated by use_unified_mem (default 0) — legacy/OFF behavior is unchanged.
            else if (cfg.use_unified_mem && rc_agents[r] != null && rc_agents[r].rc_driver != null &&
                     (tlp.kind inside {TLP_MEM_WR, TLP_MEM_RD, TLP_MEM_RD_LK,
                                       TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS})) begin
                if (scbs[r] != null && tlp.requires_completion())
                    scbs[r].register_pending(tlp);
                fork
                    begin pcie_tl_tlp req_copy = tlp; rc_agents[r].rc_driver.handle_request(req_copy); end
                join_none
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
        // FC (per-root)
        foreach (fc_mgrs[r]) begin
            fc_mgrs[r].fc_enable       = cfg.fc_enable;
            fc_mgrs[r].infinite_credit = cfg.infinite_credit;
            fc_mgrs[r].init_credits(cfg.init_ph_credit, cfg.init_pd_credit,
                                    cfg.init_nph_credit, cfg.init_npd_credit,
                                    cfg.init_cplh_credit, cfg.init_cpld_credit);
        end

        // BW Shaper (shared)
        bw_shaper.shaper_enable = cfg.shaper_enable;
        bw_shaper.avg_rate      = cfg.avg_rate;
        bw_shaper.burst_size    = cfg.burst_size;

        // Tag (per-root)
        foreach (tag_mgrs[r]) begin
            tag_mgrs[r].extended_tag_enable = cfg.extended_tag_enable;
            tag_mgrs[r].phantom_func_enable = cfg.phantom_func_enable;
            tag_mgrs[r].max_outstanding     = cfg.max_outstanding;
            tag_mgrs[r].init_pool(0, cfg.extended_tag_enable, cfg.phantom_func_enable);
        end

        // Ordering (per-root)
        foreach (ord_engs[r]) begin
            ord_engs[r].relaxed_ordering_enable  = cfg.relaxed_ordering_enable;
            ord_engs[r].id_based_ordering_enable = cfg.id_based_ordering_enable;
            ord_engs[r].bypass_ordering          = cfg.bypass_ordering;
        end

        // Coverage
        cov.cov_enable          = cfg.cov_enable;
        cov.tlp_basic_enable    = cfg.tlp_basic_cov;
        cov.fc_state_enable     = cfg.fc_state_cov;
        cov.tag_usage_enable    = cfg.tag_usage_cov;
        cov.ordering_enable     = cfg.ordering_cov;
        cov.error_inject_enable = cfg.error_inject_cov;
        cov.sriov_enable      = cfg.sriov_enable;
        cov.prefix_cov_enable = cfg.prefix_enable;

        // Scoreboard (per-root)
        foreach (scbs[r]) begin
            if (scbs[r] == null) continue;
            scbs[r].ordering_check_enable   = cfg.ordering_check_enable;
            scbs[r].completion_check_enable = cfg.completion_check_enable;
            scbs[r].data_integrity_enable   = cfg.data_integrity_enable;
            scbs[r].prefix_check_enable     = cfg.prefix_enable;
            scbs[r].strict_check            = cfg.scb_strict_check;
        end

        // Adapter mode (per-root RC; single EP)
        foreach (rc_adapters[r])
            rc_adapters[r].mode = cfg.if_mode;
        ep_adapter.mode = cfg.if_mode;

        // Config space init (per-root)
        foreach (cfg_mgrs[r]) begin
            cfg_mgrs[r].init_type0_header();
            cfg_mgrs[r].init_pcie_capability(8'h40, cfg.max_payload_size, cfg.max_read_request_size, cfg.read_completion_boundary);
        end

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
