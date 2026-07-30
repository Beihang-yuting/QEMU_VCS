//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Function Manager
//-----------------------------------------------------------------------------

//=============================================================================
// DPI-C imports for topology export (CoSim only, define PCIE_COSIM_ENABLE)
//=============================================================================
`ifdef PCIE_COSIM_ENABLE
import "DPI-C" function void bridge_vcs_set_pf_topology(
    input int pf_idx, input int bdf, input int num_vfs, input int vf_device_id,
    input int vendor_id, input int device_id, input int msix_vectors, input int vf_msix_vectors,
    input longint unsigned pf_bar0, input longint unsigned pf_bar1, input longint unsigned pf_bar2,
    input longint unsigned pf_bar3, input longint unsigned pf_bar4, input longint unsigned pf_bar5,
    input longint unsigned vf_bar0, input longint unsigned vf_bar1, input longint unsigned vf_bar2,
    input longint unsigned vf_bar3, input longint unsigned vf_bar4, input longint unsigned vf_bar5);
import "DPI-C" function void bridge_vcs_finalize_topology(input int num_pfs, input int tag_width);
import "DPI-C" function void bridge_vcs_set_pf_topology_rc(
    input int rc, input int pf_idx, input int bdf, input int num_vfs,
    input int vf_device_id, input int vendor_id, input int device_id,
    input int msix_vectors, input int vf_msix_vectors,
    input int pf_bar_flags0, input int pf_bar_flags1, input int pf_bar_flags2,
    input int pf_bar_flags3, input int pf_bar_flags4, input int pf_bar_flags5,
    input longint unsigned pf_bar0, input longint unsigned pf_bar1,
    input longint unsigned pf_bar2, input longint unsigned pf_bar3,
    input longint unsigned pf_bar4, input longint unsigned pf_bar5,
    input longint unsigned vf_bar0, input longint unsigned vf_bar1,
    input longint unsigned vf_bar2, input longint unsigned vf_bar3,
    input longint unsigned vf_bar4, input longint unsigned vf_bar5);
import "DPI-C" function void bridge_vcs_finalize_topology_rc(
    input int rc, input int num_pfs, input int tag_width);
`endif

