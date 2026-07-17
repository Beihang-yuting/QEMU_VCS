/* cosim-platform/bridge/vcs/bridge_vcs.sv
 * SystemVerilog DPI-C import 声明
 * 供 testbench 调用
 */
package cosim_bridge_pkg;

    import "DPI-C" function int bridge_vcs_init(
        input string shm_name,
        input string sock_path
    );

    import "DPI-C" function int bridge_vcs_init_ex(
        input string transport_type,
        input string shm_name,
        input string sock_path,
        input string remote_host,
        input int    port_base,
        input int    instance_id
    );

    import "DPI-C" function int bridge_vcs_poll_tlp(
        output byte unsigned tlp_type,
        output longint unsigned addr,
        output int unsigned data[16],
        output int len,
        output int tag
    );

    import "DPI-C" function int bridge_vcs_send_completion(
        input int tag,
        input int unsigned data[16],
        input int len
    );

    import "DPI-C" function void bridge_vcs_cleanup();

    /* TLP 类型常量（与 C 侧 tlp_type_t 对应） */
    typedef enum byte unsigned {
        TLP_MWR    = 8'd0,
        TLP_MRD    = 8'd1,
        TLP_CFGWR0 = 8'd2,
        TLP_CFGRD0 = 8'd3,
        TLP_CPL    = 8'd4
`ifdef COSIM_VIP_MODE
        ,
        TLP_CFGWR1          = 8'd5,
        TLP_CFGRD1          = 8'd6,
        TLP_IORD            = 8'd7,
        TLP_IOWR            = 8'd8,
        TLP_CPLD            = 8'd9,
        TLP_MSG             = 8'd10,
        TLP_ATOMIC_FETCHADD = 8'd11,
        TLP_ATOMIC_SWAP     = 8'd12,
        TLP_ATOMIC_CAS      = 8'd13,
        TLP_VENDOR_MSG      = 8'd14,
        TLP_LTR             = 8'd15,
        TLP_MRD_LK          = 8'd16
`endif
    } tlp_type_e;

    /* 向后兼容别名 */
    parameter byte unsigned TLP_CFGWR = TLP_CFGWR0;
    parameter byte unsigned TLP_CFGRD = TLP_CFGRD0;

    /* Fully-scalar DPI wrappers — no output/array params (VCS Q-2020 compat) */
    import "DPI-C" function int bridge_vcs_poll_tlp_scalar();
    import "DPI-C" function int bridge_vcs_get_poll_type();
    import "DPI-C" function longint bridge_vcs_get_poll_addr();
    import "DPI-C" function int bridge_vcs_get_poll_len();
    import "DPI-C" function int bridge_vcs_get_poll_tag();
    import "DPI-C" function int unsigned bridge_vcs_get_poll_data(input int index);
    import "DPI-C" function byte unsigned bridge_vcs_get_poll_first_be();
    import "DPI-C" function byte unsigned bridge_vcs_get_poll_last_be();
    import "DPI-C" function void bridge_vcs_set_bar_base(input int idx,
                                                          input longint unsigned base);
    import "DPI-C" function longint unsigned bridge_vcs_get_bar_base(input int idx);
    import "DPI-C" function void bridge_vcs_set_cpl_data(input int index,
                                                          input int unsigned value);
    import "DPI-C" function int bridge_vcs_send_cpl_scalar(input int tag,
                                                            input int len);

    import "DPI-C" function int bridge_vcs_dma_request(
        input int direction,
        input longint unsigned host_addr,
        input int unsigned data[16],
        input int len,
        output int out_tag
    );

    /* Phase 0: Synchronous DMA — blocks until QEMU completes */
    import "DPI-C" function int bridge_vcs_dma_read_sync(
        input longint unsigned host_addr,
        output int unsigned data[16],
        input int len
    );

    import "DPI-C" function int bridge_vcs_dma_write_sync(
        input longint unsigned host_addr,
        input int unsigned data[16],
        input int len
    );

    import "DPI-C" function int bridge_vcs_raise_msi(
        input int vector
    );

    import "DPI-C" function int bridge_vcs_wait_clock_step(
        output int cycles
    );

    import "DPI-C" function int bridge_vcs_clock_ack(
        input int cycles
    );

    typedef enum int {
        DMA_DIR_READ  = 0,
        DMA_DIR_WRITE = 1
    } dma_direction_e;

    /* ---- ETH MAC DPI-C (P3 ETH SHM layer) ---- */
    import "DPI-C" function int vcs_eth_mac_init_dpi(
        input string shm_name,
        input int role,
        input int create_shm
    );

    import "DPI-C" function int vcs_eth_mac_send_frame_dpi(
        input byte unsigned data[],
        input int len
    );

    import "DPI-C" function int vcs_eth_mac_poll_frame_dpi(
        output byte unsigned data[],
        input int max_len
    );

    import "DPI-C" function void vcs_eth_mac_close_dpi();

    import "DPI-C" function int vcs_eth_mac_peer_ready_dpi();

    /* ---- Virtqueue DMA processing (Phase 3) ---- */
    import "DPI-C" function void vcs_vq_configure(
        input int queue,
        input longint unsigned desc_gpa,
        input longint unsigned avail_gpa,
        input longint unsigned used_gpa,
        input int size
    );

    import "DPI-C" function int vcs_vq_process_tx();
    import "DPI-C" function int vcs_vq_process_rx();
    import "DPI-C" function int vcs_vq_get_tx_count();
    import "DPI-C" function int vcs_vq_get_rx_count();

    /* ---- Multi-function / SR-IOV DPI-C ---- */
    import "DPI-C" function void bridge_vcs_set_pf_topology(
        input int pf_idx, input int bdf, input int num_vfs, input int vf_device_id,
        input int vendor_id, input int device_id, input int msix_vectors, input int vf_msix_vectors,
        input longint unsigned pf_bar0, input longint unsigned pf_bar1, input longint unsigned pf_bar2,
        input longint unsigned pf_bar3, input longint unsigned pf_bar4, input longint unsigned pf_bar5,
        input longint unsigned vf_bar0, input longint unsigned vf_bar1, input longint unsigned vf_bar2,
        input longint unsigned vf_bar3, input longint unsigned vf_bar4, input longint unsigned vf_bar5);
    import "DPI-C" function void bridge_vcs_finalize_topology(input int num_pfs, input int tag_width);
    import "DPI-C" function int bridge_vcs_send_vf_event(input int event_type, input int pf_index, input int num_vfs);
    import "DPI-C" function int bridge_vcs_poll_vf_event(output int event_type, output int pf_index, output int num_vfs);
    import "DPI-C" function int bridge_vcs_get_tlp_target_bdf();
    import "DPI-C" function int bridge_vcs_get_tlp_requester_id();
    import "DPI-C" function void bridge_vcs_set_bar_base_bdf(input int bdf, input int bar_idx, input longint unsigned bar_addr);

