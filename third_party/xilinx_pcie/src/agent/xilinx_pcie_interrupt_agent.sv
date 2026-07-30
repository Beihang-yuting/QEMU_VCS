//=============================================================================
// Xilinx PCIe 中断 Agent (adapter-mode 移植版, PG213)
//
// 自包含: driver 同时提供 EP 侧发送 task 与本地 PCIe-IP 侧应答循环
// (_rc_int_respond_loop), 故单实例即可完成完整的 cfg_interrupt 握手。
// 相比 main 分支去掉了对 xilinx_pcie_env_config 的依赖 —— 配置(中断模式/
// 使能/向量数)直接作为 driver/agent 字段, 由测试设置。
//
// 依赖: xilinx_pcie_cfg_if (cfg_interrupt 边带, user_cb / pcie_ip_cb 时钟块),
//       xilinx_pcie_role_e, xilinx_interrupt_mode_e, xilinx_interrupt_item
//       (均在 xilinx_pcie_types.sv 中)。
//=============================================================================

//=============================================================================
// xilinx_pcie_interrupt_driver
//=============================================================================
class xilinx_pcie_interrupt_driver extends uvm_driver #(uvm_sequence_item);
    `uvm_component_utils(xilinx_pcie_interrupt_driver)

    virtual xilinx_pcie_cfg_if cfg_vif;
    xilinx_pcie_role_e         role = XILINX_PCIE_EP;

    // 直接配置字段 (替代 env_config 依赖)
    bit                     interrupt_enable = 1'b1;
    xilinx_interrupt_mode_e interrupt_mode   = XILINX_INT_MSI;
    int                     msi_vector_count = 1;
    int                     msix_table_size  = 1;

    int unsigned timeout_cycles = 1000;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    virtual task run_phase(uvm_phase phase);
        @(posedge cfg_vif.clk);
        wait (cfg_vif.rst_n === 1'b1);

        if (role == XILINX_PCIE_EP)
            _ep_idle_init();

        // 本地 PCIe 硬核 IP 行为模型: 驱动使能状态 + 应答 sent/fail
        fork
            _rc_init_int_status();
            _rc_int_respond_loop();
        join_none
    endtask : run_phase

    //-------------------------------------------------------------------------
    // send_legacy_interrupt: 断言 cfg_interrupt_int[vector] -> 等 sent -> 撤销
    //-------------------------------------------------------------------------
    task send_legacy_interrupt(int vector);
        int unsigned wait_cnt;
        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(), "send_legacy_interrupt: 仅 EP 角色可调用")
            return;
        end
        if (vector < 0 || vector > 3) begin
            `uvm_error(get_type_name(),
                $sformatf("send_legacy_interrupt: vector=%0d 非法 (0~3)", vector))
            return;
        end
        if (!interrupt_enable) begin
            `uvm_warning(get_type_name(), "send_legacy_interrupt: interrupt_enable=0, 跳过")
            return;
        end
        `uvm_info(get_type_name(),
            $sformatf("发送 Legacy INTx: vector=%0d", vector), UVM_MEDIUM)

        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_int[vector] <= 1'b1;

        wait_cnt = 0;
        @(cfg_vif.user_cb);
        while (cfg_vif.user_cb.cfg_interrupt_sent !== 1'b1) begin
            @(cfg_vif.user_cb);
            wait_cnt++;
            if (wait_cnt >= timeout_cycles) begin
                `uvm_error(get_type_name(),
                    $sformatf("send_legacy_interrupt 超时: vector=%0d 等待 %0d 周期未 sent",
                              vector, timeout_cycles))
                cfg_vif.user_cb.cfg_interrupt_int[vector] <= 1'b0;
                return;
            end
        end

        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_int[vector] <= 1'b0;
        `uvm_info(get_type_name(),
            $sformatf("Legacy INTx 完成: vector=%0d", vector), UVM_MEDIUM)
    endtask : send_legacy_interrupt

    //-------------------------------------------------------------------------
    // send_msi_interrupt: 查 msi_enable/mmenable -> 脉冲 msi_int -> 等 sent/fail
    //-------------------------------------------------------------------------
    task send_msi_interrupt(int vector);
        int unsigned wait_cnt;
        int          max_vec;
        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(), "send_msi_interrupt: 仅 EP 角色可调用")
            return;
        end
        if (!interrupt_enable) begin
            `uvm_warning(get_type_name(), "send_msi_interrupt: interrupt_enable=0, 跳过")
            return;
        end
        if (cfg_vif.user_cb.cfg_interrupt_msi_enable !== 1'b1) begin
            `uvm_warning(get_type_name(),
                $sformatf("send_msi_interrupt: MSI 未使能, vector=%0d 可能被拒", vector))
        end
        max_vec = 1 << int'(cfg_vif.user_cb.cfg_interrupt_msi_mmenable);
        if (vector < 0 || vector >= max_vec) begin
            `uvm_error(get_type_name(),
                $sformatf("send_msi_interrupt: vector=%0d 超 mmenable 限制 (max=%0d)",
                          vector, max_vec))
            return;
        end
        `uvm_info(get_type_name(), $sformatf("发送 MSI: vector=%0d", vector), UVM_MEDIUM)

        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msi_int <= (32'h1 << vector);

        wait_cnt = 0;
        @(cfg_vif.user_cb);
        while (cfg_vif.user_cb.cfg_interrupt_msi_sent !== 1'b1 &&
               cfg_vif.user_cb.cfg_interrupt_msi_fail !== 1'b1) begin
            @(cfg_vif.user_cb);
            wait_cnt++;
            if (wait_cnt >= timeout_cycles) begin
                `uvm_error(get_type_name(),
                    $sformatf("send_msi_interrupt 超时: vector=%0d", vector))
                cfg_vif.user_cb.cfg_interrupt_msi_int <= 32'h0;
                return;
            end
        end

        if (cfg_vif.user_cb.cfg_interrupt_msi_fail === 1'b1)
            `uvm_error(get_type_name(),
                $sformatf("MSI 发送失败 (msi_fail=1): vector=%0d", vector))
        else
            `uvm_info(get_type_name(),
                $sformatf("MSI 完成: vector=%0d", vector), UVM_MEDIUM)

        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msi_int <= 32'h0;
    endtask : send_msi_interrupt

    //-------------------------------------------------------------------------
    // send_msix_interrupt: 同拍给 address/data + 断言 msix_int 单拍脉冲 (PG213)
    //-------------------------------------------------------------------------
    task send_msix_interrupt(bit [63:0] addr, bit [31:0] data);
        if (role != XILINX_PCIE_EP) begin
            `uvm_error(get_type_name(), "send_msix_interrupt: 仅 EP 角色可调用")
            return;
        end
        if (!interrupt_enable) begin
            `uvm_warning(get_type_name(), "send_msix_interrupt: interrupt_enable=0, 跳过")
            return;
        end
        if (cfg_vif.user_cb.cfg_interrupt_msix_enable !== 1'b1)
            `uvm_warning(get_type_name(), "send_msix_interrupt: MSI-X 未使能")
        if (cfg_vif.user_cb.cfg_interrupt_msix_mask === 1'b1)
            `uvm_warning(get_type_name(), "send_msix_interrupt: MSI-X 全局 mask 置位")

        `uvm_info(get_type_name(),
            $sformatf("发送 MSI-X: addr=0x%016h data=0x%08h", addr, data), UVM_MEDIUM)

        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msix_address <= addr;
        cfg_vif.user_cb.cfg_interrupt_msix_data    <= data;
        cfg_vif.user_cb.cfg_interrupt_msix_int     <= 1'b1;

        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_msix_int <= 1'b0;
        `uvm_info(get_type_name(), "MSI-X 脉冲已发送", UVM_MEDIUM)
    endtask : send_msix_interrupt

    //-------------------------------------------------------------------------
    protected task _ep_idle_init();
        @(cfg_vif.user_cb);
        cfg_vif.user_cb.cfg_interrupt_int     <= 4'h0;
        cfg_vif.user_cb.cfg_interrupt_pending <= 4'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_int                         <= 32'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_data                        <= 32'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_select                      <= 4'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_pending_status              <= 32'h0;
        cfg_vif.user_cb.cfg_interrupt_msi_pending_status_data_enable  <= 1'b0;
        cfg_vif.user_cb.cfg_interrupt_msi_pending_status_function_num <= 4'h0;
        cfg_vif.user_cb.cfg_interrupt_msix_int     <= 1'b0;
        cfg_vif.user_cb.cfg_interrupt_msix_address <= 64'h0;
        cfg_vif.user_cb.cfg_interrupt_msix_data    <= 32'h0;
    endtask : _ep_idle_init

    //-------------------------------------------------------------------------
    protected task _rc_init_int_status();
        @(cfg_vif.pcie_ip_cb);
        cfg_vif.pcie_ip_cb.cfg_interrupt_sent            <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_enable      <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_mmenable    <= 3'h0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_mask_update <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_sent        <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msi_fail        <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_enable     <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_mask       <= 1'b0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending        <= 2'h0;
        cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending_status <= 1'b0;

        repeat (10) @(cfg_vif.pcie_ip_cb);  // 模拟枚举完成

        case (interrupt_mode)
            XILINX_INT_LEGACY:
                `uvm_info(get_type_name(), "IP 模型: Legacy INTx", UVM_MEDIUM)
            XILINX_INT_MSI: begin
                bit [2:0] mme;
                case (msi_vector_count)
                    1:  mme = 3'b000;  2:  mme = 3'b001;  4:  mme = 3'b010;
                    8:  mme = 3'b011;  16: mme = 3'b100;  32: mme = 3'b101;
                    default: mme = 3'b000;
                endcase
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_enable   <= 1'b1;
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_mmenable <= mme;
                `uvm_info(get_type_name(),
                    $sformatf("IP 模型: MSI, vec=%0d", msi_vector_count), UVM_MEDIUM)
            end
            XILINX_INT_MSIX: begin
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_enable <= 1'b1;
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_mask   <= 1'b0;
                `uvm_info(get_type_name(),
                    $sformatf("IP 模型: MSI-X, table=%0d", msix_table_size), UVM_MEDIUM)
            end
            default:
                `uvm_warning(get_type_name(), "未知中断模式")
        endcase
    endtask : _rc_init_int_status

    //-------------------------------------------------------------------------
    protected task _rc_int_respond_loop();
        forever begin
            @(cfg_vif.pcie_ip_cb);

            if (cfg_vif.pcie_ip_cb.cfg_interrupt_int !== 4'h0) begin
                repeat (2) @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_sent <= 1'b1;
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_sent <= 1'b0;
            end

            if (cfg_vif.pcie_ip_cb.cfg_interrupt_msi_int !== 32'h0) begin
                repeat (2) @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_sent <= 1'b1;
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msi_sent <= 1'b0;
            end

            if (cfg_vif.pcie_ip_cb.cfg_interrupt_msix_int === 1'b1) begin
                repeat (2) @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending_status <= 1'b1;
                @(cfg_vif.pcie_ip_cb);
                cfg_vif.pcie_ip_cb.cfg_interrupt_msix_vec_pending_status <= 1'b0;
            end
        end
    endtask : _rc_int_respond_loop
endclass : xilinx_pcie_interrupt_driver


//=============================================================================
// xilinx_pcie_interrupt_monitor — 捕获中断事件 -> int_ap
//=============================================================================
class xilinx_pcie_interrupt_monitor extends uvm_monitor;
    `uvm_component_utils(xilinx_pcie_interrupt_monitor)

    virtual xilinx_pcie_cfg_if cfg_vif;
    uvm_analysis_port #(xilinx_interrupt_item) int_ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        int_ap = new("int_ap", this);
    endfunction : build_phase

    virtual task run_phase(uvm_phase phase);
        wait (cfg_vif.rst_n === 1'b1);
        fork _monitor_legacy(); _monitor_msi(); _monitor_msix(); join_none
    endtask : run_phase

    protected task _monitor_legacy();
        bit [3:0] prev = 4'h0;
        forever begin
            @(posedge cfg_vif.clk);
            begin
                bit [3:0] curr = cfg_vif.cfg_interrupt_int;
                if ((curr & ~prev) !== 4'h0) begin
                    for (int i = 0; i < 4; i++)
                        if (curr[i] && !prev[i]) begin
                            xilinx_interrupt_item it = xilinx_interrupt_item::type_id::create("intx");
                            it.mode = XILINX_INT_LEGACY; it.vector_num = i; it.timestamp = $realtime;
                            int_ap.write(it);
                            `uvm_info(get_type_name(),
                                $sformatf("[mon] INTx vector=%0d", i), UVM_MEDIUM)
                        end
                end
                prev = curr;
            end
        end
    endtask

    protected task _monitor_msi();
        bit [31:0] prev = 32'h0;
        forever begin
            @(posedge cfg_vif.clk);
            begin
                bit [31:0] curr = cfg_vif.cfg_interrupt_msi_int;
                if ((curr & ~prev) !== 32'h0) begin
                    for (int i = 0; i < 32; i++)
                        if (curr[i] && !prev[i]) begin
                            xilinx_interrupt_item it = xilinx_interrupt_item::type_id::create("msi");
                            it.mode = XILINX_INT_MSI; it.vector_num = i;
                            it.msi_data = cfg_vif.cfg_interrupt_msi_data; it.timestamp = $realtime;
                            int_ap.write(it);
                            `uvm_info(get_type_name(),
                                $sformatf("[mon] MSI vector=%0d data=0x%08h", i, it.msi_data), UVM_MEDIUM)
                        end
                end
                prev = curr;
            end
        end
    endtask

    protected task _monitor_msix();
        bit prev = 1'b0;
        forever begin
            @(posedge cfg_vif.clk);
            begin
                bit curr = cfg_vif.cfg_interrupt_msix_int;
                if (curr && !prev) begin
                    xilinx_interrupt_item it = xilinx_interrupt_item::type_id::create("msix");
                    it.mode = XILINX_INT_MSIX;
                    it.msix_addr = cfg_vif.cfg_interrupt_msix_address;
                    it.msix_data = cfg_vif.cfg_interrupt_msix_data; it.timestamp = $realtime;
                    int_ap.write(it);
                    `uvm_info(get_type_name(),
                        $sformatf("[mon] MSI-X addr=0x%016h data=0x%08h", it.msix_addr, it.msix_data), UVM_MEDIUM)
                end
                prev = curr;
            end
        end
    endtask
endclass : xilinx_pcie_interrupt_monitor


//=============================================================================
// xilinx_pcie_interrupt_agent
//=============================================================================
class xilinx_pcie_interrupt_agent extends uvm_agent;
    `uvm_component_utils(xilinx_pcie_interrupt_agent)

    xilinx_pcie_interrupt_driver  driver;
    xilinx_pcie_interrupt_monitor monitor;

    // 配置 (由测试设置, connect_phase 下发给 driver)
    xilinx_pcie_role_e      role             = XILINX_PCIE_EP;
    bit                     interrupt_enable = 1'b1;
    xilinx_interrupt_mode_e interrupt_mode   = XILINX_INT_MSI;
    int                     msi_vector_count = 1;
    int                     msix_table_size  = 1;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction : new

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        monitor = xilinx_pcie_interrupt_monitor::type_id::create("monitor", this);
        if (get_is_active() == UVM_ACTIVE)
            driver = xilinx_pcie_interrupt_driver::type_id::create("driver", this);
    endfunction : build_phase

    virtual function void connect_phase(uvm_phase phase);
        virtual xilinx_pcie_cfg_if vif;
        super.connect_phase(phase);
        if (!uvm_config_db #(virtual xilinx_pcie_cfg_if)::get(this, "", "cfg_vif", vif))
            `uvm_fatal(get_type_name(), "connect_phase: 无法获取 cfg_vif, 请在 tb 设置")
        monitor.cfg_vif = vif;
        if (get_is_active() == UVM_ACTIVE) begin
            driver.cfg_vif          = vif;
            driver.role             = role;
            driver.interrupt_enable = interrupt_enable;
            driver.interrupt_mode   = interrupt_mode;
            driver.msi_vector_count = msi_vector_count;
            driver.msix_table_size  = msix_table_size;
        end
    endfunction : connect_phase
endclass : xilinx_pcie_interrupt_agent
