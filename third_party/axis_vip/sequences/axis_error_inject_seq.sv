class axis_error_inject_seq extends axis_base_seq;

    `uvm_object_utils(axis_error_inject_seq)

    typedef enum {
        ERR_TKEEP_TSTRB_MISMATCH,
        ERR_MID_PACKET_TID_CHANGE,
        ERR_ZERO_BYTE_TRANSFER
    } error_type_e;

    rand error_type_e error_type;

    function new(string name = "axis_error_inject_seq");
        super.new(name);
    endfunction

    task body();
        axis_transfer tr;

        case (error_type)
            ERR_TKEEP_TSTRB_MISMATCH: begin
                // TSTRB=1 where TKEEP=0 violates AXI-Stream spec
                tr = axis_transfer::type_id::create("err_tr");
                tr.cfg = cfg;
                start_item(tr);
                if (!tr.randomize() with { tlast == 1; })
                    `uvm_error(get_type_name(), "Randomization failed")
                tr.tkeep = 4'b0000;
                tr.tstrb = 4'b1111;
                finish_item(tr);
            end

            ERR_MID_PACKET_TID_CHANGE: begin
                // Send 2 beats with different TIDs in same packet
                // Beat 1: tlast=0, tid=A
                tr = axis_transfer::type_id::create("err_tr1");
                tr.cfg = cfg;
                start_item(tr);
                if (!tr.randomize() with { tlast == 0; })
                    `uvm_error(get_type_name(), "Randomization failed")
                tr.tid = 4'h0;
                finish_item(tr);

                // Beat 2: tlast=1, tid=B (different from beat 1)
                tr = axis_transfer::type_id::create("err_tr2");
                tr.cfg = cfg;
                start_item(tr);
                if (!tr.randomize() with { tlast == 1; })
                    `uvm_error(get_type_name(), "Randomization failed")
                tr.tid = 4'hF;
                finish_item(tr);
            end

            ERR_ZERO_BYTE_TRANSFER: begin
                // All bytes null-qualified: tkeep=0, tstrb=0
                tr = axis_transfer::type_id::create("err_tr");
                tr.cfg = cfg;
                start_item(tr);
                if (!tr.randomize() with { tlast == 1; })
                    `uvm_error(get_type_name(), "Randomization failed")
                tr.tkeep = 0;
                tr.tstrb = 0;
                finish_item(tr);
            end
        endcase
    endtask

endclass
