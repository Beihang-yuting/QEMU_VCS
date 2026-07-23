import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// Codec self-check test — PG213 descriptor bit-field regression guard.
//
// Exercises xilinx_desc_codec static encode/decode round-trips WITHOUT the env
// (no vif / tready needed). Asserts, per PG213:
//   - first_be/last_be are NOT carried in RQ/CQ descriptors (BE lives on tuser);
//     the Completer ID region [119:104] of a memory RQ descriptor stays 0.
//   - TC/Attr/Completer ID/BAR/target_func sit at the PG213 bit positions.
//   - RQ/CQ/RC/CC/cfg encode<->decode round-trip all model fields.
//   - CC and RC share common-field bit positions (cross-channel decode compat).
//
// Run: +UVM_TESTNAME=xilinx_pcie_adapter_codec_test (filelist_adapter.f).
//=============================================================================
class xilinx_pcie_adapter_codec_test extends uvm_test;
  `uvm_component_utils(xilinx_pcie_adapter_codec_test)

  int unsigned errs = 0;

  function new(string n, uvm_component p); super.new(n, p); endfunction

  // check helper: increments errs and logs on mismatch
  function void chk(string what, bit ok);
    if (!ok) begin
      errs++;
      `uvm_error("CODEC_CHK", $sformatf("FAIL: %s", what))
    end
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    check_rq();
    check_cq();
    check_rc();
    check_cc();
    check_cfg();
    if (errs == 0)
      `uvm_info("CODEC_CHK", "ALL CODEC ROUND-TRIP + PG213 LAYOUT CHECKS PASSED", UVM_LOW)
    else
      `uvm_error("CODEC_CHK", $sformatf("%0d codec check(s) FAILED", errs))
    phase.drop_objection(this);
  endtask

  // --- RQ: memory write request ---
  function void check_rq();
    pcie_tl_mem_tlp  m, d;
    bit [127:0]      desc;
    bit [7:0]        pl[];
    pcie_tl_tlp      t;

    m = pcie_tl_mem_tlp::type_id::create("m");
    m.kind = TLP_MEM_WR; m.fmt = FMT_3DW_WITH_DATA; m.is_64bit = 0;
    m.addr = 64'h0000_0000_1000_2004; m.first_be = 4'hF; m.last_be = 4'h3;
    m.length = 10'd4; m.tag = 10'h0A5; m.requester_id = 16'h1234;
    m.tc = 3'd3; m.attr = 3'b101; m.td = 1'b1;

    desc = xilinx_desc_codec::encode_rq(m);
    // PG213: BE must NOT appear in descriptor; mem RQ Completer ID region == 0.
    chk("RQ desc Completer ID region [119:104] must be 0 (no BE leak)",
        desc[119:104] == 16'h0);
    chk("RQ desc first_be region must NOT equal BE (BE not in desc)",
        !(desc[111:108] == m.first_be && desc[107:104] == m.last_be));
    chk("RQ desc TC @ [123:121]", desc[123:121] == m.tc);
    chk("RQ desc Attr @ [126:124]", desc[126:124] == m.attr);

    pl = new[16]; // has_data
    t = xilinx_desc_codec::decode_rq(desc, pl);
    chk("RQ decode cast", $cast(d, t));
    if (d != null) begin
      chk("RQ addr", d.addr == m.addr);
      chk("RQ length", d.length == m.length);
      chk("RQ tag[7:0]", d.tag[7:0] == m.tag[7:0]);
      chk("RQ requester_id", d.requester_id == m.requester_id);
      chk("RQ tc", d.tc == m.tc);
      chk("RQ attr", d.attr == m.attr);
      // BE comes from tuser, NOT descriptor -> decoded BE stays default 0.
      chk("RQ decoded first_be not from desc", d.first_be == 4'h0);
    end
  endfunction

  // --- CQ: memory request with BAR/target_func ---
  function void check_cq();
    pcie_tl_mem_tlp  m, d;
    bit [127:0]      desc;
    bit [7:0]        pl[];
    pcie_tl_tlp      t;

    m = pcie_tl_mem_tlp::type_id::create("m");
    m.kind = TLP_MEM_RD; m.fmt = FMT_3DW_NO_DATA; m.is_64bit = 0;
    m.addr = 64'h0000_0000_2000_0000; m.first_be = 4'hF; m.last_be = 4'h0;
    m.length = 10'd1; m.tag = 10'h033; m.requester_id = 16'h1234;
    m.tc = 3'd1; m.attr = 3'b010; m.td = 1'b0;

    desc = xilinx_desc_codec::encode_cq(m, 3'h2, 6'h14, 8'hC3);
    chk("CQ target_func @ [111:104]",
        xilinx_desc_codec::get_cq_target_func(desc) == 8'hC3);
    chk("CQ bar_id @ [114:112]",
        xilinx_desc_codec::get_cq_bar_id(desc) == 3'h2);
    chk("CQ bar_aperture @ [120:115]",
        xilinx_desc_codec::get_cq_bar_aperture(desc) == 6'h14);
    chk("CQ desc TC @ [123:121]", desc[123:121] == m.tc);
    chk("CQ desc Attr @ [126:124]", desc[126:124] == m.attr);

    pl = new[0];
    t = xilinx_desc_codec::decode_cq(desc, pl);
    chk("CQ decode cast", $cast(d, t));
    if (d != null) begin
      chk("CQ addr", d.addr == m.addr);
      chk("CQ tag[7:0]", d.tag[7:0] == m.tag[7:0]);
      chk("CQ tc", d.tc == m.tc);
      chk("CQ attr", d.attr == m.attr);
    end
  endfunction

  // --- RC: completion with data ---
  function void check_rc();
    pcie_tl_cpl_tlp  c, d;
    bit [95:0]       desc;
    bit [7:0]        pl[];
    pcie_tl_tlp      t;

    c = pcie_tl_cpl_tlp::type_id::create("c");
    c.kind = TLP_CPLD; c.fmt = FMT_3DW_WITH_DATA;
    c.completer_id = 16'hABCD; c.cpl_status = CPL_STATUS_SC;
    c.byte_count = 12'h040; c.lower_addr = 7'h10; c.bcm = 1'b1;
    c.length = 10'd1; c.tag = 10'h05A; c.requester_id = 16'h1234;
    c.tc = 3'd2; c.attr = 3'b010; c.td = 1'b0;

    desc = xilinx_desc_codec::encode_rc(c);
    chk("RC byte_count @ [28:16]", desc[28:16] == {1'b0, c.byte_count});
    chk("RC TC @ [91:89]", desc[91:89] == c.tc);
    chk("RC Attr @ [94:92]", desc[94:92] == c.attr);
    chk("RC completer_id @ [87:72]", desc[87:72] == c.completer_id);

    pl = new[4];
    t = xilinx_desc_codec::decode_rc(desc, pl);
    chk("RC decode cast", $cast(d, t));
    if (d != null) begin
      chk("RC byte_count", d.byte_count == c.byte_count);
      chk("RC lower_addr", d.lower_addr == c.lower_addr);
      chk("RC completer_id", d.completer_id == c.completer_id);
      chk("RC cpl_status", d.cpl_status == c.cpl_status);
      chk("RC tag[7:0]", d.tag[7:0] == c.tag[7:0]);
      chk("RC requester_id", d.requester_id == c.requester_id);
      chk("RC tc", d.tc == c.tc);
      chk("RC attr", d.attr == c.attr);
      chk("RC bcm", d.bcm == c.bcm);
    end
  endfunction

  // --- CC: completer completion; and CC<->RC common-field compat ---
  function void check_cc();
    pcie_tl_cpl_tlp  c, d, r;
    bit [95:0]       desc;
    bit [7:0]        pl[];
    pcie_tl_tlp      t, tr;

    c = pcie_tl_cpl_tlp::type_id::create("c");
    c.kind = TLP_CPLD; c.fmt = FMT_3DW_WITH_DATA;
    c.completer_id = 16'hBEEF; c.cpl_status = CPL_STATUS_SC;
    c.byte_count = 12'h010; c.lower_addr = 7'h04;
    c.length = 10'd1; c.tag = 10'h077; c.requester_id = 16'h4321;
    c.tc = 3'd5; c.attr = 3'b001; c.td = 1'b1;

    desc = xilinx_desc_codec::encode_cc(c);
    chk("CC completer_id split @ [79:72]+[87:80]", desc[87:72] == c.completer_id);
    chk("CC force_ecrc @ [95]", desc[95] == c.td);
    chk("CC TC @ [91:89]", desc[91:89] == c.tc);

    pl = new[4];
    t = xilinx_desc_codec::decode_cc(desc, pl);
    chk("CC decode cast", $cast(d, t));
    if (d != null) begin
      chk("CC completer_id", d.completer_id == c.completer_id);
      chk("CC byte_count", d.byte_count == c.byte_count);
      chk("CC tag[7:0]", d.tag[7:0] == c.tag[7:0]);
      chk("CC cpl_status", d.cpl_status == c.cpl_status);
      chk("CC tc", d.tc == c.tc);
      chk("CC attr", d.attr == c.attr);
    end

    // Cross-channel: a CC-encoded completion decoded as RC must keep common fields
    // (EP drives CC, RC-side may decode with RC layout).
    tr = xilinx_desc_codec::decode_rc(desc, pl);
    chk("CC->RC decode cast", $cast(r, tr));
    if (r != null) begin
      chk("CC->RC completer_id compat", r.completer_id == c.completer_id);
      chk("CC->RC byte_count compat", r.byte_count == c.byte_count);
      chk("CC->RC tag compat", r.tag[7:0] == c.tag[7:0]);
      chk("CC->RC tc compat", r.tc == c.tc);
      chk("CC->RC attr compat", r.attr == c.attr);
    end
  endfunction

  // --- Config request (routed through encode_rq -> encode_cfg_desc) ---
  function void check_cfg();
    pcie_tl_cfg_tlp  c, d;
    bit [127:0]      desc;
    bit [7:0]        pl[];
    pcie_tl_tlp      t;

    c = pcie_tl_cfg_tlp::type_id::create("c");
    c.kind = TLP_CFG_WR0; c.fmt = FMT_3DW_WITH_DATA;
    c.completer_id = 16'h0500; c.reg_num = 10'h01A; c.first_be = 4'hF;
    c.length = 10'd1; c.tag = 10'h011; c.requester_id = 16'h1234;
    c.tc = 3'd0; c.attr = 3'b000; c.td = 1'b0;

    desc = xilinx_desc_codec::encode_rq(c);  // is_cfg_kind -> encode_cfg_desc
    chk("CFG completer_id @ [119:104]", desc[119:104] == c.completer_id);
    chk("CFG reg_num @ [11:2]", desc[11:2] == c.reg_num);
    chk("CFG first_be NOT at [111:108]",
        desc[111:108] != c.first_be || c.first_be == 4'h0);

    pl = new[4];
    t = xilinx_desc_codec::decode_rq(desc, pl); // is_cfg_req_type -> decode_cfg_desc
    chk("CFG decode cast", $cast(d, t));
    if (d != null) begin
      chk("CFG reg_num", d.reg_num == c.reg_num);
      chk("CFG completer_id", d.completer_id == c.completer_id);
      chk("CFG requester_id", d.requester_id == c.requester_id);
      chk("CFG tag[7:0]", d.tag[7:0] == c.tag[7:0]);
    end
  endfunction

endclass
