# CoSim PF0 BAR0 Backdoor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Optionally intercept QEMU PF0 BAR0 MMIO before the Xilinx CQ path, dispatch it through a registered backdoor service, return read DWORDs directly to QEMU, and leave the current DUT path unchanged for misses or when no service is installed.

**Architecture:** A new AIP-independent package defines a dynamic-array request, three-state result, and virtual service. `cosim_xrc_driver` learns PF0 identity and BAR0 base from the existing enumeration proxy, performs only topology/aperture gating, then delegates region semantics to the service; handled reads use the existing per-RC scalar completion DPI while handled posted writes produce no completion.

**Tech Stack:** SystemVerilog, UVM 1.2, existing PCIe TL/Xilinx adapter VIP, VCS DPI-C bridge, QEMU CoSim transport.

---

## File map

| File | Responsibility |
| --- | --- |
| `vcs-tb/cosim_bar0_backdoor_pkg.sv` | AIP-free request/result/status types and abstract service contract. |
| `vcs-tb/cosim_xrc_pkg.sv` | Import the service package before including the driver and tests. |
| `vcs-tb/cosim_xrc_driver.sv` | Service lookup, PF0/BAR0 decode, request dispatch, direct CplD, fallback boundary, flush, and counters. |
| `vcs-tb/cosim_bar0_backdoor_test.sv` | Mock-service UVM regression for gating, MISS/HANDLED/ERROR, byte enables, tag/data, and zero-impact fallback. |
| `scripts/build_cosim_multirc.sh` | Compile order and selectable focused test target. |
| `docs/pf0-bar0-backdoor-integration.md` | User-owned AIP adapter/registration recipe, plusargs, completion semantics, and validation procedure. |

The production file list must not contain an AIP path, package, clone, submodule,
credential, or DUT-specific callback. The user compiles and registers the
concrete adapter from their test.

### Task 1: Define the AIP-independent service contract

**Files:**
- Create: `vcs-tb/cosim_bar0_backdoor_pkg.sv`
- Create: `vcs-tb/cosim_bar0_backdoor_test.sv`
- Modify: `vcs-tb/cosim_xrc_pkg.sv:10-18`
- Modify: `scripts/build_cosim_multirc.sh:46-69`

- [ ] **Step 1: Write a compile-failing contract probe.**

  Start `vcs-tb/cosim_bar0_backdoor_test.sv` with a mock service that consumes
  dynamic payload bytes and returns a DWORD:

  ```systemverilog
  class cosim_bar0_mock_service extends cosim_bar0_backdoor_service;
    int calls;
    cosim_bar0_status_e next_status = COSIM_BD_MISS;
    bit [31:0] next_read_dword = 32'h0;
    cosim_bar0_request last_req;
    virtual task access(input cosim_bar0_request req,
                        output cosim_bar0_result result);
      calls++; last_req = req.clone();
      result = new(); result.status = next_status;
      result.read_dword = next_read_dword;
    endtask
  endclass
  ```

  Temporarily include the file after `cosim_xrc_driver.sv` in
  `cosim_xrc_pkg.sv`, run the multi-RC analysis, and expect failure because
  `cosim_bar0_backdoor_service` is undefined.

- [ ] **Step 2: Add the public package.**

  Create `vcs-tb/cosim_bar0_backdoor_pkg.sv`:

  ```systemverilog
  package cosim_bar0_backdoor_pkg;
    import uvm_pkg::*;

    typedef enum { COSIM_BD_MISS, COSIM_BD_HANDLED, COSIM_BD_ERROR }
        cosim_bar0_status_e;

    class cosim_bar0_request;
      int unsigned rc_index;
      bit [15:0] target_bdf;
      byte unsigned tlp_type;
      longint unsigned absolute_addr, bar0_base, bar0_offset;
      int unsigned len_bytes;
      bit [3:0] first_be, last_be;
      bit [9:0] qemu_tag;
      byte unsigned data[];
      function new(); data = new[0]; endfunction
      function cosim_bar0_request clone();
        clone = new();
        clone.rc_index = rc_index; clone.target_bdf = target_bdf;
        clone.tlp_type = tlp_type; clone.absolute_addr = absolute_addr;
        clone.bar0_base = bar0_base; clone.bar0_offset = bar0_offset;
        clone.len_bytes = len_bytes; clone.first_be = first_be;
        clone.last_be = last_be; clone.qemu_tag = qemu_tag;
        clone.data = new[data.size()](data);
      endfunction
    endclass

    class cosim_bar0_result;
      cosim_bar0_status_e status = COSIM_BD_MISS;
      bit [31:0] read_dword;
      string detail;
    endclass

    virtual class cosim_bar0_backdoor_service;
      pure virtual task access(input cosim_bar0_request req,
                               output cosim_bar0_result result);
      virtual task flush(input string reason); endtask
      virtual function void report_status(); endfunction
    endclass
  endpackage
  ```

