`ifndef COSIM_TABLE_SERVICE_SV
`define COSIM_TABLE_SERVICE_SV

/* Keep the table package independently compilable for handler-only users.
 * The production bridge package publishes the same C ABI for callers which
 * use cosim_bridge_pkg directly. */
import "DPI-C" function int table_vcs_init_rc(
    input int rc, input string remote_host, input int table_port_base,
    input int instance_id, input int connect_timeout_ms);
import "DPI-C" function int table_vcs_load_routes_rc(
    input int rc, input string absolute_path);
import "DPI-C" function int table_vcs_register_handler_rc(
    input int rc, input string name, input int supports_read);
import "DPI-C" function int table_vcs_activate_routes_rc(input int rc);
import "DPI-C" function int table_vcs_poll_request_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_kind_rc(input int rc);
import "DPI-C" function string table_vcs_get_request_handler_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_rc_id_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_device_instance_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_pci_domain_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_target_bdf_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_target_type_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_pf_index_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_vf_index_rc(input int rc);
import "DPI-C" function int table_vcs_get_request_bar_index_rc(input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_generation_rc(input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_route_id_rc(input int rc);
import "DPI-C" function longint unsigned table_vcs_get_request_first_index_rc(
    input int rc);
import "DPI-C" function longint unsigned table_vcs_get_request_bar_offset_rc(
    input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_entry_count_rc(
    input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_entry_bytes_rc(
    input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_payload_bytes_rc(
    input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_byte_offset_rc(
    input int rc);
import "DPI-C" function int unsigned table_vcs_get_request_flags_rc(input int rc);
import "DPI-C" function longint unsigned table_vcs_get_request_transaction_id_rc(
    input int rc);
import "DPI-C" function longint unsigned table_vcs_get_request_payload_u64_rc(
    input int rc, input int unsigned word);
import "DPI-C" function int table_vcs_complete_rc(
    input int rc, input int status, input longint unsigned failed_index,
    input int unsigned committed, input int handler_error,
    input int unsigned read_data);
import "DPI-C" function void table_vcs_interrupt_rc(input int rc);
import "DPI-C" function void table_vcs_cleanup_rc(input int rc);

localparam int COSIM_TABLE_REQUEST_NONE = 0;
localparam int COSIM_TABLE_REQUEST_WRITE = 1;
localparam int COSIM_TABLE_REQUEST_READ_DWORD = 2;
localparam int COSIM_TABLE_CONNECT_TIMEOUT_MS = 5000;
localparam int unsigned COSIM_TABLE_DEFAULT_DUMP_LIMIT = 64;

class cosim_table_service;
    protected int unsigned rc_id;
    protected cosim_table_registry registry;
    protected string handler_names[$];
    protected cosim_table_protection_e active_protections[string];
    protected bit initialized;
    protected bit running;
    protected bit stopped;
    protected bit stop_requested;
    protected bit c_state_cleaned;
    protected bit high_log;
    protected int unsigned dump_limit;
    protected event stopped_event;

    protected longint unsigned accepted_counters[string];
    protected longint unsigned entry_counters[string];
    protected longint unsigned byte_counters[string];
    protected longint unsigned success_counters[string];
    protected longint unsigned read_counters[string];
    protected longint unsigned error_counters[string];

    function new(int unsigned rc_id);
        this.rc_id = rc_id;
        registry = new();
        initialized = 1'b0;
        running = 1'b0;
        stopped = 1'b1;
        stop_requested = 1'b0;
        c_state_cleaned = 1'b1;
        high_log = 1'b0;
        dump_limit = COSIM_TABLE_DEFAULT_DUMP_LIMIT;
    endfunction

    function bit register_handler(
        cosim_table_handler handler,
        cosim_table_protection_e default_protection
    );
        if (initialized || running)
            return 1'b0;
        if (!registry.register_handler(handler, default_protection))
            return 1'b0;
        handler_names.push_back(handler.get_name());
        return 1'b1;
    endfunction

    protected function string protection_name(
        input cosim_table_protection_e protection
    );
        case (protection)
            COSIM_TABLE_PROTECTION_NONE:        return "none";
            COSIM_TABLE_PROTECTION_PARITY_EVEN: return "parity_even";
            COSIM_TABLE_PROTECTION_PARITY_ODD:  return "parity_odd";
            COSIM_TABLE_PROTECTION_ECC:         return "ecc";
            COSIM_TABLE_PROTECTION_SECDED:      return "secded";
            COSIM_TABLE_PROTECTION_CUSTOM:      return "custom";
            default:                            return "invalid";
        endcase
    endfunction

    protected function bit resolve_protection(input string handler_name);
        string key;
        string value;
        cosim_table_protection_e protection;
        cosim_table_codec_base selected_codec;

        if (!registry.get_default_protection(handler_name, protection))
            return 1'b0;
        key = {"COSIM_TABLE_PROTECT_", handler_name, "=%s"};
        if ($value$plusargs(key, value)) begin
            case (value)
                "none":        protection = COSIM_TABLE_PROTECTION_NONE;
                "parity_even": protection = COSIM_TABLE_PROTECTION_PARITY_EVEN;
                "parity_odd":  protection = COSIM_TABLE_PROTECTION_PARITY_ODD;
                "ecc":         protection = COSIM_TABLE_PROTECTION_ECC;
                "secded":      protection = COSIM_TABLE_PROTECTION_SECDED;
                "custom":      protection = COSIM_TABLE_PROTECTION_CUSTOM;
                default:        return 1'b0;
            endcase
        end
        if (!registry.resolve_codec(handler_name, protection, selected_codec))
            return 1'b0;
        active_protections[handler_name] = protection;
        return 1'b1;
    endfunction

    protected function void configure_logging();
        string value;
        integer parsed_limit;

        high_log = $value$plusargs("COSIM_TABLE_LOG=%s", value) &&
                   value == "high";
        dump_limit = COSIM_TABLE_DEFAULT_DUMP_LIMIT;
        if ($value$plusargs("COSIM_TABLE_DUMP_LIMIT=%d", parsed_limit) &&
            parsed_limit > 0)
            dump_limit = parsed_limit;
    endfunction

    protected function int fail_initialize();
        if (!c_state_cleaned) begin
            table_vcs_cleanup_rc(rc_id);
            c_state_cleaned = 1'b1;
        end
        initialized = 1'b0;
        stopped = 1'b1;
        return -1;
    endfunction

    function int initialize(
        string remote_host,
        int table_port_base,
        int instance_id,
        string absolute_map_path
    );
        cosim_table_handler handler;

        if (initialized)
            return 0;
        if (running)
            return -1;

        configure_logging();
        c_state_cleaned = 1'b0;
        if (table_vcs_load_routes_rc(rc_id, absolute_map_path) != 0)
            return fail_initialize();

        foreach (handler_names[i]) begin
            handler = registry.lookup(handler_names[i]);
            if (handler == null || !resolve_protection(handler_names[i]))
                return fail_initialize();
            if (table_vcs_register_handler_rc(rc_id, handler_names[i],
                                              handler.supports_read()) != 0)
                return fail_initialize();
        end
        if (table_vcs_init_rc(rc_id, remote_host, table_port_base,
                              instance_id,
                              COSIM_TABLE_CONNECT_TIMEOUT_MS) != 0)
            return fail_initialize();
        if (table_vcs_activate_routes_rc(rc_id) != 0)
            return fail_initialize();

        initialized = 1'b1;
        stopped = 1'b1;
        stop_requested = 1'b0;
        return 0;
    endfunction

    protected function cosim_table_context read_context(input string handler_name);
        cosim_table_context ctx;

        ctx.rc_id = table_vcs_get_request_rc_id_rc(rc_id);
        ctx.device_instance = table_vcs_get_request_device_instance_rc(rc_id);
        ctx.pci_domain = table_vcs_get_request_pci_domain_rc(rc_id);
        ctx.target_bdf = table_vcs_get_request_target_bdf_rc(rc_id);
        ctx.target_type = table_vcs_get_request_target_type_rc(rc_id);
        ctx.pf_index = table_vcs_get_request_pf_index_rc(rc_id);
        ctx.vf_index = table_vcs_get_request_vf_index_rc(rc_id);
        ctx.bar_index = table_vcs_get_request_bar_index_rc(rc_id);
        ctx.generation = table_vcs_get_request_generation_rc(rc_id);
        ctx.route_id = table_vcs_get_request_route_id_rc(rc_id);
        ctx.entry_count = table_vcs_get_request_entry_count_rc(rc_id);
        ctx.entry_bytes = table_vcs_get_request_entry_bytes_rc(rc_id);
        ctx.payload_bytes = table_vcs_get_request_payload_bytes_rc(rc_id);
        ctx.byte_offset = table_vcs_get_request_byte_offset_rc(rc_id);
        ctx.flags = table_vcs_get_request_flags_rc(rc_id);
        ctx.transaction_id = table_vcs_get_request_transaction_id_rc(rc_id);
        ctx.first_index = table_vcs_get_request_first_index_rc(rc_id);
        ctx.bar_offset = table_vcs_get_request_bar_offset_rc(rc_id);
        ctx.handler_name = handler_name;
        ctx.protection = active_protections[handler_name];
        ctx.protection_bits = new[0];
        return ctx;
    endfunction

    protected function string counter_key(input cosim_table_context ctx);
        return $sformatf("%0d/%0d/%s", rc_id, ctx.route_id,
                         ctx.handler_name);
    endfunction

    protected task log_raw_entry(
        input cosim_table_context ctx,
        input longint unsigned index,
        input byte unsigned raw_data[]
    );
        int unsigned shown;

        if (!high_log)
            return;
        shown = raw_data.size() < dump_limit ? raw_data.size() : dump_limit;
        $write("COSIM_TABLE_HIGH rc=%0d route=%0d transaction=0x%016h ",
               rc_id, ctx.route_id, ctx.transaction_id);
        $write("handler=%s index=%0d raw_bytes=", ctx.handler_name, index);
        for (int unsigned i = 0; i < shown; i++) begin
            if (i != 0)
                $write(" ");
            $write("%02x", raw_data[i]);
        end
        $display(" protection=%s protection_bits=%0d dump_bytes=%0d",
                 protection_name(ctx.protection), ctx.protection_bits.size(),
                 shown);
    endtask

    protected task log_handler_result(
        input cosim_table_context ctx,
        input longint unsigned index,
        input cosim_table_result result,
        input int unsigned committed
    );
        if (!high_log)
            return;
        $display({"COSIM_TABLE_HIGH rc=%0d route=%0d transaction=0x%016h ",
                  "handler=%s index=%0d protection=%s handler_result=%0d ",
                  "handler_error=%0d committed=%0d failed_index=0x%016h"},
                 rc_id, ctx.route_id, ctx.transaction_id, ctx.handler_name,
                 index, protection_name(ctx.protection), result.status,
                 result.handler_error, committed, result.failed_index);
    endtask

    protected task log_completion(
        input cosim_table_context ctx,
        input string key,
        input cosim_table_result completion,
        input int complete_result
    );
        if (!high_log)
            return;
        $display({"COSIM_TABLE_HIGH rc=%0d route=%0d transaction=0x%016h ",
                  "handler=%s completion_status=%0d completion_rc=%0d ",
                  "committed=%0d failed_index=0x%016h accepted=%0d ",
                  "entries=%0d bytes=%0d success=%0d reads=%0d errors=%0d"},
                 rc_id, ctx.route_id, ctx.transaction_id, ctx.handler_name,
                 completion.status, complete_result,
                 completion.committed_count, completion.failed_index,
                 accepted_counters[key], entry_counters[key],
                 byte_counters[key], success_counters[key],
                 read_counters[key], error_counters[key]);
    endtask

    protected task dispatch_write(
        input cosim_table_context ctx,
        output cosim_table_result completion
    );
        cosim_table_handler handler;
        cosim_table_codec_base selected_codec;
        cosim_table_result handler_result;
        cosim_table_context entry_ctx;
        byte unsigned payload[];
        byte unsigned raw_data[];
        bit protection_bits[];
        longint unsigned payload_word;
        longint unsigned expected_payload_bytes;
        longint unsigned last_index;
        longint unsigned index;
        int unsigned committed;
        string key;

        completion.status = COSIM_TABLE_STATUS_PROTOCOL;
        completion.failed_index = ctx.first_index;
        completion.committed_count = 0;
        completion.handler_error = 0;
        completion.read_data = '0;

        expected_payload_bytes = 64'(ctx.entry_count) * ctx.entry_bytes;
        if (ctx.entry_count == 0 || ctx.entry_bytes == 0 ||
            expected_payload_bytes > 64'hffff_ffff ||
            expected_payload_bytes != ctx.payload_bytes)
            return;
        last_index = ctx.first_index + ctx.entry_count - 1;
        if (last_index < ctx.first_index)
            return;

        handler = registry.lookup(ctx.handler_name);
        if (handler == null) begin
            completion.status = COSIM_TABLE_STATUS_EXEC_ERROR;
            completion.handler_error = -1;
            return;
        end
        if (!registry.resolve_codec(ctx.handler_name, ctx.protection,
                                    selected_codec)) begin
            completion.status = COSIM_TABLE_STATUS_EXEC_ERROR;
            completion.handler_error = -2;
            return;
        end

        payload = new[ctx.payload_bytes];
        foreach (payload[i]) begin
            if ((i % 8) == 0)
                payload_word = table_vcs_get_request_payload_u64_rc(rc_id,
                                                                    i / 8);
            payload[i] = byte'(payload_word >> ((i % 8) * 8));
        end

        committed = 0;
        key = counter_key(ctx);
        for (int unsigned entry = 0; entry < ctx.entry_count; entry++) begin
            index = ctx.first_index + entry;
            raw_data = new[ctx.entry_bytes];
            foreach (raw_data[i])
                raw_data[i] = payload[entry * ctx.entry_bytes + i];

            selected_codec.protect_entry(raw_data, ctx.protection,
                                         protection_bits);
            entry_ctx = ctx;
            entry_ctx.protection_bits = new[protection_bits.size()];
            foreach (protection_bits[i])
                entry_ctx.protection_bits[i] = protection_bits[i];
            log_raw_entry(entry_ctx, index, raw_data);

            handler.write_entry(entry_ctx, index, raw_data, handler_result);
            entry_counters[key]++;
            byte_counters[key] += raw_data.size();
            if (handler_result.status != COSIM_TABLE_STATUS_SUCCESS) begin
                completion.status = COSIM_TABLE_STATUS_EXEC_ERROR;
                completion.failed_index = index;
                completion.committed_count = committed;
                completion.handler_error = handler_result.handler_error;
                handler_result.failed_index = index;
                log_handler_result(entry_ctx, index, handler_result,
                                   committed);
                error_counters[key]++;
                return;
            end
            committed++;
            handler_result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            log_handler_result(entry_ctx, index, handler_result, committed);
        end

        completion.status = COSIM_TABLE_STATUS_SUCCESS;
        completion.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
        completion.committed_count = committed;
        completion.handler_error = 0;
        success_counters[key]++;
    endtask

    protected task dispatch_read(
        input cosim_table_context ctx,
        output cosim_table_result completion
    );
        cosim_table_handler handler;
        cosim_table_result handler_result;
        bit [31:0] read_data;
        string key;

        completion.status = COSIM_TABLE_STATUS_EXEC_ERROR;
        completion.failed_index = ctx.first_index;
        completion.committed_count = 0;
        completion.handler_error = 0;
        completion.read_data = '0;
        key = counter_key(ctx);

        if (ctx.entry_count != 1 || ctx.payload_bytes != 0 ||
            ctx.entry_bytes == 0 || ctx.byte_offset + 4 > ctx.entry_bytes) begin
            completion.status = COSIM_TABLE_STATUS_PROTOCOL;
            error_counters[key]++;
            return;
        end
        handler = registry.lookup(ctx.handler_name);
        if (handler == null || !handler.supports_read()) begin
            completion.handler_error = -1;
            error_counters[key]++;
            return;
        end

        handler.read_dword(ctx, ctx.first_index, ctx.byte_offset, read_data,
                           handler_result);
        read_counters[key]++;
        if (handler_result.status != COSIM_TABLE_STATUS_SUCCESS) begin
            completion.handler_error = handler_result.handler_error;
            error_counters[key]++;
        end else begin
            completion.status = COSIM_TABLE_STATUS_SUCCESS;
            completion.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            completion.read_data = read_data;
            success_counters[key]++;
        end
        log_handler_result(ctx, ctx.first_index, completion, 0);
    endtask

    task run();
        int poll_result;
        int request_kind;
        int complete_result;
        string handler_name;
        string key;
        cosim_table_context ctx;
        cosim_table_result completion;

        if (!initialized || running)
            return;
        running = 1'b1;
        stopped = 1'b0;
        stop_requested = 1'b0;

        while (!stop_requested) begin
            poll_result = table_vcs_poll_request_rc(rc_id);
            if (poll_result != 1)
                break;

            request_kind = table_vcs_get_request_kind_rc(rc_id);
            handler_name = table_vcs_get_request_handler_rc(rc_id);
            ctx = read_context(handler_name);
            key = counter_key(ctx);
            accepted_counters[key]++;

            case (request_kind)
                COSIM_TABLE_REQUEST_WRITE:
                    dispatch_write(ctx, completion);
                COSIM_TABLE_REQUEST_READ_DWORD:
                    dispatch_read(ctx, completion);
                default: begin
                    completion.status = COSIM_TABLE_STATUS_PROTOCOL;
                    completion.failed_index = ctx.first_index;
                    completion.committed_count = 0;
                    completion.handler_error = 0;
                    completion.read_data = '0;
                    error_counters[key]++;
                end
            endcase

            complete_result = table_vcs_complete_rc(
                rc_id, completion.status, completion.failed_index,
                completion.committed_count, completion.handler_error,
                completion.read_data);
            log_completion(ctx, key, completion, complete_result);
            if (complete_result != 0) begin
                stop_requested = 1'b1;
                table_vcs_interrupt_rc(rc_id);
            end
        end

        running = 1'b0;
        stopped = 1'b1;
        ->stopped_event;
    endtask

    function void request_stop();
        if (!initialized || stop_requested)
            return;
        stop_requested = 1'b1;
        table_vcs_interrupt_rc(rc_id);
    endfunction

    task wait_stopped();
        while (!stopped)
            @stopped_event;
    endtask

    function void shutdown();
        if (running || !stopped || c_state_cleaned)
            return;
        table_vcs_cleanup_rc(rc_id);
        c_state_cleaned = 1'b1;
        initialized = 1'b0;
    endfunction
endclass

`endif
