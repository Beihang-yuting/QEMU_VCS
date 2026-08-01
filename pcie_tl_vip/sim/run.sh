#!/bin/bash
source /home/ryan/set-env.sh
cd /home/ryan/pcie_work/pcie_tl_vip/sim
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f filelist.f -o simv -l compile.log
TEST=${1:-pcie_tl_smoke_test}
TAG_BIT=${TAG_BIT:-8}
case "$TAG_BIT" in
    8|10) ;;
    *) echo "TAG_BIT must be 8 or 10, got: $TAG_BIT" >&2; exit 2 ;;
esac
./simv +UVM_TESTNAME=$TEST +UVM_VERBOSITY=UVM_MEDIUM +TAG_BIT=$TAG_BIT -l run_$TEST.log