`ifdef COSIM_VIP_MODE
    import "DPI-C" function int bridge_vcs_poll_tlp_ext(
        output byte unsigned tlp_type,
        output longint unsigned addr,
        output int unsigned data[16],
        output int len,
        output int tag,
        output byte unsigned msg_code,
        output byte unsigned atomic_op_size,
        output shortint unsigned vendor_id,
        output byte unsigned first_be,
        output byte unsigned last_be
    );
`endif

    /* ================= Multi-RC per-RC DPI (阶段2) =================
     * 每个 cosim_xrc_driver 传自己的 rc 索引；rc=0 与 legacy 单 RC 字节等价。
     * C 侧 g_rc[rc]：独立 transport / TLP 缓存 / scalar 缓存 / BAR。 */
    import "DPI-C" function int bridge_vcs_init_ex_rc(
        input int rc,
        input string transport_type,
        input string shm_name,
        input string sock_path,
        input string remote_host,
        input int    port_base,
        input int    instance_id
    );
    import "DPI-C" function void bridge_vcs_cleanup_ex_rc(input int rc);

    import "DPI-C" function int bridge_vcs_poll_tlp_scalar_rc(input int rc);
    import "DPI-C" function int bridge_vcs_get_poll_type_rc(input int rc);
    import "DPI-C" function int bridge_vcs_is_realized_rc(input int rc);
    import "DPI-C" function longint bridge_vcs_get_poll_addr_rc(input int rc);
    import "DPI-C" function int bridge_vcs_get_poll_len_rc(input int rc);
    import "DPI-C" function int bridge_vcs_get_poll_tag_rc(input int rc);
    import "DPI-C" function int unsigned bridge_vcs_get_poll_data_rc(input int rc, input int index);
    import "DPI-C" function byte unsigned bridge_vcs_get_poll_first_be_rc(input int rc);
    import "DPI-C" function byte unsigned bridge_vcs_get_poll_last_be_rc(input int rc);
    import "DPI-C" function int bridge_vcs_get_tlp_target_bdf_rc(input int rc);
    import "DPI-C" function int bridge_vcs_get_tlp_requester_id_rc(input int rc);
    import "DPI-C" function int bridge_vcs_poll_vf_event_rc(
        input int rc, output int event_type, output int pf_index, output int num_vfs);
    import "DPI-C" function void bridge_vcs_set_cpl_data_rc(
        input int rc, input int index, input int unsigned value);
    import "DPI-C" function int bridge_vcs_send_cpl_scalar_rc(
        input int rc, input int tag, input int len);
    import "DPI-C" function void bridge_vcs_set_bar_base_rc(
        input int rc, input int idx, input longint unsigned base);
    import "DPI-C" function longint unsigned bridge_vcs_get_bar_base_rc(input int rc, input int idx);

    /* DUT 入向扩展 TLP：per-RC 发起 DMA（DUT 作为 requester，host 服务） */
    import "DPI-C" function int bridge_vcs_dma_read_rc(input int rc, input longint unsigned host_addr,
                                                       output int unsigned data[16], input int len);
    import "DPI-C" function int bridge_vcs_dma_write_rc(input int rc, input longint unsigned host_addr,
                                                        input int unsigned data[16], input int len);

    /* DUT 入向 AtomicOp：per-RC FetchAdd/Swap/CAS（DUT requester，host RMW 返旧值）。
     * op ∈ {2=FETCHADD,3=SWAP,4=CAS}；op_size ∈ {4,8}。
     * operands[4]: FA/Swap 用 1 个 datum；CAS 用 compare‖swap（低位在前）。
     * old_out[2]: 返回运算前的原值。 */
    import "DPI-C" function int bridge_vcs_dma_atomic_rc(input int rc, input longint unsigned host_addr,
                                                         input int op, input int op_size,
                                                         input int unsigned operands[4],
                                                         output int unsigned old_out[2]);

endpackage
