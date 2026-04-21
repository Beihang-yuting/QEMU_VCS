/* cosim-platform/vcs-tb/cosim_test.sv
 * CoSim 专用 UVM test
 * - 配置 cosim_env_config
 * - factory override: pcie_tl_rc_driver → cosim_rc_driver
 * - 等待 shutdown 事件
 */

class cosim_test extends uvm_test;
    `uvm_component_utils(cosim_test)

    pcie_tl_env       env;
    cosim_env_config  cfg;

    function new(string name = "cosim_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        /* 创建 cosim 专用配置 */
        cfg = cosim_env_config::type_id::create("cfg");

        /* 设置到 config_db */
        uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

        /* factory override: RC driver 替换为 cosim_rc_driver */
        set_type_override_by_type(
            pcie_tl_rc_driver::get_type(),
            cosim_rc_driver::get_type()
        );

        /* 创建 env */
        env = pcie_tl_env::type_id::create("env", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        virtual pcie_tl_if vif;
        super.connect_phase(phase);

        /* Assign vif to rc_adapter (VIP adapter doesn't do config_db::get) */
        if (uvm_config_db#(virtual pcie_tl_if)::get(
                this, "env.rc_adapter", "vif", vif)) begin
            env.rc_adapter.vif = vif;
            `uvm_info("COSIM_TEST", "rc_adapter.vif assigned from config_db", UVM_MEDIUM)
        end else begin
            `uvm_warning("COSIM_TEST",
                "Could not get vif for rc_adapter from config_db")
        end
    endfunction

    task run_phase(uvm_phase phase);
        cosim_rc_driver drv;
        string shm_name, sock_path;
        string transport_type, remote_host;
        int port_base, instance_id;

        phase.raise_objection(this, "cosim_test waiting for shutdown");

        /* 等待复位完成 */
        #200ns;

        /* 读取 transport 参数 (plusarg 或 config_db) */
        if (!$value$plusargs("transport=%s", transport_type))
            transport_type = "shm";

        if (transport_type == "tcp") begin
            if (!$value$plusargs("REMOTE_HOST=%s", remote_host))
                remote_host = "127.0.0.1";
            if (!$value$plusargs("PORT_BASE=%d", port_base))
                port_base = 9100;
            if (!$value$plusargs("INSTANCE_ID=%d", instance_id))
                instance_id = 0;

            `uvm_info("COSIM_TEST", $sformatf(
                "TCP mode: host=%s port=%0d inst=%0d",
                remote_host, port_base, instance_id), UVM_LOW)

            if (bridge_vcs_init_ex(transport_type, "", "",
                    remote_host, port_base, instance_id) != 0) begin
                `uvm_fatal("COSIM_TEST", "bridge_vcs_init_ex (tcp) failed")
            end
        end else begin
            /* SHM 模式 — 使用原有 bridge_vcs_init */
            if (!uvm_config_db#(string)::get(this, "", "shm_name", shm_name))
                shm_name = "/cosim0";
            if (!uvm_config_db#(string)::get(this, "", "sock_path", sock_path))
                sock_path = "/tmp/cosim.sock";

            if (bridge_vcs_init(shm_name, sock_path) != 0) begin
                `uvm_fatal("COSIM_TEST", "bridge_vcs_init failed")
            end
        end
        `uvm_info("COSIM_TEST", "Bridge initialized, cosim_rc_driver running", UVM_LOW)

        /* 获取 driver 引用，通知 bridge 就绪，等待 shutdown 事件 */
        if ($cast(drv, env.rc_agent.driver)) begin
            drv.bridge_ready = 1;
            @(drv.shutdown_event);
        end else
            `uvm_fatal("COSIM_TEST", "Failed to cast RC driver to cosim_rc_driver")

        `uvm_info("COSIM_TEST", "Shutdown received, finishing simulation", UVM_LOW)

        phase.drop_objection(this, "cosim_test shutdown complete");
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COSIM_TEST", "=== CoSim VIP Mode Test Complete ===", UVM_LOW)
    endfunction

endclass
