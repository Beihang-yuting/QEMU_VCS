`timescale 1ns/1ps

module test_cosim_table_unit;
    import cosim_table_pkg::*;

    int unsigned failures;

    task automatic check(input bit condition, input string description);
        if (!condition) begin
            failures++;
            $error("COSIM_TABLE_UNIT: FAIL: %s", description);
        end
    endtask

    class unit_handler extends cosim_table_handler;
        string name;
        int unsigned write_calls;
        cosim_table_protection_e captured_protection;
        bit captured_protection_bits[];
        byte unsigned captured_raw_data[];

        function new(string name);
            this.name = name;
        endfunction

        virtual function string get_name();
            return name;
        endfunction

        virtual task write_entry(
            cosim_table_context ctx,
            longint unsigned index,
            byte unsigned raw_data[],
            output cosim_table_result result
        );
            write_calls++;
            captured_protection = ctx.protection;
            captured_protection_bits = new[ctx.protection_bits.size()];
            foreach (ctx.protection_bits[i])
                captured_protection_bits[i] = ctx.protection_bits[i];
            captured_raw_data = new[raw_data.size()];
            foreach (raw_data[i])
                captured_raw_data[i] = raw_data[i];
            result.status = COSIM_TABLE_STATUS_SUCCESS;
            result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            result.committed_count = 1;
            result.handler_error = 0;
            result.read_data = '0;
            cosim_table_result_mark_valid(result);
        endtask
    endclass

    class unit_custom_codec extends cosim_table_codec_base;
        virtual function void protect_entry(
            input byte unsigned raw_data[],
            input cosim_table_protection_e protection,
            output bit protection_bits[]
        );
            protection_bits = new[2];
            protection_bits[0] = raw_data.size() != 0 && raw_data[0][0];
            protection_bits[1] = 1'b1;
        endfunction
    endclass

    task automatic dispatch_write(
        input cosim_table_registry registry,
        input unit_handler handler,
        input cosim_table_protection_e protection,
        input byte unsigned raw_data[],
        output bit dispatched,
        output cosim_table_result result
    );
        cosim_table_codec_base selected_codec;
        cosim_table_context ctx;

        dispatched = registry.resolve_codec(handler.get_name(), protection,
                                            selected_codec);
        if (!dispatched)
            return;
        selected_codec.protect_entry(raw_data, protection,
                                     ctx.protection_bits);
        ctx.protection = protection;
        handler.write_entry(ctx, 64'd7, raw_data, result);
    endtask

    initial begin : run
        cosim_table_registry registry;
        cosim_table_builtin_codec codec;
        cosim_table_codec_base selected_codec;
        unit_custom_codec custom_codec;
        unit_handler lower_handler;
        unit_handler upper_handler;
        unit_handler duplicate_handler;
        unit_handler empty_handler;
        unit_handler custom_handler;
        cosim_table_handler null_handler;
        cosim_table_protection_e protection;
        byte unsigned raw_data[];
        bit bits[];
        bit ecc_bits[];
        bit [31:0] read_data;
        bit dispatched;
        cosim_table_context ctx;
        cosim_table_result result;
        int unsigned i;

        failures = 0;
        registry = new();
        codec = new();
        lower_handler = new("vio_notify");
        upper_handler = new("VIO_NOTIFY");
        duplicate_handler = new("vio_notify");
        empty_handler = new("");

        check(registry.register_handler(lower_handler,
                                        COSIM_TABLE_PROTECTION_NONE),
              "lower-case handler registers");
        check(registry.register_handler(upper_handler,
                                        COSIM_TABLE_PROTECTION_PARITY_EVEN),
              "case-distinct upper-case handler registers");
        check(!registry.register_handler(duplicate_handler,
                                         COSIM_TABLE_PROTECTION_NONE),
              "exact duplicate handler name is rejected");
        check(!registry.register_handler(empty_handler,
                                         COSIM_TABLE_PROTECTION_NONE),
              "empty handler name is rejected");
        check(!registry.register_handler(null_handler,
                                         COSIM_TABLE_PROTECTION_NONE),
              "null handler is rejected");
        check(registry.lookup("vio_notify") == lower_handler,
              "lower-case lookup is exact");
        check(registry.lookup("VIO_NOTIFY") == upper_handler,
              "upper-case lookup is exact");
        check(registry.lookup("Vio_Notify") == null,
              "mixed-case lookup does not fold case");
        check(registry.get_default_protection("VIO_NOTIFY", protection) &&
              protection == COSIM_TABLE_PROTECTION_PARITY_EVEN,
              "registry retains the handler default protection");

        raw_data = new[2];
        raw_data[0] = 8'h01;
        raw_data[1] = 8'h80;
        codec.pack_raw_lsb_first(raw_data, bits);
        check(bits.size() == 16 && bits[0] == 1'b1 &&
              bits[7] == 1'b0 && bits[8] == 1'b0 && bits[15] == 1'b1,
              "raw bytes pack LSB-first without crossing byte boundaries");

        raw_data = new[128];
        foreach (raw_data[i]) raw_data[i] = 8'h00;
        raw_data[0] = 8'h01;
        raw_data[127] = 8'h80;
        codec.pack_raw_lsb_first(raw_data, bits);
        check(bits.size() == 1024 && bits[0] == 1'b1 && bits[1023] == 1'b1,
              "128-byte entry is not truncated");

        raw_data = new[1];
        raw_data[0] = 8'hff;
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_PARITY_EVEN,
                            bits);
        check(bits.size() == 1 && bits[0] == 1'b0, "even parity");
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_PARITY_ODD,
                            bits);
        check(bits.size() == 1 && bits[0] == 1'b1, "odd parity");

        raw_data = new[3];
        raw_data[0] = 8'h01;
        raw_data[1] = 8'h03;
        raw_data[2] = 8'h80;
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_PARITY_EVEN,
                            bits);
        check(bits.size() == 3 && bits[0] == 1'b1 &&
              bits[1] == 1'b0 && bits[2] == 1'b1,
              "even parity is computed independently per byte group");
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_PARITY_ODD,
                            bits);
        check(bits.size() == 3 && bits[0] == 1'b0 &&
              bits[1] == 1'b1 && bits[2] == 1'b0,
              "odd parity is computed independently per byte group");

        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_NONE, bits);
        check(bits.size() == 0, "none produces no protection bits");

        raw_data = new[1];
        raw_data[0] = 8'h00;
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_ECC, bits);
        check(bits.size() == 5 &&
              {bits[4], bits[3], bits[2], bits[1], bits[0]} == 5'b00000,
              "zero SECDED");

        raw_data[0] = 8'h01;
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_SECDED, bits);
        check(bits.size() == 5 &&
              {bits[4], bits[3], bits[2], bits[1], bits[0]} == 5'b10011,
              "one SECDED");

        raw_data[0] = 8'h5a;
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_ECC, ecc_bits);
        codec.protect_entry(raw_data, COSIM_TABLE_PROTECTION_SECDED, bits);
        check(bits.size() == ecc_bits.size(),
              "ECC and SECDED produce equal protection widths");
        if (bits.size() == ecc_bits.size()) begin
            foreach (bits[i])
                check(bits[i] == ecc_bits[i],
                      "ECC and SECDED use the same algorithm");
        end

        selected_codec = custom_codec;
        check(!registry.resolve_codec("vio_notify",
                                      COSIM_TABLE_PROTECTION_CUSTOM,
                                      selected_codec) &&
              selected_codec == null,
              "custom override rejects and clears a null user codec");

        custom_handler = new("custom_table");
        check(!registry.register_handler(custom_handler,
                                         COSIM_TABLE_PROTECTION_CUSTOM),
              "custom protection rejects a null user codec");
        custom_codec = new();
        custom_handler.set_codec(custom_codec);
        check(registry.register_handler(custom_handler,
                                        COSIM_TABLE_PROTECTION_CUSTOM),
              "custom protection accepts a handler codec");
        check(registry.resolve_codec("custom_table",
                                     COSIM_TABLE_PROTECTION_CUSTOM,
                                     selected_codec) &&
              selected_codec == custom_codec,
              "set_codec selects the user codec for custom protection");
        selected_codec.protect_entry(raw_data,
                                     COSIM_TABLE_PROTECTION_CUSTOM, bits);
        check(bits.size() == 2 && bits[0] == 1'b0 && bits[1] == 1'b1,
              "custom codec result is explicit");
        check(registry.resolve_codec("vio_notify",
                                     COSIM_TABLE_PROTECTION_NONE,
                                     selected_codec) &&
              selected_codec != null && selected_codec != custom_codec,
              "built-in protections resolve to the built-in codec");

        check(registry.get_default_protection("vio_notify", protection),
              "default protection is available for dispatch");
        raw_data = new[1];
        raw_data[0] = 8'hff;
        dispatch_write(registry, lower_handler, protection, raw_data,
                       dispatched, result);
        check(dispatched && lower_handler.write_calls == 1 &&
              lower_handler.captured_protection ==
                  COSIM_TABLE_PROTECTION_NONE &&
              lower_handler.captured_protection_bits.size() == 0 &&
              lower_handler.captured_raw_data.size() == 1 &&
              lower_handler.captured_raw_data[0] == 8'hff,
              "NONE dispatch carries raw data and explicit empty protection");
        check(result.failed_index[63:32] == 32'h0000_0000 &&
              result.failed_index[31:0] == 32'hffff_ffff,
              "successful result uses the wire-compatible failed-index sentinel");
        check(result.valid_cookie === COSIM_TABLE_RESULT_VALID_COOKIE,
              "complete write result carries the validity cookie");
        lower_handler.read_dword(ctx, 64'd55, 0, read_data, result);
        check(result.status == COSIM_TABLE_STATUS_UNSUPPORTED &&
              result.failed_index == 64'd55 &&
              result.valid_cookie === COSIM_TABLE_RESULT_VALID_COOKIE,
              "default unsupported read reports the requested index");

        check(registry.get_default_protection("VIO_NOTIFY", protection),
              "parity default protection is available for dispatch");
        dispatch_write(registry, upper_handler, protection, raw_data,
                       dispatched, result);
        check(dispatched && upper_handler.write_calls == 1 &&
              upper_handler.captured_protection ==
                  COSIM_TABLE_PROTECTION_PARITY_EVEN &&
              upper_handler.captured_protection_bits.size() == 1 &&
              upper_handler.captured_protection_bits[0] == 1'b0,
              "default parity mode and generated bit reach write_entry");

        raw_data[0] = 8'h01;
        protection = COSIM_TABLE_PROTECTION_ECC;
        dispatch_write(registry, lower_handler, protection, raw_data,
                       dispatched, result);
        check(dispatched && lower_handler.write_calls == 2 &&
              lower_handler.captured_protection ==
                  COSIM_TABLE_PROTECTION_ECC &&
              lower_handler.captured_protection_bits.size() == 5 &&
              {lower_handler.captured_protection_bits[4],
               lower_handler.captured_protection_bits[3],
               lower_handler.captured_protection_bits[2],
               lower_handler.captured_protection_bits[1],
               lower_handler.captured_protection_bits[0]} == 5'b10011,
              "ECC override and generated bits reach write_entry");

        raw_data[0] = 8'h5a;
        protection = COSIM_TABLE_PROTECTION_CUSTOM;
        dispatch_write(registry, custom_handler, protection, raw_data,
                       dispatched, result);
        check(dispatched && custom_handler.write_calls == 1 &&
              custom_handler.captured_protection ==
                  COSIM_TABLE_PROTECTION_CUSTOM &&
              custom_handler.captured_protection_bits.size() == 2 &&
              custom_handler.captured_protection_bits[0] == 1'b0 &&
              custom_handler.captured_protection_bits[1] == 1'b1,
              "custom mode and user-codec bits reach write_entry");

        check(registry.get_default_protection("vio_notify", protection) &&
              protection == COSIM_TABLE_PROTECTION_NONE,
              "an ECC override does not mutate the registered default");
        dispatch_write(registry, lower_handler, protection, raw_data,
                       dispatched, result);
        check(dispatched && lower_handler.write_calls == 3 &&
              lower_handler.captured_protection ==
                  COSIM_TABLE_PROTECTION_NONE &&
              lower_handler.captured_protection_bits.size() == 0,
              "successive modes do not leak state through the handler");

        if (failures != 0)
            $fatal(1, "COSIM_TABLE_UNIT: %0d checks failed", failures);
        $display("COSIM_TABLE_UNIT: ALL PASS");
        $finish;
    end
endmodule
