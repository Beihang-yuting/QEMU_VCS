module axis_protocol_checker_sva (
    axis_if aif
);

    // ---- Local aliases for readability ----
    wire        aclk    = aif.aclk;
    wire        aresetn = aif.aresetn;
    wire        tvalid  = aif.tvalid;
    wire        tready  = aif.tready;
    wire        tlast   = aif.tlast;
    wire [15:0] tid     = aif.tid;
    wire [15:0] tdest   = aif.tdest;

    // ---- 1. TVALID_STABILITY ----
    // Once asserted, TVALID must stay high until handshake (TREADY=1)
    property p_tvalid_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tvalid_stability)
        tvalid && !tready |=> tvalid;
    endproperty
    assert property (p_tvalid_stability)
    else $error("[TVALID_STABILITY] TVALID deasserted before handshake completed at time %0t", $time);

    // ---- 2. TDATA_STABILITY ----
    // Payload must remain stable while TVALID is high and no handshake occurs
    property p_tdata_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tdata);
    endproperty
    assert property (p_tdata_stability)
    else $error("[TDATA_STABILITY] TDATA changed while TVALID high without handshake at time %0t", $time);

    // TSTRB stability
    property p_tstrb_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tstrb);
    endproperty
    assert property (p_tstrb_stability)
    else $error("[TDATA_STABILITY] TSTRB changed while TVALID high without handshake at time %0t", $time);

    // TKEEP stability
    property p_tkeep_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tkeep);
    endproperty
    assert property (p_tkeep_stability)
    else $error("[TDATA_STABILITY] TKEEP changed while TVALID high without handshake at time %0t", $time);

    // TLAST stability
    property p_tlast_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tlast);
    endproperty
    assert property (p_tlast_stability)
    else $error("[TDATA_STABILITY] TLAST changed while TVALID high without handshake at time %0t", $time);

    // TID stability (while TVALID without handshake — separate from TID_CONSISTENCY)
    property p_tid_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tid);
    endproperty
    assert property (p_tid_stability)
    else $error("[TDATA_STABILITY] TID changed while TVALID high without handshake at time %0t", $time);

    // TDEST stability (while TVALID without handshake)
    property p_tdest_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tdest);
    endproperty
    assert property (p_tdest_stability)
    else $error("[TDATA_STABILITY] TDEST changed while TVALID high without handshake at time %0t", $time);

    // TUSER stability (while TVALID without handshake)
    property p_tuser_stability;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdata_stability)
        tvalid && !tready |=> $stable(aif.tuser);
    endproperty
    assert property (p_tuser_stability)
    else $error("[TDATA_STABILITY] TUSER changed while TVALID high without handshake at time %0t", $time);

    // ---- Auxiliary registers for intra-packet consistency checks ----
    logic [15:0] last_hs_tid;
    logic [15:0] last_hs_tdest;
    logic        in_packet = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            in_packet     <= 0;
            last_hs_tid   <= '0;
            last_hs_tdest <= '0;
        end else if (tvalid && tready) begin
            last_hs_tid   <= tid;
            last_hs_tdest <= tdest;
            in_packet     <= !tlast;
        end
    end

    // ---- 3. TLAST_INTEGRITY ----
    // Every non-TLAST beat in a packet must eventually be followed by a TLAST beat.
    // Bounded liveness: if we see a valid handshake without TLAST, then within 65536
    // handshakes we must see TLAST.
    property p_tlast_integrity;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tlast_integrity)
        (tvalid && tready && !tlast) |-> ##[1:65536] (tvalid && tready && tlast);
    endproperty
    assert property (p_tlast_integrity)
    else $error("[TLAST_INTEGRITY] Packet did not terminate with TLAST within 65536 beats at time %0t", $time);

    // ---- 4. TID_CONSISTENCY ----
    // Consecutive handshakes within the same packet must have the same TID.
    property p_tid_consistency;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tid_consistency)
        (tvalid && tready && in_packet) |-> (tid == last_hs_tid);
    endproperty
    assert property (p_tid_consistency)
    else $error("[TID_CONSISTENCY] TID changed mid-packet at time %0t", $time);

    // ---- 5. TDEST_CONSISTENCY ----
    // Consecutive handshakes within the same packet must have the same TDEST.
    property p_tdest_consistency;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tdest_consistency)
        (tvalid && tready && in_packet) |-> (tdest == last_hs_tdest);
    endproperty
    assert property (p_tdest_consistency)
    else $error("[TDEST_CONSISTENCY] TDEST changed mid-packet at time %0t", $time);

    // ---- 6. TKEEP_TSTRB_RELATION ----
    // TSTRB can only be asserted where TKEEP is asserted: (tstrb & ~tkeep) == 0
    property p_tkeep_tstrb_relation;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_tkeep_tstrb_relation)
        tvalid |-> ((aif.tstrb & ~aif.tkeep) == '0);
    endproperty
    assert property (p_tkeep_tstrb_relation)
    else $error("[TKEEP_TSTRB_RELATION] TSTRB set where TKEEP is 0 at time %0t", $time);

    // ---- 7. RESET_SIGNAL_CHECK ----
    // TVALID must be low during reset.
    property p_reset_signal_check;
        @(posedge aclk) disable iff (!aif.chk_en_reset_signal_check)
        !aresetn |-> !tvalid;
    endproperty
    assert property (p_reset_signal_check)
    else $error("[RESET_SIGNAL_CHECK] TVALID asserted during reset at time %0t", $time);

    // ---- 8. X_Z_CHECK ----
    // No X or Z values on active signals when TVALID is asserted.
    property p_x_z_check;
        @(posedge aclk) disable iff (!aresetn || !aif.chk_en_x_z_check)
        tvalid |-> !$isunknown(aif.tdata) && !$isunknown(tvalid) && !$isunknown(tready);
    endproperty
    assert property (p_x_z_check)
    else $error("[X_Z_CHECK] Unknown (X/Z) detected on active signals at time %0t", $time);

    // ---- 9. HANDSHAKE_TIMEOUT ----
    // TVALID should not remain high without handshake for more than N cycles.
    // This is a warning-level check. Uses a counter approach for configurable timeout.
    int unsigned hs_timeout_counter = 0;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            hs_timeout_counter <= 0;
        end else if (aif.chk_en_handshake_timeout) begin
            if (tvalid && !tready) begin
                hs_timeout_counter <= hs_timeout_counter + 1;
                if (hs_timeout_counter >= aif.chk_handshake_timeout_cycles)
                    $warning("[HANDSHAKE_TIMEOUT] TVALID high for %0d cycles without handshake at time %0t",
                             hs_timeout_counter, $time);
            end else begin
                hs_timeout_counter <= 0;
            end
        end else begin
            hs_timeout_counter <= 0;
        end
    end

endmodule
