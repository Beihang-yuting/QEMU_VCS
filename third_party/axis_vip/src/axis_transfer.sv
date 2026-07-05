class axis_transfer extends uvm_sequence_item;

    rand bit [`AXIS_MAX_TDATA-1:0]   tdata;
    rand bit [`AXIS_MAX_TDATA/8-1:0] tstrb;
    rand bit [`AXIS_MAX_TDATA/8-1:0] tkeep;
    rand bit                         tlast;
    rand bit [`AXIS_MAX_TID-1:0]     tid;
    rand bit [`AXIS_MAX_TDEST-1:0]   tdest;
    rand bit [`AXIS_MAX_TUSER-1:0]   tuser;
    rand int unsigned                delay;

    axis_config cfg;

    `uvm_object_utils_begin(axis_transfer)
        `uvm_field_int(tdata,  UVM_ALL_ON)
        `uvm_field_int(tstrb,  UVM_ALL_ON)
        `uvm_field_int(tkeep,  UVM_ALL_ON)
        `uvm_field_int(tlast,  UVM_ALL_ON)
        `uvm_field_int(tid,    UVM_ALL_ON)
        `uvm_field_int(tdest,  UVM_ALL_ON)
        `uvm_field_int(tuser,  UVM_ALL_ON)
        `uvm_field_int(delay,  UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axis_transfer");
        super.new(name);
    endfunction

    constraint c_data_width {
        (cfg != null) -> (tdata >> cfg.TDATA_WIDTH) == 0;
    }
    constraint c_strb_width {
        (cfg != null) -> (tstrb >> cfg.get_byte_lanes()) == 0;
    }
    constraint c_keep_width {
        (cfg != null) -> (tkeep >> cfg.get_byte_lanes()) == 0;
    }
    constraint c_tid_width {
        (cfg != null) -> (tid >> cfg.TID_WIDTH) == 0;
    }
    constraint c_tdest_width {
        (cfg != null) -> (tdest >> cfg.TDEST_WIDTH) == 0;
    }
    constraint c_tuser_width {
        (cfg != null) -> (tuser >> cfg.TUSER_WIDTH) == 0;
    }
    constraint c_tkeep_tstrb {
        (cfg != null && cfg.HAS_TSTRB && cfg.HAS_TKEEP) -> (tstrb & ~tkeep) == 0;
    }
    constraint c_delay {
        delay inside {[0:20]};
    }
    constraint c_keep_default {
        soft tkeep == ((cfg != null)
                       ? (({`AXIS_MAX_TDATA/8{1'b1}}) >> (`AXIS_MAX_TDATA/8 - cfg.get_byte_lanes()))
                       : 'hF);
    }
    constraint c_strb_default {
        soft tstrb == tkeep;
    }

endclass
