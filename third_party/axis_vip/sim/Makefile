# axis_vip/sim/Makefile
# Cross-tool simulation build

TEST ?= axis_sanity_test
SEED ?= random
VERBOSITY ?= UVM_MEDIUM
TOOL ?= vcs

UVM_ARGS = +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERBOSITY)
FILELIST = filelist.f

# ---- VCS ----
VCS_OPTS = -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
           -debug_access+all \
           +incdir+../src +incdir+../sequences +incdir+../tests \
           -f $(FILELIST) -l compile.log

vcs_compile:
	vcs $(VCS_OPTS) -o simv

vcs_run: vcs_compile
	./simv $(UVM_ARGS) +ntb_random_seed=$(SEED) -l run.log

# ---- Xcelium ----
XRUN_OPTS = -sv -uvm -64bit -timescale 1ns/1ps \
            +incdir+../src +incdir+../sequences +incdir+../tests \
            -f $(FILELIST) -l compile.log

xcelium_compile:
	xrun -compile $(XRUN_OPTS)

xcelium_run:
	xrun $(XRUN_OPTS) $(UVM_ARGS) -svseed $(SEED) -l run.log

# ---- Questa ----
QUESTA_OPTS = -sv -timescale 1ns/1ps \
              +incdir+../src +incdir+../sequences +incdir+../tests

questa_compile:
	vlib work
	vlog $(QUESTA_OPTS) -f $(FILELIST) -l compile.log

questa_run: questa_compile
	vsim -c -do "run -all; quit" $(UVM_ARGS) -sv_seed $(SEED) work.tb_top -l run.log

# ---- Convenience targets ----
ifeq ($(TOOL),vcs)
compile: vcs_compile
run: vcs_run
else ifeq ($(TOOL),xcelium)
compile: xcelium_compile
run: xcelium_run
else ifeq ($(TOOL),questa)
compile: questa_compile
run: questa_run
endif

regression:
	$(MAKE) run TEST=axis_sanity_test
	$(MAKE) run TEST=axis_backpressure_test
	$(MAKE) run TEST=axis_bandwidth_test
	$(MAKE) run TEST=axis_reset_test
	$(MAKE) run TEST=axis_phase_jump_test
	$(MAKE) run TEST=axis_full_regression_test
	$(MAKE) run TEST=axis_misalign_test

clean:
	rm -rf simv simv.dbin csrc work xcelium.d INCA_libs *.log *.key DVEfiles ucli.key

.PHONY: compile run regression clean vcs_compile vcs_run xcelium_compile xcelium_run questa_compile questa_run
