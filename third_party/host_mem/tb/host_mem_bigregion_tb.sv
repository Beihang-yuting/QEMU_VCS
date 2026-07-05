`ifndef HOST_MEM_BIGREGION_TB_SV
`define HOST_MEM_BIGREGION_TB_SV

`include "uvm_macros.svh"

// Reproduce 32-bit arithmetic overflow in buddy allocator with 4GB region.
// init_region(0, 0xFFFF_FFFF, MODE_BUDDY, 16) then alloc/write/read/free.
//
// Expected failure (before fix): wrong addresses, FATAL, or data corruption
// due to addr_to_level() truncating longint->int and buddy split overflow.

program host_mem_bigregion_tb;

    import uvm_pkg::*;
    import host_mem_pkg::*;

    `include "host_mem_manager.sv"

    host_mem_manager mem;
    bit [63:0] addr1, addr2, addr3;
    byte wdata[], rdata[];
    int unsigned mismatch;
    bit cmp_result;

    initial begin

        $display("\n=== Big-Region Buddy Test: 4GB region ===");
        $display("  init_region(0, 0xFFFF_FFFF, MODE_BUDDY, 16)");

        mem = new("big_buddy");
        // 4 GB region: base=0, end=0xFFFF_FFFF (inclusive), granule=16
        mem.init_region(64'h0, 64'hFFFF_FFFF, MODE_BUDDY, 16);

        $display("  init done, allocating...");

        // Alloc 1: 256 bytes, align 64
        `host_mem_alloc(mem, addr1, 256, 64);
        if (addr1 == '1) begin
            $display("FAIL: alloc(256,64) returned ~0");
            $fatal(1, "alloc failed on 4GB region");
        end
        $display("  alloc1=0x%016h (expect addr < 4GB)", addr1);
        assert(addr1 < 64'h1_0000_0000)
            else $fatal(1, $sformatf("alloc1 addr=0x%016h out of 4GB region!", addr1));
        assert((addr1 % 64) == 0)
            else $fatal(1, $sformatf("alloc1 alignment fail: addr=0x%016h", addr1));

        // Alloc 2: 128 bytes, align 128
        `host_mem_alloc(mem, addr2, 128, 128);
        if (addr2 == '1) begin
            $display("FAIL: alloc(128,128) returned ~0");
            $fatal(1, "alloc2 failed on 4GB region");
        end
        $display("  alloc2=0x%016h", addr2);
        assert(addr2 < 64'h1_0000_0000)
            else $fatal(1, $sformatf("alloc2 addr=0x%016h out of 4GB region!", addr2));
        assert((addr2 % 128) == 0)
            else $fatal(1, $sformatf("alloc2 alignment fail: addr=0x%016h", addr2));

        // Alloc 3: 512 bytes, align 64
        `host_mem_alloc(mem, addr3, 512, 64);
        if (addr3 == '1) begin
            $display("FAIL: alloc(512,64) returned ~0");
            $fatal(1, "alloc3 failed on 4GB region");
        end
        $display("  alloc3=0x%016h", addr3);
        assert(addr3 < 64'h1_0000_0000)
            else $fatal(1, $sformatf("alloc3 addr=0x%016h out of 4GB region!", addr3));

        // No overlap check
        assert(addr1 + 256 <= addr2 || addr2 + 128 <= addr1)
            else $fatal(1, "OVERLAP: addr1 and addr2");
        assert(addr1 + 256 <= addr3 || addr3 + 512 <= addr1)
            else $fatal(1, "OVERLAP: addr1 and addr3");
        assert(addr2 + 128 <= addr3 || addr3 + 512 <= addr2)
            else $fatal(1, "OVERLAP: addr2 and addr3");

        // Write/read roundtrip on addr1
        wdata = new[256];
        foreach (wdata[i]) wdata[i] = byte'(i ^ 8'hA5);
        `host_mem_write(mem, addr1, wdata);
        `host_mem_read(mem, addr1, 256, rdata);
        foreach (rdata[i])
            assert(rdata[i] == wdata[i])
                else $fatal(1, $sformatf("data mismatch at byte %0d: exp=0x%02h got=0x%02h",
                    i, wdata[i], rdata[i]));
        $display("  write/read roundtrip addr1 (256B) OK");

        // Write/read roundtrip on addr2
        wdata = new[128];
        foreach (wdata[i]) wdata[i] = byte'(i ^ 8'h5A);
        `host_mem_write(mem, addr2, wdata);
        `host_mem_read(mem, addr2, 128, rdata);
        foreach (rdata[i])
            assert(rdata[i] == wdata[i])
                else $fatal(1, $sformatf("addr2 data mismatch at %0d", i));
        $display("  write/read roundtrip addr2 (128B) OK");

        // Free all
        `host_mem_free(mem, addr1);
        `host_mem_free(mem, addr2);
        `host_mem_free(mem, addr3);
        $display("  free all OK");

        // Leak check
        `host_mem_leak_check(mem);
        $display("  leak_check passed");

        // Alloc a medium block to verify merging works
        `host_mem_alloc(mem, addr1, 65536, 4096);
        assert(addr1 != '1)
            else $fatal(1, "alloc(65536,4096) after free failed - merge broken?");
        $display("  post-free re-alloc 64KB OK at 0x%016h", addr1);
        `host_mem_free(mem, addr1);
        `host_mem_leak_check(mem);

        $display("\n========================================");
        $display("BIG-REGION TEST PASSED");
        $display("========================================\n");
        $finish;
    end

endprogram

`endif
