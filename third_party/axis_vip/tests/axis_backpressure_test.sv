import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_backpressure_test extends axis_base_test;

    `uvm_component_utils(axis_backpressure_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        slave_cfg.ready_gen_mode = READY_AFTER_VALID;
        slave_cfg.ready_delay_min = 2;
        slave_cfg.ready_delay_max = 10;
    endfunction

    task run_phase(uvm_phase phase);
        axis_backpressure_stress_seq stress_seq;
        phase.raise_objection(this);
        stress_seq = axis_backpressure_stress_seq::type_id::create("stress_seq");
        if (!stress_seq.randomize() with {
            num_packets == 10;
            pkt_len == 16;
        }) `uvm_error(get_type_name(), "Randomization failed")
        stress_seq.start(env.master_agent.sqr);
        #500;
        phase.drop_objection(this);
    endtask

endclass