- [ ] **Step 3: Put the package in compile and import order.**

  In the generated file list, emit
  `vcs-tb/cosim_bar0_backdoor_pkg.sv` after `bridge_vcs.sv` and before
  `cosim_xrc_pkg.sv`. In `cosim_xrc_pkg.sv`, add
  `import cosim_bar0_backdoor_pkg::*;` before the includes and include
  `cosim_bar0_backdoor_test.sv` after `cosim_xrc_test.sv` only when
  `` `ifdef COSIM_BAR0_BACKDOOR_TEST `` is set.

  At the top of `scripts/build_cosim_multirc.sh`, parse optional compiler
  arguments without `eval`:

  ```bash
  EXTRA_VCS_ARGS_ARRAY=()
  if [[ -n "${EXTRA_VCS_ARGS:-}" ]]; then
      read -r -a EXTRA_VCS_ARGS_ARRAY <<< "$EXTRA_VCS_ARGS"
  fi
  ```

  Pass `"${EXTRA_VCS_ARGS_ARRAY[@]}"` immediately before `-f "$f"` in the VCS
  command. Defaults remain unchanged.

- [ ] **Step 4: Compile the contract on the VCS host.**

  Sync the CoSim checkout to `/home/ubuntu/test_cosim/cosim_bar0_backdoor` on
  `10.11.10.53`, then run:

  ```bash
  ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/cosim_bar0_backdoor && EXTRA_VCS_ARGS=+define+COSIM_BAR0_BACKDOOR_TEST scripts/build_cosim_multirc.sh build'"
  ```

  Expected: VCS analysis succeeds and no AIP source appears in generated
  `build/cosim_multirc/filelist.f`.

- [ ] **Step 5: Commit the contract.**

  ```bash
  git add vcs-tb/cosim_bar0_backdoor_pkg.sv vcs-tb/cosim_bar0_backdoor_test.sv vcs-tb/cosim_xrc_pkg.sv scripts/build_cosim_multirc.sh
  git commit -m "feat(cosim): define BAR0 backdoor service"
  ```

### Task 2: Capture complete per-RC request metadata

**Files:**
- Modify: `vcs-tb/cosim_xrc_driver.sv:46-52, 147-154`
- Modify: `vcs-tb/cosim_bar0_backdoor_test.sv`

- [ ] **Step 1: Add red request-construction checks.**

  Extend the test with a driver subclass exposing `build_bar0_request` and feed
  `target_bdf=16'h0300`, `first_be=4'b0110`, `last_be=0`, tag `10'h315`, address
  `64'h8123_4008`, length 4, and word `32'h4433_2211`. Assert the request retains
  every scalar and `data == '{8'h11,8'h22,8'h33,8'h44}`.

- [ ] **Step 2: Run and verify the red failure.**

  Run the focused test build on `10.11.10.53`. Expected: analysis fails because
  `build_bar0_request` is undefined.

