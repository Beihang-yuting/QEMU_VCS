import uvm_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

class xilinx_pcie_adapter_smoke_test extends xilinx_pcie_adapter_base_test;
  `uvm_component_utils(xilinx_pcie_adapter_smoke_test)
  function new(string n, uvm_component p); super.new(n,p); endfunction
endclass
