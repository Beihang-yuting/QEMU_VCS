class axis_phase_controller #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_component;

    `uvm_component_param_utils(axis_phase_controller#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef virtual axis_if #(TDATA_WIDTH, TID_WIDTH, TDEST_WIDTH,
                              TUSER_WIDTH, HAS_TSTRB, HAS_TKEEP, HAS_TLAST) vif_t;
    typedef axis_agent         #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) agent_t;
    typedef axis_reset_handler #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) rst_handler_t;
    vif_t vif;
    axis_config cfg;
    rst_handler_t rst_handler;

    int unsigned drain_timeout = 1000;
    agent_t agents[$];

    protected bit phase_jump_pending = 0;

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
        // Phase jump recovery: resume sequencers after jump
        if (phase_jump_pending) begin
            phase_jump_pending = 0;
            foreach (agents[i]) begin
                if (agents[i].sqr != null)
                    agents[i].sqr.set_reset_active(0);
            end
            `uvm_info(get_type_name(), "Phase jump recovery: sequencers resumed", UVM_LOW)
        end
    endtask

    task request_phase_jump(uvm_phase current_phase, uvm_phase target_phase);
        if (rst_handler != null && rst_handler.is_in_reset) begin
            `uvm_warning(get_type_name(), "Phase jump blocked: reset is active")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("Phase jump requested: %s -> %s", current_phase.get_name(), target_phase.get_name()),
            UVM_LOW)

        foreach (agents[i]) begin
            if (agents[i].sqr != null)
                agents[i].sqr.set_reset_active(1);
        end

        drain_in_flight();

        phase_jump_pending = 1;
        current_phase.jump(target_phase);
        // Code after jump() will NOT execute — recovery happens in run_phase
    endtask

    protected task drain_in_flight();
        int unsigned timeout_count = 0;
        bit all_drained = 0;

        `uvm_info(get_type_name(), "Draining in-flight transactions...", UVM_MEDIUM)

        while (!all_drained && timeout_count < drain_timeout) begin
            all_drained = 1;
            foreach (agents[i]) begin
                if (agents[i].sqr != null && agents[i].sqr.has_do_available()) begin
                    all_drained = 0;
                    break;
                end
            end
            if (!all_drained) begin
                @(posedge vif.aclk);
                timeout_count++;
            end
        end

        if (!all_drained)
            `uvm_warning(get_type_name(),
                $sformatf("Drain timeout after %0d cycles, forcing phase jump", drain_timeout))
        else
            `uvm_info(get_type_name(), "All in-flight transactions drained", UVM_MEDIUM)
    endtask

endclass
