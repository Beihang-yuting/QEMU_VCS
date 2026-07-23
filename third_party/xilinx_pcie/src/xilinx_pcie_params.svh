`ifndef XILINX_PCIE_PARAMS_SVH
`define XILINX_PCIE_PARAMS_SVH

// ---- Xilinx PG213 PCIe BFM compile-time width parameters ----
// Override at compile time with +define+XILINX_DATA_W=N
// (renamed from the generic DATA_WIDTH to avoid macro collision with
//  axis_vip / other IP that also define DATA_WIDTH).
// Supported widths: 64 / 128 / 256 / 512

`ifndef XILINX_DATA_W
  `define XILINX_DATA_W 256
`endif

`define XILINX_KEEP_W       (`XILINX_DATA_W/32)

// Per-channel TUSER widths from PG213 (Tables 2-35/2-48/2-52/2-42 et al).
// PG213: 64/128/256-bit interfaces share the SAME tuser width; only the
// 512-bit (straddle) interface is wider. byte_en/parity FIELD positions are
// fixed across 64/128/256 — only the number of meaningful bits scales.
//   64/128/256 -> RQ 62 / RC 75 / CQ 88 / CC 33
//   512        -> RQ 137 / RC 161 / CQ 183 / CC 81
`define XILINX_RQ_TUSER_W   ((`XILINX_DATA_W==512)?137:62)
`define XILINX_RC_TUSER_W   ((`XILINX_DATA_W==512)?161:75)
`define XILINX_CQ_TUSER_W   ((`XILINX_DATA_W==512)?183:88)
`define XILINX_CC_TUSER_W   ((`XILINX_DATA_W==512)? 81:33)

`endif
