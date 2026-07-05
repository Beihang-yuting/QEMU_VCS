class axis_master_driver #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_driver #(axis_transfer);

    `uvm_component_param_utils(axis_master_driver#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    vif_t vif;
    axis_config cfg;
    axis_bandwidth_controller bw_ctrl;
    bit in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        drive_reset_values();
        forever begin
            if (in_reset) begin
                drive_reset_values();
                @(posedge vif.aclk);
                continue;
            end
            seq_item_port.get_next_item(req);
            if (in_reset) begin
                seq_item_port.item_done();
                continue;
            end
            drive_transfer(req);
            seq_item_port.item_done();
        end
    endtask

    // Hold tvalid low until reset is truly released, then return aligned to a
    // master_cb edge. Steady-state (out of reset) the loop body never executes,
    // so back-to-back / zero-idle throughput is unaffected. Honors aresetn
    // directly so it is correct even when no env-level reset_handler is wired.
    protected task wait_reset_release();
        bit rst_active_level = (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) ? 1'b0 : 1'b1;
        while (in_reset || (vif.aresetn === rst_active_level)) begin
            vif.master_cb.tvalid <= 1'b0;
            @(vif.master_cb);
        end
    endtask

    protected task drive_transfer(axis_transfer tr);
        int unsigned idle_cycles;
        wait_reset_release();
        // tr may arrive mid-cycle (sequencer hands it over un-aligned to aclk).
        // Re-sync to a clocking edge before driving so the first assertion is not
        // missed. Only when starting from idle (tvalid low) — during back-to-back
        // tvalid is already high, so this is skipped and zero-idle throughput is
        // preserved (no bubble inserted between beats).
        if (vif.tvalid !== 1'b1) @(vif.master_cb);
        case (cfg.valid_gen_mode)
            VALID_WEIGHTED, VALID_BURST_PAUSE, VALID_PROFILE: begin
                while (!bw_ctrl.should_assert_valid()) begin
                    if (in_reset) return;
                    vif.master_cb.tvalid <= 1'b0;
                    @(vif.master_cb);
                end
            end
            default: begin
                idle_cycles = (tr.delay > 0) ? tr.delay : bw_ctrl.get_valid_idle_cycles();
                repeat (idle_cycles) begin
                    if (in_reset) return;
                    vif.master_cb.tvalid <= 1'b0;
                    @(vif.master_cb);
                end
            end
        endcase

        vif.master_cb.tvalid <= 1'b1;
        vif.master_cb.tdata  <= tr.tdata;
        if (cfg.HAS_TSTRB) vif.master_cb.tstrb <= tr.tstrb;
        if (cfg.HAS_TKEEP) vif.master_cb.tkeep <= tr.tkeep;
        if (cfg.HAS_TLAST) vif.master_cb.tlast <= tr.tlast;
        vif.master_cb.tid   <= tr.tid;
        vif.master_cb.tdest <= tr.tdest;
        vif.master_cb.tuser <= tr.tuser;

        @(vif.master_cb);
        while (!vif.master_cb.tready) begin
            if (in_reset) return;
            @(vif.master_cb);
        end
        vif.master_cb.tvalid <= 1'b0;
    endtask

    function void drive_reset_values();
        vif.master_cb.tvalid <= 1'b0;
        vif.master_cb.tdata  <= '0;
        vif.master_cb.tstrb  <= '0;
        vif.master_cb.tkeep  <= '0;
        vif.master_cb.tlast  <= 1'b0;
        vif.master_cb.tid    <= '0;
        vif.master_cb.tdest  <= '0;
        vif.master_cb.tuser  <= '0;
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
    endfunction

endclass
