/* cosim-platform/vcs-tb/cosim_env_config.sv
 * CoSim 专用 UVM 环境配置
 * 继承 pcie_tl_env_config，覆盖 cosim 模式默认值
 */

class cosim_env_config extends pcie_tl_env_config;
    `uvm_object_utils(cosim_env_config)

    function new(string name = "cosim_env_config");
        super.new(name);

        /* --- 角色: 只启用 RC agent, EP 用 stub --- */
        rc_agent_enable  = 1;
        ep_agent_enable  = 0;
        rc_is_active     = UVM_ACTIVE;

        /* --- 接口模式: 走物理接口 --- */
        if_mode = SV_IF_MODE;

        /* --- PCIe 参数: 匹配 QEMU q35 默认 --- */
        max_payload_size         = MPS_256;
        max_read_request_size    = MRRS_512;
        read_completion_boundary = RCB_64;

        /* --- FC: 初始 infinite credit，跑通后再收紧 --- */
        fc_enable       = 1;
        infinite_credit = 1;

        /* --- Tag: QEMU 用 8-bit tag --- */
        extended_tag_enable = 0;
        phantom_func_enable = 0;
        max_outstanding     = 32;

        /* --- 排序: 初始严格排序 --- */
        relaxed_ordering_enable  = 0;
        id_based_ordering_enable = 0;
        bypass_ordering          = 0;

        /* --- Scoreboard: 全部启用 --- */
        scb_enable              = 1;
        ordering_check_enable   = 1;
        completion_check_enable = 1;
        data_integrity_enable   = 1;

        /* --- Coverage --- */
        cov_enable      = 1;
        tlp_basic_cov   = 1;
        fc_state_cov    = 0;   /* infinite credit 下无意义 */
        tag_usage_cov   = 1;
        ordering_cov    = 1;
        error_inject_cov = 0;  /* 初始不做错误注入 */
    endfunction

endclass
