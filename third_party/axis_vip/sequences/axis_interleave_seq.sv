class axis_interleave_seq extends axis_base_seq;

    `uvm_object_utils(axis_interleave_seq)

    rand int unsigned num_streams;
    rand int unsigned beats_per_switch;
    rand int unsigned total_packets;

    constraint c_streams { num_streams inside {[2:8]}; }
    constraint c_switch  { beats_per_switch inside {[1:8]}; }
    constraint c_total   { total_packets inside {[4:16]}; }

    function new(string name = "axis_interleave_seq");
        super.new(name);
    endfunction

    task body();
        int unsigned pkt_per_stream = total_packets / num_streams;
        if (pkt_per_stream < 1) pkt_per_stream = 1;

        for (int p = 0; p < pkt_per_stream; p++) begin
            for (int s = 0; s < num_streams; s++) begin
                axis_packet_seq pkt_seq;
                if (should_stop()) return;
                pkt_seq = axis_packet_seq::type_id::create($sformatf("ilv_s%0d_p%0d", s, p));
                if (!pkt_seq.randomize() with {
                    packet_length inside {[2:16]};
                    packet_tid == local::s;
                    packet_tdest == local::s;
                    inter_beat_delay inside {[0:2]};
                    data_pattern == 1;
                }) `uvm_error(get_type_name(), "Randomization failed")
                pkt_seq.start(m_sequencer, this);
            end
        end
    endtask

endclass
