//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Virtual Sequencer
//-----------------------------------------------------------------------------

class pcie_tl_virtual_sequencer extends uvm_sequencer;
    `uvm_component_utils(pcie_tl_virtual_sequencer)

    //--- Sub-sequencer references ---
    uvm_sequencer #(pcie_tl_tlp)  rc_seqr;
    uvm_sequencer #(pcie_tl_tlp)  ep_seqr;

    //--- Shared component references ---
    pcie_tl_fc_manager    fc_mgr;
    pcie_tl_tag_manager   tag_mgr;

    function new(string name = "pcie_tl_virtual_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction

endclass
