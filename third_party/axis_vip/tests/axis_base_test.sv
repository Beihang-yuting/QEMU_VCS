import uvm_pkg::*;
`include "uvm_macros.svh"
import axis_pkg::*;

class axis_base_test extends uvm_test;

    `uvm_component_utils(axis_base_test)

    axis_env_default_t env;
    axis_config master_cfg;
    axis_config slave_cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        master_cfg = axis_config::type_id::create("master_cfg");
        slave_cfg  = axis_config::type_id::create("slave_cfg");
        master_cfg.agent_mode = AXIS_MASTER;
        master_cfg.is_active  = UVM_ACTIVE;
        slave_cfg.agent_mode  = AXIS_SLAVE;
        slave_cfg.is_active   = UVM_ACTIVE;
        uvm_config_db#(axis_config)::set(this, "env", "master_cfg", master_cfg);
        uvm_config_db#(axis_config)::set(this, "env", "slave_cfg",  slave_cfg);
        env = axis_env_default_t::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        uvm_top.print_topology();
    endfunction

endclass
