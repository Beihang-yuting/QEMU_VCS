// Directed repro: start stimulus deliberately OFF the clock edge (mid-cycle)
// with zero inter-beat delay. A loopback+monitor scoreboard cannot see a
// uniformly-dropped beat (master monitor and slave miss it equally), so this
// test counts the beats the MASTER MONITOR actually observes and compares to
// the number the sequence intended to drive. A swallowed first beat shows up as
// observed < intended.
import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_beat_counter extends uvm_subscriber #(axis_transfer);
    `uvm_component_utils(axis_beat_counter)
    int unsigned count = 0;
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    function void write(axis_transfer t);
        count++;
    endfunction
endclass

class axis_misalign_test extends axis_base_test;

    `uvm_component_utils(axis_misalign_test)

    axis_beat_counter mcnt;
    localparam int unsigned EXPECTED_BEATS = 16; // 4 packets x 4 beats

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mcnt = axis_beat_counter::type_id::create("mcnt", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        env.master_agent.mon.beat_ap.connect(mcnt.analysis_export);
    endfunction

    task run_phase(uvm_phase phase);
        axis_burst_seq seq;
        phase.raise_objection(this);
        // Well past reset (deasserts ~130ns), then shift 3ns off the posedge
        // (period 10ns, posedges at multiples of 10) so the first get_next_item
        // returns un-aligned to the clock.
        #203;
        seq = axis_burst_seq::type_id::create("seq");
        if (!seq.randomize() with {
            num_packets == 4;
            min_pkt_len == 4;
            max_pkt_len == 4;
        }) `uvm_error(get_type_name(), "Randomization failed")
        seq.start(env.master_agent.sqr);
        #400;
        phase.drop_objection(this);
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (mcnt.count != EXPECTED_BEATS)
            `uvm_error("BEAT_DROP",
                $sformatf("master monitor observed %0d beats, expected %0d (first-beat swallow?)",
                          mcnt.count, EXPECTED_BEATS))
        else
            `uvm_info(get_type_name(),
                $sformatf("OK: all %0d beats observed on master", mcnt.count), UVM_LOW)
    endfunction

endclass
