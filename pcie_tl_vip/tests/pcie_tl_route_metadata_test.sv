import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_route_metadata_test extends uvm_test;
    `uvm_component_utils(pcie_tl_route_metadata_test)

    function new(string name = "pcie_tl_route_metadata_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        pcie_tl_mem_tlp src;
        pcie_tl_mem_tlp dst;

        phase.raise_objection(this);
        src = pcie_tl_mem_tlp::type_id::create("src");
        if (src.cq_route.valid !== 1'b0 || src.cq_route.vf_index !== -1)
            `uvm_error("CQ_ROUTE", "new TLP route must be invalid with vf_index=-1")

        src.cq_route.valid        = 1'b1;
        src.cq_route.target_bdf   = 16'h0114;
        src.cq_route.target_func  = 8'h14;
        src.cq_route.bar_id       = 3'd2;
        src.cq_route.bar_aperture = 6'd2;
        src.cq_route.bar_offset   = 64'h123;
        src.cq_route.is_vf        = 1'b1;
        src.cq_route.pf_index     = 1;
        src.cq_route.vf_index     = 3;

        if (!$cast(dst, src.clone()))
            `uvm_fatal("CQ_ROUTE", "clone did not preserve pcie_tl_mem_tlp type")
        if (dst.cq_route !== src.cq_route)
            `uvm_error("CQ_ROUTE", "clone lost CQ route metadata")
        phase.drop_objection(this);
    endtask
endclass
