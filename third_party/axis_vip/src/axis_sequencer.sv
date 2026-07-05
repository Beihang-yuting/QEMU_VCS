class axis_sequencer extends uvm_sequencer #(axis_transfer);

    `uvm_component_utils(axis_sequencer)

    axis_config cfg;
    bit reset_active = 0;
    string last_seq_type_name;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")
    endfunction

    function void flush_pending();
        stop_sequences();
        `uvm_info(get_type_name(), "Flushed pending transactions due to reset", UVM_MEDIUM)
    endfunction

    function void set_reset_active(bit active);
        reset_active = active;
    endfunction

    task restart_last_sequence();
        uvm_object_wrapper seq_type;
        uvm_sequence_base  seq;
        uvm_factory factory;

        if (last_seq_type_name == "") begin
            `uvm_info(get_type_name(), "No sequence to restart after hot-reset", UVM_MEDIUM)
            return;
        end

        factory = uvm_factory::get();
        seq_type = factory.find_wrapper_by_name(last_seq_type_name);
        if (seq_type == null) begin
            `uvm_error(get_type_name(),
                $sformatf("Cannot find sequence type '%s' for hot-reset restart",
                          last_seq_type_name))
            return;
        end

        $cast(seq, seq_type.create_object(last_seq_type_name));
        if (seq == null) begin
            `uvm_error(get_type_name(), "Failed to create sequence for hot-reset restart")
            return;
        end

        `uvm_info(get_type_name(),
            $sformatf("Hot-reset: restarting sequence '%s'", last_seq_type_name), UVM_LOW)
        fork
            seq.start(this);
        join_none
    endtask

endclass
