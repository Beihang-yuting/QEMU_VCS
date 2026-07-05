import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_full_regression_test extends axis_base_test;

    `uvm_component_utils(axis_full_regression_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_cfg.bw_check_enable  = 1;
        master_cfg.bw_window_cycles = 500;
        slave_cfg.ready_gen_mode    = READY_WEIGHTED;
        slave_cfg.ready_weight      = 70;
    endfunction

    task run_phase(uvm_phase phase);
        axis_full_stress_vseq stress_vseq;
        phase.raise_objection(this);
        stress_vseq = axis_full_stress_vseq::type_id::create("stress_vseq");
        stress_vseq.master_sqr = env.master_agent.sqr;
        stress_vseq.slave_sqr  = env.slave_agent.sqr;
        stress_vseq.master_cfg = master_cfg;
        stress_vseq.slave_cfg  = slave_cfg;
        stress_vseq.start(null);
        #500;
        phase.drop_objection(this);
    endtask

endclass
