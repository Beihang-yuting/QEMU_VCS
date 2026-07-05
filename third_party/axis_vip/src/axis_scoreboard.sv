class axis_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(axis_scoreboard)

    uvm_analysis_imp_master #(axis_packet, axis_scoreboard) master_export;
    uvm_analysis_imp_slave  #(axis_packet, axis_scoreboard) slave_export;

    typedef bit [31:0] stream_id_t;

    protected axis_packet master_queues[stream_id_t][$];
    protected axis_packet slave_queues[stream_id_t][$];

    int unsigned match_count;
    int unsigned mismatch_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_export = new("master_export", this);
        slave_export  = new("slave_export",  this);
    endfunction

    protected function stream_id_t get_stream_id(axis_packet pkt);
        return {pkt.tid[15:0], pkt.tdest[15:0]};
    endfunction

    function void write_master(axis_packet pkt);
        stream_id_t sid = get_stream_id(pkt);
        master_queues[sid].push_back(pkt);
        try_compare(sid);
    endfunction

    function void write_slave(axis_packet pkt);
        stream_id_t sid = get_stream_id(pkt);
        slave_queues[sid].push_back(pkt);
        try_compare(sid);
    endfunction

    protected function void try_compare(stream_id_t sid);
        while (master_queues[sid].size() > 0 && slave_queues[sid].size() > 0) begin
            axis_packet expected_pkt = master_queues[sid].pop_front();
            axis_packet actual_pkt   = slave_queues[sid].pop_front();

            if (expected_pkt.compare_payload(actual_pkt)) begin
                match_count++;
                `uvm_info(get_type_name(),
                    $sformatf("MATCH: packet tid=%0h tdest=%0h len=%0d",
                              expected_pkt.tid, expected_pkt.tdest, expected_pkt.packet_length),
                    UVM_HIGH)
            end else begin
                mismatch_count++;
                `uvm_error(get_type_name(),
                    $sformatf("MISMATCH: packet tid=%0h tdest=%0h len=%0d vs len=%0d",
                              expected_pkt.tid, expected_pkt.tdest,
                              expected_pkt.packet_length, actual_pkt.packet_length))
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        int unsigned total_master_pending = 0;
        int unsigned total_slave_pending  = 0;

        foreach (master_queues[sid])
            total_master_pending += master_queues[sid].size();
        foreach (slave_queues[sid])
            total_slave_pending += slave_queues[sid].size();

        `uvm_info(get_type_name(),
            $sformatf("Scoreboard summary: %0d matches, %0d mismatches, %0d master pending, %0d slave pending",
                      match_count, mismatch_count, total_master_pending, total_slave_pending),
            UVM_LOW)
        if (total_master_pending > 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d packets in master queues not received by slave", total_master_pending))
        if (total_slave_pending > 0)
            `uvm_error(get_type_name(),
                $sformatf("%0d packets in slave queues not sent by master", total_slave_pending))
    endfunction

endclass
