// axis_net_packet_seq.sv
// Drive a net_packet-generated network frame as AXIS stimulus.
//
// Template-method design: body() is fixed and auto-sends. The user customizes
// behavior by overriding ONE or BOTH of two virtual hooks in a subclass:
//
//   1. gen_packet()  -> build/return the network packet (protocol stack + fields)
//   2. build_beats() -> map the packet byte stream into AXIS transfers
//
// Override only what you need; the defaults below cover the common case
// (template-random frame, width-parameterized byte->beat mapping).
//
// Dependency: net_packet (bare $unit classes). Guarded by `AXIS_USE_NET_PACKET
// so the default axis_vip build is unaffected.
// Enable:  +define+AXIS_USE_NET_PACKET +incdir+<net_packet/src>
//          and `include "core/packet.sv" into axis_pkg before this file.
`ifdef AXIS_USE_NET_PACKET
class axis_net_packet_seq extends axis_base_seq;

    `uvm_object_utils(axis_net_packet_seq)

    // ----- Default-path knobs (used by the default gen_packet) -----
    rand packet_template_e gen_tmpl;     // protocol stack template
    rand int unsigned      gen_pkt_len;  // total frame length in bytes

    // ----- AXIS routing / pacing (used by the default build_beats) -----
    rand bit [15:0]    stream_tid;
    rand bit [15:0]    stream_tdest;
    rand int unsigned  inter_beat_delay;

    constraint c_pkt_len { soft gen_pkt_len inside {[64:1518]}; }
    constraint c_delay   { inter_beat_delay inside {[0:3]}; }
    constraint c_tid     { stream_tid   inside {[0:15]}; }
    constraint c_tdest   { stream_tdest inside {[0:15]}; }

    function new(string name = "axis_net_packet_seq");
        super.new(name);
        gen_tmpl = ETH_IPV4_TCP;
    endfunction

    // =====================================================================
    // HOOK 1 — gen_packet: build the network packet.
    //   Override to construct any protocol stack / set any field. Must return
    //   a packet whose raw_data is (or can be) packed. Default: random frame
    //   from gen_tmpl / gen_pkt_len.
    // =====================================================================
    virtual function packet gen_packet();
        packet pkt = new();
        if (!pkt.randomize() with {
                pkt_kind == local::gen_tmpl;
                pkt_len  == local::gen_pkt_len;
            })
            `uvm_error(get_type_name(), "net_packet randomize failed")
        // packet::post_randomize() already builds layers and calls do_pack().
        return pkt;
    endfunction

    // =====================================================================
    // HOOK 2 — build_beats: map packet bytes -> AXIS transfers.
    //   Override to change endianness, tkeep/tstrb policy, tuser injection,
    //   per-beat delay, multi-stream tid, etc. Default: width-parameterized
    //   little-endian lane fill (lane0 = first wire byte), tlast on last beat.
    //   `beats` is the queue body() will drive in order.
    // =====================================================================
    virtual function void build_beats(packet pkt, ref axis_transfer beats[$]);
        byte unsigned bytes[$];
        int unsigned  lanes;
        int unsigned  nbeats;

        if (pkt.raw_data.size() == 0) pkt.do_pack();
        bytes = pkt.raw_data;
        beats.delete();
        if (bytes.size() == 0) return;

        lanes  = (cfg != null) ? cfg.get_byte_lanes() : (`AXIS_MAX_TDATA / 8);
        nbeats = (bytes.size() + lanes - 1) / lanes;

        for (int b = 0; b < nbeats; b++) begin
            axis_transfer tr = axis_transfer::type_id::create($sformatf("np_tr_%0d", b));
            int base = b * lanes;
            int n    = ((base + lanes) <= bytes.size()) ? lanes : (bytes.size() - base);
            tr.cfg   = cfg;
            tr.tdata = '0;
            tr.tkeep = '0;
            tr.tstrb = '0;
            for (int j = 0; j < n; j++) begin
                tr.tdata[8*j +: 8] = bytes[base + j];
                tr.tkeep[j]        = 1'b1;
                tr.tstrb[j]        = 1'b1;
            end
            tr.tlast = (b == nbeats - 1);
            tr.tid   = stream_tid;
            tr.tdest = stream_tdest;
            tr.tuser = '0;
            tr.delay = inter_beat_delay;
            beats.push_back(tr);
        end
    endfunction

    // =====================================================================
    // body — FIXED. Calls the two hooks, then drives every beat in order.
    //         Do not override.
    // =====================================================================
    task body();
        packet        pkt;
        axis_transfer beats[$];

        pkt = gen_packet();
        if (pkt == null) begin
            `uvm_warning(get_type_name(), "gen_packet returned null, nothing to drive")
            return;
        end
        build_beats(pkt, beats);
        if (beats.size() == 0) begin
            `uvm_warning(get_type_name(), "build_beats produced no beats")
            return;
        end

        `uvm_info(get_type_name(),
                  $sformatf("driving %0d beats (%0d bytes)", beats.size(), pkt.raw_data.size()),
                  UVM_LOW)

        foreach (beats[i]) begin
            if (should_stop()) return;
            start_item(beats[i]);
            finish_item(beats[i]);
        end
    endtask

endclass
`endif // AXIS_USE_NET_PACKET
