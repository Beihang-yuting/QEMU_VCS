`timescale 1ns/1ps

module test_cosim_table_service;
    import cosim_table_pkg::*;

    import "DPI-C" function void table_test_reset(input int rc,
                                                    input int requires_read);
    import "DPI-C" function int table_test_get_completion_count(input int rc);
    import "DPI-C" function int table_test_get_completion_status(input int rc,
                                                                  input int slot);
    import "DPI-C" function longint unsigned table_test_get_completion_failed_index(
        input int rc, input int slot);
    import "DPI-C" function int unsigned table_test_get_completion_committed(
        input int rc, input int slot);
    import "DPI-C" function int table_test_get_completion_handler_error(
        input int rc, input int slot);
    import "DPI-C" function int unsigned table_test_get_completion_read_data(
        input int rc, input int slot);
    import "DPI-C" function int table_test_get_cleanup_count(input int rc);
    import "DPI-C" function int table_test_get_order_errors(input int rc);

    int unsigned failures;

    task automatic check(input bit condition, input string description);
        if (!condition) begin
            failures++;
            $error("COSIM_TABLE_SERVICE: FAIL: %s", description);
        end
    endtask

    class service_handler extends cosim_table_handler;
        string name;
        bit read_capable;
        int unsigned write_calls;
        int unsigned read_calls;
        longint unsigned captured_index[8];
        byte unsigned captured_raw[8][16];
        int unsigned captured_size[8];
        cosim_table_protection_e captured_protection[8];
        int unsigned captured_protection_bits[8];

        function new(string name, bit read_capable);
            this.name = name;
            this.read_capable = read_capable;
        endfunction

        virtual function string get_name();
            return name;
        endfunction

        virtual function bit supports_read();
            return read_capable;
        endfunction

        virtual task write_entry(
            cosim_table_context ctx,
            longint unsigned index,
            byte unsigned raw_data[],
            output cosim_table_result result
        );
            int unsigned slot;

            slot = write_calls;
            write_calls++;
            captured_index[slot] = index;
            captured_size[slot] = raw_data.size();
            captured_protection[slot] = ctx.protection;
            captured_protection_bits[slot] = ctx.protection_bits.size();
            foreach (raw_data[i]) begin
                if (i < 16)
                    captured_raw[slot][i] = raw_data[i];
            end

            result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            result.committed_count = 1;
            result.handler_error = 0;
            result.read_data = '0;
            if (ctx.transaction_id == 64'h222 && index == 64'd3) begin
                result.status = COSIM_TABLE_STATUS_EXEC_ERROR;
                result.failed_index = index;
                result.committed_count = 0;
                result.handler_error = -77;
            end else begin
                result.status = COSIM_TABLE_STATUS_SUCCESS;
            end
        endtask

        virtual task read_dword(
            cosim_table_context ctx,
            longint unsigned index,
            int unsigned byte_offset,
            output bit [31:0] data,
            output cosim_table_result result
        );
            read_calls++;
            check(index == 64'd4, "read dispatch uses logical entry index 4");
            check(byte_offset == 8, "read dispatch uses byte offset 8");
            check(ctx.transaction_id == 64'h333,
                  "read dispatch carries transaction context");
            data = 32'ha1b2_c3d4;
            result.status = COSIM_TABLE_STATUS_SUCCESS;
            result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            result.committed_count = 0;
            result.handler_error = 0;
            result.read_data = data;
        endtask
    endclass

    task automatic check_write_call(
        input service_handler handler,
        input int unsigned slot,
        input longint unsigned expected_index,
        input int unsigned byte_base
    );
        check(handler.captured_index[slot] == expected_index,
              $sformatf("write call %0d index", slot));
        check(handler.captured_size[slot] == 16,
              $sformatf("write call %0d entry width", slot));
        check(handler.captured_protection[slot] ==
                  COSIM_TABLE_PROTECTION_PARITY_EVEN,
              $sformatf("write call %0d protection override", slot));
        check(handler.captured_protection_bits[slot] == 16,
              $sformatf("write call %0d protection bit count", slot));
        for (int unsigned i = 0; i < 16; i++) begin
            check(handler.captured_raw[slot][i] == byte'(byte_base + i),
                  $sformatf("write call %0d byte %0d", slot, i));
        end
    endtask

    initial begin : run_test
        cosim_table_service service;
        cosim_table_service write_only_service;
        cosim_table_service read_required_service;
        service_handler handler;
        service_handler write_only_handler;
        service_handler read_required_handler;

        failures = 0;

        table_test_reset(0, 0);
        service = new(0);
        handler = new("table0", 1'b1);
        check(service.register_handler(handler, COSIM_TABLE_PROTECTION_NONE),
              "read-capable handler registers");
        check(service.initialize("127.0.0.1", 10100, 0,
                                 "/absolute/routes.ini") == 0,
              "service initializes in load/register/init/activate order");
        service.run();
        service.wait_stopped();

        check(handler.write_calls == 5,
              "successful batch and failed batch stop at first failed entry");
        check_write_call(handler, 0, 64'd2, 8'h00);
        check_write_call(handler, 1, 64'd3, 8'h10);
        check_write_call(handler, 2, 64'd4, 8'h20);
        check_write_call(handler, 3, 64'd2, 8'h80);
        check_write_call(handler, 4, 64'd3, 8'h90);
        check(handler.read_calls == 1, "read_dword dispatches exactly once");

        check(table_test_get_completion_count(0) == 3,
              "each accepted request completes exactly once");
        check(table_test_get_completion_status(0, 0) ==
                  COSIM_TABLE_STATUS_SUCCESS &&
              table_test_get_completion_committed(0, 0) == 3 &&
              table_test_get_completion_failed_index(0, 0) ==
                  COSIM_TABLE_FAILED_INDEX_NONE,
              "successful batch completion reports all committed entries");
        check(table_test_get_completion_status(0, 1) ==
                  COSIM_TABLE_STATUS_EXEC_ERROR &&
              table_test_get_completion_committed(0, 1) == 1 &&
              table_test_get_completion_failed_index(0, 1) == 64'd3 &&
              table_test_get_completion_handler_error(0, 1) == -77,
              "handler failure completion preserves partial progress");
        check(table_test_get_completion_status(0, 2) ==
                  COSIM_TABLE_STATUS_SUCCESS &&
              table_test_get_completion_read_data(0, 2) == 32'ha1b2_c3d4,
              "read completion returns the handler DWORD");
        check(table_test_get_order_errors(0) == 0,
              "DPI lifecycle and completion ownership are ordered");

        service.request_stop();
        service.request_stop();
        service.shutdown();
        service.shutdown();
        check(table_test_get_cleanup_count(0) == 1,
              "shutdown is idempotent after run stops");

        table_test_reset(1, 0);
        write_only_service = new(1);
        write_only_handler = new("table0", 1'b0);
        check(write_only_service.register_handler(
                  write_only_handler, COSIM_TABLE_PROTECTION_NONE),
              "write-only handler registers");
        check(write_only_service.initialize("127.0.0.1", 10100, 1,
                                            "/absolute/write.ini") == 0,
              "write-only route accepts handler without read support");
        check(write_only_service.initialize("ignored", 1, 1,
                                            "/ignored") == 0,
              "repeated initialize is state-safe");
        write_only_service.shutdown();
        check(table_test_get_cleanup_count(1) == 1,
              "initialized service can shut down without run");

        table_test_reset(2, 1);
        read_required_service = new(2);
        read_required_handler = new("table0", 1'b0);
        check(read_required_service.register_handler(
                  read_required_handler, COSIM_TABLE_PROTECTION_NONE),
              "non-readable handler registers before route activation");
        check(read_required_service.initialize("127.0.0.1", 10100, 2,
                                               "/absolute/read.ini") != 0,
              "write,read route rejects handler without read support");
        read_required_service.shutdown();
        check(table_test_get_cleanup_count(2) == 1,
              "failed activation cleans C state exactly once");

        if (failures != 0)
            $fatal(1, "COSIM_TABLE_SERVICE: %0d checks failed", failures);
        $display("COSIM_TABLE_SERVICE: ALL PASS");
        $finish;
    end
endmodule
