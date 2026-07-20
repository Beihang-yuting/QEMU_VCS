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

    // ---- 统一 config space: func_mgr(num_pfs=1 即单func, 多func/SR-IOV 同一套)----
    pcie_tl_func_manager func_mgr;

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

    // ---- 两阶段切换控制(cosim 替换 VIP 的运行时开关)----
    //   阶段1: VIP 主导(super.run_phase 驱动真实 DUT)。
    //   UCLI 敲 start_cosim -> notify_start -> drain -> 阶段2 连 QEMU, QEMU 主导。
    static cosim_xrc_driver s_registry[$];   // 全实例表, 供 UCLI 入口广播触发
    bit   cosim_active = 0;                  // 0=VIP阶段, 1=QEMU主导(rx_loop 分流依据)
    event start_cosim_ev;                    // UCLI notify_start 触发切换

    // rx_loop 的 completion 来源: 订阅本 agent monitor 的 tlp_ap(CC/RX: DUT->RC),
    // 不与 monitor 争抢同一 adapter rx_queue(否则 monitor 抢走 cpl 不释放 tag -> 超时)。
    uvm_tlm_analysis_fifo #(pcie_tl_tlp) m_rx_fifo;

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
        s_registry.push_back(this);   // 注册实例, 供 UCLI notify_start 广播
        m_rx_fifo = new("m_rx_fifo", this);

        // 统一 config space: 建 func_mgr(num_pfs=1 即单func), 走 _bdf 应答 QEMU 枚举。
        // plusarg 可配: +NUM_PFS +MAX_VFS +NUM_VFS +VENDOR_ID +DEVICE_ID +VF_DEVICE_ID
        begin
            int n_pfs, max_vfs, n_vfs, ven, dev, vfdev, topo;
            if (!$value$plusargs("NUM_PFS=%d", n_pfs))      n_pfs   = 1;
            if (!$value$plusargs("MAX_VFS=%d", max_vfs))    max_vfs = 0;
            if (!$value$plusargs("NUM_VFS=%d", n_vfs))      n_vfs   = 0;
            if (!$value$plusargs("TOPO=%d", topo))          topo    = 0;  // 0=ep_direct 1=switch 2=multi_layer
            if (!$value$plusargs("VENDOR_ID=%h", ven))      ven     = 32'h1AF4;
            if (!$value$plusargs("DEVICE_ID=%h", dev))      dev     = 32'h1041;
            if (!$value$plusargs("VF_DEVICE_ID=%h", vfdev)) vfdev   = 32'h1041;
            func_mgr = pcie_tl_func_manager::type_id::create("func_mgr");
            func_mgr.build_topology(topo, n_pfs, max_vfs, ven[15:0], dev[15:0], vfdev[15:0]);
            config_proxy.func_mgr            = func_mgr;
            config_proxy.multi_function_mode = 1;
            config_proxy.bypass_enable       = 1;   // SV 应答 config 枚举, 不下 DUT
            // 可选预启用 VF(否则等 guest 写 sriov_numvfs 动态启用)
            if (n_vfs > 0)
                for (int pf = 0; pf < n_pfs; pf++)
                    func_mgr.enable_vfs(pf, n_vfs);
        end

        `uvm_info(get_name(), $sformatf("cosim_xrc_driver bound to RC index %0d", rc_index),
                  UVM_LOW)
    endfunction

    // -----------------------------------------------------------------------
    // connect_phase: 把本 agent monitor 的 tlp_ap(CC/RX: DUT->RC 的 TLP)接到
    //   m_rx_fifo。rx_loop 从 fifo 取, 让 monitor 当 adapter rx_queue 唯一消费者,
    //   消除 monitor/driver 争抢导致的 completion 丢失(tag 不释放 -> 超时)。
    // -----------------------------------------------------------------------
    virtual function void connect_phase(uvm_phase phase);
        pcie_tl_base_agent ag;
        super.connect_phase(phase);
        if ($cast(ag, get_parent()) && ag.monitor != null)
            ag.monitor.tlp_ap.connect(m_rx_fifo.analysis_export);
        else
            `uvm_fatal(get_name(),
                "cosim_xrc_driver: 无法连接 monitor.tlp_ap(parent 非 pcie_tl_base_agent 或 monitor 为空)")
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
    // UCLI 触发入口(供 aip_cmd 命令壳调用)。rc<0 = 全部 RC; 否则只切指定 RC。
    // 广播 start_cosim_ev, 各 driver run_phase 从阶段1(VIP)切阶段2(QEMU)。
    // 与 aip 解耦: aip 命令壳只需 new + cmd_exec 调本函数, driver 侧零 aip 依赖。
    // -----------------------------------------------------------------------
    static function void notify_start(int rc = -1);
        foreach (s_registry[i])
            if (rc < 0 || s_registry[i].rc_index == rc)
                -> s_registry[i].start_cosim_ev;
    endfunction

    // -----------------------------------------------------------------------
    // 自初始化开关。默认 1:driver 自己连 QEMU(读 +REMOTE_HOST/+PORT_BASE),
    // 无需外部 test 调 init —— 这样集成进现有环境只要一行工厂 override。
    // 若某 test 想自己管 init,先设 bridge_ready=1 即跳过。
    // -----------------------------------------------------------------------
    bit self_init_bridge_en = 1;

    // -----------------------------------------------------------------------
    // run_phase: 两阶段 ——
    //   阶段1  VIP 主导: super.run_phase 的 get_next_item/send_tlp 驱动真实 DUT。
    //   触发   UCLI 敲 start_cosim -> notify_start -> start_cosim_ev。
    //   drain  停发 VIP + 等 in-flight completion 收干净(rx_loop 走 VIP 路径)。
    //   阶段2  连 QEMU, cosim_active=1, request_loop 由 QEMU 主导发包。
    // rx_loop 全程运行, 按 cosim_active 分流 DUT 回来的 completion。
    // -----------------------------------------------------------------------
    virtual task run_phase(uvm_phase phase);
        // 全程 hold objection: 交互式 cosim 期望"不敲 start_cosim 就一直跑等你",
        // 结束由 UCLI finish 或 request_loop shutdown 决定。
        phase.raise_objection(this, "cosim_xrc_driver holding run");
        `uvm_info(get_name(), $sformatf("run_phase started (RC%0d)", rc_index), UVM_MEDIUM)

        // rx_loop 全程跑: 阶段1 收 DUT cpl 回 VIP, 阶段2 回 QEMU
        fork
            rx_loop(phase);
        join_none

        // ---- 阶段1: VIP 主导, 等 UCLI 触发 ----
        if (!bridge_ready) begin
            fork : vip_stage
                super.run_phase(phase);   // 基类 forever get_next_item/send_tlp/item_done
            join_none

            @start_cosim_ev;              // UCLI notify_start 触发
            `uvm_info(get_name(), $sformatf("RC%0d start_cosim: stop VIP, draining", rc_index),
                      UVM_LOW)
            disable vip_stage;                    // 停止 VIP 发新包
            wait (get_pending_count() == 0);      // drain: rx_loop 收干净 in-flight cpl
            `uvm_info(get_name(), $sformatf("RC%0d drained, switch to QEMU", rc_index),
                      UVM_LOW)
        end

        // ---- 阶段2: 连 QEMU + QEMU 主导 ----
        if (self_init_bridge_en && !bridge_ready)
            self_init_bridge();
        cosim_active = 1;                 // rx_loop 切到 forward_to_qemu
        request_loop(phase);              // QEMU poll → DUT, 阻塞直到 shutdown

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

            // ---- Config-space bypass: func_mgr(_bdf) answers, never reaches DUT ----
            //   target BDF 从 TLP 取(QEMU 已填, DPI getter 现成), 路由到对应 PF/VF。
            if (config_proxy != null && config_proxy.bypass_enable) begin
                bit [15:0] tgt_bdf = bridge_vcs_get_tlp_target_bdf_rc(rc_index);
                if (dpi_type == BV_TLP_CFGRD0) begin
                    bit [31:0] cfg_data;
                    int dw_addr = int'(dpi_addr) >> 2;
                    if (config_proxy.handle_cfg_read_bdf(tgt_bdf, dw_addr, cfg_data)) begin
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
                    if (config_proxy.handle_cfg_write_bdf(tgt_bdf, dw_addr, wr_data, byte_off, dpi_len)) begin
                        // BAR base 同步 C 侧(per-RC, 供 MMIO 解码): 取该 bdf 的 bar_base[0]。
                        // 多 bdf 的 per-bdf BAR 另由 config_proxy 内部 set_bar_base_bdf 同步。
                        if (dw_addr == 4 || dw_addr == 5) begin
                            pcie_tl_func_context ctx = func_mgr.lookup_by_bdf(tgt_bdf);
                            if (ctx != null)
                                bridge_vcs_set_bar_base_rc(rc_index, 0, ctx.bar_base[0]);
                        end
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

        // 从 monitor.tlp_ap 订阅(阻塞 get), 不抢 adapter rx_queue。阶段1 就要收 CplD。
        forever begin
            m_rx_fifo.get(rx_tlp);   // 阻塞: 有 TLP(CC/RX)才返回, 永不为 null

            if ($cast(cpl, rx_tlp)) begin
                if (cosim_active)
                    forward_completion_to_qemu(cpl);      // 阶段2: VIP tag→QEMU tag, 回 QEMU
                else
                    void'(super.handle_completion(cpl));  // 阶段1: VIP tag_mgr 匹配+释放, 回 sequence
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

// -----------------------------------------------------------------------
// UCLI 命令注册(aip_core): start_cosim [rc=<n>] -> notify_start。
//   start_cosim         全部 RC        start_cosim rc=0   只切 RC0
// 宏内 static __inst 自动注册, 无需 initial。
// AIP_CORE_PKG_SV 由 aip_core_pkg.sv 定义 —— 编了 aip(filelist 中 aip 在前)
// 才启用本段; 未集成时天然跳过, driver 两阶段逻辑不受影响(仅无 UCLI 命令)。
// -----------------------------------------------------------------------
`ifdef AIP_CORE_PKG_SV
`aip_cmd_1i(start_cosim, cosim_xrc_driver::notify_start, int, rc, -1)
`endif

`endif // COSIM_XRC_DRIVER_SV
