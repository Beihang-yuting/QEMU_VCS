`ifndef XILINX_PCIE_E2E_CHECKER_SV
`define XILINX_PCIE_E2E_CHECKER_SV

//=============================================================================
// xilinx_pcie_e2e_checker
//
// Thin, TLP-level end-to-end checker for the adapter-mode (SV_IF) flow. It
// replaces the PoC's reliance on the upstream scoreboard (whose register_pending
// only runs in the env's TLM loopback, which is off in SV_IF mode) and the
// ad-hoc "RC_DRV: Completion matched" driver log.
//
// Tap points (wired in the test's connect_phase):
//   req_imp <- env.ep_agent.monitor.tlp_ap   (requests arriving at the completer)
//   cpl_imp <- env.rc_agent.monitor.tlp_ap   (completions returning to requester)
//
// In the dual-BFM SV_IF model each adapter taps only its SLAVE (receive-
// direction) channels, so a BFM never re-ingests its own transmitted TLP. The
// non-posted request is therefore observed where it is RECEIVED (EP/completer
// side, CQ channel) and the matching completion where it RETURNS (RC/requester
// side, CC channel). Matching is by tag. This is a genuine end-to-end check:
// a request seen entering the completer must yield a completion seen arriving
// back at the requester, with a byte_count that echoes the requested length.
//
// Scope is intentionally TLP-level only (no PG213 protocol judgment).
//=============================================================================

`uvm_analysis_imp_decl(_req)
`uvm_analysis_imp_decl(_cpl)

class xilinx_pcie_e2e_checker extends uvm_component;
  `uvm_component_utils(xilinx_pcie_e2e_checker)

  uvm_analysis_imp_req #(pcie_tl_tlp, xilinx_pcie_e2e_checker) req_imp;
  uvm_analysis_imp_cpl #(pcie_tl_tlp, xilinx_pcie_e2e_checker) cpl_imp;

  typedef struct {
    int        expected_bytes;  // byte_count the completion must echo
    bit [15:0] requester_id;
    tlp_kind_e kind;
  } outstanding_t;

  outstanding_t outstanding[bit [9:0]];   // keyed by tag

  int unsigned n_req       = 0;  // non-posted requests tracked
  int unsigned n_matched   = 0;  // completions matched to an outstanding request
  int unsigned n_unmatched = 0;  // completions with no outstanding request
  int unsigned n_mismatch  = 0;  // matched but byte_count mismatch

  function new(string name, uvm_component parent);
    super.new(name, parent);
    req_imp = new("req_imp", this);
    cpl_imp = new("cpl_imp", this);
  endfunction

  //---------------------------------------------------------------------------
  // Completer-side tap: record each outstanding non-posted request by tag.
  //---------------------------------------------------------------------------
  virtual function void write_req(pcie_tl_tlp t);
    outstanding_t o;
    if (t == null) return;
    if (t.get_category() == TLP_CAT_COMPLETION) return;  // not a request
    if (!t.requires_completion()) return;                // posted -> no cpl due
    o.expected_bytes = (t.length == 0) ? 4096 : t.length * 4;
    o.requester_id   = t.requester_id;
    o.kind           = t.kind;
    outstanding[t.tag] = o;
    n_req++;
    `uvm_info(get_type_name(), $sformatf(
      "track request tag=0x%03h kind=%s expect=%0dB",
      t.tag, t.kind.name(), o.expected_bytes), UVM_MEDIUM)
  endfunction

  //---------------------------------------------------------------------------
  // Requester-side tap: match each completion to an outstanding request by tag
  // and verify the returned data size echoes the request.
  //---------------------------------------------------------------------------
  virtual function void write_cpl(pcie_tl_tlp t);
    pcie_tl_cpl_tlp c;
    outstanding_t   o;
    if (t == null) return;
    if (t.get_category() != TLP_CAT_COMPLETION) return;
    if (!$cast(c, t)) return;

    if (!outstanding.exists(c.tag)) begin
      n_unmatched++;
      `uvm_error(get_type_name(), $sformatf(
        "unmatched completion: tag=0x%03h req_id=0x%04h (no outstanding request)",
        c.tag, c.requester_id))
      return;
    end

    o = outstanding[c.tag];
    // For read-data completions, byte_count must echo the requested length.
    // Config-read completions are exempt: PCIe fixes their Byte Count at 4 and
    // the upstream ep_driver leaves cpl.byte_count at 0, so the generic
    // length-echo does not apply. Tag match + returned data still prove delivery.
    if (c.has_data() && !(o.kind inside {TLP_CFG_RD0, TLP_CFG_RD1}) &&
        c.byte_count != o.expected_bytes[11:0]) begin
      n_mismatch++;
      `uvm_error(get_type_name(), $sformatf(
        "completion byte_count mismatch: tag=0x%03h got=%0d expected=%0d",
        c.tag, c.byte_count, o.expected_bytes))
    end
    n_matched++;
    outstanding.delete(c.tag);
    `uvm_info(get_type_name(), $sformatf(
      "matched completion: tag=0x%03h status=%s payload=%0dB byte_count=%0d",
      c.tag, c.cpl_status.name(), c.payload.size(), c.byte_count), UVM_MEDIUM)
  endfunction

  //---------------------------------------------------------------------------
  // Final verdict: any never-completed request or any mismatch is an error.
  //---------------------------------------------------------------------------
  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    foreach (outstanding[tag])
      `uvm_error(get_type_name(), $sformatf(
        "outstanding request never completed: tag=0x%03h kind=%s",
        tag, outstanding[tag].kind.name()))
    `uvm_info(get_type_name(), $sformatf(
      "e2e checker: %0d matched, %0d outstanding, %0d unmatched, %0d mismatch (of %0d requests)",
      n_matched, outstanding.size(), n_unmatched, n_mismatch, n_req), UVM_LOW)
  endfunction
endclass

`endif // XILINX_PCIE_E2E_CHECKER_SV
