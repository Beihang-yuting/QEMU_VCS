//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Function Manager
//-----------------------------------------------------------------------------

//=============================================================================
// Per-function context: holds BDF, config space, and BAR state
//=============================================================================
class pcie_tl_func_context extends uvm_object;
    `uvm_object_utils(pcie_tl_func_context)

    //--- Identity ---
    int        pf_index;
    int        vf_index;      // -1 means this entry is a PF
    bit [15:0] bdf;
    bit        is_vf;
    bit        enabled;

    //--- Independent configuration space ---
    pcie_tl_cfg_space_manager cfg_mgr;

    //--- BAR state ---
    bit [63:0] bar_base[6];
    bit [63:0] bar_size[6];
    bit        bar_enable[6];

    //--- Bus Master Enable (mirrors Command register bit 2) ---
    bit        bus_master_en;

    function new(string name = "pcie_tl_func_context");
        super.new(name);
        vf_index      = -1;
        is_vf         = 0;
        enabled       = 1;
        bus_master_en = 0;
        foreach (bar_base[i])   bar_base[i]   = 64'h0;
        foreach (bar_size[i])   bar_size[i]   = 64'h0;
        foreach (bar_enable[i]) bar_enable[i] = 0;
    endfunction

    //=========================================================================
    // Initialize config space with Type 0 header and PCIe capability
    //=========================================================================
    function void init_cfg_space(
        bit [15:0] vendor_id,
        bit [15:0] device_id,
        bit [7:0]  header_type = 8'h00
    );
        cfg_mgr = pcie_tl_cfg_space_manager::type_id::create(
            $sformatf("cfg_mgr_bdf%04h", bdf));
        cfg_mgr.init_type0_header(vendor_id, device_id, .header_type(header_type));
        cfg_mgr.init_pcie_capability();
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
    bit [7:0]  pf_base_bus    = 8'h01;
    bit [4:0]  pf_base_dev    = 5'h00;

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

        pf_ctx     = new[num_pfs];
        vf_ctx     = new[num_pfs];
        sriov_caps = new[num_pfs];

        for (int pf = 0; pf < num_pfs; pf++) begin
            bit [15:0] pf_bdf;

            // Construct PF BDF: bus=pf_base_bus, dev=pf_base_dev, func=pf[2:0]
            pf_bdf = {pf_base_bus, pf_base_dev, pf[2:0]};

            // Create and initialise PF context
            pf_ctx[pf] = pcie_tl_func_context::type_id::create(
                $sformatf("pf_ctx_%0d", pf));
            pf_ctx[pf].pf_index = pf;
            pf_ctx[pf].vf_index = -1;
            pf_ctx[pf].bdf      = pf_bdf;
            pf_ctx[pf].is_vf    = 0;
            pf_ctx[pf].enabled  = 1;
            pf_ctx[pf].init_cfg_space(vendor_id, device_id);

            // Register PF in BDF lookup table
            bdf_lut[pf_bdf] = pf_ctx[pf];

            // Create SR-IOV extended capability for this PF
            sriov_caps[pf] = pcie_tl_sriov_cap::type_id::create(
                $sformatf("sriov_cap_%0d", pf));
            sriov_caps[pf].pf_bdf       = pf_bdf;
            sriov_caps[pf].total_vfs    = max_vfs_per_pf;
            sriov_caps[pf].vf_device_id = vf_dev_id;
            sriov_caps[pf].offset       = 12'h200;
            sriov_caps[pf].build_data();
            pf_ctx[pf].cfg_mgr.register_ext_capability(sriov_caps[pf]);

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
                // VFs start disabled — not yet added to bdf_lut
            end
        end
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

endclass
