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
        output int len
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

endpackage