- [ ] **Step 3: Fetch BDF/BE fields and convert data without narrowing.**

  Add driver scratch fields `bit [15:0] dpi_target_bdf` and
  `bit [3:0] dpi_first_be, dpi_last_be`. Immediately after the existing tag
  getter, fetch:

  ```systemverilog
  dpi_target_bdf = bit [15:0]'(bridge_vcs_get_tlp_target_bdf_rc(rc_index));
  dpi_first_be = bridge_vcs_get_poll_first_be_rc(rc_index);
  dpi_last_be  = bridge_vcs_get_poll_last_be_rc(rc_index);
  ```

  Add protected `build_bar0_request()` that copies all fields,
  allocates `dpi_len` bytes capped by the existing 16-DWORD transport limit,
  and extracts byte `i` as `dpi_data[i/4][8*(i%4) +: 8]`. This helper does not
  decide PF/BAR/region membership.

  Extend `build_mmio_tlp` with `first_be` and `last_be` arguments and assign
  them to both MRd and MWr instead of the current hard-coded `4'hf/4'h0`.
  Update its two call sites. This preserves the QEMU normalizer's aligned
  `len=4` representation for original 1/2/4-byte accesses on both the backdoor
  and fallback paths.

- [ ] **Step 4: Run metadata tests.**

  Expected: BDF, BE, 10-bit tag, and little-endian byte-array checks pass.

- [ ] **Step 5: Commit metadata capture.**

  ```bash
  git add vcs-tb/cosim_xrc_driver.sv vcs-tb/cosim_bar0_backdoor_test.sv
  git commit -m "feat(cosim): retain BAR request metadata"
  ```

### Task 3: Register a service and learn PF0 BAR0 from enumeration

**Files:**
- Modify: `vcs-tb/cosim_xrc_driver.sv:36-85, 155-184`
- Modify: `vcs-tb/cosim_bar0_backdoor_test.sv`

- [ ] **Step 1: Add red registration and identity tests.**

  Cover: no `uvm_config_db` entry leaves `bar0_backdoor_service==null`; an entry
  at the driver path is retrieved; successful config traffic to function zero
  learns the full `target_bdf`; function one does not replace it; BAR probe
  `FFFF_FFFF` does not mark BAR0 valid; completed low/high BAR programming sets
  the current 64-bit base and aperture size from `config_proxy.bar0_size`.

- [ ] **Step 2: Run and verify red assertions.**

  Expected: failures for absent service handle and PF0/BAR0 validity fields.

- [ ] **Step 3: Implement registration and enumeration state.**

  Add:

  ```systemverilog
  cosim_bar0_backdoor_service bar0_backdoor_service;
  bit pf0_bdf_valid, bar0_base_valid;
  bit bar0_low_seen, bar0_high_seen;
  bit [15:0] pf0_bdf;
  longint unsigned current_bar0_base;
  int unsigned bar0_backdoor_hit, bar0_backdoor_miss, bar0_backdoor_error;
  ```

  In `build_phase`, perform a non-fatal
  `uvm_config_db#(cosim_bar0_backdoor_service)::get(this, "",
  "bar0_backdoor_service", bar0_backdoor_service)` and log INFO only when one
  is registered. In the existing config bypass, after a request is successfully
  handled, learn `pf0_bdf` only when `target_bdf[2:0]==0`; on real BAR writes
  (not sizing probes), mark DW4/DW5 in `bar0_low_seen/bar0_high_seen`, update
  `current_bar0_base=config_proxy.bar0_addr`, and set `bar0_base_valid` only when
  both halves have been seen and the assembled base is nonzero. Continue calling
  `bridge_vcs_set_bar_base_rc` exactly as today.

  This learns the guest-assigned BDF and BAR dynamically; neither belongs in
  the table INI. The first version assumes one endpoint PF0 per RC, matching the
  existing XRC topology.

- [ ] **Step 4: Run registration/enumeration tests.**

  Expected: null and registered cases pass, PF1 is excluded, and a 64-bit BAR
  base is not treated as valid until enumeration has assigned a nonzero value.

- [ ] **Step 5: Commit service registration.**

  ```bash
  git add vcs-tb/cosim_xrc_driver.sv vcs-tb/cosim_bar0_backdoor_test.sv
  git commit -m "feat(cosim): bind backdoor to enumerated PF0 BAR0"
  ```

### Task 4: Gate PF0 BAR0 and enforce the acceptance boundary

**Files:**
- Modify: `vcs-tb/cosim_xrc_driver.sv:125-205`
- Modify: `vcs-tb/cosim_bar0_backdoor_test.sv`

