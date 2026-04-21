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

endpackage
