/* cosim-platform/vcs-tb/cosim_xrc_test.sv
 *
 * 2-RC cosim test over the Xilinx PG213 AXIS adapter path.
 *
 * Mirrors xilinx_pcie_adapter_multirc_noep_test (cfg.num_rc=2, RC-role adapters,
 * no EP, no switch) and adds the cosim bridge:
 *   - factory override rc_driver -> cosim_xrc_driver
 *   - per-RC transport init over TCP (each RC = one QEMU on the far host)
 *   - per-RC rc_index + bridge_ready, then wait for a shutdown from any RC.
 *
 * Plusargs:
 *   +NUM_RC=2                 (default 2)
 *   +REMOTE_HOST=10.11.10.53  (QEMU host; default 10.11.10.53)
 *   +PORT_BASE=9000           (RC r uses PORT_BASE + r*PORT_STRIDE unless
 *   +PORT_STRIDE=100           +PORT_BASE<r> overrides it, e.g. +PORT_BASE0=9000)
 *   +INSTANCE_ID<r>=<n>       (default instance id = r)
 */

class cosim_xrc_test extends uvm_test;
    `uvm_component_utils(cosim_xrc_test)

    int NUM_RC = 2;

    pcie_tl_env        env;
    cosim_env_config   cfg;
    cosim_xrc_driver   drivers[$];

    function new(string name = "cosim_xrc_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!$value$plusargs("NUM_RC=%d", NUM_RC)) NUM_RC = 2;

        // --- Factory overrides: xilinx AXIS adapter + cosim RC driver ---
        pcie_tl_if_adapter::type_id::set_type_override(
            xilinx_pcie_if_adapter::get_type());
        pcie_tl_rc_driver::type_id::set_type_override(
            cosim_xrc_driver::get_type());

        // --- Env config: 2 independent RC host links, no EP, no switch ---
        cfg = cosim_env_config::type_id::create("cfg");
        cfg.if_mode         = SV_IF_MODE;   // disable env TLM loopback
        cfg.rc_agent_enable = 1;
        cfg.ep_agent_enable = 0;
        cfg.num_rc          = NUM_RC;
        cfg.num_ep          = 0;
        cfg.switch_enable   = 0;
        cfg.infinite_credit = 1;
        cfg.scb_enable      = 0;            // no scoreboard against a real DUT
        uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);

        env = pcie_tl_env::type_id::create("env", this);

        // --- Per-RC index for each driver (driver also name-parses as fallback) ---
        for (int r = 0; r < NUM_RC; r++)
            uvm_config_db#(int)::set(
                this, $sformatf("env.rc_agent_%0d*", r), "rc_index", r);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (env.rc_agents.size() != NUM_RC)
            `uvm_error("COSIM_XRC", $sformatf(
                "expected %0d RC agents, got %0d", NUM_RC, env.rc_agents.size()))
    endfunction

    task run_phase(uvm_phase phase);
        string remote_host;
        int    port_base;

        phase.raise_objection(this, "cosim_xrc_test running");

        if (!$value$plusargs("REMOTE_HOST=%s", remote_host))
            remote_host = "10.11.10.53";
        // Same PORT_BASE for all RCs; the transport derives the real port as
        // port_base + instance_id*3 — matching QEMU's cosim-pcie-rc
        // (transport=tcp, port_base=PORT_BASE, instance_id=r). Default 9100
        // matches the QEMU device's DEFINE_PROP default.
        if (!$value$plusargs("PORT_BASE=%d", port_base)) port_base = 9100;

        // --- Per-RC transport init (one QEMU per RC on the far host) ---
        for (int r = 0; r < NUM_RC; r++) begin
            int rc_port, rc_inst;
            // Per-RC overrides (rare: QEMU instances on different port bases)
            if (!$value$plusargs($sformatf("PORT_BASE%0d=%%d", r), rc_port))
                rc_port = port_base;                 // same base for every RC
            if (!$value$plusargs($sformatf("INSTANCE_ID%0d=%%d", r), rc_inst))
                rc_inst = r;                          // instance_id = RC index

            if (bridge_vcs_init_ex_rc(r, "tcp", "", "", remote_host, rc_port, rc_inst) != 0)
                `uvm_fatal("COSIM_XRC", $sformatf(
                    "RC%0d bridge_vcs_init_ex_rc(tcp %s:%0d inst=%0d) failed",
                    r, remote_host, rc_port, rc_inst))
            `uvm_info("COSIM_XRC", $sformatf(
                "RC%0d bridge up: tcp %s:%0d inst=%0d", r, remote_host, rc_port, rc_inst),
                UVM_LOW)
        end

        // --- Grab each driver, mark bridge ready ---
        foreach (env.rc_agents[i]) begin
            cosim_xrc_driver drv;
            if (env.rc_agents[i] != null && $cast(drv, env.rc_agents[i].driver)) begin
                drv.bridge_ready = 1;
                drivers.push_back(drv);
            end else
                `uvm_fatal("COSIM_XRC", $sformatf(
                    "RC%0d: driver is not a cosim_xrc_driver", i))
        end
        `uvm_info("COSIM_XRC", $sformatf("%0d RC bridges ready, polling", drivers.size()), UVM_LOW)

        // --- Wait until ANY RC's QEMU shuts down ---
        wait_any_shutdown();

        `uvm_info("COSIM_XRC", "shutdown received, finishing", UVM_LOW)
        for (int r = 0; r < NUM_RC; r++) bridge_vcs_cleanup_ex_rc(r);
        phase.drop_objection(this, "cosim_xrc_test done");
    endtask

    // Block until ANY driver fires its shutdown_event.
    protected task wait_any_shutdown();
        event any_done;
        foreach (drivers[i]) begin
            automatic int k = i;
            fork
                begin @(drivers[k].shutdown_event); -> any_done; end
            join_none
        end
        @any_done;
    endtask

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COSIM_XRC", "=== cosim 2-RC test complete ===", UVM_LOW)
    endfunction

endclass
