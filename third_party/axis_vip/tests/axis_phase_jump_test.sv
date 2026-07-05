import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_phase_jump_test extends axis_base_test;

    `uvm_component_utils(axis_phase_jump_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        axis_burst_seq burst;
        axis_burst_seq burst2;
        phase.raise_objection(this);

        // Run initial burst
        burst = axis_burst_seq::type_id::create("burst");
        if (!burst.randomize() with {
            num_packets == 4;
            min_pkt_len == 4;
            max_pkt_len == 8;
        }) `uvm_error(get_type_name(), "Randomization failed")
        burst.start(env.master_agent.sqr);

        // Exercise the drain mechanism via phase jump (jump to self)
        `uvm_info(get_type_name(), "Requesting phase jump to test drain mechanism", UVM_LOW)
        env.phase_ctrl.request_phase_jump(phase, phase);

        // Run second burst to verify recovery after phase jump
        burst2 = axis_burst_seq::type_id::create("burst2");
        if (!burst2.randomize() with {
            num_packets == 2;
            min_pkt_len == 2;
            max_pkt_len == 4;
        }) `uvm_error(get_type_name(), "Randomization failed")
        burst2.start(env.master_agent.sqr);

        #200;
        phase.drop_objection(this);
    endtask

endclass
