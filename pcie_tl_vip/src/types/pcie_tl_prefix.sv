//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - TLP Prefix
// Represents a single TLP Prefix DW (Local or End-to-End)
//-----------------------------------------------------------------------------

class pcie_tl_prefix extends uvm_object;
    `uvm_object_utils(pcie_tl_prefix)

    rand tlp_prefix_type_e  prefix_type;
    rand bit [31:0]         raw_dw;

    constraint c_type_matches_raw {
        raw_dw[31:24] == prefix_type;
    }

    function new(string name = "pcie_tl_prefix");
        super.new(name);
    endfunction

    //--- Type query ---
    function bit is_local();
        return raw_dw[28] == 0;  // Type[4] == 0
    endfunction

    function bit is_e2e();
        return raw_dw[28] == 1;  // Type[4] == 1
    endfunction

    //--- PASID field accessors (valid when prefix_type == PREFIX_PASID) ---
    function bit [19:0] get_pasid();
        return raw_dw[19:0];
    endfunction

    function bit get_pasid_exe();
        return raw_dw[21];
    endfunction

    function bit get_pasid_pmr();
        return raw_dw[22];
    endfunction

    //--- Extended TPH accessor (valid when prefix_type == PREFIX_EXT_TPH) ---
    function bit [7:0] get_tph_st_upper();
        return raw_dw[23:16];
    endfunction

    //--- MR-IOV accessor (valid when prefix_type == PREFIX_MRIOV) ---
    function bit [7:0] get_mriov_vhid();
        return raw_dw[15:8];
    endfunction

    //--- IDE accessors (valid when prefix_type == PREFIX_IDE) ---
    function bit get_ide_tee();
        return raw_dw[23];
    endfunction

    function bit [7:0] get_ide_stream_id();
        return raw_dw[21:14];
    endfunction

    function bit get_ide_pcrc();
        return raw_dw[12];
    endfunction

    function bit get_ide_mac();
        return raw_dw[11];
    endfunction

    function bit get_ide_keyset();
        return raw_dw[10];
    endfunction

    //--- Vendor-Defined accessors ---
    function bit [3:0] get_vendor_subfield();
        return raw_dw[23:20];
    endfunction

    function bit [19:0] get_vendor_data();
        return raw_dw[19:0];
    endfunction

    //--- Factory helpers ---
    static function pcie_tl_prefix create_pasid(
        bit [19:0] pasid, bit exe = 0, bit pmr = 0);
        pcie_tl_prefix p = new("pasid_prefix");
        p.prefix_type = PREFIX_PASID;
        p.raw_dw = {8'h91, 1'b0, pmr, exe, 1'b0, pasid};
        return p;
    endfunction

    static function pcie_tl_prefix create_mriov(bit [7:0] vhid);
        pcie_tl_prefix p = new("mriov_prefix");
        p.prefix_type = PREFIX_MRIOV;
        p.raw_dw = {8'h80, 8'h00, vhid, 8'h00};
        return p;
    endfunction

    static function pcie_tl_prefix create_ext_tph(bit [7:0] st_upper);
        pcie_tl_prefix p = new("ext_tph_prefix");
        p.prefix_type = PREFIX_EXT_TPH;
        p.raw_dw = {8'h90, st_upper, 16'h0000};
        return p;
    endfunction

    static function pcie_tl_prefix create_ide(
        bit tee, bit [7:0] stream_id, bit pcrc, bit mac, bit keyset);
        pcie_tl_prefix p = new("ide_prefix");
        p.prefix_type = PREFIX_IDE;
        p.raw_dw = {8'h92, tee, 1'b0, stream_id, 1'b0, pcrc, mac, keyset, 10'h000};
        return p;
    endfunction

    //--- String conversion ---
    virtual function string convert2string();
        return $sformatf("Prefix: type=%s raw=0x%08h local=%0b",
                         prefix_type.name(), raw_dw, is_local());
    endfunction

    //--- Compare ---
    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        pcie_tl_prefix rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (prefix_type == rhs_.prefix_type && raw_dw == rhs_.raw_dw);
    endfunction

endclass