- [ ] **Step 1: Add a table-driven red gating test.**

  Use a mock service and assert it is not called for: null service, PF0 not yet
  learned, BAR0 not assigned, PF1/function one, another BDF, address below BAR0,
  address at `BAR0+bar0_size`, config TLP, unsupported 8-byte access, and a
  request that crosses a DWORD. Assert it receives one request for aligned
  4-byte MRd/MWr inside the aperture with
  `bar0_offset=absolute_addr-current_bar0_base`. Assert service MISS selects
  fallback; service HANDLED/ERROR never selects fallback.

- [ ] **Step 2: Run and verify failure.**

  Expected: analysis fails because `try_bar0_backdoor` is undefined.

- [ ] **Step 3: Implement a testable dispatcher.**

  Add protected virtual task:

  ```systemverilog
  protected virtual task try_bar0_backdoor(
      input cosim_bar0_request req,
      output cosim_bar0_result rsp,
      output bit use_original_path);
    rsp = new(); use_original_path = 1;
    if (bar0_backdoor_service == null || !pf0_bdf_valid || !bar0_base_valid) return;
    if (req.target_bdf != pf0_bdf) return;
    if (req.absolute_addr < current_bar0_base ||
        req.absolute_addr >= current_bar0_base + config_proxy.bar0_size) return;
    if (!(req.tlp_type inside {BV_TLP_MRD, BV_TLP_MWR}) ||
        req.len_bytes != 4 || req.absolute_addr[1:0] != 0) return;
    req.bar0_base = current_bar0_base;
    req.bar0_offset = req.absolute_addr - current_bar0_base;
    bar0_backdoor_service.access(req, rsp);
    if (rsp == null) begin
      rsp = new(); rsp.status = COSIM_BD_ERROR;
      rsp.detail = "service returned null result";
    end
    case (rsp.status)
      COSIM_BD_MISS:    bar0_backdoor_miss++;
      COSIM_BD_HANDLED: begin bar0_backdoor_hit++; use_original_path = 0; end
      COSIM_BD_ERROR:   begin bar0_backdoor_error++; use_original_path = 0; end
      default:          begin rsp.status = COSIM_BD_ERROR;
                              rsp.detail = "invalid service status";
                              bar0_backdoor_error++; use_original_path = 0; end
    endcase
  endtask
  ```

  Use overflow-safe aperture comparison (`absolute_addr-base < bar0_size`) in
  implementation. A service MISS is the only service result that permits the
  original path. ERROR means the service accepted or started work, so it must
  never be transformed into MISS.

- [ ] **Step 4: Run the gating matrix.**

  Expected: every pre-acceptance exclusion falls back without a service call;
  only PF0 BAR0 reaches the mock; ERROR cannot cause a duplicate CQ request.

- [ ] **Step 5: Commit gating.**

  ```bash
  git add vcs-tb/cosim_xrc_driver.sv vcs-tb/cosim_bar0_backdoor_test.sv
  git commit -m "feat(cosim): gate PF0 BAR0 backdoor requests"
  ```

### Task 5: Directly complete reads and consume posted writes

**Files:**
- Modify: `vcs-tb/cosim_xrc_driver.sv:125-205`
- Modify: `vcs-tb/cosim_bar0_backdoor_test.sv`

- [ ] **Step 1: Add red completion-semantics tests.**

  In a test driver subclass, override a new
  `send_bar0_read_completion(tag,data)` hook to record calls and return a
  programmable status. Assert HANDLED MRd sends exactly one 4-byte completion
  with original 10-bit QEMU tag and returned DWORD, never allocates a VIP tag,
  never calls `send_tlp`, and increments direct completion count. Assert
  HANDLED MWr sends no completion and no TLP. Assert completion send failure is
  logged/counted as ERROR without CQ fallback. Assert service ERROR for either
  type produces neither completion nor TLP.

- [ ] **Step 2: Run and verify the red state.**

  Expected: failures because handled requests still reach `build_mmio_tlp`.

