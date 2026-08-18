`ifndef COSIM_TABLE_RUNTIME_SV
`define COSIM_TABLE_RUNTIME_SV

class cosim_table_runtime;
    localparam int unsigned COSIM_TABLE_RUNTIME_MAX_RCS = 4;

    protected static cosim_table_handler saved_handlers[0:3][$];
    protected static cosim_table_protection_e saved_protections[0:3][$];
    protected static bit saved_names[0:3][string];
    protected static cosim_table_service services[0:3];
    protected static bit registration_closed[0:3];
    protected static bit start_called[0:3];
    protected static bit stop_called[0:3];
    protected static bit service_active[0:3];

    protected static function bit valid_protection(
        input cosim_table_protection_e protection
    );
        case (protection)
            COSIM_TABLE_PROTECTION_NONE,
            COSIM_TABLE_PROTECTION_PARITY_EVEN,
            COSIM_TABLE_PROTECTION_PARITY_ODD,
            COSIM_TABLE_PROTECTION_ECC,
            COSIM_TABLE_PROTECTION_SECDED,
            COSIM_TABLE_PROTECTION_CUSTOM:
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    protected static function void report_error(
        input int unsigned rc,
        input string message
    );
        $display("COSIM_TABLE_ERROR rc=%0d %s", rc, message);
    endfunction

    static function bit register_handler(
        int unsigned rc,
        cosim_table_handler handler,
        cosim_table_protection_e default_protection =
            COSIM_TABLE_PROTECTION_NONE
    );
        string name;

        if (rc >= COSIM_TABLE_RUNTIME_MAX_RCS || handler == null ||
            registration_closed[rc] || !valid_protection(default_protection))
            return 1'b0;
        name = handler.get_name();
        if (name.len() == 0 || saved_names[rc].exists(name))
            return 1'b0;
        if (default_protection == COSIM_TABLE_PROTECTION_CUSTOM &&
            handler.get_codec() == null)
            return 1'b0;

        saved_handlers[rc].push_back(handler);
        saved_protections[rc].push_back(default_protection);
        saved_names[rc][name] = 1'b1;
        return 1'b1;
    endfunction

    static function bit enabled();
        integer table_enable;

        return $value$plusargs("COSIM_TABLE_ENABLE=%d", table_enable) &&
               table_enable == 1;
    endfunction

    static task start_rc(int unsigned rc);
        string remote_host;
        string map_path;
        integer table_port_base;
        integer map_fd;
        cosim_table_service service;

        if (!enabled())
            return;
        if (rc >= COSIM_TABLE_RUNTIME_MAX_RCS) begin
            report_error(rc, "RC index is outside the supported range 0..3");
            return;
        end
        if (start_called[rc])
            return;

        start_called[rc] = 1'b1;
        registration_closed[rc] = 1'b1;
        if (saved_handlers[rc].size() == 0) begin
            report_error(rc, "no table handler was registered before start_rc");
            return;
        end
        if (!$value$plusargs("COSIM_TABLE_MAP=%s", map_path)) begin
            report_error(rc, "+COSIM_TABLE_MAP=<absolute-path> is required");
            return;
        end
        if (map_path.len() == 0 || map_path.getc(0) != 8'h2f) begin
            report_error(rc, {"COSIM_TABLE_MAP must be an absolute Unix path: ",
                              map_path});
            return;
        end
        map_fd = $fopen(map_path, "r");
        if (map_fd == 0) begin
            report_error(rc, {"COSIM_TABLE_MAP is not readable: ", map_path});
            return;
        end
        $fclose(map_fd);

        if (!$value$plusargs("REMOTE_HOST=%s", remote_host))
            remote_host = "10.11.10.53";
        if (!$value$plusargs("TABLE_PORT_BASE=%d", table_port_base))
            table_port_base = 10100;

        service = new(rc);
        foreach (saved_handlers[rc][i]) begin
            if (!service.register_handler(saved_handlers[rc][i],
                                          saved_protections[rc][i])) begin
                report_error(rc, $sformatf(
                    "failed to register table handler %s with the RC service",
                    saved_handlers[rc][i].get_name()));
                return;
            end
        end
        services[rc] = service;
        if (service.initialize(remote_host, table_port_base, rc, map_path) != 0) begin
            report_error(rc, "table routes or transport failed to initialize");
            service.shutdown();
            services[rc] = null;
            return;
        end

        service_active[rc] = 1'b1;
        fork
            begin
                automatic cosim_table_service runner = service;
                runner.run();
            end
        join_none
        #0;
    endtask

    static task stop_rc(int unsigned rc);
        cosim_table_service service;

        if (rc >= COSIM_TABLE_RUNTIME_MAX_RCS || !start_called[rc] ||
            stop_called[rc])
            return;
        stop_called[rc] = 1'b1;
        service = services[rc];
        if (service == null)
            return;

        service.request_stop();
        service.wait_stopped();
        service.shutdown();
        services[rc] = null;
        service_active[rc] = 1'b0;
    endtask
endclass

`endif
