/* cosim-platform/vcs-tb/cosim_xrc_driver.sv
 *
 * Multi-RC cosim adapter driver for the Xilinx PG213 AXIS datapath.
 *
 * One instance lives inside each pcie_tl env rc_agent_<N>. It bridges a
 * per-RC QEMU host (over a cosim transport, DPI _rc(rc_index)) to a real
 * xilinx-pcie EP DUT reached through this RC's xilinx_pcie_if_adapter:
 *
 *   QEMU MMIO/Cfg  --poll_tlp_scalar_rc--> build TLP --send_tlp--> adapter
 *                    --> CQ channel --> DUT
 *   DUT CplD       --> CC channel --> adapter.rx_queue --adapter.receive-->
 *                    handle + send_cpl_scalar_rc --> QEMU
 *
 * Scope: MMIO (BAR read/write) + config-space bypass. DUT-initiated DMA
 * (RQ inbound) + MSI are logged as TODO here — that's the next increment.
 *
 * Isolation: this is the multi-RC cosim adapter driver. rc_index defaults
 * to 0; the C _rc(0) path is byte-equivalent to the legacy single-RC DPI.
 */

`ifndef COSIM_XRC_DRIVER_SV
`define COSIM_XRC_DRIVER_SV

class cosim_xrc_driver extends pcie_tl_rc_driver;
    `uvm_component_utils(cosim_xrc_driver)

    // DPI-C TLP type constants (kept in sync with bridge_vcs.sv)
    localparam byte unsigned BV_TLP_MWR    = 8'd0;
    localparam byte unsigned BV_TLP_MRD    = 8'd1;
    localparam byte unsigned BV_TLP_CFGWR0 = 8'd2;
    localparam byte unsigned BV_TLP_CFGRD0 = 8'd3;
    localparam byte unsigned BV_TLP_CPL    = 8'd4;

    // ---- Which RC this driver serves (its slot in the C-side g_rc[]) ----
    int rc_index = 0;

    // ---- Config-space bypass proxy (answers enumeration in SV) ----
    pcie_tl_config_proxy config_proxy;

    // ---- Tag mapping: QEMU 8-bit tag <-> VIP tag ----
    bit [9:0] vip_tag_to_qemu_tag[int];        // 10-bit QEMU tag (extended tag)
    int       qemu_tag_to_vip_tag[bit [9:0]];

    // ---- DPI scratch (class members = static storage; VCS Q-2020 safe) ----
    byte unsigned    dpi_type;
    longint unsigned dpi_addr;
    int unsigned     dpi_data[16];
    int              dpi_len;
    int              dpi_tag;

    // ---- Coordination ----
    bit   bridge_ready = 0;
    event shutdown_event;
    int   polling_interval_ns = 10;

    // ---- Stats ----
    int unsigned total_tlp_count;
    int unsigned total_cpl_count;
    int unsigned unknown_type_count;
    int unsigned inbound_req_count;   // DUT-initiated (DMA) — TODO next increment

    function new(string name = "cosim_xrc_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // -----------------------------------------------------------------------
    // build_phase: resolve rc_index, create the config proxy.
    //   rc_index source (in priority order):
    //     1. uvm_config_db#(int) "rc_index" set by the test on this agent path
    //     2. parsed from the hierarchical name (".rc_agent_<N>.")
    //     3. default 0
    // -----------------------------------------------------------------------
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(int)::get(this, "", "rc_index", rc_index))
            rc_index = parse_rc_index_from_name(get_full_name());

        config_proxy = pcie_tl_config_proxy::type_id::create("config_proxy", this);

        `uvm_info(get_name(), $sformatf("cosim_xrc_driver bound to RC index %0d", rc_index),
                  UVM_LOW)
    endfunction

    // Parse "...rc_agent_<N>..." -> N ; returns 0 if not found.
    protected function int parse_rc_index_from_name(string full);
        int idx = 0;
        byte c;
        int  pos;
        string key = "rc_agent_";
        for (int i = 0; i + key.len() < full.len(); i++) begin
            if (full.substr(i, i + key.len() - 1) == key) begin
                pos = i + key.len();
                idx = 0;
                while (pos < full.len()) begin
                    c = full[pos];
                    if (c >= "0" && c <= "9") begin
                        idx = idx * 10 + (c - "0");
                        pos++;
                    end else break;
                end
                return idx;
            end
        end
        return 0;
    endfunction

    // -----------------------------------------------------------------------
    // 自初始化开关。默认 1:driver 自己连 QEMU(读 +REMOTE_HOST/+PORT_BASE),
    // 无需外部 test 调 init —— 这样集成进现有环境只要一行工厂 override。
    // 若某 test 想自己管 init,先设 bridge_ready=1 即跳过。
    // -----------------------------------------------------------------------
    bit self_init_bridge_en = 1;

    // -----------------------------------------------------------------------
    // run_phase: 自 init bridge(可选) + 两个 loop。NO super.run_phase。
    // -----------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this, "cosim_xrc_driver running");
        `uvm_info(get_name(), $sformatf("run_phase started (RC%0d, DPI polling)", rc_index),
                  UVM_MEDIUM)

        if (self_init_bridge_en && !bridge_ready)
            self_init_bridge();

        fork
            request_loop(phase);
            rx_loop(phase);
        join

        bridge_vcs_cleanup_ex_rc(rc_index);
        phase.drop_objection(this, "cosim_xrc_driver done");
    endtask

    // 连本 RC 对应的 QEMU(client)。host/port 从 plusarg,instance_id=rc_index。
    protected task self_init_bridge();
        string remote_host;
        int    port_base;
        if (!$value$plusargs("REMOTE_HOST=%s", remote_host)) remote_host = "10.11.10.53";
        if (!$value$plusargs("PORT_BASE=%d", port_base))     port_base   = 9100;
        if (bridge_vcs_init_ex_rc(rc_index, "tcp", "", "", remote_host, port_base, rc_index) != 0)
            `uvm_fatal(get_name(), $sformatf(
                "RC%0d bridge_vcs_init_ex_rc(tcp %s:%0d inst=%0d) failed",
                rc_index, remote_host, port_base, rc_index))
        `uvm_info(get_name(), $sformatf(
            "RC%0d bridge up: tcp %s:%0d inst=%0d", rc_index, remote_host, port_base, rc_index),
            UVM_LOW)
        bridge_ready = 1;
    endtask

    // -----------------------------------------------------------------------
    // request_loop: poll this RC's QEMU, forward MMIO to the DUT (via adapter
    // -> CQ), answer config-space reads/writes locally via the proxy.
    // -----------------------------------------------------------------------
    protected task request_loop(uvm_phase phase);
        int         ret;
        pcie_tl_tlp vip_tlp;

        wait (bridge_ready);
        `uvm_info(get_name(), $sformatf("RC%0d bridge ready, polling", rc_index), UVM_MEDIUM)

        forever begin
            ret = bridge_vcs_poll_tlp_scalar_rc(rc_index);
            if (ret < 0) begin
                `uvm_info(get_name(), $sformatf("RC%0d poll<0: shutdown", rc_index), UVM_MEDIUM)
                ->shutdown_event;
                break;
            end
            if (ret > 0) begin
                #(polling_interval_ns * 1ns);
                continue;
            end

            // ret == 0: a TLP is available — fetch fields via _rc getters
            dpi_type = bridge_vcs_get_poll_type_rc(rc_index);
            dpi_addr = bridge_vcs_get_poll_addr_rc(rc_index);
            dpi_len  = bridge_vcs_get_poll_len_rc(rc_index);
            dpi_tag  = bridge_vcs_get_poll_tag_rc(rc_index);
            for (int i = 0; i < 16; i++)
                dpi_data[i] = bridge_vcs_get_poll_data_rc(rc_index, i);

            // ---- Config-space bypass: proxy answers, never reaches the DUT ----
            if (config_proxy != null && config_proxy.bypass_enable) begin
                if (dpi_type == BV_TLP_CFGRD0) begin
                    bit [31:0] cfg_data;
                    int dw_addr = int'(dpi_addr) >> 2;
                    if (config_proxy.handle_cfg_read(dw_addr, cfg_data)) begin
                        for (int i = 0; i < 16; i++) bridge_vcs_set_cpl_data_rc(rc_index, i, 0);
                        bridge_vcs_set_cpl_data_rc(rc_index, 0, cfg_data);
                        void'(bridge_vcs_send_cpl_scalar_rc(rc_index, dpi_tag, 1));
                        total_tlp_count++;
                        #1;
                        continue;
                    end
                end
                if (dpi_type == BV_TLP_CFGWR0) begin
                    int dw_addr = int'(dpi_addr) >> 2;
                    int byte_off = int'(dpi_addr) & 3;
                    bit [31:0] wr_data = dpi_data[0];
                    if (config_proxy.handle_cfg_write(dw_addr, wr_data, byte_off, dpi_len)) begin
                        // Keep the C-side per-RC BAR base in sync for address decode
                        if (dw_addr == 4 && wr_data != 32'hFFFF_FFFF)
                            bridge_vcs_set_bar_base_rc(rc_index, 0, {32'h0, config_proxy.bar0_addr[31:0]});
                        if (dw_addr == 5)
                            bridge_vcs_set_bar_base_rc(rc_index, 0, config_proxy.bar0_addr);
                        // CfgWr is fire-and-forget (QEMU does not wait on completion)
                        total_tlp_count++;
                        #1;
                        continue;
                    end
                end
            end

            // ---- MMIO to DUT: build a VIP TLP, send through the pipeline ----
            vip_tlp = build_mmio_tlp(dpi_type, dpi_addr, dpi_data, dpi_len, dpi_tag);
            if (vip_tlp == null) begin
                unknown_type_count++;
                `uvm_warning(get_name(),
                    $sformatf("RC%0d unknown/unsupported TLP type 0x%02h, dropping",
                              rc_index, dpi_type))
                continue;
            end

            begin
                bit [9:0] qemu_tag_10 = dpi_tag[9:0];   // 10-bit QEMU tag
                send_tlp(vip_tlp);   // adapter.send -> CQ channel -> DUT
                if (vip_tlp.requires_completion()) begin
                    vip_tag_to_qemu_tag[int'(vip_tlp.tag)] = qemu_tag_10;
                    qemu_tag_to_vip_tag[qemu_tag_10]       = int'(vip_tlp.tag);
                end
            end
            total_tlp_count++;
        end
    endtask

    // -----------------------------------------------------------------------
    // rx_loop: drain decoded TLPs arriving from the DUT via this RC's adapter.
    //   - CplD/Cpl (completions on CC channel) -> forward to QEMU.
    //   - MRd/MWr  (DUT-initiated DMA on RQ channel) -> TODO next increment.
    // -----------------------------------------------------------------------
    protected task rx_loop(uvm_phase phase);
        pcie_tl_tlp     rx_tlp;
        pcie_tl_cpl_tlp cpl;

        wait (bridge_ready);
        forever begin
            adapter.receive(rx_tlp);   // xilinx adapter: non-blocking, null if empty
            if (rx_tlp == null) begin
                #(polling_interval_ns * 1ns);
                continue;
            end

            if ($cast(cpl, rx_tlp)) begin
                forward_completion_to_qemu(cpl);
            end else begin
                // DUT-initiated request (DMA MRd/MWr). MMIO-first scope: log only.
                inbound_req_count++;
                `uvm_info(get_name(),
                    $sformatf("RC%0d inbound DUT request %s (DMA path TODO, dropping)",
                              rc_index, rx_tlp.kind.name()), UVM_MEDIUM)
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // forward_completion_to_qemu: VIP tag -> QEMU tag, push CplD payload back
    // over this RC's bridge. Also lets the base class free the VIP tag.
    // -----------------------------------------------------------------------
    protected function void forward_completion_to_qemu(pcie_tl_cpl_tlp cpl);
        int        vip_tag_int = int'(cpl.tag);
        int        qemu_tag;
        bit [31:0] rdata = 0;

        void'(super.handle_completion(cpl));   // base: tag match + release

        if (!vip_tag_to_qemu_tag.exists(vip_tag_int)) begin
            `uvm_warning(get_name(),
                $sformatf("RC%0d completion with no QEMU tag map: vip_tag=0x%03h",
                          rc_index, cpl.tag))
            return;
        end
        qemu_tag = int'(vip_tag_to_qemu_tag[vip_tag_int]);
        vip_tag_to_qemu_tag.delete(vip_tag_int);
        qemu_tag_to_vip_tag.delete(qemu_tag[9:0]);

        // First dword of payload, PCIe big-endian -> little-endian word for QEMU
        if (cpl.payload.size() >= 4)
            rdata = {cpl.payload[0], cpl.payload[1], cpl.payload[2], cpl.payload[3]};
        else
            for (int i = 0; i < cpl.payload.size(); i++)
                rdata[((3-i)*8) +: 8] = cpl.payload[i];

        for (int i = 0; i < 16; i++) bridge_vcs_set_cpl_data_rc(rc_index, i, 0);
        bridge_vcs_set_cpl_data_rc(rc_index, 0, rdata);
        if (bridge_vcs_send_cpl_scalar_rc(rc_index, qemu_tag, 1) != 0)
            `uvm_error(get_name(),
                $sformatf("RC%0d send_cpl failed qemu_tag=0x%03h", rc_index, qemu_tag))
        total_cpl_count++;

        `uvm_info(get_name(),
            $sformatf("RC%0d Cpl->QEMU vip_tag=0x%03h qemu_tag=0x%03h data=0x%08h",
                      rc_index, cpl.tag, qemu_tag, rdata), UVM_HIGH)
    endfunction

    // -----------------------------------------------------------------------
    // build_mmio_tlp: MMIO subset (MWr / MRd). Config types are bypassed
    // before this point; Cpl-out is not produced by the RC host.
    // -----------------------------------------------------------------------
    protected function pcie_tl_tlp build_mmio_tlp(
        input byte unsigned    t,
        input longint unsigned addr,
        input int unsigned     d[16],
        input int              len,
        input int              tag);

        pcie_tl_mem_tlp m;
        int payload_bytes;

        case (t)
            BV_TLP_MWR: begin
                m = pcie_tl_mem_tlp::type_id::create("mwr");
                m.kind     = TLP_MEM_WR;
                m.addr     = addr;
                m.is_64bit = (addr[63:32] != 0);
                m.fmt      = m.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
                m.type_f   = TLP_TYPE_MEM_RD;   // MEM_WR shares encoding
                m.first_be = 4'hF;
                m.last_be  = (len > 4) ? 4'hF : 4'h0;
                payload_bytes = (len > 0) ? len : 4;
                m.length   = (payload_bytes + 3) / 4;
                unpack_words_to_bytes(d, payload_bytes, m.payload);
                return m;
            end
            BV_TLP_MRD: begin
                m = pcie_tl_mem_tlp::type_id::create("mrd");
                m.kind     = TLP_MEM_RD;
                m.addr     = addr;
                m.is_64bit = (addr[63:32] != 0);
                m.fmt      = m.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
                m.type_f   = TLP_TYPE_MEM_RD;
                m.first_be = 4'hF;
                m.last_be  = (len > 4) ? 4'hF : 4'h0;
                m.length   = (len > 0) ? (len + 3) / 4 : 1;
                m.tag      = 10'(tag[9:0]);
                return m;
            end
            default: return null;
        endcase
    endfunction

    // int[16] words (LE within each word) -> VIP byte payload
    protected function void unpack_words_to_bytes(
        input  int unsigned d[16],
        input  int          byte_count,
        output bit [7:0]    payload[]);
        int words;
        if (byte_count <= 0) begin payload = new[0]; return; end
        payload = new[byte_count];
        words = (byte_count + 3) / 4;
        for (int i = 0; i < words && i < 16; i++)
            for (int b = 0; b < 4; b++)
                if (i*4 + b < byte_count)
                    payload[i*4 + b] = d[i][(b*8) +: 8];
    endfunction

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info(get_name(), $sformatf(
            "=== cosim_xrc_driver RC%0d: tlp=%0d cpl=%0d unknown=%0d inbound(DMA-todo)=%0d ===",
            rc_index, total_tlp_count, total_cpl_count, unknown_type_count, inbound_req_count),
            UVM_NONE)
    endfunction

endclass

`endif // COSIM_XRC_DRIVER_SV
