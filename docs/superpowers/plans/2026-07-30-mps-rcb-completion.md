# MPS/RCB Long-Read Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a VCS regression that exhaustively validates long Memory Read Completion fragmentation for every supported MPS and RCB pair, then make every response path comply with it.

**Architecture:** A new UVM test observes the Completion stream for one request at a time and computes the expected fragment boundaries from `(address, length, MPS, RCB)`.  The three existing Completion generators retain their interfaces but use the same per-iteration clamp: remaining bytes, MPS, and distance to the next RCB boundary.

**Tech Stack:** SystemVerilog, UVM 1.2, PCIe TL VIP, Synopsys VCS.

---

### Task 1: Add a failing MPS/RCB Completion matrix regression

**Files:**
- Modify: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv`
- Test: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv`

- [ ] **Step 1: Add a Completion observer and matrix test class**

  Add a `pcie_tl_mps_rcb_matrix_test` after `pcie_tl_mps_sweep_test`.  The test sweeps `MPS_{128,256,512,1024,2048,4096}` and `RCB_{64,128}`, sends a request larger than MPS from offsets `0`, `4`, `32`, and `RCB-4`, and records every observed CplD.  For each CplD, assert:

  ```systemverilog
  bytes_to_rcb = rcb_bytes - (cpl.lower_addr % rcb_bytes);
  if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
  if (cpl.payload.size() > mps_bytes || cpl.payload.size() > bytes_to_rcb)
      `uvm_error("MPS_RCB", "Completion exceeds MPS or crosses RCB")
  if (cpl.byte_count != remaining[11:0] || cpl.lower_addr != cur_addr[6:0])
      `uvm_error("MPS_RCB", "Completion byte_count/lower_addr mismatch")
  ```

  Check RC-to-EP and EP-to-RC streams separately, and verify the concatenated data length is the original request length.

- [ ] **Step 2: Build and run the new test before changing completion generation**

  Run from the VCS host project root:

  ```bash
  vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
      -f pcie_tl_vip/sim/filelist_local.f -top pcie_tl_tb_top \
      -Mdir=build/mps-rcb-red/csrc -o build/mps-rcb-red/simv \
      -l build/mps-rcb-red/compile.log
  build/mps-rcb-red/simv +UVM_TESTNAME=pcie_tl_mps_rcb_matrix_test \
      -l logs/mps_rcb_red.log
  ```

  Expected: the MPS=128/RCB=64 case fails when its second CplD is 128 bytes,
  proving the new check detects the existing RCB violation.

### Task 2: Correct EP Completion fragmentation

**Files:**
- Modify: `pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv:182-202`
- Test: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv`

- [ ] **Step 1: Apply the per-Completion RCB clamp**

  Replace the first-completion special case in `handle_mem_read` with the
  same calculation on every loop iteration:

  ```systemverilog
  bytes_to_rcb = rcb_bytes - (cur_addr % rcb_bytes);
  if (bytes_to_rcb == 0) bytes_to_rcb = rcb_bytes;
  chunk = mps_bytes;
  if (bytes_to_rcb < chunk) chunk = bytes_to_rcb;
  if (chunk > remaining) chunk = remaining;
  ```

- [ ] **Step 2: Re-run the matrix and confirm RC-to-EP reads pass**

  ```bash
  build/mps-rcb-red/simv +UVM_TESTNAME=pcie_tl_mps_rcb_matrix_test \
      +MPS_RCB_DIRECTION=RC_TO_EP -l logs/mps_rcb_ep_green.log
  ```

  Expected: all 12 configurations pass for EP-generated Completion streams.

### Task 3: Correct RC Completion fragmentation on both RC paths

**Files:**
- Modify: `pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv:112-130`
- Modify: `pcie_tl_vip/src/env/pcie_tl_env.sv:631-649`
- Test: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv`

- [ ] **Step 1: Apply the same per-Completion RCB clamp to `send_mem_completion`**

  Use the exact `bytes_to_rcb` and `chunk` calculation from Task 2 in
  `pcie_tl_rc_driver::send_mem_completion`.

- [ ] **Step 2: Apply the same calculation to legacy `rc_auto_respond`**

  Replace its `cpl_idx == 0` special case with the exact per-iteration clamp
  so EP DMA reads receive legal Completion boundaries without unified memory.

- [ ] **Step 3: Run the whole matrix and confirm both directions pass**

  ```bash
  build/mps-rcb-red/simv +UVM_TESTNAME=pcie_tl_mps_rcb_matrix_test \
      -l logs/mps_rcb_matrix.log
  ```

  Expected: `MPS_RCB PASS configurations=12 directions=2` and zero UVM errors
  or fatals.

### Task 4: Regress existing VIP and bridge behavior

**Files:**
- Test: `pcie_tl_vip/tests/pcie_tl_advanced_test.sv`
- Test: `vcs-tb/cosim_xrc_driver.sv`

- [ ] **Step 1: Run the existing completion-split regression**

  ```bash
  build/mps-rcb-red/simv +UVM_TESTNAME=pcie_tl_cpl_split_test \
      -l logs/cpl_split_regression.log
  ```

  Expected: zero UVM errors or fatals.

- [ ] **Step 2: Rebuild and run the established QEMU/VCS byte-enable DMA regression**

  Build a fresh `simv` directory using `pcie_tl_vip/sim/filelist_cosim.f`,
  then start QEMU and VCS with `+BE_MATRIX_SELFTEST`.  Expected:

  ```text
  BE_MATRIX PASS cases=240
  UVM_ERROR=0
  UVM_FATAL=0
  qemu_data_faults=0
  ```

- [ ] **Step 3: Inspect the final diff and commit**

  ```bash
  git diff --check
  git add pcie_tl_vip/src/agent/pcie_tl_ep_driver.sv \
          pcie_tl_vip/src/agent/pcie_tl_rc_driver.sv \
          pcie_tl_vip/src/env/pcie_tl_env.sv \
          pcie_tl_vip/tests/pcie_tl_advanced_test.sv
  git commit -m "fix(vip): enforce MPS and RCB completion boundaries"
  ```

  Expected: the commit contains only Completion segmentation and its
  regression coverage; do not include unrelated worktree changes.
