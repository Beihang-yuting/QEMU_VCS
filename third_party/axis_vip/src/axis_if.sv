interface axis_if #(
    parameter int TDATA_WIDTH = 512,   // 默认最大值，兼容 PCIe 256/512 位宽
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 512,   // 默认最大值，兼容 PCIe tuser 各通道宽度
    parameter bit HAS_TSTRB   = 1,
    parameter bit HAS_TKEEP   = 1,
    parameter bit HAS_TLAST   = 1
)(
    input logic aclk,
    input logic aresetn
);

    logic                       tvalid;
    logic                       tready;
    logic [TDATA_WIDTH-1:0]     tdata;
    logic [TDATA_WIDTH/8-1:0]   tstrb;
    logic [TDATA_WIDTH/8-1:0]   tkeep;
    logic                       tlast;
    logic [TID_WIDTH-1:0]       tid;
    logic [TDEST_WIDTH-1:0]     tdest;
    logic [TUSER_WIDTH-1:0]     tuser;

    // Master clocking block
    clocking master_cb @(posedge aclk);
        default input #1step output #0;
        output tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
        input  tready;
    endclocking

    // Slave clocking block
    clocking slave_cb @(posedge aclk);
        default input #1step output #0;
        output tready;
        input  tvalid, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    // Monitor clocking block — sample after NBA settles (Observed region)
    // so DUT registered outputs are visible in the same cycle they are driven
    clocking monitor_cb @(posedge aclk);
        default input #0;
        input tvalid, tready, tdata, tstrb, tkeep, tlast, tid, tdest, tuser;
    endclocking

    // Modports
    modport master_mp  (clocking master_cb,  input aclk, aresetn);
    modport slave_mp   (clocking slave_cb,   input aclk, aresetn);
    modport monitor_mp (clocking monitor_cb, input aclk, aresetn);

    // Protocol checker control signals (set by UVM axis_protocol_checker)
    logic        chk_en_tvalid_stability;
    logic        chk_en_tdata_stability;
    logic        chk_en_tlast_integrity;
    logic        chk_en_tid_consistency;
    logic        chk_en_tdest_consistency;
    logic        chk_en_tkeep_tstrb_relation;
    logic        chk_en_reset_signal_check;
    logic        chk_en_x_z_check;
    logic        chk_en_handshake_timeout;
    int unsigned chk_handshake_timeout_cycles;

    initial begin
        chk_en_tvalid_stability     = 0;
        chk_en_tdata_stability      = 0;
        chk_en_tlast_integrity      = 0;
        chk_en_tid_consistency      = 0;
        chk_en_tdest_consistency    = 0;
        chk_en_tkeep_tstrb_relation = 0;
        chk_en_reset_signal_check   = 0;
        chk_en_x_z_check           = 0;
        chk_en_handshake_timeout    = 0;
        chk_handshake_timeout_cycles = 1000;
    end

endinterface
