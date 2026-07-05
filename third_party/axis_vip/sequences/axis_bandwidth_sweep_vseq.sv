class axis_bandwidth_sweep_vseq extends axis_base_vseq;

    `uvm_object_utils(axis_bandwidth_sweep_vseq)

    function new(string name = "axis_bandwidth_sweep_vseq");
        super.new(name);
    endfunction

    task body();
        axis_burst_seq burst;
        int unsigned weights[] = '{100, 80, 60, 40, 20};
        foreach (weights[i]) begin
            `uvm_info(get_type_name(),
                $sformatf("Sweep: valid_weight=%0d%%", weights[i]), UVM_LOW)
            master_cfg.valid_gen_mode = VALID_WEIGHTED;
            master_cfg.valid_weight   = weights[i];
            master_cfg.notify_config_changed();
            burst = axis_burst_seq::type_id::create($sformatf("bw_%0d", weights[i]));
            if (!burst.randomize() with {
                num_packets == 8;
                min_pkt_len == 16;
                max_pkt_len == 16;
            }) `uvm_error(get_type_name(), "Randomization failed")
            burst.start(master_sqr);
        end
        `uvm_info(get_type_name(), "Bandwidth sweep complete", UVM_LOW)
    endtask

endclass
