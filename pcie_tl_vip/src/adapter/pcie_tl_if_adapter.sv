//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Interface Adapter (TLM / SV IF dual mode)
//-----------------------------------------------------------------------------

class pcie_tl_if_adapter extends uvm_component;
    `uvm_component_utils(pcie_tl_if_adapter)

    //--- Mode ---
    pcie_tl_if_mode_e mode = TLM_MODE;

    //--- TLM side ---
    uvm_tlm_fifo #(pcie_tl_tlp) tlm_tx_fifo;
    uvm_tlm_fifo #(pcie_tl_tlp) tlm_rx_fifo;

    //--- SV Interface side ---
    virtual pcie_tl_if vif;

    //--- Codec reference ---
    pcie_tl_codec codec;

    //--- FC Manager reference (for credit sync) ---
    pcie_tl_fc_manager fc_mgr;

    function new(string name = "pcie_tl_if_adapter", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        tlm_tx_fifo = new("tlm_tx_fifo", this, 256);
        tlm_rx_fifo = new("tlm_rx_fifo", this, 256);
    endfunction

    //=========================================================================
    // Run phase: start FC credit sync if SV_IF_MODE
    //=========================================================================
    task run_phase(uvm_phase phase);
        if (mode == SV_IF_MODE && vif != null) begin
            fork
                fc_credit_sync();
            join_none
        end
    endtask

    //=========================================================================
    // Send TLP (dispatch by mode)
    //=========================================================================
    task send(pcie_tl_tlp tlp);
        case (mode)
            TLM_MODE:   tlm_tx_fifo.put(tlp);
            SV_IF_MODE: drive_to_interface(tlp);
        endcase
    endtask

    //=========================================================================
    // Receive TLP (dispatch by mode)
    //=========================================================================
    task receive(output pcie_tl_tlp tlp);
        case (mode)
            TLM_MODE: begin
                if (tlm_rx_fifo.can_get())
                    void'(tlm_rx_fifo.try_get(tlp));
                else
                    tlp = null;
            end
            SV_IF_MODE: sample_from_interface(tlp);
        endcase
    endtask

    //=========================================================================
    // Runtime mode switching
    //=========================================================================
    function void switch_mode(pcie_tl_if_mode_e new_mode);
        `uvm_info("ADAPTER", $sformatf("Mode switch: %s -> %s",
                  mode.name(), new_mode.name()), UVM_MEDIUM)
        mode = new_mode;
    endfunction

    //=========================================================================
    // SV IF: Drive TLP to interface
    //=========================================================================
    protected task drive_to_interface(pcie_tl_tlp tlp);
        bit [7:0] bytes[];
        int total_beats;

        codec.encode(tlp, bytes);
        total_beats = (bytes.size() + 31) / 32;  // 256-bit bus = 32 bytes

        for (int i = 0; i < total_beats; i++) begin
            /* Drive signals before the clock edge so glue's always_ff
               samples the updated value.  Using blocking assign here
               would violate synthesis style, but for a VIP driver task
               it is acceptable and avoids the NBA delta-cycle race where
               glue_if_to_stub samples vip_tlp_valid before the NBA
               update from <= takes effect on the same posedge. */
            @(negedge vif.clk);
            vif.tlp_valid <= 1;
            vif.tlp_sop   <= (i == 0);
            vif.tlp_eop   <= (i == total_beats - 1);
            vif.tlp_data  <= pack_beat(bytes, i);
            vif.tlp_strb  <= calc_strb(bytes, i, total_beats);
            @(posedge vif.clk);
            while (!vif.tlp_ready) @(posedge vif.clk);
        end
        vif.tlp_valid <= 0;
        vif.tlp_sop   <= 0;
        vif.tlp_eop   <= 0;
    endtask

    //=========================================================================
    // SV IF: Sample TLP from interface
    //=========================================================================
    protected task sample_from_interface(output pcie_tl_tlp tlp);
        bit [7:0] bytes[$];

        // Wait for SOP
        @(posedge vif.clk iff (vif.tlp_valid && vif.tlp_ready && vif.tlp_sop));

        forever begin
            unpack_beat(vif.tlp_data, vif.tlp_strb, bytes);
            if (vif.tlp_eop) break;
            @(posedge vif.clk iff (vif.tlp_valid && vif.tlp_ready));
        end

        begin
            bit [7:0] byte_arr[] = new[bytes.size()];
            foreach (bytes[i]) byte_arr[i] = bytes[i];
            tlp = codec.decode(byte_arr);
        end
    endtask

    //=========================================================================
    // SV IF: FC Credit synchronization
    //=========================================================================
    protected task fc_credit_sync();
        if (fc_mgr == null || vif == null) return;
        forever begin
            @(posedge vif.clk iff vif.fc_update);
            fc_mgr.return_credit(FC_POSTED_HDR,    vif.ph_credit);
            fc_mgr.return_credit(FC_POSTED_DATA,   vif.pd_credit);
            fc_mgr.return_credit(FC_NONPOSTED_HDR, vif.nph_credit);
            fc_mgr.return_credit(FC_NONPOSTED_DATA,vif.npd_credit);
            fc_mgr.return_credit(FC_CPL_HDR,       vif.cplh_credit);
            fc_mgr.return_credit(FC_CPL_DATA,      vif.cpld_credit);
        end
    endtask

    //=========================================================================
    // Internal: Pack bytes into 256-bit beat
    //=========================================================================
    protected function bit [255:0] pack_beat(bit [7:0] bytes[], int beat_idx);
        bit [255:0] data = '0;
        int base = beat_idx * 32;
        for (int i = 0; i < 32 && (base + i) < bytes.size(); i++) begin
            data[i*8 +: 8] = bytes[base + i];
        end
        return data;
    endfunction

    //=========================================================================
    // Internal: Calculate strobe for beat
    //=========================================================================
    protected function bit [3:0] calc_strb(bit [7:0] bytes[], int beat_idx, int total);
        int base = beat_idx * 32;
        int remaining = bytes.size() - base;
        if (remaining >= 32) return 4'hF;
        if (remaining >= 24) return 4'h7;
        if (remaining >= 16) return 4'h3;
        if (remaining >= 8)  return 4'h1;
        return 4'h1;
    endfunction

    //=========================================================================
    // Internal: Unpack 256-bit beat to bytes
    //=========================================================================
    protected function void unpack_beat(bit [255:0] data, bit [3:0] strb,
                                         ref bit [7:0] bytes[$]);
        int num_lanes;
        case (strb)
            4'hF: num_lanes = 32;
            4'h7: num_lanes = 24;
            4'h3: num_lanes = 16;
            4'h1: num_lanes = 8;
            default: num_lanes = 32;
        endcase
        for (int i = 0; i < num_lanes; i++) begin
            bytes.push_back(data[i*8 +: 8]);
        end
    endfunction

endclass
