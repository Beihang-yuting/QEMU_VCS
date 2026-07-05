class axis_reset_handler #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_component;

    `uvm_component_param_utils(axis_reset_handler#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    typedef axis_agent #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) agent_t;
    vif_t vif;
    axis_config cfg;

    uvm_event reset_asserted_evt;
    uvm_event reset_active_evt;
    uvm_event reset_deasserted_evt;

    agent_t agents[$];
    bit is_in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        reset_asserted_evt   = new("reset_asserted_evt");
        reset_active_evt     = new("reset_active_evt");
        reset_deasserted_evt = new("reset_deasserted_evt");
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
        if (!uvm_config_db#(vif_t)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        // Handle initial reset: mark all agents in reset before traffic starts
        handle_reset_assert();
        wait_for_reset_done();
        handle_reset_deassert();
        @(posedge vif.aclk);
        reset_deasserted_evt.reset();
        forever begin
            if (cfg.reset_sync_mode == AXIS_RESET_SYNC)
                wait_for_sync_reset_assert();
            else
                wait_for_async_reset_assert();
            handle_reset_assert();
            @(posedge vif.aclk);
            reset_asserted_evt.reset();
            reset_active_evt.reset();

            if (cfg.reset_sync_mode == AXIS_RESET_SYNC)
                wait_for_sync_reset_deassert();
            else
                wait_for_async_reset_deassert();
            handle_reset_deassert();
            @(posedge vif.aclk);
            reset_deasserted_evt.reset();
        end
    endtask

    protected task wait_for_sync_reset_assert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b0) @(posedge vif.aclk);
        end else begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b1) @(posedge vif.aclk);
        end
    endtask

    protected task wait_for_sync_reset_deassert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b1) @(posedge vif.aclk);
        end else begin
            @(posedge vif.aclk);
            while (vif.aresetn !== 1'b0) @(posedge vif.aclk);
        end
    endtask

    protected task wait_for_async_reset_assert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            @(negedge vif.aresetn);
        else
            @(posedge vif.aresetn);
    endtask

    protected task wait_for_async_reset_deassert();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            @(posedge vif.aresetn);
        else
            @(negedge vif.aresetn);
    endtask

    protected task wait_for_reset_done();
        if (cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW) begin
            if (vif.aresetn === 1'b0) begin
                `uvm_info(get_type_name(), "Waiting for initial reset to complete", UVM_MEDIUM)
                @(posedge vif.aresetn);
            end
        end else begin
            if (vif.aresetn === 1'b1) begin
                `uvm_info(get_type_name(), "Waiting for initial reset to complete", UVM_MEDIUM)
                @(negedge vif.aresetn);
            end
        end
        `uvm_info(get_type_name(), "Initial reset complete", UVM_MEDIUM)
    endtask

    protected function void handle_reset_assert();
        is_in_reset = 1;
        `uvm_info(get_type_name(), "Reset asserted", UVM_MEDIUM)
        foreach (agents[i])
            agents[i].set_in_reset(1);
        reset_asserted_evt.trigger();
        reset_active_evt.trigger();
    endfunction

    protected function void handle_reset_deassert();
        is_in_reset = 0;
        `uvm_info(get_type_name(), "Reset deasserted", UVM_MEDIUM)
        foreach (agents[i])
            agents[i].set_in_reset(0);
        reset_deasserted_evt.trigger();
    endfunction

endclass
