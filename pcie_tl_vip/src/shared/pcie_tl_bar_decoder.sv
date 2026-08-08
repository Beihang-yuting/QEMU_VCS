//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - configuration-driven PF/VF BAR decoder
//-----------------------------------------------------------------------------

class pcie_tl_bar_decode_entry extends uvm_object;
    `uvm_object_utils(pcie_tl_bar_decode_entry)

    bit        is_vf;
    bit        enabled;
    bit [63:0] base;
    bit [63:0] span;
    bit [63:0] function_size;
    bit [15:0] pf_bdf;
    bit [15:0] first_vf_bdf;
    int unsigned vf_bdf_stride;
    int unsigned num_vfs;
    int        pf_index;
    bit [2:0]  bar_id;
    bit [5:0]  bar_aperture;

    function new(string name = "pcie_tl_bar_decode_entry");
        super.new(name);
    endfunction
endclass

class pcie_tl_bar_decoder extends uvm_object;
    `uvm_object_utils(pcie_tl_bar_decoder)

    pcie_tl_func_manager func_mgr;
    pcie_tl_func_manager cached_func_mgr;
    longint unsigned cached_generation = '1;
    pcie_tl_bar_decode_entry entries[$];
    pcie_bar_decode_result_e cache_result = PCIE_BAR_DECODE_OK;
    string cache_reason;

    function new(string name = "pcie_tl_bar_decoder");
        super.new(name);
    endfunction

    protected function automatic bit size_is_valid(bit [63:0] size);
        return size >= 64'd4096 &&
               (size & (size - 64'd1)) == 64'd0;
    endfunction

    protected function automatic bit be_is_contiguous(bit [3:0] be);
        return be inside {4'h1, 4'h2, 4'h3, 4'h4, 4'h6, 4'h7,
                          4'h8, 4'hc, 4'he, 4'hf};
    endfunction

    protected function automatic int first_lane(bit [3:0] be);
        for (int lane = 0; lane < 4; lane++)
            if (be[lane])
                return lane;
        return -1;
    endfunction

    protected function automatic int last_lane(bit [3:0] be);
        for (int lane = 3; lane >= 0; lane--)
            if (be[lane])
                return lane;
        return -1;
    endfunction

    protected function automatic int unsigned log2_size(bit [63:0] size);
        int unsigned value;
        value = 0;
        while (size > 64'd1) begin
            size >>= 1;
            value++;
        end
        return value;
    endfunction

    protected function pcie_bar_decode_result_e rebuild_cache(
        output string reason
    );
        pcie_tl_bar_decode_entry next_entries[$];
        pcie_tl_bar_decode_entry entry;
        pcie_tl_func_context ctx;
        pcie_tl_sriov_cap sc;
        bit [63:0] span;
        longint unsigned first_vf_rid;
        longint unsigned last_vf_rid;
        longint unsigned vf_count;
        longint unsigned vf_index_span;
        longint unsigned vf_stride;
        bit vf_rid_validated;
        int unsigned aperture_log2;

        // A failed generation must never retain the old snapshot or expose a
        // partially constructed new one. Only publish next_entries on success.
        entries.delete();
        reason = "";
        if (func_mgr == null) begin
            reason = "BAR decoder has no function manager";
            return PCIE_BAR_DECODE_INVALID_CONFIG;
        end
        if (func_mgr.num_pfs < 0 ||
            func_mgr.pf_ctx.size() < func_mgr.num_pfs ||
            func_mgr.sriov_caps.size() < func_mgr.num_pfs) begin
            reason = "function manager topology arrays are incomplete";
            return PCIE_BAR_DECODE_INVALID_CONFIG;
        end

        for (int pf = 0; pf < func_mgr.num_pfs; pf++) begin
            ctx = func_mgr.pf_ctx[pf];
            if (ctx == null) begin
                reason = $sformatf("PF%0d context is null", pf);
                return PCIE_BAR_DECODE_INVALID_CONFIG;
            end
            for (int bar = 0; bar < 6; bar++) begin
                // PF routing publishes only the 64-bit owner positions. Paired
                // high DWORDs and odd self-owned legacy metadata are ignored.
                if (!(bar inside {0, 2, 4}) ||
                    ctx.bar_owner[bar] != bar || ctx.bar_size[bar] == 0)
                    continue;
                aperture_log2 = log2_size(ctx.bar_size[bar]);
                if (!size_is_valid(ctx.bar_size[bar]) ||
                    ctx.bar_base[bar] > (~64'b0 - ctx.bar_size[bar]) ||
                    aperture_log2 < 12 || aperture_log2 - 12 > 63) begin
                    reason = $sformatf(
                        "invalid PF%0d BAR%0d base=%016h size=%016h",
                        pf, bar, ctx.bar_base[bar], ctx.bar_size[bar]);
                    return PCIE_BAR_DECODE_INVALID_CONFIG;
                end
                entry = pcie_tl_bar_decode_entry::type_id::create(
                    $sformatf("pf%0d_bar%0d", pf, bar));
                entry.is_vf = 0;
                entry.enabled = ctx.enabled && ctx.bar_enable[bar];
                entry.base = ctx.bar_base[bar];
                entry.span = ctx.bar_size[bar];
                entry.function_size = ctx.bar_size[bar];
                entry.pf_bdf = ctx.bdf;
                entry.first_vf_bdf = 0;
                entry.vf_bdf_stride = 0;
                entry.num_vfs = 0;
                entry.pf_index = pf;
                entry.bar_id = bar[2:0];
                entry.bar_aperture = 6'(aperture_log2 - 12);
                next_entries.push_back(entry);
            end

            sc = func_mgr.sriov_caps[pf];
            if (sc == null) begin
                reason = $sformatf("PF%0d SR-IOV capability is null", pf);
                return PCIE_BAR_DECODE_INVALID_CONFIG;
            end
            vf_rid_validated = 0;
            for (int bar = 0; bar < 6; bar++) begin
                if (sc.vf_bar_owner[bar] != bar ||
                    sc.vf_bar_size[bar] == 0 || sc.num_vfs == 0)
                    continue;
                if (!vf_rid_validated) begin
                    vf_count = sc.num_vfs;
                    vf_stride = sc.vf_stride;
                    if (vf_count == 0 || vf_stride == 0) begin
                        reason = $sformatf(
                            "invalid PF%0d VF RID count=%0d stride=%0d",
                            pf, vf_count, vf_stride);
                        return PCIE_BAR_DECODE_INVALID_CONFIG;
                    end
                    first_vf_rid = ctx.bdf;
                    if (first_vf_rid >
                        (~64'b0 - sc.first_vf_offset)) begin
                        reason = $sformatf(
                            "PF%0d VF RID overflow computing first RID", pf);
                        return PCIE_BAR_DECODE_INVALID_CONFIG;
                    end
                    first_vf_rid += sc.first_vf_offset;
                    if ((vf_count - 1) > (~64'b0 / vf_stride)) begin
                        reason = $sformatf(
                            "PF%0d VF RID overflow count=%0d stride=%0d",
                            pf, vf_count, vf_stride);
                        return PCIE_BAR_DECODE_INVALID_CONFIG;
                    end
                    vf_index_span = (vf_count - 1) * vf_stride;
                    if (first_vf_rid > (~64'b0 - vf_index_span)) begin
                        reason = $sformatf(
                            "PF%0d VF RID overflow first=%0h span=%0h",
                            pf, first_vf_rid, vf_index_span);
                        return PCIE_BAR_DECODE_INVALID_CONFIG;
                    end
                    last_vf_rid = first_vf_rid + vf_index_span;
                    if (first_vf_rid > 64'hffff ||
                        last_vf_rid > 64'hffff) begin
                        reason = $sformatf(
                            "PF%0d VF RID overflow first=%0h last=%0h",
                            pf, first_vf_rid, last_vf_rid);
                        return PCIE_BAR_DECODE_INVALID_CONFIG;
                    end
                    vf_rid_validated = 1;
                end
                aperture_log2 = log2_size(sc.vf_bar_size[bar]);
                if (!size_is_valid(sc.vf_bar_size[bar]) ||
                    aperture_log2 < 12 || aperture_log2 - 12 > 63 ||
                    sc.vf_bar_size[bar] > (~64'b0 / sc.num_vfs)) begin
                    reason = $sformatf(
                        "invalid PF%0d VF BAR%0d size=%016h NumVFs=%0d",
                        pf, bar, sc.vf_bar_size[bar], sc.num_vfs);
                    return PCIE_BAR_DECODE_INVALID_CONFIG;
                end
                span = sc.vf_bar_size[bar] * sc.num_vfs;
                if (sc.vf_bar[bar] > (~64'b0 - span)) begin
                    reason = $sformatf(
                        "overflow PF%0d VF BAR%0d base=%016h span=%016h",
                        pf, bar, sc.vf_bar[bar], span);
                    return PCIE_BAR_DECODE_INVALID_CONFIG;
                end
                entry = pcie_tl_bar_decode_entry::type_id::create(
                    $sformatf("pf%0d_vf_bar%0d", pf, bar));
                entry.is_vf = 1;
                entry.enabled = sc.vf_enable && sc.vf_mse;
                entry.base = sc.vf_bar[bar];
                entry.span = span;
                entry.function_size = sc.vf_bar_size[bar];
                entry.pf_bdf = ctx.bdf;
                entry.first_vf_bdf = first_vf_rid[15:0];
                entry.vf_bdf_stride = int'(vf_stride);
                entry.num_vfs = int'(vf_count);
                entry.pf_index = pf;
                entry.bar_id = bar[2:0];
                entry.bar_aperture = 6'(aperture_log2 - 12);
                next_entries.push_back(entry);
            end
        end

        entries = next_entries;
        return PCIE_BAR_DECODE_OK;
    endfunction

    function pcie_bar_decode_result_e decode(
        pcie_tl_mem_tlp req,
        bit [15:0] qemu_target_bdf,
        output pcie_tl_cq_route_t route,
        output string reason
    );
        pcie_tl_bar_decode_entry enabled_hits[$];
        pcie_tl_bar_decode_entry disabled_hits[$];
        pcie_tl_bar_decode_entry selected;
        pcie_tl_func_context vf_context;
        pcie_tl_func_context expected_vf_context;
        longint unsigned dwords;
        longint unsigned decoded_rid;
        longint unsigned decoded_rid_offset;
        bit [63:0] first_byte;
        bit [63:0] last_byte;
        bit [63:0] tail_bytes;
        bit [63:0] first_index;
        bit [63:0] last_index;
        bit [63:0] function_base;
        bit [15:0] decoded_bdf;
        bit [3:0] enabled_be;
        bit [63:0] enabled_byte_addr;
        int first_be_lane;
        int last_be_lane;
        int decoded_vf_index;
        int enabled_entry_count;

        route = pcie_tl_cq_route_default();
        reason = "";
        decoded_vf_index = -1;
        if (func_mgr == null || req == null) begin
            reason = "null function manager or memory request";
            return PCIE_BAR_DECODE_INVALID_CONFIG;
        end

        if (cached_func_mgr != func_mgr ||
            cached_generation != func_mgr.config_generation) begin
            cache_result = rebuild_cache(cache_reason);
            cached_func_mgr = func_mgr;
            cached_generation = func_mgr.config_generation;
        end
        if (cache_result != PCIE_BAR_DECODE_OK) begin
            reason = cache_reason;
            return cache_result;
        end

        if (req.addr[1:0] != 0 || !be_is_contiguous(req.first_be)) begin
            reason = $sformatf("malformed addr=%016h first_be=%h",
                               req.addr, req.first_be);
            return PCIE_BAR_DECODE_MALFORMED;
        end
        dwords = (req.length == 0) ? 64'd1024 : req.length;
        first_be_lane = first_lane(req.first_be);
        if (dwords == 1) begin
            if (req.last_be != 0) begin
                reason = "one-DW request has nonzero last_be";
                return PCIE_BAR_DECODE_MALFORMED;
            end
            last_be_lane = last_lane(req.first_be);
        end else begin
            if (!be_is_contiguous(req.last_be)) begin
                reason = $sformatf("multi-DW request has last_be=%h",
                                   req.last_be);
                return PCIE_BAR_DECODE_MALFORMED;
            end
            last_be_lane = last_lane(req.last_be);
        end

        tail_bytes = (dwords - 1) * 64'd4 + last_be_lane;
        if (req.addr > (~64'b0 - tail_bytes)) begin
            reason = "request byte range overflows 64-bit address";
            return PCIE_BAR_DECODE_MALFORMED;
        end
        first_byte = req.addr + first_be_lane;
        last_byte = req.addr + tail_bytes;

        // Overlap is a property of each byte actually enabled by the request,
        // not only its first byte or its enclosing continuous address span.
        // This also avoids treating a request that touches two disjoint BARs as
        // overlap; the normal boundary checks below classify that request.
        for (longint unsigned dw = 0; dw < dwords; dw++) begin
            if (dwords == 1)
                enabled_be = req.first_be;
            else if (dw == 0)
                enabled_be = req.first_be;
            else if (dw == dwords - 1)
                enabled_be = req.last_be;
            else
                enabled_be = 4'hf;
            for (int lane = 0; lane < 4; lane++) begin
                if (!enabled_be[lane])
                    continue;
                enabled_byte_addr = req.addr + dw * 64'd4 + lane;
                enabled_entry_count = 0;
                foreach (entries[i]) begin
                    if (entries[i].enabled &&
                        enabled_byte_addr >= entries[i].base &&
                        enabled_byte_addr < entries[i].base + entries[i].span)
                        enabled_entry_count++;
                end
                if (enabled_entry_count > 1) begin
                    reason = $sformatf(
                        "%0d enabled BARs overlap at enabled byte %016h",
                        enabled_entry_count, enabled_byte_addr);
                    return PCIE_BAR_DECODE_OVERLAP;
                end
            end
        end

        // Address selection is authoritative. The QEMU BDF hint is deliberately
        // not consulted until a unique function has been derived below.
        foreach (entries[i]) begin
            if (first_byte >= entries[i].base &&
                first_byte < entries[i].base + entries[i].span) begin
                if (entries[i].enabled)
                    enabled_hits.push_back(entries[i]);
                else
                    disabled_hits.push_back(entries[i]);
            end
        end
        if (enabled_hits.size() > 1) begin
            reason = $sformatf("%0d enabled BARs overlap at %016h",
                               enabled_hits.size(), first_byte);
            return PCIE_BAR_DECODE_OVERLAP;
        end
        if (enabled_hits.size() == 0) begin
            if (disabled_hits.size() != 0) begin
                reason = $sformatf("BAR at %016h is disabled", first_byte);
                return PCIE_BAR_DECODE_DISABLED;
            end
            reason = $sformatf("no BAR contains %016h", first_byte);
            return PCIE_BAR_DECODE_NO_MATCH;
        end

        selected = enabled_hits[0];
        if (!selected.is_vf) begin
            if (last_byte >= selected.base + selected.function_size) begin
                reason = "request crosses PF BAR boundary";
                return PCIE_BAR_DECODE_CROSS_BOUNDARY;
            end
            decoded_bdf = selected.pf_bdf;
            function_base = selected.base;
        end else begin
            if (last_byte >= selected.base + selected.span) begin
                reason = "request crosses VF aperture boundary";
                return PCIE_BAR_DECODE_CROSS_BOUNDARY;
            end
            first_index = (first_byte - selected.base) /
                          selected.function_size;
            last_index = (last_byte - selected.base) /
                         selected.function_size;
            if (first_index != last_index || first_index >= selected.num_vfs) begin
                reason = "request crosses VF function BAR boundary";
                return PCIE_BAR_DECODE_CROSS_BOUNDARY;
            end
            if (selected.vf_bdf_stride == 0 ||
                first_index > (~64'b0 / selected.vf_bdf_stride)) begin
                reason = "decoded VF RID overflow";
                return PCIE_BAR_DECODE_INVALID_CONFIG;
            end
            decoded_rid_offset = first_index * selected.vf_bdf_stride;
            decoded_rid = selected.first_vf_bdf;
            if (decoded_rid > (~64'b0 - decoded_rid_offset)) begin
                reason = "decoded VF RID overflow";
                return PCIE_BAR_DECODE_INVALID_CONFIG;
            end
            decoded_rid += decoded_rid_offset;
            if (decoded_rid > 64'hffff) begin
                reason = $sformatf("decoded VF RID overflow RID=%0h",
                                   decoded_rid);
                return PCIE_BAR_DECODE_INVALID_CONFIG;
            end
            decoded_bdf = decoded_rid[15:0];
            vf_context = func_mgr.lookup_by_bdf(decoded_bdf);
            decoded_vf_index = int'(first_index);
            if (selected.pf_index < 0 ||
                selected.pf_index >= func_mgr.vf_ctx.size() ||
                decoded_vf_index < 0 ||
                decoded_vf_index >=
                    func_mgr.vf_ctx[selected.pf_index].size()) begin
                reason = $sformatf(
                    "decoded VF context PF%0d VF%0d is out of bounds",
                    selected.pf_index, decoded_vf_index);
                return PCIE_BAR_DECODE_DISABLED;
            end
            expected_vf_context =
                func_mgr.vf_ctx[selected.pf_index][decoded_vf_index];
            if (vf_context == null || expected_vf_context == null ||
                vf_context != expected_vf_context || !vf_context.enabled ||
                !vf_context.is_vf ||
                vf_context.pf_index != selected.pf_index ||
                vf_context.vf_index != decoded_vf_index) begin
                reason = $sformatf("decoded VF BDF %04h is not enabled",
                                   decoded_bdf);
                return PCIE_BAR_DECODE_DISABLED;
            end
            function_base = selected.base +
                            first_index * selected.function_size;
        end

        if (decoded_bdf != qemu_target_bdf) begin
            reason = $sformatf("address decoded BDF=%04h QEMU BDF=%04h",
                               decoded_bdf, qemu_target_bdf);
            return PCIE_BAR_DECODE_BDF_MISMATCH;
        end

        route.valid = 1;
        route.target_bdf = decoded_bdf;
        route.target_func = decoded_bdf[7:0];
        route.bar_id = selected.bar_id;
        route.bar_aperture = selected.bar_aperture;
        route.bar_offset = req.addr - function_base;
        route.is_vf = selected.is_vf;
        route.pf_index = selected.pf_index;
        route.vf_index = decoded_vf_index;
        reason = "BAR decode success";
        return PCIE_BAR_DECODE_OK;
    endfunction
endclass
