`timescale 1ns/1ps

module test_cosim_cpl_payload_codec;
    import cosim_xrc_utils_pkg::*;

    byte unsigned payload[];
    bit [31:0] dword;

    task automatic expect_dword(
        input string name,
        input int unsigned base,
        input bit [31:0] expected
    );
        dword = cosim_pack_cpl_dword_le(payload, base);
        if (dword !== expected)
            $fatal(1, "%s: got 0x%08h, expected 0x%08h",
                   name, dword, expected);
    endtask

    initial begin
        payload = new[9];
        payload[0] = 8'h08;
        payload[1] = 8'h00;
        payload[2] = 8'h00;
        payload[3] = 8'h00;
        expect_dword("AF valid bit", 0, 32'h0000_0008);

        payload[0] = 8'h78;
        payload[1] = 8'h56;
        payload[2] = 8'h34;
        payload[3] = 8'h12;
        expect_dword("little-endian DWORD", 0, 32'h1234_5678);

        payload[4] = 8'h89;
        payload[5] = 8'hab;
        payload[6] = 8'hcd;
        payload[7] = 8'hef;
        expect_dword("second DWORD", 4, 32'hefcd_ab89);

        payload[8] = 8'h5a;
        expect_dword("partial DWORD zero fill", 8, 32'h0000_005a);

        $display("PASS: cosim Completion payload little-endian packing");
        $finish;
    end
endmodule
