//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Environment Configuration
//-----------------------------------------------------------------------------

class pcie_tl_env_config extends uvm_object;
    `uvm_object_utils(pcie_tl_env_config)

    //--- Role ---
    bit                       rc_agent_enable  = 1;
    bit                       ep_agent_enable  = 1;
    uvm_active_passive_enum   rc_is_active     = UVM_ACTIVE;
    uvm_active_passive_enum   ep_is_active     = UVM_ACTIVE;

    //--- Interface mode ---
    pcie_tl_if_mode_e         if_mode          = TLM_MODE;

    //--- FC ---
    bit                       fc_enable        = 1;
    bit                       infinite_credit  = 0;
    int                       init_ph_credit   = 32;
    int                       init_pd_credit   = 256;
    int                       init_nph_credit  = 32;
    int                       init_npd_credit  = 256;
    int                       init_cplh_credit = 32;
    int                       init_cpld_credit = 256;

    //--- Bandwidth shaper ---
    bit                       shaper_enable    = 0;
    real                      avg_rate         = 0.0;
    int                       burst_size       = 4096;

    //--- Tag ---
    bit                       extended_tag_enable  = 1;
    bit                       phantom_func_enable  = 0;
    int                       max_outstanding      = 1024;

    //--- PCIe Capability parameters ---
    mps_e                     max_payload_size         = MPS_256;
    mrrs_e                    max_read_request_size    = MRRS_512;
    rcb_e                     read_completion_boundary = RCB_64;
    bit                       no_snoop_enable          = 0;

    //--- Ordering ---
    bit                       relaxed_ordering_enable    = 1;
    bit                       id_based_ordering_enable   = 1;
    bit                       bypass_ordering            = 0;

    //--- Coverage (all default OFF) ---
    bit                       cov_enable          = 0;
    bit                       tlp_basic_cov       = 0;
    bit                       fc_state_cov        = 0;
    bit                       tag_usage_cov       = 0;
    bit                       ordering_cov        = 0;
    bit                       error_inject_cov    = 0;

    //--- Scoreboard ---
    bit                       scb_enable              = 1;
    bit                       ordering_check_enable   = 1;
    bit                       completion_check_enable = 1;
    bit                       data_integrity_enable   = 1;

    //--- EP auto-response ---
    bit                       ep_auto_response   = 1;
    int                       response_delay_min = 0;
    int                       response_delay_max = 10;

    //--- Completion Timeout ---
    int                       cpl_timeout_ns     = 50000;

    //--- Link Delay ---
    bit                       link_delay_enable              = 0;
    int                       rc2ep_latency_min_ns           = 0;
    int                       rc2ep_latency_max_ns           = 0;
    int                       ep2rc_latency_min_ns           = 0;
    int                       ep2rc_latency_max_ns           = 0;
    int                       link_delay_update_interval     = 16;

    //--- Switch ---
    bit                    switch_enable = 0;
    pcie_tl_switch_config  switch_cfg;

    //--- SR-IOV / Function ---
    bit              sriov_enable         = 0;
    int              num_pfs              = 1;
    int              max_vfs_per_pf       = 256;
    int              default_num_vfs      = 0;
    bit [15:0]       pf_vendor_id         = 16'hABCD;
    bit [15:0]       pf_device_id         = 16'h1234;
    bit [15:0]       vf_device_id         = 16'h1235;
    bit              ari_enable           = 0;

    //--- TLP Prefix ---
    bit              prefix_enable        = 0;
    bit              pasid_enable         = 0;
    int              pasid_width          = 20;
    bit              pasid_exe_supported  = 0;
    bit              pasid_priv_supported = 0;
    bit              ext_tph_enable       = 0;
    bit              ide_enable           = 0;
    bit              mriov_enable         = 0;
    int              max_e2e_prefix       = 4;

    function new(string name = "pcie_tl_env_config");
        super.new(name);
    endfunction

endclass