- [ ] **Step 3: Add the completion hook and request-loop branch.**

  Implement:

  ```systemverilog
  protected virtual function int send_bar0_read_completion(
      input bit [9:0] qemu_tag, input bit [31:0] data);
    for (int i = 0; i < 16; i++) bridge_vcs_set_cpl_data_rc(rc_index, i, 0);
    bridge_vcs_set_cpl_data_rc(rc_index, 0, data);
    return bridge_vcs_send_cpl_scalar_rc(rc_index, int'(qemu_tag), 1);
  endfunction
  ```

  In `request_loop`, after config bypass and before `build_mmio_tlp`, build the
  request and call `try_bar0_backdoor`. Branch exactly as follows:

  ```systemverilog
  if (!use_original_path) begin
    if (rsp.status == COSIM_BD_HANDLED && dpi_type == BV_TLP_MRD) begin
      if (send_bar0_read_completion(dpi_tag[9:0], rsp.read_dword) != 0) begin
        bar0_backdoor_error++;
        `uvm_error(get_name(), $sformatf("RC%0d BAR0 direct completion failed tag=0x%03h",
                                         rc_index, dpi_tag[9:0]))
      end else total_cpl_count++;
    end else if (rsp.status == COSIM_BD_ERROR) begin
      `uvm_error(get_name(), $sformatf("RC%0d BAR0 backdoor error: %s",
                                       rc_index, rsp.detail))
    end
    total_tlp_count++;
    continue;
  end
  ```

  HANDLED MWr intentionally has no completion because PCIe Memory Write is
  posted. The service returning from its write call means that request was
  accepted; its own row cache/writer defines later full-row commit. Direct MRd
  always sends one DWORD (`len=1` to the scalar API), letting QEMU apply the
  original 1/2/4-byte `first_be` extraction.

- [ ] **Step 4: Run completion tests.**

  Expected: exact tag/data/length behavior passes, handled traffic has zero VIP
  sends and tag-map entries, posted writes have zero completions, and all ERROR
  cases have zero fallback.

- [ ] **Step 5: Commit direct completion.**

  ```bash
  git add vcs-tb/cosim_xrc_driver.sv vcs-tb/cosim_bar0_backdoor_test.sv
  git commit -m "feat(cosim): complete BAR0 reads without DUT"
  ```

### Task 6: Preserve legacy fallback byte-for-byte

**Files:**
- Modify: `vcs-tb/cosim_bar0_backdoor_test.sv`
- Modify: `scripts/build_cosim_multirc.sh`

- [ ] **Step 1: Add null-service and MISS regression assertions.**

  Instrument the test driver so `build_mmio_tlp`, `send_tlp`, and tag-map state
  are observable. Send the same MRd/MWr in three modes: old baseline helper,
  no service, and mock MISS. Compare kind, address, length, payload,
  `first_be/last_be`, VIP/QEMU tag map, TLP count, and CQ-send count. Also cover
  PF1 and an address in BAR0 aperture but outside all service regions (mock
  MISS). Assert no direct completion occurs.

- [ ] **Step 2: Make the focused test selectable.**

  Update `scripts/build_cosim_multirc.sh` to make the focused UVM test selectable
  without changing the default:

  ```bash
  VCS_TEST="${VCS_TEST:-cosim_xrc_test}"
  ```

  The compiler-argument array was added in Task 1; continue to avoid `eval`.

- [ ] **Step 3: Run the focused regression.**

  ```bash
  ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/cosim_bar0_backdoor && VCS_TEST=cosim_bar0_backdoor_test EXTRA_VCS_ARGS=+define+COSIM_BAR0_BACKDOOR_TEST scripts/build_cosim_multirc.sh build && VCS_TEST=cosim_bar0_backdoor_test scripts/build_cosim_multirc.sh run'"
  ```

  Expected: `COSIM_BAR0_BACKDOOR_TEST_PASS`; null/MISS comparisons are equal and
  the test log contains no `UVM_ERROR` or `UVM_FATAL`.

- [ ] **Step 4: Run the existing XRC build without the test define.**

  ```bash
  ssh ubuntu@10.11.10.53 "bash -lic 'cd /home/ubuntu/test_cosim/cosim_bar0_backdoor && OUT=/home/ubuntu/test_cosim/build_cosim_bar0_default scripts/build_cosim_multirc.sh build'"
  ```

  Expected: the default `cosim_xrc_test` build succeeds and its generated
  filelist contains the new abstract package but no AIP package.

- [ ] **Step 5: Commit regression/build support.**

  ```bash
  git add vcs-tb/cosim_bar0_backdoor_test.sv scripts/build_cosim_multirc.sh
  git commit -m "test(cosim): prove BAR0 fallback compatibility"
  ```

