module axis_dummy_dut #(
    parameter int TDATA_WIDTH = 32,
    parameter int TID_WIDTH   = 4,
    parameter int TDEST_WIDTH = 4,
    parameter int TUSER_WIDTH = 1
)(
    input  logic                       aclk,
    input  logic                       aresetn,
    input  logic                       s_tvalid,
    output logic                       s_tready,
    input  logic [TDATA_WIDTH-1:0]     s_tdata,
    input  logic [TDATA_WIDTH/8-1:0]   s_tstrb,
    input  logic [TDATA_WIDTH/8-1:0]   s_tkeep,
    input  logic                       s_tlast,
    input  logic [TID_WIDTH-1:0]       s_tid,
    input  logic [TDEST_WIDTH-1:0]     s_tdest,
    input  logic [TUSER_WIDTH-1:0]     s_tuser,
    output logic                       m_tvalid,
    input  logic                       m_tready,
    output logic [TDATA_WIDTH-1:0]     m_tdata,
    output logic [TDATA_WIDTH/8-1:0]   m_tstrb,
    output logic [TDATA_WIDTH/8-1:0]   m_tkeep,
    output logic                       m_tlast,
    output logic [TID_WIDTH-1:0]       m_tid,
    output logic [TDEST_WIDTH-1:0]     m_tdest,
    output logic [TUSER_WIDTH-1:0]     m_tuser
);

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            m_tvalid <= 1'b0;
            m_tdata  <= '0;
            m_tstrb  <= '0;
            m_tkeep  <= '0;
            m_tlast  <= 1'b0;
            m_tid    <= '0;
            m_tdest  <= '0;
            m_tuser  <= '0;
        end else if (s_tvalid && s_tready) begin
            m_tvalid <= 1'b1;
            m_tdata  <= s_tdata;
            m_tstrb  <= s_tstrb;
            m_tkeep  <= s_tkeep;
            m_tlast  <= s_tlast;
            m_tid    <= s_tid;
            m_tdest  <= s_tdest;
            m_tuser  <= s_tuser;
        end else if (m_tvalid && m_tready) begin
            m_tvalid <= 1'b0;
        end
    end

    assign s_tready = !m_tvalid || m_tready;

endmodule
