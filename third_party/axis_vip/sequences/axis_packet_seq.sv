class axis_packet_seq extends axis_base_seq;

    `uvm_object_utils(axis_packet_seq)

    rand int unsigned  packet_length;
    rand bit [15:0]    packet_tid;
    rand bit [15:0]    packet_tdest;
    rand int unsigned  inter_beat_delay;
    rand int unsigned  data_pattern; // 0=random, 1=incrementing, 2=all-zero, 3=all-one

    constraint c_length { packet_length inside {[1:256]}; }
    constraint c_delay  { inter_beat_delay inside {[0:3]}; }
    constraint c_pattern { data_pattern inside {[0:3]}; }
    constraint c_tid_range  { packet_tid   inside {[0:15]}; }
    constraint c_tdest_range { packet_tdest inside {[0:15]}; }

    function new(string name = "axis_packet_seq");
        super.new(name);
    endfunction

    task body();
        for (int i = 0; i < packet_length; i++) begin
            axis_transfer tr;
            if (should_stop()) return;
            tr = axis_transfer::type_id::create($sformatf("tr_%0d", i));
            tr.cfg = cfg;
            start_item(tr);
            if (!tr.randomize() with {
                tid   == local::packet_tid;
                tdest == local::packet_tdest;
                tlast == (i == local::packet_length - 1);
                delay == local::inter_beat_delay;
            }) `uvm_error(get_type_name(), "Randomization failed")
            case (data_pattern)
                1: tr.tdata = i;
                2: tr.tdata = 0;
                3: tr.tdata = '1;
            endcase
            finish_item(tr);
        end
    endtask

endclass
