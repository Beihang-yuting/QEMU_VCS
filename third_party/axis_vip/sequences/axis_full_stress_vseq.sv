class axis_full_stress_vseq extends axis_base_vseq;

    `uvm_object_utils(axis_full_stress_vseq)

    function new(string name = "axis_full_stress_vseq");
        super.new(name);
    endfunction

    task body();
        begin
            axis_interleave_seq ilv;
            `uvm_info(get_type_name(), "Stress phase 1: interleaved traffic", UVM_LOW)
            ilv = axis_interleave_seq::type_id::create("stress_ilv");
            if (!ilv.randomize() with {
                num_streams == 4;
                total_packets == 16;
            }) `uvm_error(get_type_name(), "Randomization failed")
            ilv.start(master_sqr);
        end
        begin
            axis_backpressure_stress_seq bp;
            `uvm_info(get_type_name(), "Stress phase 2: backpressure", UVM_LOW)
            bp = axis_backpressure_stress_seq::type_id::create("stress_bp");
            if (!bp.randomize() with {
                num_packets == 20;
                pkt_len == 32;
            }) `uvm_error(get_type_name(), "Randomization failed")
            bp.start(master_sqr);
        end
        begin
            axis_boundary_seq bnd;
            `uvm_info(get_type_name(), "Stress phase 3: boundary conditions", UVM_LOW)
            bnd = axis_boundary_seq::type_id::create("stress_bnd");
            bnd.start(master_sqr);
        end
        begin
            axis_burst_seq burst;
            `uvm_info(get_type_name(), "Stress phase 4: burst", UVM_LOW)
            burst = axis_burst_seq::type_id::create("stress_burst");
            if (!burst.randomize() with {
                num_packets == 16;
                min_pkt_len == 1;
                max_pkt_len == 64;
            }) `uvm_error(get_type_name(), "Randomization failed")
            burst.start(master_sqr);
        end
        `uvm_info(get_type_name(), "Full stress test complete", UVM_LOW)
    endtask

endclass
