class axis_idle_seq extends axis_base_seq;

    `uvm_object_utils(axis_idle_seq)

    rand int unsigned idle_cycles;
    constraint c_idle { idle_cycles inside {[1:100]}; }

    function new(string name = "axis_idle_seq");
        super.new(name);
    endfunction

    task body();
        axis_transfer tr;
        tr = axis_transfer::type_id::create("idle_tr");
        tr.cfg = cfg;
        start_item(tr);
        tr.tdata = 0;
        tr.tkeep = 0;
        tr.tstrb = 0;
        tr.tlast = 0;
        tr.tid   = 0;
        tr.tdest = 0;
        tr.tuser = 0;
        tr.delay = idle_cycles;
        finish_item(tr);
    endtask

endclass
