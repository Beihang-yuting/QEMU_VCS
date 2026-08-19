`timescale 1ns/1ps

module test_cosim_table_multiram;
    import cosim_table_pkg::*;

    import "DPI-C" function void multiram_test_reset();
    import "DPI-C" function int multiram_test_completion_count();
    import "DPI-C" function int multiram_test_completion_failures();
    import "DPI-C" function int unsigned multiram_test_read_data();
    import "DPI-C" function int multiram_test_order_errors();

    int unsigned failures;

    task automatic check(input bit condition, input string description);
        if (!condition) begin
            failures++;
            $error("COSIM_TABLE_MULTIRAM: FAIL: %s", description);
        end
    endtask

    function automatic vio_notify_mock_value_t expected_value(
        input byte unsigned byte_base,
        input cosim_table_protection_e protection
    );
        cosim_table_builtin_codec codec;
        byte unsigned raw_data[];
        bit protection_bits[];
        vio_notify_mock_value_t value;

        codec = new();
        raw_data = new[16];
        foreach (raw_data[i])
            raw_data[i] = byte'(byte_base + i);
        codec.protect_entry(raw_data, protection, protection_bits);

        value = '0;
        foreach (raw_data[i])
            value[i * 8 +: 8] = raw_data[i];
        foreach (protection_bits[i])
            value[raw_data.size() * 8 + i] = protection_bits[i];
        return value;
    endfunction

    initial begin : run_test
        cosim_table_service service;
        vio_notify_mock_handler vio_handler;
        vio_notify_mock_handler flat_handler;
        string map_path;

        failures = 0;
        multiram_test_reset();
        check($value$plusargs("MULTIRAM_MAP=%s", map_path),
              "runner supplies an absolute route-map path");

        service = new(0);
        vio_handler = new("vio_notify", 1'b0);
        flat_handler = new("flat_table", 1'b1);
        check(vio_handler.get_name().len() < 64 &&
                  flat_handler.get_name().len() < 64,
              "example handler names fit the route ABI");
        check(!vio_handler.supports_read(),
              "write-only handler does not advertise a read callback");
        check(flat_handler.supports_read(),
              "readable mock advertises its 4-byte callback");
        check(service.register_handler(vio_handler,
                                       COSIM_TABLE_PROTECTION_NONE),
              "RC0 vio_notify handler registers");
        check(service.register_handler(flat_handler,
                                       COSIM_TABLE_PROTECTION_NONE),
              "RC0 flat_table handler registers");
        check(service.initialize("127.0.0.1", 10100, 0, map_path) == 0,
              "route map activates with write-only and readable handlers");

        service.run();
        service.wait_stopped();

        check(vio_handler.l3_write_count == 3,
              "indices 0, 15 and 255 each deposit into L3");
        check(vio_handler.l2_write_count == 2,
              "indices 15 and 255 additionally deposit into L2");
        check(vio_handler.l1_write_count == 1,
              "index 255 additionally deposits into L1");

        check(vio_handler.l3_logical_index[0] == 0 &&
                  vio_handler.l3_bank[0] == 0 &&
                  vio_handler.l3_ram_index[0] == 0,
              "index 0 selects L3 bank 0 RAM index 0");
        check(vio_handler.l3_logical_index[1] == 15 &&
                  vio_handler.l3_bank[1] == 3 &&
                  vio_handler.l3_ram_index[1] == 3,
              "index 15 selects L3 bank 3 RAM index 3");
        check(vio_handler.l2_logical_index[0] == 15 &&
                  vio_handler.l2_bank[0] == 0 &&
                  vio_handler.l2_ram_index[0] == 0,
              "index 15 selects L2 bank 0 RAM index 0");
        check(vio_handler.l3_logical_index[2] == 255 &&
                  vio_handler.l3_bank[2] == 3 &&
                  vio_handler.l3_ram_index[2] == 63,
              "index 255 selects L3 bank 3 RAM index 63");
        check(vio_handler.l2_logical_index[1] == 255 &&
                  vio_handler.l2_bank[1] == 3 &&
                  vio_handler.l2_ram_index[1] == 3,
              "index 255 selects L2 bank 3 RAM index 3");
        check(vio_handler.l1_logical_index[0] == 255 &&
                  vio_handler.l1_bank[0] == 0 &&
                  vio_handler.l1_ram_index[0] == 0,
              "index 255 selects L1 bank 0 RAM index 0");

        check(vio_handler.l3_value[0] ==
                  expected_value(8'h00, vio_handler.last_protection),
              "index 0 stores the selected protected value");
        check(vio_handler.l3_value[1] ==
                  expected_value(8'h20, vio_handler.last_protection),
              "index 15 stores the selected protected value");
        check(vio_handler.l3_value[2] ==
                  expected_value(8'h40, vio_handler.last_protection),
              "index 255 stores the selected protected value");
        check(vio_handler.l2_value[0] == vio_handler.l3_value[1] &&
                  vio_handler.l2_value[1] == vio_handler.l3_value[2] &&
                  vio_handler.l1_value[0] == vio_handler.l3_value[2],
              "all destinations for an entry receive one identical value");

        check(flat_handler.l3_write_count == 1 &&
                  flat_handler.l3_logical_index[0] == 7,
              "flat-table write seeds logical index 7");
        check(flat_handler.read_count == 1,
              "readable mock receives exactly one 4-byte callback");
        check(multiram_test_read_data() == 32'h8786_8584,
              "read callback returns the selected four stored bytes");
        check(multiram_test_completion_count() == 5 &&
                  multiram_test_completion_failures() == 0,
              "four writes and one read complete successfully");
        check(multiram_test_order_errors() == 0,
              "route and service lifecycle calls remain ordered");

        service.shutdown();
        if (failures == 0)
            $display("COSIM_TABLE_MULTIRAM: ALL PASS");
        else
            $fatal(1, "COSIM_TABLE_MULTIRAM: %0d failure(s)", failures);
        $finish;
    end
endmodule
