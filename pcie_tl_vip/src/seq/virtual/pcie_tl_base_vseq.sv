class pcie_tl_base_vseq extends uvm_sequence;
    `uvm_object_utils(pcie_tl_base_vseq)
    uvm_sequencer #(pcie_tl_tlp) rc_seqr;
    uvm_sequencer #(pcie_tl_tlp) ep_seqr;
    pcie_tl_fc_manager  fc_mgr;
    pcie_tl_tag_manager tag_mgr;
    function new(string name = "pcie_tl_base_vseq"); super.new(name); endfunction
    task pre_body();
        pcie_tl_virtual_sequencer v_seqr;
        if ($cast(v_seqr, m_sequencer)) begin
            rc_seqr = v_seqr.rc_seqr;
            ep_seqr = v_seqr.ep_seqr;
            fc_mgr  = v_seqr.fc_mgr;
            tag_mgr = v_seqr.tag_mgr;
        end
    endtask
endclass