### Task 7: Flush and report service lifecycle

**Files:**
- Modify: `vcs-tb/cosim_xrc_driver.sv:110-122, 435-455`
- Modify: `vcs-tb/cosim_xrc_test.sv:120-135, 200-208`
- Modify: `vcs-tb/cosim_bar0_backdoor_test.sv`

- [ ] **Step 1: Add red lifecycle tests.**

  Extend the mock with `flush_calls`, `last_flush_reason`, and `status_calls`.
  Assert bridge shutdown calls `flush("bridge shutdown")` once; normal test
  cleanup calls `flush("test shutdown")` without a second discard; report phase
  calls `report_status()` once. Assert a null service is a no-op.

- [ ] **Step 2: Run and verify lifecycle failure.**

  Expected: mock lifecycle counters remain zero.

- [ ] **Step 3: Add idempotent driver lifecycle methods.**

  Add `bit bar0_backdoor_flushed` and public task:

  ```systemverilog
  task flush_bar0_backdoor(input string reason);
    if (bar0_backdoor_service != null && !bar0_backdoor_flushed) begin
      bar0_backdoor_service.flush(reason);
      bar0_backdoor_flushed = 1;
    end
  endtask
  ```

  Invoke it before firing `shutdown_event` on poll shutdown and from
  `cosim_xrc_test` before bridge cleanup. In driver `report_phase`, call service
  `report_status()` and print hit/miss/error/direct-completion counts beside the
  existing TLP counters. Do not flush on reset unless the current environment
  exposes an actual reset event; document the public method as the reset hook
  for the user test.

- [ ] **Step 4: Run lifecycle regression.**

  Expected: flush is exactly once, status exactly once, and null service causes
  no method call or warning.

- [ ] **Step 5: Commit lifecycle integration.**

  ```bash
  git add vcs-tb/cosim_xrc_driver.sv vcs-tb/cosim_xrc_test.sv vcs-tb/cosim_bar0_backdoor_test.sv
  git commit -m "feat(cosim): flush and report BAR0 services"
  ```

### Task 8: Document the user-owned AIP adapter

**Files:**
- Create: `docs/pf0-bar0-backdoor-integration.md`

- [ ] **Step 1: Document compile and registration order.**

  State that the user's VCS invocation analyzes `aip_core_pkg.sv`, then
  `cosim_bar0_backdoor_pkg.sv`, then their adapter/test, with CoSim and AIP kept
  as independent checkouts. Show registration before env creation:

  ```systemverilog
  user_cosim_bar0_adapter svc = new("bar0_service");
  svc.engine = new("aip_engine");
  svc.engine.configure();
  uvm_config_db#(cosim_bar0_backdoor_service)::set(
      null, "uvm_test_top.env.rc_agent_*", "bar0_backdoor_service", svc);
  ```

- [ ] **Step 2: Provide the exact adapter translation.**

  Show a user-test class extending `cosim_bar0_backdoor_service`. Its `access`
  creates `aip_table_request`, copies `rc_index`, `bar0_offset`, MWr/MRd kind,
  length, BE, tag, and dynamic bytes, calls `engine.access`, then maps
  `AIP_TABLE_MISS/HANDLED/ERROR` one-to-one and copies the read DWORD/detail.
  Its `flush` and `report_status` directly delegate. The example must not be
  compiled or referenced by CoSim's production file list.

- [ ] **Step 3: Document runtime and completion semantics.**

  Include:

  ```text
  +bar0_bd.enable=1
  +bar0_bd.map=/absolute/path/pf0_bar0.ini
  +bar0_bd.rc_mask=0x3
  +bar0_bd.log_level=debug
  +bar0_bd.dump_max_bits=1024
  ```

  Explain that the INI uses BAR-relative offsets, the guest BAR base and PF0
  BDF are learned during enumeration, MRd returns one full DWORD on the original
  QEMU tag, MWr is posted, reads are immediate, only writes aggregate, MISS uses
  CQ, and ERROR never falls back. Include the INFO/DEBUG/TRACE meanings and
  point to the AIP README for map/protection/custom multi-RAM writer details.

