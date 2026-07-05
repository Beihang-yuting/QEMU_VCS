class axis_reset_recovery_vseq extends axis_base_vseq;

    `uvm_object_utils(axis_reset_recovery_vseq)

    axis_vif_default_t vif;

    rand int unsigned pre_reset_packets;
    rand int unsigned post_reset_packets;
    rand int unsigned reset_duration_cycles;

    constraint c_reset {
        pre_reset_packets inside {[2:8]};
        post_reset_packets inside {[2:8]};
        reset_duration_cycles inside {[5:20]};
    }

    function new(string name = "axis_reset_recovery_vseq");
        super.new(name);
    endfunction

    task body();
        axis_burst_seq pre_seq, post_seq;

        transition_to(AXIS_SEQ_STATE_NORMAL);
        pre_seq = axis_burst_seq::type_id::create("pre_rst");
        if (!pre_seq.randomize() with {
            num_packets == local::pre_reset_packets;
            min_pkt_len == 4;
            max_pkt_len == 8;
        }) `uvm_error(get_type_name(), "Randomization failed")
        pre_seq.start(master_sqr);

        `uvm_info(get_type_name(), "Asserting reset", UVM_LOW)
        if (master_cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            void'(uvm_hdl_force("tb_top.aresetn", 0));
        else
            void'(uvm_hdl_force("tb_top.aresetn", 1));
        repeat (reset_duration_cycles) @(posedge vif.aclk);

        `uvm_info(get_type_name(), "Deasserting reset", UVM_LOW)
        if (master_cfg.reset_polarity == AXIS_RESET_ACTIVE_LOW)
            void'(uvm_hdl_force("tb_top.aresetn", 1));
        else
            void'(uvm_hdl_force("tb_top.aresetn", 0));
        repeat (5) @(posedge vif.aclk);

        transition_to(AXIS_SEQ_STATE_RECOVERY);
        post_seq = axis_burst_seq::type_id::create("post_rst");
        if (!post_seq.randomize() with {
            num_packets == local::post_reset_packets;
            min_pkt_len == 4;
            max_pkt_len == 8;
        }) `uvm_error(get_type_name(), "Randomization failed")
        post_seq.start(master_sqr);

        transition_to(AXIS_SEQ_STATE_DONE);
        `uvm_info(get_type_name(), "Reset recovery complete", UVM_LOW)
    endtask

endclass
