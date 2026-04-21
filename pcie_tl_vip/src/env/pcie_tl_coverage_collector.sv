//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Coverage Collector
//-----------------------------------------------------------------------------

class pcie_tl_coverage_collector extends uvm_subscriber #(pcie_tl_tlp);
    `uvm_component_utils(pcie_tl_coverage_collector)

    //--- Switches (all default OFF) ---
    bit cov_enable          = 0;
    bit tlp_basic_enable    = 0;
    bit fc_state_enable     = 0;
    bit tag_usage_enable    = 0;
    bit ordering_enable     = 0;
    bit error_inject_enable = 0;
    bit mps_mrrs_enable     = 0;

    //--- Shared component references ---
    pcie_tl_fc_manager    fc_mgr;
    pcie_tl_tag_manager   tag_mgr;

    //--- PCIe config references ---
    int cfg_mps_bytes  = 256;
    int cfg_mrrs_bytes = 512;
    int cfg_rcb_bytes  = 64;

    //--- Sampled TLP ---
    pcie_tl_tlp  sampled_tlp;
    tlp_category_e prev_category;
    tlp_category_e curr_category;
    bit            is_first_tlp = 1;

    //--- Covergroups (lazily constructed) ---
    covergroup tlp_basic_cg;
        cp_kind:    coverpoint sampled_tlp.kind;
        cp_fmt:     coverpoint sampled_tlp.fmt;
        cp_length:  coverpoint sampled_tlp.length {
            bins len_zero     = {0};           // 0 means 1024 DW in PCIe
            bins len_small    = {[1:16]};
            bins len_medium   = {[17:128]};
            bins len_large    = {[129:512]};
            bins len_max_half = {[513:1023]};
        }
        cp_tc:      coverpoint sampled_tlp.tc;
        cp_attr_ro: coverpoint sampled_tlp.attr[0];
        cp_attr_ido:coverpoint sampled_tlp.attr[1];
        cp_attr_ns: coverpoint sampled_tlp.attr[2];
    endgroup

    covergroup fc_state_cg;
        cp_ph_credit: coverpoint fc_mgr.posted_header.current {
            bins empty  = {0};
            bins low    = {[1:4]};
            bins normal = {[5:32]};
            bins high   = {[33:$]};
        }
        cp_nph_credit: coverpoint fc_mgr.non_posted_header.current {
            bins empty  = {0};
            bins low    = {[1:4]};
            bins normal = {[5:32]};
            bins high   = {[33:$]};
        }
        cp_cplh_credit: coverpoint fc_mgr.completion_header.current {
            bins empty  = {0};
            bins low    = {[1:4]};
            bins normal = {[5:32]};
            bins high   = {[33:$]};
        }
        cp_infinite: coverpoint fc_mgr.infinite_credit;
    endgroup

    covergroup tag_usage_cg;
        cp_outstanding: coverpoint tag_mgr.get_outstanding_count() {
            bins empty     = {0};
            bins low       = {[1:64]};
            bins mid       = {[65:256]};
            bins high      = {[257:512]};
            bins near_full = {[513:1023]};
            bins full      = {1024};
        }
        cp_phantom:  coverpoint tag_mgr.phantom_func_enable;
        cp_extended: coverpoint tag_mgr.extended_tag_enable;
    endgroup

    covergroup ordering_cg;
        cp_prev_cat: coverpoint prev_category;
        cp_curr_cat: coverpoint curr_category;
        cx_ordering: cross cp_prev_cat, cp_curr_cat;
    endgroup

    covergroup error_injection_cg;
        cp_ecrc:     coverpoint sampled_tlp.inject_ecrc_err;
        cp_poisoned: coverpoint sampled_tlp.inject_poisoned;
        cp_ord_vio:  coverpoint sampled_tlp.violate_ordering;
        cp_bitmask:  coverpoint (sampled_tlp.field_bitmask != 0) {
            bins no_flip  = {0};
            bins has_flip = {1};
        }
    endgroup

    covergroup mps_mrrs_cg;
        cp_mps: coverpoint cfg_mps_bytes {
            bins mps_128  = {128};
            bins mps_256  = {256};
            bins mps_512  = {512};
            bins mps_1024 = {1024};
            bins mps_2048 = {2048};
            bins mps_4096 = {4096};
        }
        cp_mrrs: coverpoint cfg_mrrs_bytes {
            bins mrrs_128  = {128};
            bins mrrs_256  = {256};
            bins mrrs_512  = {512};
            bins mrrs_1024 = {1024};
            bins mrrs_2048 = {2048};
            bins mrrs_4096 = {4096};
        }
        cp_rcb: coverpoint cfg_rcb_bytes {
            bins rcb_64  = {64};
            bins rcb_128 = {128};
        }
    endgroup

    //--- User callbacks ---
    pcie_tl_coverage_callback user_callbacks[$];

    function new(string name = "pcie_tl_coverage_collector", uvm_component parent = null);
        super.new(name, parent);
        // Embedded covergroups must be constructed in new()
        tlp_basic_cg = new();
        fc_state_cg = new();
        tag_usage_cg = new();
        ordering_cg = new();
        error_injection_cg = new();
        mps_mrrs_cg = new();
    endfunction

    //=========================================================================
    // Build phase
    //=========================================================================
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
    endfunction

    //=========================================================================
    // Enable/Disable all
    //=========================================================================
    function void enable_all();
        cov_enable          = 1;
        tlp_basic_enable    = 1;
        fc_state_enable     = 1;
        tag_usage_enable    = 1;
        ordering_enable     = 1;
        error_inject_enable = 1;
        mps_mrrs_enable     = 1;
    endfunction

    function void disable_all();
        cov_enable          = 0;
        tlp_basic_enable    = 0;
        fc_state_enable     = 0;
        tag_usage_enable    = 0;
        ordering_enable     = 0;
        error_inject_enable = 0;
        mps_mrrs_enable     = 0;
    endfunction

    //=========================================================================
    // Subscriber write: called for each TLP
    //=========================================================================
    function void write(pcie_tl_tlp t);
        if (!cov_enable) begin
            // Still call user callbacks even when internal coverage is off
            foreach (user_callbacks[i])
                user_callbacks[i].sample(t);
            return;
        end

        sampled_tlp = t;
        curr_category = t.get_category();

        if (tlp_basic_enable && tlp_basic_cg != null)
            tlp_basic_cg.sample();
        if (fc_state_enable && fc_state_cg != null && fc_mgr != null)
            fc_state_cg.sample();
        if (tag_usage_enable && tag_usage_cg != null && tag_mgr != null)
            tag_usage_cg.sample();
        if (ordering_enable && ordering_cg != null && !is_first_tlp)
            ordering_cg.sample();
        if (error_inject_enable && error_injection_cg != null)
            error_injection_cg.sample();
        if (mps_mrrs_enable && mps_mrrs_cg != null)
            mps_mrrs_cg.sample();

        prev_category = curr_category;
        is_first_tlp = 0;

        foreach (user_callbacks[i])
            user_callbacks[i].sample(t);
    endfunction

    //=========================================================================
    // User callback registration
    //=========================================================================
    function void register_callback(pcie_tl_coverage_callback cb);
        user_callbacks.push_back(cb);
    endfunction

endclass
