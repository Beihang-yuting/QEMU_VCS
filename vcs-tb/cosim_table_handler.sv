`ifndef COSIM_TABLE_HANDLER_SV
`define COSIM_TABLE_HANDLER_SV

virtual class cosim_table_handler;
    protected cosim_table_codec_base codec;

    pure virtual function string get_name();

    pure virtual task write_entry(
        cosim_table_context ctx,
        longint unsigned index,
        byte unsigned raw_data[],
        output cosim_table_result result
    );

    virtual task read_dword(
        cosim_table_context ctx,
        longint unsigned index,
        int unsigned byte_offset,
        output bit [31:0] data,
        output cosim_table_result result
    );
        data = '0;
        result.status = COSIM_TABLE_STATUS_UNSUPPORTED;
        result.failed_index = index;
        result.committed_count = 0;
        result.handler_error = 0;
        result.read_data = '0;
        cosim_table_result_mark_valid(result);
    endtask

    virtual function bit supports_read();
        return 1'b0;
    endfunction

    virtual function void set_codec(cosim_table_codec_base codec);
        this.codec = codec;
    endfunction

    function cosim_table_codec_base get_codec();
        return codec;
    endfunction
endclass

`endif
