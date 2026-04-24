import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

// Test 1: TLM Loopback - Memory Read/Write
class pcie_tl_smoke_mem_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_smoke_mem_test)
    function new(string name = "pcie_tl_smoke_mem_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        pcie_tl_rc_ep_rdwr_vseq seq = pcie_tl_rc_ep_rdwr_vseq::type_id::create("seq");
        phase.raise_objection(this);
        seq.addr = 64'h0000_0001_0000_0000;
        seq.length = 4; seq.is_read = 0;
        seq.start(env.v_seqr);
        #100ns;
        seq.is_read = 1;
        seq.start(env.v_seqr);
        #100ns;
        phase.drop_objection(this);
    endtask
endclass

// Test 2: Config Space Enumeration
class pcie_tl_smoke_cfg_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_smoke_cfg_test)
    function new(string name = "pcie_tl_smoke_cfg_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        pcie_tl_bar_enum_seq seq = pcie_tl_bar_enum_seq::type_id::create("seq");
        phase.raise_objection(this);
        seq.target_bdf = 16'h0100; seq.num_bars = 2;
        seq.start(env.rc_agent.sequencer);
        #200ns;
        phase.drop_objection(this);
    endtask
endclass

// Test 3: Error Injection - Poisoned TLP
class pcie_tl_smoke_err_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_smoke_err_test)
    function new(string name = "pcie_tl_smoke_err_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        pcie_tl_err_poisoned_seq seq = pcie_tl_err_poisoned_seq::type_id::create("seq");
        phase.raise_objection(this);
        seq.start(env.rc_agent.sequencer);
        #200ns;
        phase.drop_objection(this);
    endtask
endclass

// Test 4: FC Back-pressure
class pcie_tl_smoke_fc_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_smoke_fc_test)
    function new(string name = "pcie_tl_smoke_fc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        cfg.init_ph_credit = 16;  // Enough credits for 8 burst writes
        cfg.init_pd_credit = 1024;
    endfunction
    task run_phase(uvm_phase phase);
        pcie_tl_backpressure_vseq seq = pcie_tl_backpressure_vseq::type_id::create("seq");
        phase.raise_objection(this);
        seq.burst_count = 8;
        seq.start(env.v_seqr);
        #500ns;
        phase.drop_objection(this);
    endtask
endclass

// Test 5: Ordering Compliance
class pcie_tl_smoke_ordering_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_smoke_ordering_test)
    function new(string name = "pcie_tl_smoke_ordering_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    virtual function void configure_test();
        super.configure_test();
        enable_coverage();
    endfunction
    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        // Send mixed P/NP/CPL
        begin
            pcie_tl_mem_wr_seq wr = pcie_tl_mem_wr_seq::type_id::create("wr");
            wr.addr = 64'hA000; wr.length = 1; wr.first_be = 4'hF; wr.last_be = 4'h0;
            wr.start(env.rc_agent.sequencer);
        end
        begin
            pcie_tl_mem_rd_seq rd = pcie_tl_mem_rd_seq::type_id::create("rd");
            rd.addr = 64'hB000; rd.length = 1; rd.first_be = 4'hF; rd.last_be = 4'h0;
            rd.start(env.rc_agent.sequencer);
        end
        #500ns;
        phase.drop_objection(this);
    endtask
endclass
