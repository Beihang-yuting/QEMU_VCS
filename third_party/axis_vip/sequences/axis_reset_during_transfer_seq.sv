class axis_reset_during_transfer_seq extends axis_base_seq;

    `uvm_object_utils(axis_reset_during_transfer_seq)

    rand int unsigned pkt_len;
    constraint c_len { pkt_len inside {[16:64]}; }

    function new(string name = "axis_reset_during_transfer_seq");
        super.new(name);
    endfunction

    task body();
        axis_packet_seq pkt_seq;
        pkt_seq = axis_packet_seq::type_id::create("rst_pkt");
        if (!pkt_seq.randomize() with {
            packet_length == local::pkt_len;
            inter_beat_delay == 1;
            data_pattern == 1;
        }) `uvm_error(get_type_name(), "Randomization failed")
        fork
            pkt_seq.start(m_sequencer, this);
        join_any
        `uvm_info(get_type_name(), "Reset-during-transfer sequence completed or interrupted", UVM_MEDIUM)
    endtask

endclass
