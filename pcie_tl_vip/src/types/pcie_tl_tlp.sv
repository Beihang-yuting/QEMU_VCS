//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - TLP Transaction Classes
//-----------------------------------------------------------------------------

//=============================================================================
// Callback base class for config space
//=============================================================================
virtual class pcie_cfg_callback extends uvm_object;

    function new(string name = "pcie_cfg_callback");
        super.new(name);
    endfunction

    pure virtual function void on_read(bit [11:0] addr, ref bit [31:0] data);

    pure virtual function void on_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);

endclass

//=============================================================================
// Coverage callback base class
//=============================================================================
virtual class pcie_tl_coverage_callback extends uvm_object;

    function new(string name = "pcie_tl_coverage_callback");
        super.new(name);
    endfunction

    pure virtual function void sample(uvm_sequence_item tlp);

endclass

//=============================================================================
// Capability structures
//=============================================================================
class pcie_capability extends uvm_object;
    `uvm_object_utils(pcie_capability)

    bit [7:0]  cap_id;
    bit [7:0]  next_ptr;
    bit [7:0]  offset;       // location in config space
    bit [7:0]  data[];       // capability data bytes

    function new(string name = "pcie_capability");
        super.new(name);
    endfunction
endclass

class pcie_ext_capability extends uvm_object;
    `uvm_object_utils(pcie_ext_capability)

    bit [15:0] cap_id;
    bit [3:0]  cap_ver;
    bit [11:0] next_ptr;
    bit [11:0] offset;       // location in extended config space
    bit [7:0]  data[];

    function new(string name = "pcie_ext_capability");
        super.new(name);
    endfunction
endclass

