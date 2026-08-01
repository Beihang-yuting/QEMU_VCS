import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

// Runtime policy regression: TAG_BIT must bind the actual VIP tag pool and
// every generated generic PF/VF configuration image to the same capability.
class pcie_tl_tag_bit_runtime_test extends pcie_tl_base_test;
    `uvm_component_utils(pcie_tl_tag_bit_runtime_test)

    function new(string name = "pcie_tl_tag_bit_runtime_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void configure_test();
        cfg.if_mode          = TLM_MODE;
        cfg.sriov_enable     = 1;
        cfg.num_pfs          = 1;
        cfg.max_vfs_per_pf   = 1;
    endfunction

    function void expect_bit(string label, bit actual, bit expected);
        if (actual !== expected)
            `uvm_error("TAG_BIT", $sformatf("%s: got %0b expected %0b",
                                              label, actual, expected))
        else
            `uvm_info("TAG_BIT", $sformatf("%s: %0b", label, actual), UVM_LOW)
    endfunction

    function void expect_int(string label, int actual, int expected);
        if (actual != expected)
            `uvm_error("TAG_BIT", $sformatf("%s: got %0d expected %0d",
                                              label, actual, expected))
        else
            `uvm_info("TAG_BIT", $sformatf("%s: %0d", label, actual), UVM_LOW)
    endfunction

    task run_phase(uvm_phase phase);
        int tag_bit;
        int expected_pool;
        bit expected_10bit;
        bit [15:0] pf_bdf;
        bit [15:0] vf_bdf;
        bit [31:0] ctrl2;

        phase.raise_objection(this);
        if (!$value$plusargs("TAG_BIT=%d", tag_bit)) begin
            `uvm_fatal("TAG_BIT", "This regression requires +TAG_BIT=8 or +TAG_BIT=10")
        end
        if (tag_bit != 8 && tag_bit != 10) begin
            `uvm_fatal("TAG_BIT", $sformatf("unsupported TAG_BIT=%0d", tag_bit))
        end

        expected_10bit = (tag_bit == 10);
        expected_pool  = expected_10bit ? 1024 : 256;
        expect_bit("tag manager extended mode", env.tag_mgr.extended_tag_enable,
                   expected_10bit);
        expect_int("tag manager pool size", env.tag_mgr.tag_pool[0].size(),
                   expected_pool);

        // Generic config image maintained directly by the environment.
        expect_bit("env Device Capabilities 2 10-bit support",
                   env.cfg_mgr.read(12'h064)[12], expected_10bit);
        env.cfg_mgr.write(12'h068, 32'h0000_1000, 4'hf);
        expect_bit("env Device Control 2 10-bit enable readback",
                   env.cfg_mgr.read(12'h068)[12], expected_10bit);

        // SR-IOV manager must apply the same policy to both PF and VF images.
        pf_bdf = env.func_mgr_sriov.pf_ctx[0].bdf;
        env.func_mgr_sriov.enable_vfs(0, 1);
        vf_bdf = env.func_mgr_sriov.vf_ctx[0][0].bdf;
        expect_bit("PF Device Capabilities 2 10-bit support",
                   env.func_mgr_sriov.cfg_read(pf_bdf, 12'h064)[12], expected_10bit);
        env.func_mgr_sriov.cfg_write(pf_bdf, 12'h068, 32'h0000_1000, 4'hf);
        ctrl2 = env.func_mgr_sriov.cfg_read(pf_bdf, 12'h068);
        expect_bit("PF Device Control 2 10-bit enable readback", ctrl2[12], expected_10bit);

        expect_bit("VF Device Capabilities 2 10-bit support",
                   env.func_mgr_sriov.cfg_read(vf_bdf, 12'h064)[12], expected_10bit);
        env.func_mgr_sriov.cfg_write(vf_bdf, 12'h068, 32'h0000_1000, 4'hf);
        ctrl2 = env.func_mgr_sriov.cfg_read(vf_bdf, 12'h068);
        expect_bit("VF Device Control 2 10-bit enable readback", ctrl2[12], expected_10bit);

        phase.drop_objection(this);
    endtask
endclass
