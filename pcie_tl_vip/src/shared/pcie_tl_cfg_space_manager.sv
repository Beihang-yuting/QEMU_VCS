//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Configuration Space Manager
//-----------------------------------------------------------------------------

class pcie_tl_cfg_space_manager extends uvm_object;
    `uvm_object_utils(pcie_tl_cfg_space_manager)

    //--- 4KB Configuration Space ---
    bit [7:0] cfg_space[4096];

    //--- Field attributes ---
    cfg_field_attr_e field_attrs[4096];  // per-byte attribute

    //--- Capability lists ---
    pcie_capability    cap_list[$];
    pcie_ext_capability ext_cap_list[$];

    //--- Callbacks ---
    pcie_cfg_callback callbacks[bit [11:0]];

    function new(string name = "pcie_tl_cfg_space_manager");
        super.new(name);
        // Initialize all to RW by default
        foreach (field_attrs[i]) field_attrs[i] = CFG_FIELD_RW;
    endfunction

    //=========================================================================
    // Initialize standard Type 0 Configuration Header
    //=========================================================================
    function void init_type0_header(
        bit [15:0] vendor_id    = 16'hABCD,
        bit [15:0] device_id    = 16'h1234,
        bit [7:0]  revision_id  = 8'h01,
        bit [23:0] class_code   = 24'h020000,  // Ethernet controller
        bit [7:0]  header_type  = 8'h00
    );
        // Clear config space
        foreach (cfg_space[i]) cfg_space[i] = 0;

        // Vendor ID (00h) - RO
        cfg_space[0] = vendor_id[7:0];
        cfg_space[1] = vendor_id[15:8];
        field_attrs[0] = CFG_FIELD_RO;
        field_attrs[1] = CFG_FIELD_RO;

        // Device ID (02h) - RO
        cfg_space[2] = device_id[7:0];
        cfg_space[3] = device_id[15:8];
        field_attrs[2] = CFG_FIELD_RO;
        field_attrs[3] = CFG_FIELD_RO;

        // Command (04h) - RW
        cfg_space[4] = 0;
        cfg_space[5] = 0;

        // Status (06h) - RW1C for some bits
        cfg_space[6] = 0;
        cfg_space[7] = 0;
        field_attrs[6] = CFG_FIELD_RW1C;
        field_attrs[7] = CFG_FIELD_RW1C;

        // Revision ID (08h) - RO
        cfg_space[8] = revision_id;
        field_attrs[8] = CFG_FIELD_RO;

        // Class Code (09h-0Bh) - RO
        cfg_space[9]  = class_code[7:0];
        cfg_space[10] = class_code[15:8];
        cfg_space[11] = class_code[23:16];
        field_attrs[9]  = CFG_FIELD_RO;
        field_attrs[10] = CFG_FIELD_RO;
        field_attrs[11] = CFG_FIELD_RO;

        // Cache Line Size (0Ch) - RW
        cfg_space[12] = 0;

        // Latency Timer (0Dh) - RO for PCIe
        cfg_space[13] = 0;
        field_attrs[13] = CFG_FIELD_RO;

        // Header Type (0Eh) - RO
        cfg_space[14] = header_type;
        field_attrs[14] = CFG_FIELD_RO;

        // BIST (0Fh) - RO
        cfg_space[15] = 0;

        // BAR0-BAR5 (10h-27h) - RW (lower bits RO depending on size)
        // Left as zeros, to be configured by user

        // Capabilities Pointer (34h) - RO
        field_attrs[52] = CFG_FIELD_RO;

        // Interrupt Line (3Ch) - RW
        // Interrupt Pin (3Dh) - RO
        field_attrs[61] = CFG_FIELD_RO;
    endfunction

    //=========================================================================
    // Register a standard capability
    //=========================================================================
    function void register_capability(pcie_capability cap);
        bit [7:0] prev_next_ptr_addr;

        // Set capability offset
        if (cap_list.size() == 0) begin
            // First capability: update Capabilities Pointer (34h)
            cfg_space[52] = cap.offset;
        end else begin
            // Link from previous capability
            prev_next_ptr_addr = cap_list[$].offset + 1;
            cfg_space[prev_next_ptr_addr] = cap.offset;
            cap_list[$].next_ptr = cap.offset;
        end

        // Write capability header
        cfg_space[cap.offset]     = cap.cap_id;
        cfg_space[cap.offset + 1] = 0;  // next_ptr = 0 (end of list)
        cap.next_ptr = 0;

        // Write capability data
        for (int i = 0; i < cap.data.size(); i++) begin
            cfg_space[cap.offset + 2 + i] = cap.data[i];
        end

        // Set cap header as RO
        field_attrs[cap.offset]     = CFG_FIELD_RO;
        field_attrs[cap.offset + 1] = CFG_FIELD_RO;

        cap_list.push_back(cap);
    endfunction

    //=========================================================================
    // Unregister a capability
    //=========================================================================
    function void unregister_capability(bit [7:0] cap_id);
        int idx = -1;

        // Find capability
        foreach (cap_list[i]) begin
            if (cap_list[i].cap_id == cap_id) begin
                idx = i;
                break;
            end
        end

        if (idx < 0) return;

        // Relink: update previous capability's next pointer
        if (idx == 0) begin
            // First in list
            if (cap_list.size() > 1)
                cfg_space[52] = cap_list[1].offset;
            else
                cfg_space[52] = 0;
        end else begin
            bit [7:0] prev_next_addr = cap_list[idx-1].offset + 1;
            if (idx < cap_list.size() - 1) begin
                cfg_space[prev_next_addr] = cap_list[idx+1].offset;
                cap_list[idx-1].next_ptr = cap_list[idx+1].offset;
            end else begin
                cfg_space[prev_next_addr] = 0;
                cap_list[idx-1].next_ptr = 0;
            end
        end

        // Clear capability data in config space
        cfg_space[cap_list[idx].offset] = 0;
        cfg_space[cap_list[idx].offset + 1] = 0;

        cap_list.delete(idx);
    endfunction

    //=========================================================================
    // Register an extended capability
    //=========================================================================
    function void register_ext_capability(pcie_ext_capability ext_cap);
        bit [11:0] prev_next_ptr_addr;
        bit [31:0] prev_dw;

        if (ext_cap_list.size() == 0) begin
            // First extended capability at offset 100h
            if (ext_cap.offset == 0) ext_cap.offset = 12'h100;
        end else begin
            // Link from previous
            prev_next_ptr_addr = ext_cap_list[$].offset;
            // Next pointer is in bits [31:20] of the first DW
            prev_dw = read_raw_dw(prev_next_ptr_addr);
            prev_dw[31:20] = ext_cap.offset;
            write_raw_dw(prev_next_ptr_addr, prev_dw);
            ext_cap_list[$].next_ptr = ext_cap.offset;
        end

        // Write ext capability header (DW at offset)
        // [15:0] = cap_id, [19:16] = version, [31:20] = next_ptr
        begin
            bit [31:0] ext_hdr = {12'h000, ext_cap.cap_ver, ext_cap.cap_id};
            write_raw_dw(ext_cap.offset, ext_hdr);
        end

        // Write data
        for (int i = 0; i < ext_cap.data.size(); i++) begin
            cfg_space[ext_cap.offset + 4 + i] = ext_cap.data[i];
        end

        ext_cap_list.push_back(ext_cap);
    endfunction

    //=========================================================================
    // Register Vendor-Specific capability
    //=========================================================================
    function void register_vendor_specific(bit [7:0] data[], bit [7:0] offset);
        pcie_capability vs_cap = pcie_capability::type_id::create("vs_cap");
        vs_cap.cap_id = CAP_ID_VENDOR;
        vs_cap.offset = offset;
        vs_cap.data = data;
        register_capability(vs_cap);
    endfunction

    //=========================================================================
    // Read config space (DW-aligned) with callback
    //=========================================================================
    function bit [31:0] read(bit [11:0] addr);
        bit [11:0] aligned_addr = {addr[11:2], 2'b00};
        bit [31:0] data;

        data = read_raw_dw(aligned_addr);

        // Trigger callback
        if (callbacks.exists(aligned_addr))
            callbacks[aligned_addr].on_read(aligned_addr, data);

        return data;
    endfunction

    //=========================================================================
    // Write config space (DW-aligned) with BE and callback
    //=========================================================================
    function void write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        bit [11:0] aligned_addr = {addr[11:2], 2'b00};

        for (int i = 0; i < 4; i++) begin
            if (be[i]) begin
                bit [11:0] byte_addr = aligned_addr + i;
                bit [7:0] byte_val = data[i*8 +: 8];

                case (field_attrs[byte_addr])
                    CFG_FIELD_RW, CFG_FIELD_RWS:
                        cfg_space[byte_addr] = byte_val;
                    CFG_FIELD_RW1C:
                        cfg_space[byte_addr] = cfg_space[byte_addr] & ~byte_val;
                    CFG_FIELD_RO, CFG_FIELD_ROS, CFG_FIELD_RSVD:
                        ; // ignore write to RO fields
                endcase
            end
        end

        // Trigger callback
        if (callbacks.exists(aligned_addr))
            callbacks[aligned_addr].on_write(aligned_addr, data, be);
    endfunction

    //=========================================================================
    // Register callback for an address
    //=========================================================================
    function void register_callback(bit [11:0] addr, pcie_cfg_callback cb);
        callbacks[addr] = cb;
    endfunction

    //=========================================================================
    // Internal: raw DW read/write (no callback)
    //=========================================================================
    protected function bit [31:0] read_raw_dw(bit [11:0] addr);
        return {cfg_space[addr+3], cfg_space[addr+2], cfg_space[addr+1], cfg_space[addr]};
    endfunction

    protected function void write_raw_dw(bit [11:0] addr, bit [31:0] data);
        cfg_space[addr]   = data[7:0];
        cfg_space[addr+1] = data[15:8];
        cfg_space[addr+2] = data[23:16];
        cfg_space[addr+3] = data[31:24];
    endfunction

    //=========================================================================
    // Initialize PCIe Capability structure
    //=========================================================================
    function void init_pcie_capability(bit [7:0] cap_offset = 8'h40, mps_e mps = MPS_256, mrrs_e mrrs = MRRS_512, rcb_e rcb = RCB_64);
        pcie_capability pcie_cap;
        bit [31:0] dev_cap, dev_ctrl;
        bit [2:0] mps_enc, mrrs_enc;

        case (mps)
            MPS_128:  mps_enc = 3'b000;
            MPS_256:  mps_enc = 3'b001;
            MPS_512:  mps_enc = 3'b010;
            MPS_1024: mps_enc = 3'b011;
            MPS_2048: mps_enc = 3'b100;
            MPS_4096: mps_enc = 3'b101;
            default:  mps_enc = 3'b001;
        endcase
        case (mrrs)
            MRRS_128:  mrrs_enc = 3'b000;
            MRRS_256:  mrrs_enc = 3'b001;
            MRRS_512:  mrrs_enc = 3'b010;
            MRRS_1024: mrrs_enc = 3'b011;
            MRRS_2048: mrrs_enc = 3'b100;
            MRRS_4096: mrrs_enc = 3'b101;
            default:   mrrs_enc = 3'b010;
        endcase

        dev_cap = 32'h0;
        dev_cap[2:0] = mps_enc;

        dev_ctrl = 32'h0;
        dev_ctrl[7:5] = mps_enc;
        dev_ctrl[14:12] = mrrs_enc;
        dev_ctrl[3] = (rcb == RCB_128) ? 1'b1 : 1'b0;

        pcie_cap = pcie_capability::type_id::create("pcie_cap");
        pcie_cap.cap_id = CAP_ID_PCIE;
        pcie_cap.offset = cap_offset;
        pcie_cap.data = new[10];
        pcie_cap.data[0] = 8'h02;  // PCIe Caps: version=2, type=EP
        pcie_cap.data[1] = 8'h00;
        pcie_cap.data[2] = dev_cap[7:0];
        pcie_cap.data[3] = dev_cap[15:8];
        pcie_cap.data[4] = dev_cap[23:16];
        pcie_cap.data[5] = dev_cap[31:24];
        pcie_cap.data[6] = dev_ctrl[7:0];
        pcie_cap.data[7] = dev_ctrl[15:8];
        pcie_cap.data[8] = dev_ctrl[23:16];
        pcie_cap.data[9] = dev_ctrl[31:24];

        register_capability(pcie_cap);

        // Device Capabilities = RO
        for (int i = 0; i < 4; i++)
            field_attrs[cap_offset + 4 + i] = CFG_FIELD_RO;
    endfunction

    //=========================================================================
    // Get MPS in bytes from Device Control register
    //=========================================================================
    function int get_mps_bytes();
        return 128 << get_dev_ctrl_field(7, 5);
    endfunction

    //=========================================================================
    // Get MRRS in bytes from Device Control register
    //=========================================================================
    function int get_mrrs_bytes();
        return 128 << get_dev_ctrl_field(14, 12);
    endfunction

    //=========================================================================
    // Get RCB in bytes from Device Control register
    //=========================================================================
    function int get_rcb_bytes();
        return get_dev_ctrl_field(3, 3) ? 128 : 64;
    endfunction

    //=========================================================================
    // Internal: read a field from Device Control register
    //=========================================================================
    protected function int get_dev_ctrl_field(int hi, int lo);
        bit [7:0] cap_offset;
        bit [31:0] dev_ctrl;
        int i;
        cap_offset = 0;
        for (i = 0; i < cap_list.size(); i++) begin
            if (cap_list[i].cap_id == CAP_ID_PCIE) begin
                cap_offset = cap_list[i].offset;
                break;
            end
        end
        if (cap_offset == 0) return 0;
        dev_ctrl = read(cap_offset + 8);
        return (dev_ctrl >> lo) & ((1 << (hi - lo + 1)) - 1);
    endfunction

endclass