//=============================================================================
// Base TLP class
//=============================================================================
class pcie_tl_tlp extends uvm_sequence_item;
    `uvm_object_utils(pcie_tl_tlp)

    //--- Header common fields ---
    rand tlp_fmt_e              fmt;
    rand tlp_type_e             type_f;
    rand tlp_kind_e             kind;
    rand bit [2:0]              tc;
    rand bit                    th;
    rand bit                    td;
    rand bit                    ep_bit;       // Poisoned (avoid name clash with 'ep')
    rand bit [2:0]              attr;         // [0]=RO, [1]=IDO, [2]=NS
    rand bit [9:0]              length;       // in DW, 0 means 1024
    rand bit [15:0]             requester_id;
    rand bit [9:0]              tag;          // 10-bit Extended Tag
    rand bit [7:0]              payload[];

    //--- Error injection metadata ---
    rand bit                    inject_ecrc_err;
    rand bit                    inject_lcrc_err;
    rand bit                    inject_poisoned;
    rand bit                    violate_ordering;
    rand bit [31:0]             field_bitmask;
    rand tlp_constraint_mode_e  constraint_mode_sel;

    //--- Default constraints: no error injection (only in LEGAL mode) ---
    constraint c_no_inject {
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> inject_ecrc_err  == 0;
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> inject_lcrc_err  == 0;
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> inject_poisoned  == 0;
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> violate_ordering == 0;
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> field_bitmask    == 0;
    }

    constraint c_default_mode {
        soft constraint_mode_sel == CONSTRAINT_LEGAL;
    }

    //--- Bound payload size regardless of mode ---
    constraint c_max_payload {
        payload.size() <= 4096;
    }

    //--- No payload for no-data TLPs ---
    constraint c_no_data_no_payload {
        (fmt == FMT_3DW_NO_DATA || fmt == FMT_4DW_NO_DATA) -> payload.size() == 0;
    }

    constraint c_legal_tc {
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> tc == 0;
    }

    function new(string name = "pcie_tl_tlp");
        super.new(name);
    endfunction

    // Determine TLP category for ordering
    virtual function tlp_category_e get_category();
        case (kind)
            TLP_MEM_WR, TLP_MSG, TLP_MSGD:
                return TLP_CAT_POSTED;
            TLP_MEM_RD, TLP_MEM_RD_LK, TLP_IO_RD, TLP_IO_WR,
            TLP_CFG_RD0, TLP_CFG_WR0, TLP_CFG_RD1, TLP_CFG_WR1,
            TLP_ATOMIC_FETCHADD, TLP_ATOMIC_SWAP, TLP_ATOMIC_CAS:
                return TLP_CAT_NON_POSTED;
            TLP_CPL, TLP_CPLD, TLP_CPL_LK, TLP_CPLD_LK:
                return TLP_CAT_COMPLETION;
            default:
                return TLP_CAT_NON_POSTED;
        endcase
    endfunction

    // Whether this TLP requires a Completion
    virtual function bit requires_completion();
        return (get_category() == TLP_CAT_NON_POSTED);
    endfunction

    // Whether this TLP carries data
    virtual function bit has_data();
        return (fmt == FMT_3DW_WITH_DATA || fmt == FMT_4DW_WITH_DATA);
    endfunction

    // Whether this TLP uses 4DW header
    virtual function bit is_4dw();
        return (fmt == FMT_4DW_NO_DATA || fmt == FMT_4DW_WITH_DATA);
    endfunction

    // Get payload size in bytes
    virtual function int get_payload_size();
        return payload.size();
    endfunction

    // Get payload size in DW (for FC credit calculation)
    virtual function int get_data_credits();
        if (!has_data()) return 0;
        return (payload.size() + 3) / 4;  // round up to DW
    endfunction

    virtual function string convert2string();
        string s;
        s = $sformatf("TLP: kind=%s fmt=%s type=0x%02h tc=%0d len=%0d req_id=0x%04h tag=0x%03h",
                       kind.name(), fmt.name(), type_f, tc, length, requester_id, tag);
        if (has_data())
            s = {s, $sformatf(" payload_bytes=%0d", payload.size())};
        if (inject_ecrc_err || inject_poisoned || violate_ordering || field_bitmask != 0)
            s = {s, $sformatf(" [ERR_INJ: ecrc=%0b poison=%0b ord_vio=%0b bitmask=0x%08h]",
                               inject_ecrc_err, inject_poisoned, violate_ordering, field_bitmask)};
        return s;
    endfunction

    virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        pcie_tl_tlp rhs_;
        if (!$cast(rhs_, rhs)) return 0;
        return (kind          == rhs_.kind          &&
                fmt           == rhs_.fmt           &&
                type_f        == rhs_.type_f        &&
                tc            == rhs_.tc            &&
                th            == rhs_.th            &&
                td            == rhs_.td            &&
                ep_bit        == rhs_.ep_bit        &&
                attr          == rhs_.attr          &&
                length        == rhs_.length        &&
                requester_id  == rhs_.requester_id  &&
                tag           == rhs_.tag           &&
                payload.size() == rhs_.payload.size());
    endfunction

    virtual function void do_print(uvm_printer printer);
        super.do_print(printer);
        printer.print_string("kind",         kind.name());
        printer.print_string("fmt",          fmt.name());
        printer.print_field("type_f",        type_f, 5, UVM_HEX);
        printer.print_field("tc",            tc, 3, UVM_DEC);
        printer.print_field("length",        length, 10, UVM_DEC);
        printer.print_field("requester_id",  requester_id, 16, UVM_HEX);
        printer.print_field("tag",           tag, 10, UVM_HEX);
        printer.print_field("attr",          attr, 3, UVM_BIN);
        printer.print_field("payload_size",  payload.size(), 32, UVM_DEC);
    endfunction
endclass

//=============================================================================
// Memory TLP (Read / Write)
//=============================================================================
class pcie_tl_mem_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_mem_tlp)

    rand bit [63:0]  addr;
    rand bit [3:0]   first_be;
    rand bit [3:0]   last_be;
    rand bit         is_64bit;

    constraint c_mem_fmt {
        (kind == TLP_MEM_RD || kind == TLP_MEM_RD_LK) -> {
            is_64bit -> fmt == FMT_4DW_NO_DATA;
            !is_64bit -> fmt == FMT_3DW_NO_DATA;
        }
        (kind == TLP_MEM_WR) -> {
            is_64bit -> fmt == FMT_4DW_WITH_DATA;
            !is_64bit -> fmt == FMT_3DW_WITH_DATA;
        }
    }

    constraint c_mem_type {
        (kind == TLP_MEM_RD)    -> type_f == TLP_TYPE_MEM_RD;
        (kind == TLP_MEM_RD_LK) -> type_f == TLP_TYPE_MEM_RD_LK;
        (kind == TLP_MEM_WR)    -> type_f == TLP_TYPE_MEM_WR;
    }

    constraint c_mem_addr {
        !is_64bit -> addr[63:32] == 0;
    }

    // MPS/MRRS config (set by env/sequence before randomization)
    int cfg_mps_bytes  = 256;
    int cfg_mrrs_bytes = 512;

    // MPS: MEM_WR payload must not exceed MPS
    constraint c_mps_limit {
        (constraint_mode_sel == CONSTRAINT_LEGAL && kind == TLP_MEM_WR) -> {
            payload.size() <= cfg_mps_bytes;
        }
    }

    // MRRS: MEM_RD length (in bytes) must not exceed MRRS
    constraint c_mrrs_limit {
        (constraint_mode_sel == CONSTRAINT_LEGAL &&
         (kind == TLP_MEM_RD || kind == TLP_MEM_RD_LK)) -> {
            ((length == 0) ? 4096 : (length * 4)) <= cfg_mrrs_bytes;
        }
    }

    // 4KB boundary: TLP must not cross a 4KB address boundary
    constraint c_4kb_boundary {
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> {
            (length == 0) -> (addr[11:0] == 0);
            (length != 0) -> ((addr[11:0] + length * 4) <= 4096);
        }
    }

    constraint c_legal_be {
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> {
            (length == 1) -> {
                last_be == 0;
                first_be != 0;
                first_be inside {4'h1, 4'h2, 4'h3, 4'h4, 4'h6, 4'h7,
                                 4'h8, 4'hC, 4'hE, 4'hF};
            }
            (length >= 2) -> {
                first_be != 0;
                last_be  != 0;
            }
        }
    }

    constraint c_legal_payload {
        (constraint_mode_sel == CONSTRAINT_LEGAL && kind == TLP_MEM_WR) -> {
            payload.size() == ((length == 0) ? 4096 : length * 4);
        }
    }

    function new(string name = "pcie_tl_mem_tlp");
        super.new(name);
    endfunction

    virtual function string convert2string();
        string s = super.convert2string();
        s = {s, $sformatf(" addr=0x%016h first_be=0x%01h last_be=0x%01h 64bit=%0b",
                           addr, first_be, last_be, is_64bit)};
        return s;
    endfunction
endclass

//=============================================================================
// IO TLP (Read / Write)
//=============================================================================
class pcie_tl_io_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_io_tlp)

    rand bit [31:0]  addr;
    rand bit [3:0]   first_be;

    constraint c_io_fmt {
        (kind == TLP_IO_RD) -> fmt == FMT_3DW_NO_DATA;
        (kind == TLP_IO_WR) -> fmt == FMT_3DW_WITH_DATA;
    }

    constraint c_io_type {
        type_f == TLP_TYPE_IO_RD;
    }

    constraint c_io_length {
        length == 1;
    }

    constraint c_io_payload {
        (constraint_mode_sel == CONSTRAINT_LEGAL && kind == TLP_IO_WR) -> {
            payload.size() == 4;
        }
    }

    function new(string name = "pcie_tl_io_tlp");
        super.new(name);
    endfunction
endclass

//=============================================================================
// Config TLP (Read / Write, Type 0 / Type 1)
//=============================================================================
class pcie_tl_cfg_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_cfg_tlp)

    rand bit [15:0]  completer_id;   // Bus/Dev/Func of target
    rand bit [9:0]   reg_num;        // Register number (DW address)
    rand bit [3:0]   first_be;

    constraint c_cfg_fmt {
        (kind == TLP_CFG_RD0 || kind == TLP_CFG_RD1) -> fmt == FMT_3DW_NO_DATA;
        (kind == TLP_CFG_WR0 || kind == TLP_CFG_WR1) -> fmt == FMT_3DW_WITH_DATA;
    }

    constraint c_cfg_type {
        (kind == TLP_CFG_RD0 || kind == TLP_CFG_WR0) -> type_f == TLP_TYPE_CFG_RD0;
        (kind == TLP_CFG_RD1 || kind == TLP_CFG_WR1) -> type_f == TLP_TYPE_CFG_RD1;
    }

    constraint c_cfg_length {
        length == 1;
    }

    constraint c_cfg_payload {
        (constraint_mode_sel == CONSTRAINT_LEGAL &&
         (kind == TLP_CFG_WR0 || kind == TLP_CFG_WR1)) -> {
            payload.size() == 4;
        }
    }

    function new(string name = "pcie_tl_cfg_tlp");
        super.new(name);
    endfunction

    function bit [11:0] get_cfg_addr();
        return {reg_num, 2'b00};
    endfunction
endclass

//=============================================================================
// Completion TLP
//=============================================================================
class pcie_tl_cpl_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_cpl_tlp)

    rand bit [15:0]    completer_id;
    rand cpl_status_e  cpl_status;
    rand bit           bcm;          // Byte Count Modified
    rand bit [11:0]    byte_count;
    rand bit [6:0]     lower_addr;

    constraint c_cpl_fmt {
        (kind == TLP_CPL || kind == TLP_CPL_LK)   -> fmt == FMT_3DW_NO_DATA;
        (kind == TLP_CPLD || kind == TLP_CPLD_LK) -> fmt == FMT_3DW_WITH_DATA;
    }

    constraint c_cpl_type {
        (kind == TLP_CPL || kind == TLP_CPLD)     -> type_f == TLP_TYPE_CPL;
        (kind == TLP_CPL_LK || kind == TLP_CPLD_LK) -> type_f == TLP_TYPE_CPL_LK;
    }

    constraint c_cpl_legal {
        (constraint_mode_sel == CONSTRAINT_LEGAL) -> {
            cpl_status == CPL_STATUS_SC;
        }
    }

    constraint c_cpl_payload {
        (constraint_mode_sel == CONSTRAINT_LEGAL && kind == TLP_CPLD) -> {
            payload.size() == ((length == 0) ? 4096 : length * 4);
        }
    }

    function new(string name = "pcie_tl_cpl_tlp");
        super.new(name);
    endfunction
endclass

//=============================================================================
// Message TLP
//=============================================================================
class pcie_tl_msg_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_msg_tlp)

    rand msg_code_e   msg_code;
    rand bit [63:0]   msg_addr;      // used for address-routed messages
    rand bit [15:0]   target_id;     // used for ID-routed messages

    constraint c_msg_fmt {
        (kind == TLP_MSG)  -> fmt == FMT_4DW_NO_DATA;
        (kind == TLP_MSGD) -> fmt == FMT_4DW_WITH_DATA;
    }

    constraint c_msg_type {
        type_f inside {TLP_TYPE_MSG_RC, TLP_TYPE_MSG_ADDR, TLP_TYPE_MSG_ID,
                       TLP_TYPE_MSG_BCAST, TLP_TYPE_MSG_LOCAL, TLP_TYPE_MSG_PME_TO_ACK};
    }

    function new(string name = "pcie_tl_msg_tlp");
        super.new(name);
    endfunction
endclass

//=============================================================================
// AtomicOp TLP
//=============================================================================
class pcie_tl_atomic_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_atomic_tlp)

    rand bit [63:0]       addr;
    rand bit              is_64bit;
    rand atomic_op_size_e op_size;

    constraint c_atomic_fmt {
        fmt == FMT_3DW_WITH_DATA || fmt == FMT_4DW_WITH_DATA;
        is_64bit -> (fmt == FMT_4DW_WITH_DATA);
        !is_64bit -> (fmt == FMT_3DW_WITH_DATA);
    }

    constraint c_atomic_type {
        (kind == TLP_ATOMIC_FETCHADD) -> type_f == TLP_TYPE_ATOMIC_FETCHADD;
        (kind == TLP_ATOMIC_SWAP)     -> type_f == TLP_TYPE_ATOMIC_SWAP;
        (kind == TLP_ATOMIC_CAS)      -> type_f == TLP_TYPE_ATOMIC_CAS;
    }

    constraint c_atomic_length {
        (kind == TLP_ATOMIC_FETCHADD || kind == TLP_ATOMIC_SWAP) -> {
            (op_size == ATOMIC_SIZE_32) -> length == 1;
            (op_size == ATOMIC_SIZE_64) -> length == 2;
        }
        (kind == TLP_ATOMIC_CAS) -> {
            (op_size == ATOMIC_SIZE_32) -> length == 2;
            (op_size == ATOMIC_SIZE_64) -> length == 4;
        }
    }

    function new(string name = "pcie_tl_atomic_tlp");
        super.new(name);
    endfunction
endclass

//=============================================================================
// Vendor Defined Message TLP
//=============================================================================
class pcie_tl_vendor_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_vendor_tlp)

    rand bit [15:0]  vendor_id;
    rand bit [7:0]   vendor_data[];

    constraint c_vendor_fmt {
        (kind == TLP_VENDOR_MSG)  -> fmt == FMT_4DW_NO_DATA;
        (kind == TLP_VENDOR_MSGD) -> fmt == FMT_4DW_WITH_DATA;
    }

    constraint c_vendor_type {
        type_f == TLP_TYPE_VENDOR_MSG;
    }

    function new(string name = "pcie_tl_vendor_tlp");
        super.new(name);
    endfunction
endclass

//=============================================================================
// LTR (Latency Tolerance Reporting) TLP
//=============================================================================
class pcie_tl_ltr_tlp extends pcie_tl_tlp;
    `uvm_object_utils(pcie_tl_ltr_tlp)

    rand bit [9:0]   snoop_latency_value;
    rand bit [2:0]   snoop_latency_scale;
    rand bit         snoop_requirement;
    rand bit [9:0]   no_snoop_latency_value;
    rand bit [2:0]   no_snoop_latency_scale;
    rand bit         no_snoop_requirement;

    constraint c_ltr_fmt {
        fmt == FMT_4DW_WITH_DATA;
    }

    constraint c_ltr_type {
        type_f == TLP_TYPE_MSG_RC;
    }

    constraint c_ltr_length {
        length == 1;
    }

    function new(string name = "pcie_tl_ltr_tlp");
        super.new(name);
    endfunction
endclass
