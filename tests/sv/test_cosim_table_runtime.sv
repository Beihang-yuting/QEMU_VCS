`timescale 1ns/1ps

module test_cosim_table_runtime;
    import cosim_table_pkg::*;

    import "DPI-C" function void table_runtime_test_reset();
    import "DPI-C" function void table_runtime_test_fail_activate(input int rc);
    import "DPI-C" function int table_runtime_test_total_calls();
    import "DPI-C" function int table_runtime_test_load_calls(input int rc);
    import "DPI-C" function int table_runtime_test_register_calls(input int rc);
    import "DPI-C" function int table_runtime_test_init_calls(input int rc);
    import "DPI-C" function int table_runtime_test_activate_calls(input int rc);
    import "DPI-C" function int table_runtime_test_interrupt_calls(input int rc);
    import "DPI-C" function int table_runtime_test_cleanup_calls(input int rc);
    import "DPI-C" function int table_runtime_test_order_errors(input int rc);

    int unsigned failures;

    task automatic check(input bit condition, input string description);
        if (!condition) begin
            failures++;
            $error("COSIM_TABLE_RUNTIME: FAIL: %s", description);
        end
    endtask

    class runtime_handler extends cosim_table_handler;
        string handler_name;
        int unsigned write_calls;
        cosim_table_protection_e observed_protection;

        function new(string handler_name);
            this.handler_name = handler_name;
        endfunction

        virtual function string get_name();
            return handler_name;
        endfunction

        virtual task write_entry(
            cosim_table_context ctx,
            longint unsigned index,
            byte unsigned raw_data[],
            output cosim_table_result result
        );
            write_calls++;
            observed_protection = ctx.protection;
            result.status = COSIM_TABLE_STATUS_SUCCESS;
            result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            result.committed_count = 1;
            result.handler_error = 0;
            result.read_data = '0;
            cosim_table_result_mark_valid(result);
        endtask
    endclass

    initial begin : run_test
        runtime_handler rc0_handler;
        runtime_handler rc0_duplicate;
        runtime_handler rc1_handler;
        runtime_handler rc2_handler;
        runtime_handler empty_handler;
        runtime_handler null_handler;
        bit active_case;

        failures = 0;
        table_runtime_test_reset();
        active_case = cosim_table_runtime::enabled();

        rc0_handler = new("shared");
        rc0_duplicate = new("shared");
        rc1_handler = new("shared");
        rc2_handler = new("bad");
        empty_handler = new("");
        null_handler = null;

        check(cosim_table_runtime::register_handler(
                  0, rc0_handler, COSIM_TABLE_PROTECTION_SECDED),
              "RC0 handler registers before service creation");
        check(!cosim_table_runtime::register_handler(
                   0, rc0_duplicate, COSIM_TABLE_PROTECTION_NONE),
              "same RC and handler name duplicate is rejected");
        check(cosim_table_runtime::register_handler(
                  1, rc1_handler, COSIM_TABLE_PROTECTION_PARITY_ODD),
              "same handler name on another RC is independent");
        check(!cosim_table_runtime::register_handler(
                   4, rc2_handler, COSIM_TABLE_PROTECTION_NONE),
              "out-of-range RC is rejected");
        check(!cosim_table_runtime::register_handler(
                   3, empty_handler, COSIM_TABLE_PROTECTION_NONE),
              "empty handler name is rejected");
        check(!cosim_table_runtime::register_handler(
                   3, null_handler, COSIM_TABLE_PROTECTION_NONE),
              "null handler is rejected");

        if (!active_case) begin
            cosim_table_runtime::start_rc(0);
            cosim_table_runtime::stop_rc(0);
            #1ns;
            check(table_runtime_test_total_calls() == 0,
                  "disabled runtime neither creates a service nor calls DPI");
        end else begin
            check(cosim_table_runtime::register_handler(
                      2, rc2_handler, COSIM_TABLE_PROTECTION_NONE),
                  "RC2 failure-path handler registers");
            table_runtime_test_fail_activate(2);

            cosim_table_runtime::start_rc(0);
            cosim_table_runtime::start_rc(0);
            cosim_table_runtime::start_rc(1);
            cosim_table_runtime::start_rc(2);
            cosim_table_runtime::start_rc(3);

            for (int unsigned wait_count = 0;
                 wait_count < 100 &&
                 (rc0_handler.write_calls == 0 || rc1_handler.write_calls == 0);
                 wait_count++)
                #10ns;

            check(rc0_handler.write_calls == 1,
                  "RC0 service dispatches one request");
            check(rc1_handler.write_calls == 1,
                  "RC1 service dispatches one request");
            check(rc0_handler.observed_protection ==
                      COSIM_TABLE_PROTECTION_SECDED,
                  "RC0 compiled default protection survives facade registration");
            check(rc1_handler.observed_protection ==
                      COSIM_TABLE_PROTECTION_PARITY_ODD,
                  "RC1 compiled default protection survives facade registration");

            cosim_table_runtime::stop_rc(0);
            cosim_table_runtime::stop_rc(0);
            cosim_table_runtime::stop_rc(1);
            cosim_table_runtime::stop_rc(2);
            cosim_table_runtime::stop_rc(3);

            for (int rc = 0; rc < 2; rc++) begin
                check(table_runtime_test_load_calls(rc) == 1,
                      $sformatf("RC%0d routes load once", rc));
                check(table_runtime_test_register_calls(rc) == 1,
                      $sformatf("RC%0d handler registers with service once", rc));
                check(table_runtime_test_init_calls(rc) == 1,
                      $sformatf("RC%0d table transport initializes once", rc));
                check(table_runtime_test_activate_calls(rc) == 1,
                      $sformatf("RC%0d route set activates once", rc));
                check(table_runtime_test_interrupt_calls(rc) == 1,
                      $sformatf("RC%0d stop interrupts once", rc));
                check(table_runtime_test_cleanup_calls(rc) == 1,
                      $sformatf("RC%0d service cleans once", rc));
                check(table_runtime_test_order_errors(rc) == 0,
                      $sformatf("RC%0d service lifecycle stays ordered", rc));
            end
            check(table_runtime_test_activate_calls(2) == 1 &&
                      table_runtime_test_cleanup_calls(2) == 1,
                  "failed service activation cleans its partial C state");
            check(table_runtime_test_load_calls(3) == 0,
                  "missing RC handler leaves the service inactive before DPI");
        end

        if (failures == 0)
            $display("COSIM_TABLE_RUNTIME: ALL PASS");
        else
            $fatal(1, "COSIM_TABLE_RUNTIME: %0d failure(s)", failures);
        $finish;
    end
endmodule