- [ ] **Step 4: Commit documentation.**

  ```bash
  git add docs/pf0-bar0-backdoor-integration.md
  git commit -m "docs(cosim): explain AIP BAR0 adapter integration"
  ```

### Task 9: Validate QEMU-to-RTL behavior on the VCS host

**Files:**
- Verify: `vcs-tb/cosim_xrc_driver.sv`
- Verify: user test and map on `10.11.10.53:/home/ubuntu/test_cosim/`

- [ ] **Step 1: Establish the disabled baseline.**

  In a login shell on `10.11.10.53`, run the user's normal QEMU/VCS launch with
  no `+bar0_bd.enable`. Save CQ/CC counters and a known table programming/read
  result. Expected: all requests traverse CQ/DUT/CC exactly as before.

- [ ] **Step 2: Validate generic complete-row writes.**

  Enable a 128-bit `none` region and issue driver writes high-to-low, then
  low-to-high. Expected: DEBUG logs show four `WR CAPTURE` lines and one
  `ROW COMPLETE`; the RTL RAM changes only after the fourth DWORD; MRd of each
  DWORD returns immediately with the original QEMU tag and does not increment
  CQ count. Repeat one representative 256-bit and 1024-bit row.

- [ ] **Step 3: Validate protection and interleaved indices.**

  Run parity/1B and SECDED/4B regions with two logical indices interleaved.
  Expected: independent valid masks, exactly one commit per index, protected
  physical values match the AIP unit vectors, and DEBUG shows logical,
  protection, and final physical values.

- [ ] **Step 4: Validate custom multi-RAM routing.**

  Register the user's compiled `vio_notify` writer/reader and program ordinary
  index 14, L2 boundary 15, and L1 boundary 255. Expected: L3-only, L3+L2, and
  L3+L2+L1 deposits respectively, with identical configured data and correct
  per-level physical indices; reads route to primary L3. Inject one callback
  failure and confirm the log lists successful/failed levels and no CQ fallback.

- [ ] **Step 5: Validate miss/error boundaries and shutdown.**

  Access PF1, another BAR, stride padding, and an unmapped BAR0 offset; expected
  CQ fallback. Inject duplicate chunk, HDL read failure, and direct completion
  failure; expected ERROR and no duplicate CQ request/completion. Shut down with
  one partial row; expected missing mask, discard count, and final status.

- [ ] **Step 6: Record evidence.**

  Save the exact AIP and CoSim revisions, command lines, map, VCS/QEMU logs, and
  counter summary under the user's test-results directory on host 53. Do not
  commit generated logs, credentials, or DUT hierarchy files to CoSim.

### Task 10: Final repository review

**Files:**
- Review: `vcs-tb/cosim_bar0_backdoor_pkg.sv`
- Review: `vcs-tb/cosim_xrc_driver.sv`
- Review: `vcs-tb/cosim_bar0_backdoor_test.sv`
- Review: `scripts/build_cosim_multirc.sh`
- Review: `docs/pf0-bar0-backdoor-integration.md`

- [ ] **Step 1: Scan scope and placeholders.**

  ```bash
  git diff --check
  rg -n 'aip_core|ghp_|target-bar|0x80000000' vcs-tb/cosim_bar0_backdoor_pkg.sv vcs-tb/cosim_xrc_driver.sv scripts/build_cosim_multirc.sh
  ```

  Expected: diff check is silent; production sources have no AIP dependency,
  token, unfinished marker, static target BAR setting, or hard-coded guest BAR
  base. AIP may appear only in the user-integration documentation and mock
  commentary, never the production file list.

- [ ] **Step 2: Run final focused/default builds on host 53.**

  Run the focused regression from Task 6, then run the default build with a
  separate `OUT` directory as shown there.
  Expected: `COSIM_BAR0_BACKDOOR_TEST_PASS`, no UVM errors, and default analysis
  success.

- [ ] **Step 3: Inspect commit and worktree scope.**

  ```bash
  git status --short
  git log --oneline --decorate -10
  git diff 3129fa4..HEAD --stat
  ```

  Expected: the pre-existing script mode changes and
  `tools/eth_tap_bridge` remain untouched; only the planned service, driver,
  test, build-script content, and documentation are part of feature commits.
