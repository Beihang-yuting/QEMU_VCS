import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_base_test extends uvm_test;
    `uvm_component_utils(pcie_tl_base_test)
    pcie_tl_env        env;
    pcie_tl_env_config cfg;
    function new(string name = "pcie_tl_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cfg = pcie_tl_env_config::type_id::create("cfg");
        configure_test();
        uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
        env = pcie_tl_env::type_id::create("env", this);
    endfunction
    // Override in derived tests
    virtual function void configure_test();
        cfg.if_mode = TLM_MODE;
    endfunction
    // Convenience methods
    function void configure_fc(bit enable, bit infinite = 0);
        cfg.fc_enable = enable; cfg.infinite_credit = infinite;
    endfunction
    function void configure_tags(bit extended = 1, bit phantom = 0, int max_out = 1024);
        cfg.extended_tag_enable = extended; cfg.phantom_func_enable = phantom;
        cfg.max_outstanding = max_out;
    endfunction
    function void enable_coverage();
        cfg.cov_enable = 1; cfg.tlp_basic_cov = 1; cfg.fc_state_cov = 1;
        cfg.tag_usage_cov = 1; cfg.ordering_cov = 1; cfg.error_inject_cov = 1;
    endfunction
    function void set_mode(pcie_tl_if_mode_e mode);
        cfg.if_mode = mode;
    endfunction
endclass
