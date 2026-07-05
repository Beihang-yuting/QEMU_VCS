class axis_packet extends uvm_sequence_item;

    axis_transfer beats[$];
    bit [15:0]    tid;
    bit [15:0]    tdest;
    int unsigned  packet_length;
    time          timestamp;

    `uvm_object_utils_begin(axis_packet)
        `uvm_field_int(tid,           UVM_ALL_ON)
        `uvm_field_int(tdest,         UVM_ALL_ON)
        `uvm_field_int(packet_length, UVM_ALL_ON)
        `uvm_field_int(timestamp,     UVM_ALL_ON | UVM_TIME)
    `uvm_object_utils_end

    function new(string name = "axis_packet");
        super.new(name);
    endfunction

    function void add_beat(axis_transfer beat);
        beats.push_back(beat);
        if (beats.size() == 1) begin
            tid       = beat.tid;
            tdest     = beat.tdest;
            timestamp = $time;
        end
        packet_length = beats.size();
    endfunction

    function bit is_complete();
        if (beats.size() == 0) return 0;
        return beats[beats.size()-1].tlast;
    endfunction

    function void get_payload(ref bit [7:0] payload[$]);
        int unsigned bl;
        payload.delete();
        if (beats.size() == 0) return;
        bl = (beats[0].cfg != null) ? beats[0].cfg.get_byte_lanes() : 64;
        foreach (beats[i]) begin
            for (int b = 0; b < bl; b++) begin
                if (beats[i].tkeep[b])
                    payload.push_back(beats[i].tdata[b*8 +: 8]);
            end
        end
    endfunction

    function bit compare_payload(axis_packet other);
        bit [7:0] this_payload[$];
        bit [7:0] other_payload[$];
        this.get_payload(this_payload);
        other.get_payload(other_payload);
        if (this_payload.size() != other_payload.size()) return 0;
        foreach (this_payload[i])
            if (this_payload[i] !== other_payload[i]) return 0;
        return 1;
    endfunction

endclass
