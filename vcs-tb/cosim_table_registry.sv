`ifndef COSIM_TABLE_REGISTRY_SV
`define COSIM_TABLE_REGISTRY_SV

class cosim_table_registry;
    protected cosim_table_handler handlers[string];
    protected cosim_table_protection_e default_protections[string];
    protected cosim_table_builtin_codec builtin_codec;

    function new();
        builtin_codec = new();
    endfunction

    function bit register_handler(
        cosim_table_handler handler,
        cosim_table_protection_e default_protection
    );
        string name;

        if (handler == null)
            return 1'b0;
        name = handler.get_name();
        if (name.len() == 0 || handlers.exists(name))
            return 1'b0;
        if (default_protection == COSIM_TABLE_PROTECTION_CUSTOM &&
            handler.get_codec() == null)
            return 1'b0;

        handlers[name] = handler;
        default_protections[name] = default_protection;
        return 1'b1;
    endfunction

    function cosim_table_handler lookup(input string name);
        if (handlers.exists(name))
            return handlers[name];
        return null;
    endfunction

    function bit get_default_protection(
        input string name,
        output cosim_table_protection_e protection
    );
        if (!default_protections.exists(name))
            return 1'b0;
        protection = default_protections[name];
        return 1'b1;
    endfunction

    function bit resolve_codec(
        input string name,
        input cosim_table_protection_e protection,
        output cosim_table_codec_base selected_codec
    );
        cosim_table_handler handler;

        selected_codec = null;
        if (!handlers.exists(name))
            return 1'b0;
        handler = handlers[name];
        if (protection == COSIM_TABLE_PROTECTION_CUSTOM) begin
            selected_codec = handler.get_codec();
            return selected_codec != null;
        end
        selected_codec = builtin_codec;
        return 1'b1;
    endfunction
endclass

`endif
