import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Switch-mode read-back demo: 1 RC (USP) + 2 EP (DSP).
//
// Non-unified memory: each EP uses its sparse mem_space (any address, no alloc).
// For each EP: RC writes a distinct golden pattern to that DSP's routing-window
// address (rw_seq WRITE routes through the switch to EP[ep], stored in its
// sparse mem), then RC issues rw_seq READ at the same address. The switch routes
// the MRd downstream to EP[ep]; the CplD is routed back upstream to RC and
// rc_driver.handle_completion folds it onto the request object. Asserts the
// read-back rdata == the written pattern -> proves RC reads EP[ep]'s data.
//=============================================================================
class pcie_tl_switch_rw_readback_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_switch_rw_readback_test)

    function new(string name = "pcie_tl_switch_rw_readback_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        pcie_tl_switch_config sw_cfg;
        super.configure_test();
        cfg.use_unified_mem = 1'b0;   // EP sparse mem_space: any addr, no alloc
        sw_cfg = new("sw_cfg");
        sw_cfg.num_ds_ports = 2;      // 2 EPs
        sw_cfg.p2p_enable   = 1;
        sw_cfg.init_defaults();
        cfg.switch_enable   = 1;
        cfg.switch_cfg      = sw_cfg;
        cfg.fc_enable       = 1;
        cfg.infinite_credit = 1;
        cfg.cpl_timeout_ns  = 200000;
        cfg.scb_enable      = 1;
        cfg.ep_auto_response= 1;
    endfunction

    task run_phase(uvm_phase phase);
        int num_eps;
        phase.raise_objection(this);
        `uvm_info("SW_RB", "=== switch rw_seq read-back (1 RC + 2 EP) START ===", UVM_LOW)

        num_eps = cfg.switch_cfg.num_ds_ports;

        for (int ep_idx = 0; ep_idx < num_eps; ep_idx++) begin
            automatic int ep = ep_idx;
            bit [63:0] a; byte golden[]; int sz = 64;
            pcie_tl_rw_seq wr, rw;
            bit ok = 1'b1;

            // DSP[ep] routing-window base address (switch routes reads/writes here
            // downstream to EP[ep]). Sparse EP mem serves any address.
            a = {32'h0, cfg.switch_cfg.ds_mem_base[ep]};
            golden = new[sz];
            foreach (golden[i]) golden[i] = byte'((8'hA0 + ep*8'h20 + i) & 8'hFF);
            `uvm_info("SW_RB", $sformatf("EP%0d window addr=0x%016h", ep, a), UVM_LOW)

            // RC writes golden to EP[ep] through the switch
            wr = pcie_tl_rw_seq::type_id::create($sformatf("rc_wr_ep%0d", ep));
            wr.op = PCIE_RW_WRITE; wr.addr = a; wr.byte_len = sz;
            wr.wdata = new[sz];
            foreach (wr.wdata[i]) wr.wdata[i] = golden[i];
            wr.start(env.rc_agent.sequencer);
            #1us;

            // RC reads it back through the switch
            rw = pcie_tl_rw_seq::type_id::create($sformatf("rc_rd_ep%0d", ep));
            rw.op = PCIE_RW_READ; rw.addr = a; rw.byte_len = sz;
            rw.start(env.rc_agent.sequencer);

            `uvm_info("SW_RB", $sformatf("RC->EP%0d READ status=%s rdata.size=%0d",
                                          ep, rw.status.name(), rw.rdata.size()), UVM_LOW)
            if (rw.status != PCIE_RW_OK)
                `uvm_error("SW_RB", $sformatf("EP%0d READ status not OK: %s", ep, rw.status.name()))
            else if (rw.rdata.size() < sz)
                `uvm_error("SW_RB", $sformatf("EP%0d rdata.size=%0d < %0d", ep, rw.rdata.size(), sz))
            else begin
                for (int i = 0; i < sz; i++)
                    if (rw.rdata[i] !== golden[i]) begin
                        `uvm_error("SW_RB", $sformatf("EP%0d byte[%0d] exp=0x%02h got=0x%02h",
                                                       ep, i, golden[i], rw.rdata[i]))
                        ok = 1'b0; break;
                    end
                if (ok) `uvm_info("SW_RB", $sformatf("RC read EP%0d: read-back MATCH (%0d bytes)", ep, sz), UVM_LOW)
            end
        end

        `uvm_info("SW_RB", "=== switch rw_seq read-back END ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
