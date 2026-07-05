class axis_backpressure_stress_seq extends axis_base_seq;

    `uvm_object_utils(axis_backpressure_stress_seq)

    rand int unsigned num_packets;
    rand int unsigned pkt_len;

    constraint c_stress { num_packets inside {[10:50]}; pkt_len inside {[8:128]}; }

    function new(string name = "axis_backpressure_stress_seq");
        super.new(name);
    endfunction

    task body();
        for (int p = 0; p < num_packets; p++) begin
            axis_packet_seq pkt_seq;
            if (should_stop()) return;
            pkt_seq = axis_packet_seq::type_id::create($sformatf("stress_pkt_%0d", p));
            if (!pkt_seq.randomize() with {
                packet_length == local::pkt_len;
                inter_beat_delay == 0;
                data_pattern == 0;
            }) `uvm_error(get_type_name(), "Randomization failed")
            pkt_seq.start(m_sequencer, this);
        end
    endtask

endclass
