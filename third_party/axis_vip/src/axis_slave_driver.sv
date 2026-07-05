class axis_slave_driver #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_driver #(axis_transfer);

    `uvm_component_param_utils(axis_slave_driver#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    vif_t vif;
    axis_config cfg;
    axis_bandwidth_controller bw_ctrl;
    bit in_reset = 0;

    protected bit valid_seen = 0;
    protected int unsigned delay_counter = 0;
    protected int unsigned target_delay = 0;
    protected bit ready_before_valid_active = 0;
    protected int unsigned rbv_cooldown = 0;

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

    // Reset is active if the env-level handler flagged it OR aresetn is asserted
    // directly. Honoring aresetn keeps the slave correct even when no env-level
    // reset_handler is wired (e.g. external integration).
    protected function bit reset_active();
        bit lvl = (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) ? 1'b0 : 1'b1;
        return in_reset || (vif.aresetn === lvl);
    endfunction

    task run_phase(uvm_phase phase);
        drive_reset_values();
        forever begin
            if (reset_active()) begin
                drive_reset_values();
                valid_seen = 0;
                delay_counter = 0;
                ready_before_valid_active = 0;
                rbv_cooldown = 0;
                @(posedge vif.aclk);
                continue;
            end
            if (cfg.slave_drive_mode == SLAVE_SEQ_DRIVEN) begin
                drive_ready_from_seq();
            end else begin
                drive_ready();
                @(vif.slave_cb);
            end
        end
    endtask

    protected task drive_ready();
        bit tvalid_current;
        tvalid_current = vif.slave_cb.tvalid;

        case (cfg.ready_gen_mode)
            READY_ALWAYS: begin
                vif.slave_cb.tready <= 1'b1;
            end
            READY_BEFORE_VALID: begin
                if (rbv_cooldown > 0) begin
                    vif.slave_cb.tready <= 1'b0;
                    rbv_cooldown--;
                end else if (!ready_before_valid_active) begin
                    vif.slave_cb.tready <= 1'b1;
                    ready_before_valid_active = 1;
                end else if (tvalid_current) begin
                    // Handshake will complete this cycle; deassert ready and cooldown
                    vif.slave_cb.tready <= 1'b0;
                    ready_before_valid_active = 0;
                    rbv_cooldown = cfg.ready_advance_cycles;
                end
            end
            READY_WITH_VALID: begin
                vif.slave_cb.tready <= tvalid_current;
            end
            READY_AFTER_VALID: begin
                if (tvalid_current && !valid_seen) begin
                    valid_seen = 1;
                    target_delay = bw_ctrl.get_ready_delay();
                    delay_counter = 0;
                end
                if (valid_seen) begin
                    if (delay_counter >= target_delay) begin
                        vif.slave_cb.tready <= 1'b1;
                        if (tvalid_current) begin
                            valid_seen = 0;
                            delay_counter = 0;
                        end
                    end else begin
                        vif.slave_cb.tready <= 1'b0;
                        delay_counter++;
                    end
                end else begin
                    vif.slave_cb.tready <= 1'b0;
                end
            end
            READY_WEIGHTED: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            READY_TOGGLE: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            READY_PROFILE: begin
                vif.slave_cb.tready <= bw_ctrl.should_assert_ready(tvalid_current);
            end
            default: begin
                vif.slave_cb.tready <= 1'b1;
            end
        endcase
    endtask

    protected task drive_ready_from_seq();
        seq_item_port.get_next_item(req);
        if (in_reset) begin
            seq_item_port.item_done();
            return;
        end
        // req.delay = number of cycles to hold tready low before asserting
        repeat (req.delay) begin
            if (in_reset) begin
                seq_item_port.item_done();
                return;
            end
            vif.slave_cb.tready <= 1'b0;
            @(vif.slave_cb);
        end
        // Assert tready, wait for handshake
        vif.slave_cb.tready <= 1'b1;
        @(vif.slave_cb);
        while (!(vif.slave_cb.tvalid && vif.tready)) begin
            if (in_reset) begin
                seq_item_port.item_done();
                return;
            end
            @(vif.slave_cb);
        end
        seq_item_port.item_done();
    endtask

    function void drive_reset_values();
        vif.slave_cb.tready <= 1'b0;
    endfunction

    function void set_in_reset(bit rst);
        in_reset = rst;
    endfunction

endclass
