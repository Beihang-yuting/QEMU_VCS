class axis_base_vseq extends uvm_sequence #(axis_transfer);

    `uvm_object_utils(axis_base_vseq)

    axis_sequencer master_sqr;
    axis_sequencer slave_sqr;
    axis_config master_cfg;
    axis_config slave_cfg;
    axis_seq_state_e current_state;
    uvm_event state_change_evt;

    function new(string name = "axis_base_vseq");
        super.new(name);
        current_state = AXIS_SEQ_STATE_NORMAL;
        state_change_evt = new("state_change_evt");
    endfunction

    task pre_body();
        if (master_sqr != null) master_cfg = master_sqr.cfg;
        if (slave_sqr != null)  slave_cfg  = slave_sqr.cfg;
        // Wait for initial reset to complete before sending traffic
        if (master_sqr != null)
            while (master_sqr.reset_active) #1;
    endtask

    function void transition_to(axis_seq_state_e new_state);
        `uvm_info(get_type_name(),
            $sformatf("State transition: %s -> %s", current_state.name(), new_state.name()),
            UVM_MEDIUM)
        current_state = new_state;
        state_change_evt.trigger();
    endfunction

endclass
