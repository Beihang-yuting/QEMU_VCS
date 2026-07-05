import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_reset_test extends axis_base_test;

    `uvm_component_utils(axis_reset_test)

    axis_vif_default_t vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_cfg.hot_reset_enable = 1;
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!uvm_config_db#(axis_vif_default_t)::get(this, "", "vif", vif))
            void'(uvm_config_db#(axis_vif_default_t)::get(null, "uvm_test_top.env.master_agent*", "vif", vif));
    endfunction

    task run_phase(uvm_phase phase);
        axis_reset_recovery_vseq rst_vseq;
        phase.raise_objection(this);
        rst_vseq = axis_reset_recovery_vseq::type_id::create("rst_vseq");
        rst_vseq.master_sqr = env.master_agent.sqr;
        rst_vseq.slave_sqr  = env.slave_agent.sqr;
        rst_vseq.master_cfg = master_cfg;
        rst_vseq.slave_cfg  = slave_cfg;
        rst_vseq.vif = vif;
        if (!rst_vseq.randomize() with {
            pre_reset_packets == 4;
            post_reset_packets == 4;
            reset_duration_cycles == 10;
        }) `uvm_error(get_type_name(), "Randomization failed")
        rst_vseq.start(null);
        #200;
        phase.drop_objection(this);
    endtask

endclass
