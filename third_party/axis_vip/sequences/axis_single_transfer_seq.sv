class axis_single_transfer_seq extends axis_base_seq;

    `uvm_object_utils(axis_single_transfer_seq)

    rand bit [511:0]  data;
    rand bit [63:0]   strb;
    rand bit [63:0]   keep;
    rand bit          last;
    rand bit [15:0]   id;
    rand bit [15:0]   dest;
    rand bit [127:0]  user;
    rand int unsigned  delay;

    constraint c_default_delay { delay inside {[0:5]}; }
    constraint c_default_last  { soft last == 1; }

    function new(string name = "axis_single_transfer_seq");
        super.new(name);
    endfunction

    task body();
        axis_transfer tr;
        tr = axis_transfer::type_id::create("tr");
        tr.cfg = cfg;
        start_item(tr);
        tr.tdata = data;
        tr.tstrb = strb;
        tr.tkeep = keep;
        tr.tlast = last;
        tr.tid   = id;
        tr.tdest = dest;
        tr.tuser = user;
        tr.delay = delay;
        finish_item(tr);
    endtask

endclass
