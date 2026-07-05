`ifndef XILINX_PCIE_PARAMS_SVH
`define XILINX_PCIE_PARAMS_SVH

// ---- Xilinx PG213 PCIe BFM compile-time width parameters ----
// Override at compile time with +define+DATA_WIDTH=N
// Supported widths: 64 / 128 / 256 / 512

`ifndef DATA_WIDTH
  `define DATA_WIDTH 256
`endif

`define XILINX_DATA_W       `DATA_WIDTH
`define XILINX_KEEP_W       (`DATA_WIDTH/32)

// Per-channel TUSER widths from PG213 (Tables 2-35/2-48/2-52/2-42 et al)
// 64/128 -> small; 256 -> medium; 512 -> max
`define XILINX_RQ_TUSER_W   ((`DATA_WIDTH==512)?285:((`DATA_WIDTH==256)?137:62))
`define XILINX_RC_TUSER_W   ((`DATA_WIDTH==512)?321:((`DATA_WIDTH==256)?161:75))
`define XILINX_CQ_TUSER_W   ((`DATA_WIDTH==512)?375:((`DATA_WIDTH==256)?183:88))
`define XILINX_CC_TUSER_W   ((`DATA_WIDTH==512)?161:((`DATA_WIDTH==256)? 81:33))

`endif
