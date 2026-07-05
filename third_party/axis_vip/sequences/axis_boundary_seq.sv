class axis_boundary_seq extends axis_base_seq;

    `uvm_object_utils(axis_boundary_seq)

    function new(string name = "axis_boundary_seq");
        super.new(name);
    endfunction

    task body();
        send_packet(1, 0, 0);
        send_packet_with_data(4, 0, '0);
        send_packet_with_data(4, 0, '1);
        send_packet(4, (1 << cfg.TID_WIDTH) - 1, 0);
        send_packet(4, 0, (1 << cfg.TDEST_WIDTH) - 1);
        send_packet(256, 0, 0);
    endtask

    protected task send_packet(int unsigned length, bit [15:0] tid, bit [15:0] tdest);
        axis_packet_seq pkt_seq;
        pkt_seq = axis_packet_seq::type_id::create("boundary_pkt");
        if (!pkt_seq.randomize() with {
            packet_length == local::length;
            packet_tid    == local::tid;
            packet_tdest  == local::tdest;
            data_pattern  == 0;
        }) `uvm_error(get_type_name(), "Randomization failed")
        pkt_seq.start(m_sequencer, this);
    endtask

    protected task send_packet_with_data(int unsigned length, bit [15:0] tid, bit [511:0] data_val);
        for (int i = 0; i < length; i++) begin
            axis_transfer tr;
            if (should_stop()) return;
            tr = axis_transfer::type_id::create($sformatf("bnd_tr_%0d", i));
            tr.cfg = cfg;
            start_item(tr);
            tr.tdata = data_val;
            tr.tkeep = (1 << cfg.get_byte_lanes()) - 1;
            tr.tstrb = tr.tkeep;
            tr.tlast = (i == length - 1);
            tr.tid   = tid;
            tr.tdest = 0;
            tr.tuser = 0;
            tr.delay = 0;
            finish_item(tr);
        end
    endtask

endclass
