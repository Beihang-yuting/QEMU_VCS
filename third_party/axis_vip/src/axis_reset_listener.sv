class axis_reset_listener extends uvm_component;

    `uvm_component_utils(axis_reset_listener)

    axis_config cfg;

    uvm_event reset_asserted_evt;
    uvm_event reset_active_evt;
    uvm_event reset_deasserted_evt;

    axis_sequencer           sqr;
    axis_bandwidth_controller bw_ctrl;

    bit is_in_reset = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            reset_asserted_evt.wait_ptrigger();
            is_in_reset = 1;
            `uvm_info(get_type_name(), "Reset asserted - notifying agent components", UVM_MEDIUM)

            if (sqr != null) begin
                sqr.set_reset_active(1);
                sqr.flush_pending();
            end

            if (bw_ctrl != null)
                bw_ctrl.reset_state();

            reset_deasserted_evt.wait_ptrigger();
            is_in_reset = 0;
            `uvm_info(get_type_name(), "Reset deasserted - agent ready to resume", UVM_MEDIUM)

            if (sqr != null)
                sqr.set_reset_active(0);

            if (cfg.hot_reset_enable && sqr != null && sqr.last_seq_type_name != "") begin
                sqr.restart_last_sequence();
            end
        end
    endtask

endclass
