// cosim_sequences.sv — Test sequences for standalone mode

class cosim_base_seq extends uvm_sequence #(cosim_tlp_tr);
    `uvm_object_utils(cosim_base_seq)

    function new(string name = "cosim_base_seq");
        super.new(name);
    endfunction

    task cfg_read(int offset, int tag);
        cosim_tlp_tr tr = cosim_tlp_tr::type_id::create("cfg_rd");
        tr.tlp_type = 3'd3;
        tr.addr     = offset;
        tr.data     = 0;
        tr.len      = 4;
        tr.tag      = tag;
        start_item(tr);
        finish_item(tr);
    endtask

    task cfg_write(int offset, bit [31:0] wdata, int tag);
        cosim_tlp_tr tr = cosim_tlp_tr::type_id::create("cfg_wr");
        tr.tlp_type = 3'd2;
        tr.addr     = offset;
        tr.data     = wdata;
        tr.len      = 4;
        tr.tag      = tag;
        start_item(tr);
        finish_item(tr);
    endtask

    task mem_read(bit [63:0] address, int tag);
        cosim_tlp_tr tr = cosim_tlp_tr::type_id::create("mem_rd");
        tr.tlp_type = 3'd1;
        tr.addr     = address;
        tr.data     = 0;
        tr.len      = 4;
        tr.tag      = tag;
        start_item(tr);
        finish_item(tr);
    endtask

    task mem_write(bit [63:0] address, bit [31:0] wdata, int tag);
        cosim_tlp_tr tr = cosim_tlp_tr::type_id::create("mem_wr");
        tr.tlp_type = 3'd0;
        tr.addr     = address;
        tr.data     = wdata;
        tr.len      = 4;
        tr.tag      = tag;
        start_item(tr);
        finish_item(tr);
    endtask

    task send_shutdown();
        cosim_tlp_tr tr = cosim_tlp_tr::type_id::create("shutdown");
        tr.is_shutdown = 1;
        start_item(tr);
        finish_item(tr);
    endtask
endclass


// Config Space read test
class cosim_cfgrd_seq extends cosim_base_seq;
    `uvm_object_utils(cosim_cfgrd_seq)
    function new(string name = "cosim_cfgrd_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info("SEQ", "=== Config Space Read Test ===", UVM_LOW)
        cfg_read(32'h0000, 1);  // VID/DID
        cfg_read(32'h0004, 2);  // Status/Command
        cfg_read(32'h0008, 3);  // Class/Rev
        cfg_read(32'h0010, 4);  // BAR0
        cfg_read(32'h002C, 5);  // Subsystem
        `uvm_info("SEQ", "=== Config Space Read Done ===", UVM_LOW)
        send_shutdown();
    endtask
endclass


// BAR0 register R/W test
class cosim_bar_rw_seq extends cosim_base_seq;
    `uvm_object_utils(cosim_bar_rw_seq)
    function new(string name = "cosim_bar_rw_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info("SEQ", "=== BAR0 Register R/W Test ===", UVM_LOW)
        mem_write(64'h0000, 32'hCAFEBABE, 10);
        mem_read(64'h0000, 11);
        mem_write(64'h1014, 32'h0000_000F, 12);
        mem_read(64'h1014, 13);
        mem_write(64'h1016, 32'h0000_0001, 14);
        mem_read(64'h1018, 15);
        `uvm_info("SEQ", "=== BAR0 Register R/W Done ===", UVM_LOW)
        send_shutdown();
    endtask
endclass


// Random traffic test
class cosim_random_seq extends cosim_base_seq;
    `uvm_object_utils(cosim_random_seq)
    int num_transactions = 20;
    function new(string name = "cosim_random_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info("SEQ", $sformatf("=== Random Traffic (%0d TLPs) ===",
                                    num_transactions), UVM_LOW)
        for (int i = 0; i < num_transactions; i++) begin
            cosim_tlp_tr tr = cosim_tlp_tr::type_id::create($sformatf("rand_%0d", i));
            start_item(tr);
            if (!tr.randomize() with {
                tlp_type inside {0, 1, 2, 3};
                addr[63:16] == 0;
                addr[15:0] inside {16'h0000, 16'h0004, 16'h0008, 16'h0010,
                                   16'h1000, 16'h1014, 16'h1016, 16'h1018,
                                   16'h3000};
                tag == i;
            }) `uvm_error("SEQ", "Randomization failed")
            finish_item(tr);
        end
        `uvm_info("SEQ", "=== Random Traffic Done ===", UVM_LOW)
        send_shutdown();
    endtask
endclass


// Full functional test
class cosim_functional_seq extends cosim_base_seq;
    `uvm_object_utils(cosim_functional_seq)
    function new(string name = "cosim_functional_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info("SEQ", "=== Full Functional Test ===", UVM_LOW)

        // Config Space
        cfg_read(32'h0000, 1);
        cfg_read(32'h0008, 2);
        cfg_read(32'h0010, 3);

        // VirtIO init
        mem_write(64'h1014, 32'h0, 10);   // reset
        mem_write(64'h1014, 32'h1, 11);   // ACKNOWLEDGE
        mem_read(64'h1014, 12);
        mem_write(64'h1014, 32'h3, 13);   // DRIVER
        mem_read(64'h1000, 14);            // features

        // Queue setup
        mem_write(64'h1016, 32'h0, 20);
        mem_read(64'h1018, 21);
        mem_write(64'h1016, 32'h1, 22);
        mem_read(64'h1018, 23);

        // Misc
        mem_read(64'h3000, 30);  // ISR
        mem_read(64'h2000, 31);  // MAC
        mem_read(64'h2004, 32);

        `uvm_info("SEQ", "=== Full Functional Test Done ===", UVM_LOW)
        send_shutdown();
    endtask
endclass
