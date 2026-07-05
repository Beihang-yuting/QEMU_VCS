import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_sanity_test extends axis_base_test;

    `uvm_component_utils(axis_sanity_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axis_master_slave_sync_vseq vseq;
        phase.raise_objection(this);
        vseq = axis_master_slave_sync_vseq::type_id::create("vseq");
        vseq.master_sqr = env.master_agent.sqr;
        vseq.slave_sqr  = env.slave_agent.sqr;
        if (!vseq.randomize() with {
            num_packets == 4;
            pkt_len == 8;
        }) `uvm_error(get_type_name(), "Randomization failed")
        vseq.start(null);
        #200;
        phase.drop_objection(this);
    endtask

endclass
