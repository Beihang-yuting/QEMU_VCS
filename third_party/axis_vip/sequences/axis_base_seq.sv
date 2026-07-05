class axis_base_seq extends uvm_sequence #(axis_transfer);

    `uvm_object_utils(axis_base_seq)

    axis_config cfg;

    function new(string name = "axis_base_seq");
        super.new(name);
    endfunction

    task pre_body();
        if (m_sequencer != null) begin
            axis_sequencer sqr;
            if ($cast(sqr, m_sequencer)) begin
                cfg = sqr.cfg;
                sqr.last_seq_type_name = get_type_name();
            end
        end
        if (cfg == null)
            `uvm_fatal("NOCFG", "axis_config not available in sequence")
    endtask

    function bit should_stop();
        axis_sequencer sqr;
        if ($cast(sqr, m_sequencer))
            return sqr.reset_active;
        return 0;
    endfunction

endclass
