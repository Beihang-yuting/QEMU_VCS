import uvm_pkg::*;
import pcie_tl_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Read-back demo test for pcie_tl_rw_seq.
//
// Proves the unified op-typed sequence:
//   READ  waits for the Completion(s) and exposes the actual read-back bytes
//         in rw.rdata (+ rw.status). Verified on BOTH the EP requester side
//         (EP reads host_mem) and the RC requester side (RC reads dev_mem[0]).
//   WRITE is fire-and-forget; verified by reading the backing store afterwards.
//=============================================================================
class pcie_tl_rw_readback_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_rw_readback_test)

    function new(string name = "pcie_tl_rw_readback_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        super.configure_test();
        cfg.use_unified_mem = 1'b1;
        cfg.mem_access_mode = PCIE_TL_MEM_PER_BUFFER;
        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;
        cfg.cpl_timeout_ns  = 100000;
        cfg.scb_enable      = 1;
    endfunction

    // Compare rw.rdata against golden; log PASS/FAIL.
    function automatic void check_rdata(bit [7:0] rdata[], byte golden[],
                                        int sz, string tag);
        bit ok = 1'b1;
        if (rdata.size() < sz) begin
            `uvm_error("RB_TEST", $sformatf("%s: rdata.size=%0d < %0d", tag, rdata.size(), sz))
            return;
        end
        for (int i = 0; i < sz; i++)
            if (rdata[i] !== golden[i]) begin
                `uvm_error("RB_TEST", $sformatf("%s: byte[%0d] exp=0x%02h got=0x%02h",
                                                tag, i, golden[i], rdata[i]))
                ok = 1'b0; break;
            end
        if (ok) `uvm_info("RB_TEST", $sformatf("%s: read-back MATCH (%0d bytes)", tag, sz), UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        `uvm_info("RB_TEST", "=== rw_seq read-back demo START ===", UVM_LOW)

        if (env.host_mem == null || env.dev_mem[0] == null)
            `uvm_fatal("RB_TEST", "memory handles null")

        // --- EP side: EP reads host_mem via rw_seq READ ---
        begin
            bit [63:0] a; byte golden[]; int sz = 256;
            pcie_tl_rw_seq rw;
            a = env.host_mem.alloc(sz, 64);
            golden = new[sz];
            foreach (golden[i]) golden[i] = byte'((8'hA0 + i) & 8'hFF);
            env.host_mem.write_mem(a, golden);

            rw = pcie_tl_rw_seq::type_id::create("ep_rd");
            rw.op = PCIE_RW_READ; rw.addr = a; rw.byte_len = sz;
            rw.start(env.ep_agent.sequencer);

            `uvm_info("RB_TEST", $sformatf("EP READ status=%s", rw.status.name()), UVM_LOW)
            if (rw.status != PCIE_RW_OK)
                `uvm_error("RB_TEST", $sformatf("EP READ status not OK: %s", rw.status.name()))
            check_rdata(rw.rdata, golden, sz, "EP_RD_HOST");
            env.host_mem.free(a);
        end

        // --- RC side: RC reads dev_mem[0] via rw_seq READ ---
        begin
            bit [63:0] b; byte golden[]; int sz = 128;
            pcie_tl_rw_seq rw;
            b = env.dev_mem[0].alloc(sz, 64);
            golden = new[sz];
            foreach (golden[i]) golden[i] = byte'((8'h5A ^ i) & 8'hFF);
            env.dev_mem[0].write_mem(b, golden);

            rw = pcie_tl_rw_seq::type_id::create("rc_rd");
            rw.op = PCIE_RW_READ; rw.addr = b; rw.byte_len = sz;
            rw.start(env.rc_agent.sequencer);

            `uvm_info("RB_TEST", $sformatf("RC READ status=%s", rw.status.name()), UVM_LOW)
            if (rw.status != PCIE_RW_OK)
                `uvm_error("RB_TEST", $sformatf("RC READ status not OK: %s", rw.status.name()))
            check_rdata(rw.rdata, golden, sz, "RC_RD_DEV");
            env.dev_mem[0].free(b);
        end

        // --- WRITE demo: rw_seq WRITE to host_mem, confirm via backing store ---
        begin
            bit [63:0] a; byte rd[]; int sz = 64;
            pcie_tl_rw_seq rw;
            a = env.host_mem.alloc(sz, 64);
            rw = pcie_tl_rw_seq::type_id::create("ep_wr");
            rw.op = PCIE_RW_WRITE; rw.addr = a; rw.byte_len = sz;
            rw.wdata = new[sz];
            foreach (rw.wdata[i]) rw.wdata[i] = byte'((8'h3C + i) & 8'hFF);
            rw.start(env.ep_agent.sequencer);
            #2us;   // posted write: allow it to land in the backing store

            env.host_mem.read_mem(a, sz, rd);
            begin
                bit ok = 1'b1;
                for (int i = 0; i < sz; i++)
                    if (rd[i] !== byte'((8'h3C + i) & 8'hFF)) begin
                        `uvm_error("RB_TEST", $sformatf("WR byte[%0d] mismatch", i)) ok = 0; break;
                    end
                if (ok) `uvm_info("RB_TEST", $sformatf("EP_WR_HOST: write verified (%0d bytes)", sz), UVM_LOW)
            end
            env.host_mem.free(a);
        end

        `uvm_info("RB_TEST", "=== rw_seq read-back demo END ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
