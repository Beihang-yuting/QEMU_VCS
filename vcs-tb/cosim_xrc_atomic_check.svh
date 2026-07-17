// cosim_xrc_atomic_check.svh — inbound AtomicOp self-check for the XRC cosim.
//
// Simulates the EP (requester) issuing FetchAdd / Swap / CAS AtomicOp TLPs to
// QEMU host memory through bridge_vcs_dma_atomic_rc, and verifies both the
// returned ORIGINAL value and the post-op memory (via a follow-up DMA read).
// Mirrors the C wire test tests-side (/tmp/atomic_e2e_test.c logic).
//
// Integration: `include this file inside a class/module that already does
//   import cosim_bridge_pkg::*;
// then call, after the RC device is realized (see bridge_vcs_is_realized_rc):
//   cosim_xrc_atomic_selfcheck(rc, 64'h0000_2000);
//
// DPI array widths (see bridge/vcs/bridge_vcs.sv):
//   bridge_vcs_dma_write_rc / read_rc : data[16]
//   bridge_vcs_dma_atomic_rc          : operands[4], old_out[2]
//   op codes: 2=FETCHADD 3=SWAP 4=CAS   (== DMA_DIR_ATOMIC_*)

task automatic cosim_xrc_atomic_selfcheck(int rc, longint unsigned addr);
  int unsigned seed[16];
  int unsigned rd[16];
  int unsigned ops[4];
  int unsigned old_val[2];
  int r;

  // ---- seed the datum: 32-bit = 100 ----
  foreach (seed[i]) seed[i] = 0;
  seed[0] = 100;
  r = bridge_vcs_dma_write_rc(rc, addr, seed, 4);
  if (r != 0) `uvm_error("ATOMIC", "seed DMA write failed")

  // ---- FetchAdd += 5  -> returns old=100, memory becomes 105 ----
  foreach (ops[i]) ops[i] = 0;
  ops[0] = 5;
  r = bridge_vcs_dma_atomic_rc(rc, addr, 2, 4, ops, old_val);
  if (r != 0 || old_val[0] != 100)
    `uvm_error("ATOMIC", $sformatf("FetchAdd old=%0d (want 100) r=%0d", old_val[0], r))
  r = bridge_vcs_dma_read_rc(rc, addr, rd, 4);
  if (rd[0] != 105) `uvm_error("ATOMIC", $sformatf("FetchAdd mem=%0d (want 105)", rd[0]))

  // ---- Swap -> 0xDEAD, returns old=105 ----
  foreach (ops[i]) ops[i] = 0;
  ops[0] = 32'hDEAD;
  r = bridge_vcs_dma_atomic_rc(rc, addr, 3, 4, ops, old_val);
  if (old_val[0] != 105) `uvm_error("ATOMIC", $sformatf("Swap old=%0d (want 105)", old_val[0]))
  r = bridge_vcs_dma_read_rc(rc, addr, rd, 4);
  if (rd[0] != 32'hDEAD) `uvm_error("ATOMIC", $sformatf("Swap mem=0x%08x (want 0xDEAD)", rd[0]))

  // ---- CAS hit: compare=0xDEAD swap=0xBEEF -> old=0xDEAD, mem=0xBEEF ----
  foreach (ops[i]) ops[i] = 0;
  ops[0] = 32'hDEAD; ops[1] = 32'hBEEF;
  r = bridge_vcs_dma_atomic_rc(rc, addr, 4, 4, ops, old_val);
  if (old_val[0] != 32'hDEAD) `uvm_error("ATOMIC", $sformatf("CAS-hit old=0x%08x (want 0xDEAD)", old_val[0]))
  r = bridge_vcs_dma_read_rc(rc, addr, rd, 4);
  if (rd[0] != 32'hBEEF) `uvm_error("ATOMIC", $sformatf("CAS-hit mem=0x%08x (want 0xBEEF)", rd[0]))

  // ---- CAS miss: compare=0x1111 swap=0x2222 -> old=0xBEEF, mem UNCHANGED ----
  foreach (ops[i]) ops[i] = 0;
  ops[0] = 32'h1111; ops[1] = 32'h2222;
  r = bridge_vcs_dma_atomic_rc(rc, addr, 4, 4, ops, old_val);
  if (old_val[0] != 32'hBEEF) `uvm_error("ATOMIC", $sformatf("CAS-miss old=0x%08x (want 0xBEEF)", old_val[0]))
  r = bridge_vcs_dma_read_rc(rc, addr, rd, 4);
  if (rd[0] != 32'hBEEF) `uvm_error("ATOMIC", $sformatf("CAS-miss mem=0x%08x changed! (want 0xBEEF)", rd[0]))

  `uvm_info("ATOMIC",
            "inbound AtomicOp self-check PASSED (FetchAdd / Swap / CAS-hit / CAS-miss)",
            UVM_LOW)
endtask
