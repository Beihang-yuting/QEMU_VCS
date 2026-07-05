class axis_agent #(
    parameter int TDATA_WIDTH = `AXIS_MAX_TDATA,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1,
    parameter bit HAS_TSTRB   = 0,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
) extends uvm_agent;

    `uvm_component_param_utils(axis_agent#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST))

    typedef axis_master_driver#(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) m_drv_t;
    typedef axis_slave_driver #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) s_drv_t;
    typedef axis_monitor      #(TDATA_WIDTH,TID_WIDTH,TDEST_WIDTH,TUSER_WIDTH,HAS_TSTRB,HAS_TKEEP,HAS_TLAST) mon_t;

    axis_config              cfg;
    axis_sequencer           sqr;
    m_drv_t                  m_drv;
    s_drv_t                  s_drv;
    mon_t                    mon;
    axis_bandwidth_controller bw_ctrl;
    axis_reset_listener      rst_listener;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(axis_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("NOCFG", "axis_config not found in config_db")

        mon = mon_t::type_id::create("mon", this);
        rst_listener = axis_reset_listener::type_id::create("rst_listener", this);

        if (cfg.agent_mode != AXIS_MONITOR_ONLY && cfg.is_active == UVM_ACTIVE) begin
            sqr     = axis_sequencer::type_id::create("sqr", this);
            bw_ctrl = axis_bandwidth_controller::type_id::create("bw_ctrl", this);
            if (cfg.agent_mode == AXIS_MASTER)
                m_drv = m_drv_t::type_id::create("m_drv", this);
            else if (cfg.agent_mode == AXIS_SLAVE)
                s_drv = s_drv_t::type_id::create("s_drv", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (cfg.agent_mode != AXIS_MONITOR_ONLY && cfg.is_active == UVM_ACTIVE) begin
            if (cfg.agent_mode == AXIS_MASTER && m_drv != null) begin
                m_drv.seq_item_port.connect(sqr.seq_item_export);
                m_drv.bw_ctrl = bw_ctrl;
            end else if (cfg.agent_mode == AXIS_SLAVE && s_drv != null) begin
                s_drv.seq_item_port.connect(sqr.seq_item_export);
                s_drv.bw_ctrl = bw_ctrl;
            end
            rst_listener.sqr     = sqr;
            rst_listener.bw_ctrl = bw_ctrl;
        end
    endfunction

    function void set_in_reset(bit rst);
        mon.set_in_reset(rst);
        if (m_drv != null) m_drv.set_in_reset(rst);
        if (s_drv != null) s_drv.set_in_reset(rst);
    endfunction

endclass
