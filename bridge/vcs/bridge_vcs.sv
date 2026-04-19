/* cosim-platform/bridge/vcs/bridge_vcs.sv
 * SystemVerilog DPI-C import 声明
 * 供 testbench 调用
 */
package cosim_bridge_pkg;

    import "DPI-C" function int bridge_vcs_init(
        input string shm_name,
        input string sock_path
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
        TLP_MWR   = 8'd0,
        TLP_MRD   = 8'd1,
        TLP_CFGWR = 8'd2,
        TLP_CFGRD = 8'd3,
        TLP_CPL   = 8'd4
    } tlp_type_e;

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

endpackage
