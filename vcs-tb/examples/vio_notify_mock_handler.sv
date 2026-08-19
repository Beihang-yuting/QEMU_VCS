`ifndef VIO_NOTIFY_MOCK_HANDLER_SV
`define VIO_NOTIFY_MOCK_HANDLER_SV

import cosim_table_pkg::*;

typedef bit [255:0] vio_notify_mock_value_t;

/*
 * Array-only reference model.  A production subclass keeps write_entry's
 * protection and index policy, then overrides deposit_l[123]() and
 * read_backend_dword() with the target's hierarchy macros/backdoor API.
 * For example, an override may call the user's generic form:
 *
 *   `ST_WRITE_DEPOSIT_RAM(index, value, path_macro)
 *
 * where this class supplies ram_index/bank as that override's physical index
 * and path selector.
 *
 * The production subclass owns the DUT-specific data/protection packing if
 * its RAM word differs from this illustrative raw-LSB/protection-MSB layout.
 */
class vio_notify_mock_handler extends cosim_table_handler;
    protected string handler_name;
    protected bit read_capable;

    int unsigned l3_write_count;
    int unsigned l2_write_count;
    int unsigned l1_write_count;
    int unsigned read_count;
    cosim_table_protection_e last_protection;

    longint unsigned l3_logical_index[1024];
    longint unsigned l2_logical_index[1024];
    longint unsigned l1_logical_index[1024];
    int unsigned l3_bank[1024];
    int unsigned l2_bank[1024];
    int unsigned l1_bank[1024];
    longint unsigned l3_ram_index[1024];
    longint unsigned l2_ram_index[1024];
    longint unsigned l1_ram_index[1024];
    vio_notify_mock_value_t l3_value[1024];
    vio_notify_mock_value_t l2_value[1024];
    vio_notify_mock_value_t l1_value[1024];

    function new(string handler_name = "vio_notify", bit read_capable = 1'b0);
        this.handler_name = handler_name;
        this.read_capable = read_capable;
        l3_write_count = 0;
        l2_write_count = 0;
        l1_write_count = 0;
        read_count = 0;
        last_protection = COSIM_TABLE_PROTECTION_NONE;
    endfunction

    virtual function string get_name();
        return handler_name;
    endfunction

    virtual function bit supports_read();
        return read_capable;
    endfunction

    protected function bit high_logging_enabled();
        string value;
        return $value$plusargs("COSIM_TABLE_LOG=%s", value) && value == "high";
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

    protected virtual function vio_notify_mock_value_t pack_value(
        input byte unsigned raw_data[],
        input bit protection_bits[]
    );
        vio_notify_mock_value_t value;

        value = '0;
        foreach (raw_data[i]) begin
            if (i * 8 + 7 < $bits(value))
                value[i * 8 +: 8] = raw_data[i];
        end
        foreach (protection_bits[i]) begin
            if (raw_data.size() * 8 + i < $bits(value))
                value[raw_data.size() * 8 + i] = protection_bits[i];
        end
        return value;
    endfunction

    virtual task deposit_l3(
        input longint unsigned logical_index,
        input int unsigned bank,
        input longint unsigned ram_index,
        input vio_notify_mock_value_t value
    );
        int unsigned slot;

        slot = l3_write_count;
        if (slot < 1024) begin
            l3_logical_index[slot] = logical_index;
            l3_bank[slot] = bank;
            l3_ram_index[slot] = ram_index;
            l3_value[slot] = value;
        end
        l3_write_count++;
        if (high_logging_enabled())
            $display({"COSIM_TABLE_MOCK_HIGH handler=%s logical_index=%0d ",
                      "destination=l3 bank=%0d ram_index=%0d value=0x%064h"},
                     handler_name, logical_index, bank, ram_index, value);
    endtask

    virtual task deposit_l2(
        input longint unsigned logical_index,
        input int unsigned bank,
        input longint unsigned ram_index,
        input vio_notify_mock_value_t value
    );
        int unsigned slot;

        slot = l2_write_count;
        if (slot < 1024) begin
            l2_logical_index[slot] = logical_index;
            l2_bank[slot] = bank;
            l2_ram_index[slot] = ram_index;
            l2_value[slot] = value;
        end
        l2_write_count++;
        if (high_logging_enabled())
            $display({"COSIM_TABLE_MOCK_HIGH handler=%s logical_index=%0d ",
                      "destination=l2 bank=%0d ram_index=%0d value=0x%064h"},
                     handler_name, logical_index, bank, ram_index, value);
    endtask

    virtual task deposit_l1(
        input longint unsigned logical_index,
        input int unsigned bank,
        input longint unsigned ram_index,
        input vio_notify_mock_value_t value
    );
        int unsigned slot;

        slot = l1_write_count;
        if (slot < 1024) begin
            l1_logical_index[slot] = logical_index;
            l1_bank[slot] = bank;
            l1_ram_index[slot] = ram_index;
            l1_value[slot] = value;
        end
        l1_write_count++;
        if (high_logging_enabled())
            $display({"COSIM_TABLE_MOCK_HIGH handler=%s logical_index=%0d ",
                      "destination=l1 bank=%0d ram_index=%0d value=0x%064h"},
                     handler_name, logical_index, bank, ram_index, value);
    endtask

    virtual task read_backend_dword(
        input longint unsigned logical_index,
        input int unsigned byte_offset,
        output bit found,
        output bit [31:0] data
    );
        found = 1'b0;
        data = '0;
        for (int unsigned slot = 0;
             slot < l3_write_count && slot < 1024;
             slot++) begin
            if (l3_logical_index[slot] == logical_index &&
                byte_offset + 4 <= 16) begin
                data = l3_value[slot][byte_offset * 8 +: 32];
                found = 1'b1;
            end
        end
    endtask

    virtual task write_entry(
        cosim_table_context ctx,
        longint unsigned index,
        byte unsigned raw_data[],
        output cosim_table_result result
    );
        vio_notify_mock_value_t value;
        int unsigned bank;
        longint unsigned ram_index;

        value = pack_value(raw_data, ctx.protection_bits);
        last_protection = ctx.protection;
        if (high_logging_enabled())
            $display({"COSIM_TABLE_MOCK_HIGH handler=%s logical_index=%0d ",
                      "protection=%s final_protected_value=0x%064h"},
                     handler_name, index, protection_name(ctx.protection),
                     value);

        bank = int'(index % 4);
        ram_index = index / 4;
        deposit_l3(index, bank, ram_index, value);

        if (index >= 15) begin
            bank = int'((((index + 1) / 16) - 1) % 4);
            ram_index = ((index - 15) / 16) / 4;
            deposit_l2(index, bank, ram_index, value);
        end

        if (index >= 255) begin
            bank = int'((((index + 1) / 256) - 1) % 4);
            ram_index = ((index - 255) / 256) / 4;
            deposit_l1(index, bank, ram_index, value);
        end

        result.status = COSIM_TABLE_STATUS_SUCCESS;
        result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
        result.committed_count = 1;
        result.handler_error = 0;
        result.read_data = '0;
        cosim_table_result_mark_valid(result);
    endtask

    virtual task read_dword(
        cosim_table_context ctx,
        longint unsigned index,
        int unsigned byte_offset,
        output bit [31:0] data,
        output cosim_table_result result
    );
        bit found;

        read_count++;
        read_backend_dword(index, byte_offset, found, data);
        if (!read_capable || !found) begin
            data = '0;
            result.status = COSIM_TABLE_STATUS_EXEC_ERROR;
            result.failed_index = index;
            result.committed_count = 0;
            result.handler_error = -1;
            result.read_data = '0;
        end else begin
            result.status = COSIM_TABLE_STATUS_SUCCESS;
            result.failed_index = COSIM_TABLE_FAILED_INDEX_NONE;
            result.committed_count = 0;
            result.handler_error = 0;
            result.read_data = data;
        end
        cosim_table_result_mark_valid(result);
        if (high_logging_enabled())
            $display({"COSIM_TABLE_MOCK_HIGH handler=%s logical_index=%0d ",
                      "read_byte_offset=%0d read_data=0x%08h"},
                     handler_name, index, byte_offset, data);
    endtask
endclass

`endif
