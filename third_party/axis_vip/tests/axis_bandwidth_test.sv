import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_bandwidth_test extends axis_base_test;

    `uvm_component_utils(axis_bandwidth_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_cfg.bw_check_enable  = 1;
        master_cfg.bw_window_cycles = 500;
        master_cfg.bw_min_threshold = 0.1;
        master_cfg.bw_max_threshold = -1.0;
    endfunction

    task run_phase(uvm_phase phase);
        axis_bandwidth_sweep_vseq sweep_vseq;
        phase.raise_objection(this);
        sweep_vseq = axis_bandwidth_sweep_vseq::type_id::create("sweep_vseq");
        sweep_vseq.master_sqr = env.master_agent.sqr;
        sweep_vseq.slave_sqr  = env.slave_agent.sqr;
        sweep_vseq.master_cfg = master_cfg;
        sweep_vseq.slave_cfg  = slave_cfg;
        sweep_vseq.start(null);
        #200;
        phase.drop_objection(this);
    endtask

endclass
