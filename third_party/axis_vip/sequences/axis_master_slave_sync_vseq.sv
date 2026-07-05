class axis_master_slave_sync_vseq extends axis_base_vseq;

    `uvm_object_utils(axis_master_slave_sync_vseq)

    rand int unsigned num_packets;
    rand int unsigned pkt_len;
    constraint c_sync { num_packets inside {[4:16]}; pkt_len inside {[4:32]}; }

    function new(string name = "axis_master_slave_sync_vseq");
        super.new(name);
    endfunction

    task body();
        axis_burst_seq master_seq;
        master_seq = axis_burst_seq::type_id::create("m_burst");
        if (!master_seq.randomize() with {
            num_packets == local::num_packets;
            min_pkt_len == local::pkt_len;
            max_pkt_len == local::pkt_len;
        }) `uvm_error(get_type_name(), "Randomization failed")
        master_seq.start(master_sqr);
        `uvm_info(get_type_name(), "Master-slave sync complete", UVM_LOW)
    endtask

endclass
