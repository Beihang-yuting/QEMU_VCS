class axis_burst_seq extends axis_base_seq;

    `uvm_object_utils(axis_burst_seq)

    rand int unsigned num_packets;
    rand int unsigned min_pkt_len;
    rand int unsigned max_pkt_len;
    rand bit [15:0]   burst_tid;
    rand bit [15:0]   burst_tdest;

    constraint c_packets { num_packets inside {[2:32]}; }
    constraint c_pkt_len { min_pkt_len inside {[1:16]}; max_pkt_len inside {[4:64]}; max_pkt_len >= min_pkt_len; }
    constraint c_tid_range  { burst_tid   inside {[0:15]}; }
    constraint c_tdest_range { burst_tdest inside {[0:15]}; }

    function new(string name = "axis_burst_seq");
        super.new(name);
    endfunction

    task body();
        for (int p = 0; p < num_packets; p++) begin
            axis_packet_seq pkt_seq;
            if (should_stop()) return;
            pkt_seq = axis_packet_seq::type_id::create($sformatf("pkt_%0d", p));
            if (!pkt_seq.randomize() with {
                packet_length inside {[local::min_pkt_len : local::max_pkt_len]};
                packet_tid  == local::burst_tid;
                packet_tdest == local::burst_tdest;
                inter_beat_delay == 0;
                data_pattern == 0;
            }) `uvm_error(get_type_name(), "Randomization failed")
            pkt_seq.start(m_sequencer, this);
        end
    endtask

endclass