//=============================================================================
// Per-function context: holds BDF, config space, and BAR state
//=============================================================================
class pcie_tl_func_context extends uvm_object;
    `uvm_object_utils(pcie_tl_func_context)

    //--- Identity ---
    int        pf_index;
    int        vf_index;      // -1 means this entry is a PF
    bit [15:0] bdf;
    bit [15:0] vendor_id;
    bit [15:0] device_id;
    bit        is_vf;
    bit        enabled;

    //--- Independent configuration space ---
    pcie_tl_cfg_space_manager cfg_mgr;

    //--- BAR state ---
    bit [63:0] bar_base[6];
    bit [63:0] bar_size[6];
    bit        bar_enable[6];

    //--- BAR descriptor metadata ---
    // A 64-bit BAR occupies two configuration DWORDs. bar_owner resolves
    // either word to the low DWORD which owns the size/base/flags state.
    bit [31:0] bar_flags[6];
    int        bar_owner[6];

    //--- BAR sizing state per BAR register ---
    bit        bar_sizing[6];

    //--- Bus Master Enable (mirrors Command register bit 2) ---
    bit        bus_master_en;

    //--- Bridge (Type 1) support: 该 context 是桥则置位 + bus number 窗口 ---
    bit        is_bridge;
    bit [7:0]  primary_bus;
    bit [7:0]  secondary_bus;
    bit [7:0]  subordinate_bus;

    function new(string name = "pcie_tl_func_context");
        super.new(name);
        vf_index      = -1;
        is_vf         = 0;
        enabled       = 1;
        bus_master_en = 0;
        foreach (bar_base[i])   bar_base[i]   = 64'h0;
        foreach (bar_size[i])   bar_size[i]   = 64'h0;
        foreach (bar_enable[i]) bar_enable[i] = 0;
        foreach (bar_sizing[i]) bar_sizing[i] = 0;
        foreach (bar_flags[i]) begin
            bar_flags[i] = 32'h0;
            bar_owner[i] = i;
        end
    endfunction

    //=========================================================================
    // Initialize the DPU's three 64-bit prefetchable PF/VF BAR descriptors.
    // Only BAR0/BAR2/BAR4 are owners; BAR1/BAR3/BAR5 are their upper words.
    //=========================================================================
    function void init_dpu_bar_descriptors();
        for (int bar = 0; bar < 6; bar++) begin
            bar_base[bar]  = 64'h0;
            bar_size[bar]  = 64'h0;
            bar_sizing[bar] = 0;
            bar_owner[bar] = (bar / 2) * 2;
            bar_flags[bar] = pcie_dpu_bar_flags(bar);
        end
        for (int bar = 0; bar < 6; bar++) begin
            if (bar_owner[bar] == bar) begin
                bar_size[bar] = pcie_dpu_bar_size(is_vf, bar);
                // The raw image must advertise the low-word type/prefetch
                // bits even before a configuration proxy handles a BAR read.
                cfg_mgr.write(12'h010 + bar * 4, bar_flags[bar], 4'hf);
            end
        end
    endfunction

    //=========================================================================
    // Initialize config space with Type 0 header and PCIe capability
    //=========================================================================
    function void init_cfg_space(
        bit [15:0] vendor_id,
        bit [15:0] device_id,
        bit [7:0]  header_type = 8'h00,
        pcie_cfg_profile_e profile = PCIE_CFG_PROFILE_LEGACY
    );
        this.vendor_id = vendor_id;
        this.device_id = device_id;
        cfg_mgr = pcie_tl_cfg_space_manager::type_id::create(
            $sformatf("cfg_mgr_bdf%04h", bdf));
        if (is_bridge) begin
            // Type 1 (bridge/switch): bus number 窗口由本 context 携带
            cfg_mgr.init_type1_header(vendor_id, device_id,
                .primary_bus(primary_bus), .secondary_bus(secondary_bus),
                .subordinate_bus(subordinate_bus));
            cfg_mgr.init_pcie_capability();  // TODO: bridge 的 PCIe cap port type(switch/root)细化
        end else begin
            // Type 0 (endpoint)
            if (profile == PCIE_CFG_PROFILE_DPU_20F9_501X) begin
                cfg_mgr.init_type0_header(vendor_id, device_id,
                    .revision_id(8'h00), .class_code(24'h020000),
                    .header_type(header_type),
                    .subsystem_vendor_id(16'h20f9),
                    .subsystem_device_id(16'h0000));
                cfg_mgr.init_pm_capability(.cap_offset(8'h40),
                                           .static_fields_ro(1'b1));
                cfg_mgr.init_msix_capability(.cap_offset(8'h60), .table_size(16),
                    .bir(3'd4), .table_off(32'h0000_0000),
                    .pba_off(32'h0000_4000));
                cfg_mgr.init_dpu_501x_pcie_capability(.cap_offset(8'h70));
            end else begin
                cfg_mgr.init_type0_header(vendor_id, device_id, .header_type(header_type));
                cfg_mgr.init_pcie_capability();
                cfg_mgr.init_pm_capability();
            end
        end
    endfunction

endclass


//=============================================================================
// Function manager: owns all PF/VF contexts and SR-IOV capabilities
//=============================================================================
class pcie_tl_func_manager extends uvm_object;
    `uvm_object_utils(pcie_tl_func_manager)

    //--- Configuration ---
    int        num_pfs        = 1;
    int        max_vfs_per_pf = 256;
    bit [15:0] vendor_id      = 16'hABCD;
    bit [15:0] device_id      = 16'h1234;
    bit [15:0] vf_device_id   = 16'h1235;
    pcie_cfg_profile_e cfg_profile = PCIE_CFG_PROFILE_LEGACY;
    bit [7:0]  pf_base_bus    = 8'h01;   // cosim EP behind pcie-root-port -> 01:00.0
    bit [4:0]  pf_base_dev    = 5'h00;
    bit        runtime_bdf_bound = 0;
    bit [15:0] runtime_pf_base_bdf = 16'h0000;

    //--- MSI-X and tag configuration (CoSim topology export) ---
    int        pf_msix_vectors = 64;
    int        vf_msix_vectors = 8;
    int        tag_width = 1;  // 0=5bit, 1=8bit, 2=10bit

    //--- Context arrays ---
    pcie_tl_func_context  pf_ctx[];
    pcie_tl_func_context  vf_ctx[][];
    pcie_tl_sriov_cap     sriov_caps[];

    //--- BDF lookup table (fast path) ---
    pcie_tl_func_context  bdf_lut[bit [15:0]];

    function new(string name = "pcie_tl_func_manager");
        super.new(name);
    endfunction

    //=========================================================================
    // Build all PF and VF contexts, wire SR-IOV capabilities
    //=========================================================================
    function void build(
        int        n_pfs     = 1,
        int        max_vfs   = 256,
        bit [15:0] v_id      = 16'hABCD,
        bit [15:0] d_id      = 16'h1234,
        bit [15:0] vf_dev_id = 16'h1235
    );
        num_pfs        = n_pfs;
        max_vfs_per_pf = max_vfs;
        vendor_id      = v_id;
        device_id      = d_id;
        vf_device_id   = vf_dev_id;
        if (cfg_profile == PCIE_CFG_PROFILE_DPU_20F9_501X) begin
            vendor_id = 16'h20f9;
            device_id = 16'h5011;
        end

        pf_ctx     = new[num_pfs];
        vf_ctx     = new[num_pfs];
        sriov_caps = new[num_pfs];

        for (int pf = 0; pf < num_pfs; pf++) begin
            bit [15:0] pf_bdf;
            bit [15:0] pf_vendor_id;
            bit [15:0] pf_device_id;

            // Preserve the complete eight-bit ARI function number. For PF8+
            // the conventional BDF rendering advances the device field; using
            // pf[2:0] here would alias PF8 back onto PF0.
            pf_bdf = pcie_pf_bdf({pf_base_bus, pf_base_dev, 3'b000}, pf);

            // Create and initialise PF context
            pf_ctx[pf] = pcie_tl_func_context::type_id::create(
                $sformatf("pf_ctx_%0d", pf));
            pf_ctx[pf].pf_index = pf;
            pf_ctx[pf].vf_index = -1;
            pf_ctx[pf].bdf      = pf_bdf;
            pf_ctx[pf].is_vf    = 0;
            pf_ctx[pf].enabled  = 1;
            // PF BAR0 size — without a sizeable PF BAR the guest sees no MMIO
            // window and SR-IOV init bails (no VF resources). 64KB memory BAR.
            pf_ctx[pf].bar_size[0] = 64 * 1024;
            // 多 PF 时置 Header Type multi-function bit(0x80), 否则 OS 只扫 function 0
            if (cfg_profile == PCIE_CFG_PROFILE_DPU_20F9_501X) begin
                pf_vendor_id = 16'h20f9;
                pf_device_id = pcie_dpu_pf_device_id(pf);
            end else begin
                pf_vendor_id = vendor_id;
                pf_device_id = device_id;
            end
            pf_ctx[pf].init_cfg_space(pf_vendor_id, pf_device_id,
                                      .header_type((num_pfs > 1) ? 8'h80 : 8'h00),
                                      .profile(cfg_profile));
            if (cfg_profile == PCIE_CFG_PROFILE_DPU_20F9_501X)
                pf_ctx[pf].init_dpu_bar_descriptors();

            // Register PF in BDF lookup table
            bdf_lut[pf_bdf] = pf_ctx[pf];

            if (cfg_profile == PCIE_CFG_PROFILE_DPU_20F9_501X) begin
                // Captured DPU PF extended-capability chain. Unlike the legacy
                // PF chain, DPU PFs intentionally do not advertise ATS, PRI,
                // or PASID.
                begin
                    pcie_ext_capability aer_cap = pcie_ext_capability::type_id::create(
                        $sformatf("dpu_aer_cap_%0d", pf));
                    aer_cap.cap_id  = EXT_CAP_ID_AER;
                    aer_cap.cap_ver = 4'h1;
                    aer_cap.offset  = 12'h100;
                    // The next capability begins at 0x140, so AER owns
                    // exactly bytes 0x104..0x13f (60 bytes of payload).
                    aer_cap.data    = new[60];
                    foreach (aer_cap.data[i]) aer_cap.data[i] = 8'h00;
                    // UE Mask = 0x00400000; UE Severity = 0x00462030.
                    aer_cap.data[6]  = 8'h40;
                    aer_cap.data[8]  = 8'h30;
                    aer_cap.data[9]  = 8'h20;
                    aer_cap.data[10] = 8'h46;
                    // CE Mask = 0x0000e000.
                    aer_cap.data[17] = 8'he0;
                    pf_ctx[pf].cfg_mgr.register_ext_capability(aer_cap);
                    // UE Status (+0x04) and CE Status (+0x10) are RW1C;
                    // masks and severity retain their normal RW permissions.
                    for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
                        pf_ctx[pf].cfg_mgr.field_attrs[12'h104 + byte_idx] = CFG_FIELD_RW1C;
                        pf_ctx[pf].cfg_mgr.field_attrs[12'h110 + byte_idx] = CFG_FIELD_RW1C;
                    end
                end

                sriov_caps[pf] = pcie_tl_sriov_cap::type_id::create(
                    $sformatf("dpu_sriov_cap_%0d", pf));
                sriov_caps[pf].pf_bdf                   = pf_bdf;
                sriov_caps[pf].initial_vfs              = 16;
                sriov_caps[pf].total_vfs                = 16;
                sriov_caps[pf].vf_device_id             = 16'h8689;
                sriov_caps[pf].function_dependency_link = pf;
                sriov_caps[pf].first_vf_offset = pcie_dpu_first_vf_offset(num_pfs, pf);
                sriov_caps[pf].vf_stride                = 1;
                sriov_caps[pf].ari_capable_hierarchy    = 1;
                sriov_caps[pf].init_dpu_vf_bar_descriptors();
                sriov_caps[pf].offset                   = 12'h140;
                sriov_caps[pf].build_data();
                pf_ctx[pf].cfg_mgr.register_ext_capability(sriov_caps[pf]);
                // Static SR-IOV discovery fields are read-only. NumVFs,
                // Control, System Page Size, and VF BAR state remain dynamic.
                for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h144 + byte_idx] = CFG_FIELD_RO;
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h14c + byte_idx] = CFG_FIELD_RO;
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h154 + byte_idx] = CFG_FIELD_RO;
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h158 + byte_idx] = CFG_FIELD_RO;
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h15c + byte_idx] = CFG_FIELD_RO;
                end
                pf_ctx[pf].cfg_mgr.field_attrs[12'h152] = CFG_FIELD_RO;
                pf_ctx[pf].cfg_mgr.field_attrs[12'h153] = CFG_FIELD_RO;
                pf_ctx[pf].cfg_mgr.field_attrs[12'h14a] = CFG_FIELD_RW1C;
                pf_ctx[pf].cfg_mgr.field_attrs[12'h14b] = CFG_FIELD_RW1C;

                begin
                    pcie_ext_capability ari_cap = pcie_ext_capability::type_id::create(
                        $sformatf("dpu_ari_cap_%0d", pf));
                    ari_cap.cap_id  = EXT_CAP_ID_ARI;
                    ari_cap.cap_ver = 4'h1;
                    ari_cap.offset  = 12'h180;
                    ari_cap.data    = new[4];
                    foreach (ari_cap.data[i]) ari_cap.data[i] = 8'h00;
                    // Next Function Number is ARI Capability bits [15:8].
                    ari_cap.data[1] = (pf + 1 < num_pfs) ? 8'(pf + 1) : 8'h00;
                    pf_ctx[pf].cfg_mgr.register_ext_capability(ari_cap);
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h184] = CFG_FIELD_RO;
                    pf_ctx[pf].cfg_mgr.field_attrs[12'h185] = CFG_FIELD_RO;
                end

                begin
                    pcie_ext_capability sec_pcie_cap = pcie_ext_capability::type_id::create(
                        $sformatf("dpu_secondary_pcie_cap_%0d", pf));
                    sec_pcie_cap.cap_id  = 16'h0019;
                    sec_pcie_cap.cap_ver = 4'h1;
                    sec_pcie_cap.offset  = 12'h1c0;
                    sec_pcie_cap.data    = new[4];
                    foreach (sec_pcie_cap.data[i]) sec_pcie_cap.data[i] = 8'h00;
                    pf_ctx[pf].cfg_mgr.register_ext_capability(sec_pcie_cap);
                    for (int byte_idx = 0; byte_idx < 4; byte_idx++)
                        pf_ctx[pf].cfg_mgr.field_attrs[12'h1c4 + byte_idx] = CFG_FIELD_RO;
                end

                begin
                    pcie_ext_capability acs_cap = pcie_ext_capability::type_id::create(
                        $sformatf("dpu_acs_cap_%0d", pf));
                    acs_cap.cap_id  = EXT_CAP_ID_ACS;
                    acs_cap.cap_ver = 4'h1;
                    acs_cap.offset  = 12'h400;
                    acs_cap.data    = new[4];
                    foreach (acs_cap.data[i]) acs_cap.data[i] = 8'h00;
                    acs_cap.data[0] = 8'h20;
                    acs_cap.data[1] = 8'h20;
                    pf_ctx[pf].cfg_mgr.register_ext_capability(acs_cap);
                    for (int byte_idx = 0; byte_idx < 4; byte_idx++)
                        pf_ctx[pf].cfg_mgr.field_attrs[12'h404 + byte_idx] = CFG_FIELD_RO;
                end
            end else begin
            // ARI Extended Capability (0x000E): extended cap 链头必须在 0x100,
            // 否则 OS 从 0x100 见空即止, SR-IOV(@0x200)永远发现不了。
            // 且多 VF(function# > 7)路由依赖 ARI。先注册 ARI(占 0x100)再链到 SR-IOV。
            begin
                pcie_ext_capability ari_cap = pcie_ext_capability::type_id::create(
                    $sformatf("ari_cap_%0d", pf));
                ari_cap.cap_id  = EXT_CAP_ID_ARI;
                ari_cap.cap_ver = 4'h1;
                ari_cap.data    = new[4];   // ARI Cap Reg(2B) + ARI Control(2B)
                foreach (ari_cap.data[i]) ari_cap.data[i] = 8'h00;
                // ARI Next Function Number (ARI Cap Reg bits[15:8] = data[1]): chain
                // the PFs so OS ARI enumeration visits PF0->PF1->..->PF(N-1). Without
                // this (next=0) ARI enumeration stops at function 0 and only PF0 is
                // discovered even though the multi-function header bit is set.
                ari_cap.data[1] = (pf + 1 < num_pfs) ? 8'(pf + 1) : 8'h00;
                pf_ctx[pf].cfg_mgr.register_ext_capability(ari_cap);  // 首个 -> 0x100
            end

            // Create SR-IOV extended capability for this PF (链在 ARI 之后 @0x200)
            sriov_caps[pf] = pcie_tl_sriov_cap::type_id::create(
                $sformatf("sriov_cap_%0d", pf));
            sriov_caps[pf].pf_bdf                = pf_bdf;
            sriov_caps[pf].total_vfs             = max_vfs_per_pf;
            sriov_caps[pf].initial_vfs           = max_vfs_per_pf;  // InitialVFs = TotalVFs
            sriov_caps[pf].vf_device_id          = vf_dev_id;
            sriov_caps[pf].ari_capable_hierarchy = 1;               // 多 VF 需 ARI capable
            sriov_caps[pf].vf_bar_size[0]        = 64 * 1024;       // VF BAR0 默认 64KB(sizing 用)
            sriov_caps[pf].offset                = 12'h200;
            // VF Offset/Stride: interleave VFs of all PFs so VF RIDs never collide
            // with PF functions (0..num_pfs-1) or with other PFs' VFs. With
            // offset=stride=num_pfs: PF_k VF_i RID = pf_bdf + num_pfs + i*num_pfs,
            // e.g. 4 PF -> VFs start at PF0=0x0104,PF1=0x0105,.. striding by 4.
            // Default 1/1 only works for a single PF (VF0 would land on PF1's BDF).
            sriov_caps[pf].first_vf_offset       = num_pfs;
            sriov_caps[pf].vf_stride             = num_pfs;
            sriov_caps[pf].build_data();
            pf_ctx[pf].cfg_mgr.register_ext_capability(sriov_caps[pf]);

            // AER Extended Capability (0x0001) stub —— 链在 SR-IOV 之后 @0x300。
            // 错误寄存器全 0(无错误), 让 OS AER 服务能遍历到而不崩。
            begin
                pcie_ext_capability aer_cap = pcie_ext_capability::type_id::create(
                    $sformatf("aer_cap_%0d", pf));
                aer_cap.cap_id  = EXT_CAP_ID_AER;
                aer_cap.cap_ver = 4'h2;
                aer_cap.offset  = 12'h300;
                aer_cap.data    = new[64];
                foreach (aer_cap.data[i]) aer_cap.data[i] = 8'h00;
                pf_ctx[pf].cfg_mgr.register_ext_capability(aer_cap);
            end

            // ATS Extended Capability (0x000F) —— 链在 AER 之后 @0x350。DUT 广告
            // ATS，guest lspci 可见 + 可 pci_enable_ats。config-bypass 下 DUT(此
            // func_mgr)拥有该 cap；数据面 ATS TLP 由 VIP 桥接(§6.12/6.13)。
            begin
                pcie_ext_capability ats_cap = pcie_ext_capability::type_id::create(
                    $sformatf("ats_cap_%0d", pf));
                ats_cap.cap_id  = EXT_CAP_ID_ATS;
                ats_cap.cap_ver = 4'h1;
                ats_cap.offset  = 12'h350;
                ats_cap.data    = new[4];   // ATS Cap Reg(2B) + ATS Control Reg(2B)
                foreach (ats_cap.data[i]) ats_cap.data[i] = 8'h00;
                ats_cap.data[0] = 8'h20;    // Cap Reg bit5 = Page Aligned Request
                // Control Reg (data[2..3]) = 0: Enable=0 (guest sets), STU=0
                pf_ctx[pf].cfg_mgr.register_ext_capability(ats_cap);
            end

            // PRI Extended Capability (0x0013) —— 链在 ATS 之后 @0x360。
            begin
                pcie_ext_capability pri_cap = pcie_ext_capability::type_id::create(
                    $sformatf("pri_cap_%0d", pf));
                pri_cap.cap_id  = EXT_CAP_ID_PRI;
                pri_cap.cap_ver = 4'h1;
                pri_cap.offset  = 12'h360;
                pri_cap.data    = new[12];  // Ctrl/Status(4B) + OutstandingCap(4B) + Alloc(4B)
                foreach (pri_cap.data[i]) pri_cap.data[i] = 8'h00;
                pri_cap.data[4] = 8'h20;    // Outstanding Page Request Capacity = 32
                pf_ctx[pf].cfg_mgr.register_ext_capability(pri_cap);
            end

            // PASID Extended Capability (0x001B) —— 链在 PRI 之后 @0x370。
            begin
                pcie_ext_capability pasid_cap = pcie_ext_capability::type_id::create(
                    $sformatf("pasid_cap_%0d", pf));
                pasid_cap.cap_id  = EXT_CAP_ID_PASID;
                pasid_cap.cap_ver = 4'h1;
                pasid_cap.offset  = 12'h370;
                pasid_cap.data    = new[4];  // PASID Cap Reg(2B) + PASID Control Reg(2B)
                foreach (pasid_cap.data[i]) pasid_cap.data[i] = 8'h00;
                pasid_cap.data[1] = 8'h10;   // Cap Reg [12:8] Max PASID Width = 16
                // Control Reg (data[2..3]) = 0: PASID Enable(bit0)=0 (guest sets)
                pf_ctx[pf].cfg_mgr.register_ext_capability(pasid_cap);
            end
            end

            // Pre-allocate VF contexts (disabled by default)
            vf_ctx[pf] = new[max_vfs_per_pf];
            for (int vf = 0; vf < max_vfs_per_pf; vf++) begin
                bit [15:0] vf_bdf = sriov_caps[pf].get_vf_rid(vf);

                vf_ctx[pf][vf] = pcie_tl_func_context::type_id::create(
                    $sformatf("vf_ctx_%0d_%0d", pf, vf));
                vf_ctx[pf][vf].pf_index = pf;
                vf_ctx[pf][vf].vf_index = vf;
                vf_ctx[pf][vf].bdf      = vf_bdf;
                vf_ctx[pf][vf].is_vf    = 1;
                vf_ctx[pf][vf].enabled  = 0;
                vf_ctx[pf][vf].init_cfg_space(vendor_id, vf_dev_id);
                if (cfg_profile == PCIE_CFG_PROFILE_DPU_20F9_501X)
                    vf_ctx[pf][vf].init_dpu_bar_descriptors();
                // MSI-X capability so guest/VFIO can enable per-VF interrupts.
                // Table @ VF BAR0 + 0x1000, PBA @ +0x1800 (doorbell regs are at
                // 0x00..0x0C, no overlap). EP captures the table addr/data writes.
                vf_ctx[pf][vf].cfg_mgr.init_msix_capability(
                    .table_size(vf_msix_vectors > 0 ? vf_msix_vectors : 8));
                // ATS/PRI Extended Capabilities on the VF — real SR-IOV VFs
                // advertise ATS so the guest can enable per-VF address
                // translation. The VF ext-cap chain is empty, so ATS is the head
                // @0x100 and PRI @0x110. Data-plane ATS TLPs bridge via §6.12-6.14.
                begin
                    pcie_ext_capability vats;
                    pcie_ext_capability vpri;
                    pcie_ext_capability vpasid;
                    vats = pcie_ext_capability::type_id::create(
                        $sformatf("vf_ats_%0d_%0d", pf, vf));
                    vats.cap_id  = EXT_CAP_ID_ATS;
                    vats.cap_ver = 4'h1;
                    vats.offset  = 12'h100;
                    vats.data    = new[4];
                    foreach (vats.data[i]) vats.data[i] = 8'h00;
                    vats.data[0] = 8'h20;   // Cap Reg bit5 = Page Aligned Request
                    vf_ctx[pf][vf].cfg_mgr.register_ext_capability(vats);

                    vpri = pcie_ext_capability::type_id::create(
                        $sformatf("vf_pri_%0d_%0d", pf, vf));
                    vpri.cap_id  = EXT_CAP_ID_PRI;
                    vpri.cap_ver = 4'h1;
                    vpri.offset  = 12'h110;
                    vpri.data    = new[12];
                    foreach (vpri.data[i]) vpri.data[i] = 8'h00;
                    vpri.data[4] = 8'h20;   // Outstanding Page Request Capacity = 32
                    vf_ctx[pf][vf].cfg_mgr.register_ext_capability(vpri);

                    vpasid = pcie_ext_capability::type_id::create(
                        $sformatf("vf_pasid_%0d_%0d", pf, vf));
                    vpasid.cap_id  = EXT_CAP_ID_PASID;
                    vpasid.cap_ver = 4'h1;
                    vpasid.offset  = 12'h120;
                    vpasid.data    = new[4];
                    foreach (vpasid.data[i]) vpasid.data[i] = 8'h00;
                    vpasid.data[1] = 8'h10;  // Cap Reg [12:8] Max PASID Width = 16
                    vf_ctx[pf][vf].cfg_mgr.register_ext_capability(vpasid);
                end
                // VFs start disabled — not yet added to bdf_lut
            end
        end
    endfunction

    //=========================================================================
    // build_topology — cosim entry that also selects a topology form.
    // topo (0=ep_direct, 1=switch, 2=multi_layer) is reserved for the Type1
    // multi-topology roadmap; only flat ep_direct is modeled today, so it is
    // accepted for API compatibility and delegated to build().
    //=========================================================================
    function void build_topology(
        int        topo      = 0,
        int        n_pfs     = 1,
        int        max_vfs   = 256,
        bit [15:0] v_id      = 16'hABCD,
        bit [15:0] d_id      = 16'h1234,
        bit [15:0] vf_dev_id = 16'h1235
    );
        if (topo != 0)
            `uvm_info("FUNC_MGR", $sformatf(
                "build_topology: topo=%0d not yet modeled, using flat ep_direct", topo),
                UVM_LOW)
        build(n_pfs, max_vfs, v_id, d_id, vf_dev_id);
    endfunction

    //=========================================================================
    // Bind the bootstrap PF/VF model to the BDF assigned by firmware.
    // Called synchronously on the first PF0 Vendor ID read, before lookup, so
    // enumeration never observes an intermediate 0xFFFF_FFFF response.
    //=========================================================================
    function bit bind_runtime_pf_base(bit [15:0] observed_pf0_bdf);
        bit [15:0] old_base;
        bit [15:0] new_base;

        if (num_pfs < 1 || pf_ctx.size() < num_pfs) begin
            `uvm_error("FUNC_MGR", "runtime BDF bind requested before PF contexts exist")
            return 0;
        end
        if (observed_pf0_bdf[2:0] != 3'b000) begin
            `uvm_warning("FUNC_MGR", $sformatf(
                "runtime BDF bind rejected: observed PF0 has non-zero function 0x%04h",
                observed_pf0_bdf))
            return 0;
        end
        if (num_pfs == 16 && observed_pf0_bdf[7:0] != 8'h00) begin
            `uvm_fatal("FUNC_MGR", $sformatf(
                "16-PF single-bus profile requires PF0 devfn 0, observed 0x%04h",
                observed_pf0_bdf))
            return 0;
        end

        old_base = pcie_pf_base_bdf(pf_ctx[0].bdf);
        new_base = pcie_pf_base_bdf(observed_pf0_bdf);
        if (runtime_bdf_bound)
            return runtime_pf_base_bdf == new_base;

        // Remove all old keys before changing any context. Enabled VFs are
        // uncommon during boot, but handling them keeps a rekey atomic.
        for (int pf = 0; pf < num_pfs; pf++) begin
            bdf_lut.delete(pf_ctx[pf].bdf);
            for (int vf = 0; vf < max_vfs_per_pf; vf++)
                if (vf_ctx[pf][vf].enabled)
                    bdf_lut.delete(vf_ctx[pf][vf].bdf);
        end

        pf_base_bus = new_base[15:8];
        pf_base_dev = new_base[7:3];
        for (int pf = 0; pf < num_pfs; pf++) begin
            bit [15:0] new_pf_bdf = pcie_pf_bdf(new_base, pf);

            pf_ctx[pf].bdf       = new_pf_bdf;
            sriov_caps[pf].pf_bdf = new_pf_bdf;
            bdf_lut[new_pf_bdf]  = pf_ctx[pf];

            for (int vf = 0; vf < max_vfs_per_pf; vf++) begin
                bit [15:0] new_vf_bdf = pcie_vf_bdf(
                    new_pf_bdf,
                    sriov_caps[pf].first_vf_offset,
                    sriov_caps[pf].vf_stride,
                    vf);
                vf_ctx[pf][vf].bdf = new_vf_bdf;
                if (vf_ctx[pf][vf].enabled)
                    bdf_lut[new_vf_bdf] = vf_ctx[pf][vf];
            end
        end

        runtime_pf_base_bdf = new_base;
        runtime_bdf_bound   = 1;
        `uvm_info("FUNC_MGR", $sformatf(
            "runtime BDF bind: PF base 0x%04h -> 0x%04h (%0d PFs)",
            old_base, new_base, num_pfs), UVM_LOW)
        return 1;
    endfunction

    //=========================================================================
    // Enable a set of VFs for a given PF; add them to the BDF lookup table
    //=========================================================================
    function void enable_vfs(int pf_idx, int num_vfs);
        if (pf_idx < 0 || pf_idx >= num_pfs) begin
            `uvm_error("FUNC_MGR", $sformatf("enable_vfs: pf_idx %0d out of range", pf_idx))
            return;
        end
        if (num_vfs > max_vfs_per_pf) begin
            `uvm_warning("FUNC_MGR", $sformatf(
                "enable_vfs: num_vfs %0d exceeds max_vfs_per_pf %0d, clamping",
                num_vfs, max_vfs_per_pf))
            num_vfs = max_vfs_per_pf;
        end

        // Update SR-IOV capability num_vfs and vf_enable fields
        sriov_caps[pf_idx].num_vfs   = num_vfs;
        sriov_caps[pf_idx].vf_enable = 1;
        sriov_caps[pf_idx].build_data();

        for (int vf = 0; vf < num_vfs; vf++) begin
            vf_ctx[pf_idx][vf].enabled = 1;
            bdf_lut[vf_ctx[pf_idx][vf].bdf] = vf_ctx[pf_idx][vf];
        end
    endfunction

    //=========================================================================
    // Disable all VFs for a given PF; remove them from the BDF lookup table
    //=========================================================================
    function void disable_vfs(int pf_idx);
        if (pf_idx < 0 || pf_idx >= num_pfs) begin
            `uvm_error("FUNC_MGR", $sformatf("disable_vfs: pf_idx %0d out of range", pf_idx))
            return;
        end

        for (int vf = 0; vf < max_vfs_per_pf; vf++) begin
            if (vf_ctx[pf_idx][vf].enabled) begin
                bdf_lut.delete(vf_ctx[pf_idx][vf].bdf);
                vf_ctx[pf_idx][vf].enabled = 0;
            end
        end

        // Update SR-IOV capability
        sriov_caps[pf_idx].num_vfs   = 0;
        sriov_caps[pf_idx].vf_enable = 0;
        sriov_caps[pf_idx].build_data();
    endfunction

    //=========================================================================
    // Look up a function context by BDF; returns null if not found
    //=========================================================================
    function pcie_tl_func_context lookup_by_bdf(bit [15:0] bdf);
        if (bdf_lut.exists(bdf))
            return bdf_lut[bdf];
        return null;
    endfunction

    //=========================================================================
    // Config space read; returns 32'hFFFFFFFF if BDF not found
    //=========================================================================
    function bit [31:0] cfg_read(bit [15:0] target_bdf, bit [11:0] addr);
        pcie_tl_func_context ctx = lookup_by_bdf(target_bdf);
        if (ctx == null) return 32'hFFFF_FFFF;
        return ctx.cfg_mgr.read(addr);
    endfunction

    //=========================================================================
    // Config space write; no-op if BDF not found
    //=========================================================================
    function void cfg_write(
        bit [15:0] target_bdf,
        bit [11:0] addr,
        bit [31:0] data,
        bit [3:0]  be
    );
        pcie_tl_func_context ctx = lookup_by_bdf(target_bdf);
        if (ctx == null) return;
        ctx.cfg_mgr.write(addr, data, be);
    endfunction

    //=========================================================================
    // Return total count of active functions (all PFs + enabled VFs)
    //=========================================================================
    function int get_active_count();
        int count = num_pfs;
        for (int pf = 0; pf < num_pfs; pf++) begin
            for (int vf = 0; vf < max_vfs_per_pf; vf++) begin
                if (vf_ctx[pf][vf].enabled)
                    count++;
            end
        end
        return count;
    endfunction

    `ifdef PCIE_COSIM_ENABLE
    //=========================================================================
    // Export topology to C bridge via DPI-C for one initialized RC.
    // A paired 64-bit BAR contributes flags and size only at its low owner;
    // its upper configuration DWORD is not an independently registered BAR.
    //=========================================================================
    function void export_topology_to_bridge(int rc_index);
        longint unsigned pf_bar_size[6];
        longint unsigned vf_bar_size[6];

        for (int pf = 0; pf < num_pfs; pf++) begin
            for (int bar = 0; bar < 6; bar++) begin
                pf_bar_size[bar] = (pf_ctx[pf].bar_owner[bar] == bar)
                    ? pf_ctx[pf].bar_size[bar] : 64'h0;
                vf_bar_size[bar] = (sriov_caps[pf].vf_bar_owner[bar] == bar)
                    ? sriov_caps[pf].vf_bar_size[bar] : 64'h0;
            end
            bridge_vcs_set_pf_topology_rc(
                rc_index, pf, pf_ctx[pf].bdf, max_vfs_per_pf,
                sriov_caps[pf].vf_device_id, pf_ctx[pf].vendor_id,
                pf_ctx[pf].device_id, pf_msix_vectors, vf_msix_vectors,
                int'(pf_ctx[pf].bar_flags[0]), int'(pf_ctx[pf].bar_flags[1]),
                int'(pf_ctx[pf].bar_flags[2]), int'(pf_ctx[pf].bar_flags[3]),
                int'(pf_ctx[pf].bar_flags[4]), int'(pf_ctx[pf].bar_flags[5]),
                pf_bar_size[0], pf_bar_size[1], pf_bar_size[2],
                pf_bar_size[3], pf_bar_size[4], pf_bar_size[5],
                vf_bar_size[0], vf_bar_size[1], vf_bar_size[2],
                vf_bar_size[3], vf_bar_size[4], vf_bar_size[5]);
        end
        bridge_vcs_finalize_topology_rc(rc_index, num_pfs, tag_width);
    endfunction
    `endif

endclass
