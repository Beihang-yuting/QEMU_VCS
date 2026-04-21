//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Flow Control Manager
//-----------------------------------------------------------------------------

class pcie_tl_fc_manager extends uvm_object;
    `uvm_object_utils(pcie_tl_fc_manager)

    //--- Credit counters ---
    fc_credit_t posted_header;
    fc_credit_t posted_data;
    fc_credit_t non_posted_header;
    fc_credit_t non_posted_data;
    fc_credit_t completion_header;
    fc_credit_t completion_data;

    //--- Switches ---
    bit fc_enable       = 1;
    bit infinite_credit = 0;

    function new(string name = "pcie_tl_fc_manager");
        super.new(name);
    endfunction

    //=========================================================================
    // Initialize credits from configuration
    //=========================================================================
    function void init_credits(int ph, int pd, int nph, int npd, int cplh, int cpld);
        posted_header      = '{current: ph,   limit: ph};
        posted_data        = '{current: pd,   limit: pd};
        non_posted_header  = '{current: nph,  limit: nph};
        non_posted_data    = '{current: npd,  limit: npd};
        completion_header  = '{current: cplh, limit: cplh};
        completion_data    = '{current: cpld, limit: cpld};
    endfunction

    //=========================================================================
    // Check if enough credit to send TLP
    //=========================================================================
    function bit check_credit(pcie_tl_tlp tlp);
        int hdr_needed = 1;
        int data_needed;
        fc_credit_t hdr_credit, data_credit;

        if (!fc_enable) return 1;
        if (infinite_credit) return 1;

        data_needed = tlp.get_data_credits();
        get_credit_ref(tlp.get_category(), hdr_credit, data_credit);

        return (hdr_credit.current >= hdr_needed &&
                data_credit.current >= data_needed);
    endfunction

    //=========================================================================
    // Consume credit after sending TLP
    //=========================================================================
    function void consume_credit(pcie_tl_tlp tlp);
        int data_needed;
        fc_credit_t hdr_credit, data_credit;

        if (!fc_enable) return;
        if (infinite_credit) return;

        data_needed = tlp.get_data_credits();
        get_credit_ref(tlp.get_category(), hdr_credit, data_credit);

        hdr_credit.current  -= 1;
        data_credit.current -= data_needed;

        set_credit(tlp.get_category(), hdr_credit, data_credit);
    endfunction

    //=========================================================================
    // Return credit (from peer)
    //=========================================================================
    function void return_credit(fc_type_e fc_type, int amount);
        case (fc_type)
            FC_POSTED_HDR:    posted_header.current     = min_uint(posted_header.current + amount, posted_header.limit);
            FC_POSTED_DATA:   posted_data.current       = min_uint(posted_data.current + amount, posted_data.limit);
            FC_NONPOSTED_HDR: non_posted_header.current = min_uint(non_posted_header.current + amount, non_posted_header.limit);
            FC_NONPOSTED_DATA:non_posted_data.current   = min_uint(non_posted_data.current + amount, non_posted_data.limit);
            FC_CPL_HDR:       completion_header.current = min_uint(completion_header.current + amount, completion_header.limit);
            FC_CPL_DATA:      completion_data.current   = min_uint(completion_data.current + amount, completion_data.limit);
        endcase
    endfunction

    //=========================================================================
    // Error injection
    //=========================================================================
    function void force_credit_overflow();
        posted_header.current     = posted_header.limit + 100;
        posted_data.current       = posted_data.limit + 100;
        non_posted_header.current = non_posted_header.limit + 100;
        non_posted_data.current   = non_posted_data.limit + 100;
        completion_header.current = completion_header.limit + 100;
        completion_data.current   = completion_data.limit + 100;
    endfunction

    function void force_credit_underflow();
        posted_header.current     = 0;
        posted_data.current       = 0;
        non_posted_header.current = 0;
        non_posted_data.current   = 0;
        completion_header.current = 0;
        completion_data.current   = 0;
    endfunction

    //=========================================================================
    // Query
    //=========================================================================
    function int get_available(fc_type_e fc_type);
        case (fc_type)
            FC_POSTED_HDR:     return posted_header.current;
            FC_POSTED_DATA:    return posted_data.current;
            FC_NONPOSTED_HDR:  return non_posted_header.current;
            FC_NONPOSTED_DATA: return non_posted_data.current;
            FC_CPL_HDR:        return completion_header.current;
            FC_CPL_DATA:       return completion_data.current;
            default:           return 0;
        endcase
    endfunction

    //=========================================================================
    // Internal helpers
    //=========================================================================
    protected function void get_credit_ref(tlp_category_e cat,
                                            output fc_credit_t hdr, output fc_credit_t data);
        case (cat)
            TLP_CAT_POSTED:     begin hdr = posted_header;     data = posted_data;     end
            TLP_CAT_NON_POSTED: begin hdr = non_posted_header; data = non_posted_data; end
            TLP_CAT_COMPLETION: begin hdr = completion_header;  data = completion_data;  end
        endcase
    endfunction

    protected function void set_credit(tlp_category_e cat,
                                        fc_credit_t hdr, fc_credit_t data);
        case (cat)
            TLP_CAT_POSTED:     begin posted_header = hdr;     posted_data = data;     end
            TLP_CAT_NON_POSTED: begin non_posted_header = hdr; non_posted_data = data; end
            TLP_CAT_COMPLETION: begin completion_header = hdr;  completion_data = data;  end
        endcase
    endfunction

    protected function int unsigned min_uint(int unsigned a, int unsigned b);
        return (a < b) ? a : b;
    endfunction

endclass
