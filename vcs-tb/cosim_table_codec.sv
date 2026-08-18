`ifndef COSIM_TABLE_CODEC_SV
`define COSIM_TABLE_CODEC_SV

virtual class cosim_table_codec_base;
    pure virtual function void protect_entry(
        input byte unsigned raw_data[],
        input cosim_table_protection_e protection,
        output bit protection_bits[]
    );
endclass

class cosim_table_builtin_codec extends cosim_table_codec_base;
    function automatic bit is_power_of_two(input int unsigned value);
        return value != 0 && ((value & (value - 1)) == 0);
    endfunction

    function void pack_raw_lsb_first(
        input byte unsigned raw_data[],
        output bit data_bits[]
    );
        int unsigned byte_index;
        int unsigned bit_index;

        data_bits = new[raw_data.size() * 8];
        foreach (raw_data[byte_index]) begin
            for (bit_index = 0; bit_index < 8; bit_index++)
                data_bits[byte_index * 8 + bit_index] =
                    raw_data[byte_index][bit_index];
        end
    endfunction

    protected function void protect_parity(
        input byte unsigned raw_data[],
        input bit odd,
        output bit protection_bits[]
    );
        int unsigned byte_index;

        protection_bits = new[raw_data.size()];
        foreach (raw_data[byte_index])
            protection_bits[byte_index] = (^raw_data[byte_index]) ^ odd;
    endfunction

    protected function void protect_secded(
        input byte unsigned raw_data[],
        output bit protection_bits[]
    );
        bit data_bits[];
        bit encoded_bits[];
        int unsigned data_count;
        int unsigned parity_count;
        int unsigned encoded_count;
        int unsigned position;
        int unsigned parity_index;
        int unsigned data_index;
        bit parity;
        bit overall;

        pack_raw_lsb_first(raw_data, data_bits);
        data_count = data_bits.size();
        parity_count = 0;
        while ((64'(1) << parity_count) <
               (data_count + parity_count + 1))
            parity_count++;

        encoded_count = data_count + parity_count;
        encoded_bits = new[encoded_count + 1];
        data_index = 0;
        for (position = 1; position <= encoded_count; position++) begin
            if (!is_power_of_two(position)) begin
                encoded_bits[position] = data_bits[data_index];
                data_index++;
            end
        end

        for (parity_index = 0;
             parity_index < parity_count;
             parity_index++) begin
            parity = 1'b0;
            for (position = 1; position <= encoded_count; position++) begin
                if ((position & (64'(1) << parity_index)) != 0)
                    parity ^= encoded_bits[position];
            end
            encoded_bits[64'(1) << parity_index] = parity;
        end

        overall = 1'b0;
        for (position = 1; position <= encoded_count; position++)
            overall ^= encoded_bits[position];
        encoded_bits[0] = overall;

        protection_bits = new[parity_count + 1];
        for (parity_index = 0;
             parity_index < parity_count;
             parity_index++)
            protection_bits[parity_index] =
                encoded_bits[64'(1) << parity_index];
        protection_bits[parity_count] = encoded_bits[0];
    endfunction

    virtual function void protect_entry(
        input byte unsigned raw_data[],
        input cosim_table_protection_e protection,
        output bit protection_bits[]
    );
        case (protection)
            COSIM_TABLE_PROTECTION_NONE:
                protection_bits = new[0];
            COSIM_TABLE_PROTECTION_PARITY_EVEN:
                protect_parity(raw_data, 1'b0, protection_bits);
            COSIM_TABLE_PROTECTION_PARITY_ODD:
                protect_parity(raw_data, 1'b1, protection_bits);
            COSIM_TABLE_PROTECTION_ECC,
            COSIM_TABLE_PROTECTION_SECDED:
                protect_secded(raw_data, protection_bits);
            default:
                protection_bits = new[0];
        endcase
    endfunction
endclass

`endif
