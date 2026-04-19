// cosim_tlp_transaction.sv — UVM sequence item for TLP transactions
class cosim_tlp_tr extends uvm_sequence_item;
    `uvm_object_utils(cosim_tlp_tr)

    // TLP request fields
    rand bit [2:0]  tlp_type;   // MWr=0, MRd=1, CfgWr=2, CfgRd=3, Cpl=4
    rand bit [63:0] addr;
    rand bit [31:0] data;       // write data (single DWORD)
    rand int        len;
    rand int        tag;

    // Completion fields (filled by driver after DUT responds)
    bit             has_cpl;
    bit [31:0]      cpl_rdata;
    bit             cpl_status;

    // Control flags
    bit             is_shutdown;

    // Constraints for standalone test sequences
    constraint c_len  { len inside {[1:4]}; }
    constraint c_tag  { tag inside {[0:255]}; }
    constraint c_type { tlp_type inside {[0:3]}; }

    function new(string name = "cosim_tlp_tr");
        super.new(name);
        is_shutdown = 0;
        has_cpl     = 0;
    endfunction

    function string convert2string();
        string s;
        s = $sformatf("TLP: type=%0d addr=0x%016h data=0x%08h len=%0d tag=%0d",
                       tlp_type, addr, data, len, tag);
        if (has_cpl)
            s = {s, $sformatf(" -> cpl_rdata=0x%08h status=%0d", cpl_rdata, cpl_status)};
        return s;
    endfunction

    function void do_copy(uvm_object rhs);
        cosim_tlp_tr rhs_;
        super.do_copy(rhs);
        if (!$cast(rhs_, rhs)) return;
        tlp_type    = rhs_.tlp_type;
        addr        = rhs_.addr;
        data        = rhs_.data;
        len         = rhs_.len;
        tag         = rhs_.tag;
        has_cpl     = rhs_.has_cpl;
        cpl_rdata   = rhs_.cpl_rdata;
        cpl_status  = rhs_.cpl_status;
        is_shutdown = rhs_.is_shutdown;
    endfunction

    function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        cosim_tlp_tr rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (super.do_compare(rhs, comparer) &&
                tlp_type  == rhs_.tlp_type &&
                addr      == rhs_.addr &&
                data      == rhs_.data &&
                tag       == rhs_.tag);
    endfunction
endclass
