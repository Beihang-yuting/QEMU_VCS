#!/bin/bash
source /home/ryan/set-env.sh
cd /home/ryan/pcie_work/pcie_tl_vip/sim
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelist.f -o simv -l compile.log
TEST=${1:-pcie_tl_smoke_test}
./simv +UVM_TESTNAME=$TEST +UVM_VERBOSITY=UVM_MEDIUM -l run_$TEST.log
