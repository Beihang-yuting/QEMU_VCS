`ifndef HOST_MEM_TB_SV
`define HOST_MEM_TB_SV

`include "uvm_macros.svh"

program host_mem_tb;

    import uvm_pkg::*;
    import host_mem_pkg::*;

    `include "host_mem_manager.sv"

    // UVM report catcher to capture expected FATAL/ERROR messages
    class expected_msg_catcher extends uvm_report_catcher;
        string expected_id;
        bit    caught;

        function new(string name = "expected_msg_catcher");
            super.new(name);
            caught = 0;
        endfunction

        function action_e catch();
            if (get_id() == expected_id) begin
                caught = 1;
                return CAUGHT;
            end
            return THROW;
        endfunction
    endclass

    // All variable declarations at module level
    host_mem_manager mem;
    bit [63:0] addr1, addr2, addr3;
    byte wdata[], rdata[];
    int unsigned mismatch;
    bit cmp_result;
    expected_msg_catcher catcher;
    byte one_byte[];
    byte small_data[];
    byte dummy[];

    // Test 11 variables
    host_mem_manager big_mem;
    bit [63:0] big_addrs[256];
    int unsigned big_sizes[256];
    int unsigned alloc_ok;
    int unsigned seed;
    byte wd[], rd[];

    // Test 12 variables
    host_mem_manager cycle_mem;
    bit [63:0] cycle_addrs[128];
    int unsigned cycle_count;
    int unsigned ok_count;
    bit [63:0] big_addr;

    // Test 13 variables
    host_mem_manager dma_mem;
    bit [63:0] dma_addr;
    int unsigned chunk_size;
    int unsigned total_chunks;
    bit [63:0] realloc_addr;

    // Test 14 variables
    host_mem_manager mr_mem;
    bit [63:0] a1, a2, a3;

    // Test 15 variables
    host_mem_manager thrash_mem;
    bit [63:0] t_addr;

    // Test 16 variables
    host_mem_manager rand_mem;
    bit [63:0] pool[$];
    int unsigned pool_sizes[bit[63:0]];
    int unsigned seed2;
    int unsigned alloc_ops, free_ops;
    int unsigned r, sz, al, idx;
    bit [63:0] a, fa;

    integer i_iter, j_iter, op_iter;

    // Test 17 variables - 10K stress test
    host_mem_manager stress_mem;
    bit [63:0] stress_pool[$];
    int unsigned stress_pool_sizes[bit[63:0]];
    byte stress_pool_tags[bit[63:0]];  // tag per block for data verify
    int unsigned stress_seed;
    int unsigned stress_alloc_ok, stress_alloc_fail;
    int unsigned stress_free_ok;
    int unsigned stress_dup_detected;
    int unsigned stress_data_err;
    int unsigned stress_total_ops;
    bit [63:0] stress_addr;
    bit [63:0] stress_live_set[bit[63:0]];  // addr -> 1, for dup detection
    int unsigned stress_sz, stress_al, stress_r, stress_idx;
    byte stress_tag;
    bit [63:0] stress_fa;

    // Test 18 variables - linear mode small CPU memory
    host_mem_manager lin_mem;
    bit [63:0] lin_addrs[4];
    int unsigned lin_sizes[4] = '{100, 200, 1000, 17000};  // odd sizes - buddy would round to 128/256/1024/32768
    int unsigned lin_total_occ;
    bit [63:0] lin_big;
    byte lin_wd[], lin_rd[];

    // Test 19 variables - linear arbitrary-order free
    host_mem_manager lin2_mem;
    bit [63:0] lin2_addrs[8];
    bit [63:0] lin2_after;

    // Test 20 variables - linear 15K random stress (mirrors test 17)
    host_mem_manager lstr_mem;
    bit [63:0] lstr_pool[$];
    int unsigned lstr_pool_sizes[bit[63:0]];
    byte lstr_pool_tags[bit[63:0]];
    bit [63:0] lstr_live_set[bit[63:0]];
    int unsigned lstr_seed;
    int unsigned lstr_alloc_ok, lstr_alloc_fail, lstr_free_ok;
    int unsigned lstr_dup_detected, lstr_data_err;
    int unsigned lstr_total_ops;
    bit [63:0] lstr_addr, lstr_fa;
    int unsigned lstr_sz, lstr_al, lstr_r, lstr_idx;
    byte lstr_tag;

    // Test 21 variables - buddy mode mixed alloc/free/release_range random
    host_mem_manager bm_mem;
    bit [63:0] bm_pool[$];
    int unsigned bm_pool_sizes[bit[63:0]];
    byte bm_pool_tags[bit[63:0]];
    int unsigned bm_seed;
    int unsigned bm_alloc_ok, bm_free_ok, bm_release_ok, bm_data_err;
    int unsigned bm_total_ops;
    bit [63:0] bm_addr, bm_fa;
    int unsigned bm_sz, bm_al, bm_r, bm_idx;
    byte bm_tag;
    int unsigned bm_rel_size;

    // Test 22 variables - linear fragmentation merge stress
    host_mem_manager lf_mem;
    bit [63:0] lf_addrs[200];
    int unsigned lf_sizes[200];
    bit lf_alive[200];
    int unsigned lf_seed;
    bit [63:0] lf_big_addr;
    int unsigned lf_alive_count;
    int unsigned lf_free_count;

    // Test 23 - granule (4/16/64) comparison for 16B-heavy workload
    host_mem_manager g_mem[3];
    int unsigned g_granules[3] = '{4, 16, 64};
    bit [63:0] g_addrs[500];
    int unsigned g_idx;
    bit [63:0] g_big16;
    int unsigned g_eff_granule;
    int unsigned g_per_block_occ;
    int unsigned g_total_occ;

    initial begin

        // ========================================
        // Test 1: Basic init and alloc
        // ========================================
        $display("\n=== Test 1: Basic init and alloc ===");
        mem = new("mem0");
        mem.init_region(64'h0, 64'hFFFF);  // 64KB

        `host_mem_alloc(mem, addr1, 100, 64);
        assert(addr1 != '1) else $fatal(1, "alloc failed");
        assert((addr1 % 64) == 0) else $fatal(1, "alignment check failed");
        $display("Test 1 PASSED: alloc returned 0x%016h", addr1);

        // ========================================
        // Test 2: Write and read back
        // ========================================
        $display("\n=== Test 2: Write and read back ===");
        wdata = new[100];
        foreach (wdata[i]) wdata[i] = i;
        `host_mem_write(mem, addr1, wdata);

        `host_mem_read(mem, addr1, 100, rdata);
        foreach (rdata[i])
            assert(rdata[i] == wdata[i]) else $fatal(1, $sformatf("data mismatch at %0d", i));
        $display("Test 2 PASSED: write/read 100 bytes OK");

        // ========================================
        // Test 3: Multiple allocations, no overlap
        // ========================================
        $display("\n=== Test 3: Multiple allocations ===");
        `host_mem_alloc(mem, addr2, 200, 128);
        `host_mem_alloc(mem, addr3, 4, 4);
        assert(addr2 != '1 && addr3 != '1) else $fatal(1, "alloc failed");
        assert(addr2 + 200 <= addr3 || addr3 + 4 <= addr2)
            else $fatal(1, "allocations overlap!");
        $display("Test 3 PASSED: addr2=0x%016h addr3=0x%016h", addr2, addr3);

        // ========================================
        // Test 4: Free and re-alloc (buddy merge)
        // ========================================
        $display("\n=== Test 4: Free and re-alloc ===");
        `host_mem_free(mem, addr1);
        `host_mem_free(mem, addr2);
        `host_mem_free(mem, addr3);
        `host_mem_alloc(mem, addr1, 32768);
        assert(addr1 != '1) else $fatal(1, "large alloc after free failed");
        `host_mem_free(mem, addr1);
        $display("Test 4 PASSED: free+merge+realloc OK");

        // ========================================
        // Test 5: memset, memcpy, compare
        // ========================================
        $display("\n=== Test 5: Bulk operations ===");
        `host_mem_alloc(mem, addr1, 256);
        `host_mem_alloc(mem, addr2, 256);

        `host_mem_set(mem, addr1, 8'hAA, 256);
        `host_mem_cpy(mem, addr2, addr1, 256);
        `host_mem_compare(mem, cmp_result, addr1, addr2, 256, mismatch);
        assert(cmp_result) else $fatal(1, $sformatf("compare failed at offset %0d", mismatch));

        one_byte = '{8'hBB};
        `host_mem_write(mem, addr2 + 100, one_byte);
        `host_mem_compare(mem, cmp_result, addr1, addr2, 256, mismatch);
        assert(!cmp_result) else $fatal(1, "compare should have found mismatch");
        assert(mismatch == 100) else $fatal(1, $sformatf("expected mismatch at 100, got %0d", mismatch));
        $display("Test 5 PASSED: memset/memcpy/compare OK");

        `host_mem_free(mem, addr1);
        `host_mem_free(mem, addr2);

        // ========================================
        // Test 6: release_range partial free
        // ========================================
        $display("\n=== Test 6: release_range ===");
        `host_mem_alloc(mem, addr1, 256);
        wdata = new[256];
        foreach (wdata[i]) wdata[i] = i;
        `host_mem_write(mem, addr1, wdata);

        `host_mem_release_range(mem, addr1, 64);

        catcher = new("catcher6");
        catcher.expected_id = "HOST_MEM";
        uvm_report_cb::add(null, catcher);
        small_data = '{8'h00};
        `host_mem_write(mem, addr1, small_data);
        assert(catcher.caught) else $fatal(1, "Expected FATAL for write to released range");
        uvm_report_cb::delete(null, catcher);

        `host_mem_read(mem, addr1 + 64, 64, rdata);
        assert(rdata[0] == 64) else $fatal(1, "read from valid range failed");

        `host_mem_release_range(mem, addr1 + 64, 64);
        `host_mem_release_range(mem, addr1 + 128, 128);
        $display("Test 6 PASSED: release_range OK");

        // ========================================
        // Test 7: Debug output
        // ========================================
        $display("\n=== Test 7: Debug output ===");
        `host_mem_alloc(mem, addr1, 128);
        wdata = new[128];
        foreach (wdata[i]) wdata[i] = i;
        `host_mem_write(mem, addr1, wdata);

        mem.hexdump(addr1, 128);
        mem.print_alloc_table();
        mem.print_stats();
        mem.print_history(5);

        // ========================================
        // Test 8: Leak check
        // ========================================
        $display("\n=== Test 8: Leak check ===");
        `host_mem_leak_check(mem);

        `host_mem_free(mem, addr1);
        `host_mem_leak_check(mem);

        // ========================================
        // Test 9: Double-free detection
        // ========================================
        $display("\n=== Test 9: Double-free detection ===");
        `host_mem_alloc(mem, addr1, 64);
        `host_mem_free(mem, addr1);

        catcher = new("catcher9");
        catcher.expected_id = "HOST_MEM";
        uvm_report_cb::add(null, catcher);
        `host_mem_free(mem, addr1);
        assert(catcher.caught) else $fatal(1, "Expected FATAL for double-free");
        uvm_report_cb::delete(null, catcher);
        $display("Test 9 PASSED: double-free detected");

        // ========================================
        // Test 10: Unallocated access detection
        // ========================================
        $display("\n=== Test 10: Unallocated access ===");
        catcher = new("catcher10");
        catcher.expected_id = "HOST_MEM";
        uvm_report_cb::add(null, catcher);
        `host_mem_read(mem, 64'hDEAD_0000, 4, dummy);
        assert(catcher.caught) else $fatal(1, "Expected FATAL for unallocated read");
        uvm_report_cb::delete(null, catcher);
        $display("Test 10 PASSED: unallocated access detected");

        // ========================================
        // Test 11: Large-scale allocation stress test
        // ========================================
        $display("\n=== Test 11: Large-scale allocation stress (1MB region, 256 random allocs) ===");

        big_mem = new("big_mem");
        big_mem.init_region(64'h0, 64'hF_FFFF);  // 1MB region

        // Phase 1: Allocate 256 blocks with random sizes (4B ~ 4KB)
        alloc_ok = 0;
        seed = 42;
        for (i_iter = 0; i_iter < 256; i_iter++) begin
            big_sizes[i_iter] = (($urandom(seed) % 4093) + 4);  // 4 ~ 4096
            `host_mem_alloc(big_mem, big_addrs[i_iter], big_sizes[i_iter], 64);
            if (big_addrs[i_iter] != '1) begin
                alloc_ok++;
            end
        end
        $display("  Phase 1: %0d / 256 allocations succeeded", alloc_ok);
        assert(alloc_ok > 100) else $fatal(1, "Too few allocations succeeded");

        // Phase 2: Verify no overlap between all allocated blocks
        for (i_iter = 0; i_iter < 256; i_iter++) begin
            if (big_addrs[i_iter] == '1) continue;
            for (j_iter = i_iter + 1; j_iter < 256; j_iter++) begin
                if (big_addrs[j_iter] == '1) continue;
                assert(big_addrs[i_iter] + big_sizes[i_iter] <= big_addrs[j_iter] || big_addrs[j_iter] + big_sizes[j_iter] <= big_addrs[i_iter])
                    else $fatal(1, $sformatf("Overlap detected: block[%0d]=0x%h+%0d vs block[%0d]=0x%h+%0d",
                        i_iter, big_addrs[i_iter], big_sizes[i_iter], j_iter, big_addrs[j_iter], big_sizes[j_iter]));
            end
        end
        $display("  Phase 2: No overlap detected among %0d blocks", alloc_ok);

        // Phase 3: Write unique pattern to each block and read back
        for (i_iter = 0; i_iter < 256; i_iter++) begin
            if (big_addrs[i_iter] == '1) continue;
            wd = new[big_sizes[i_iter]];
            foreach (wd[b]) wd[b] = (i_iter + b) & 8'hFF;
            `host_mem_write(big_mem, big_addrs[i_iter], wd);
        end
        for (i_iter = 0; i_iter < 256; i_iter++) begin
            if (big_addrs[i_iter] == '1) continue;
            `host_mem_read(big_mem, big_addrs[i_iter], big_sizes[i_iter], rd);
            foreach (rd[b])
                assert(rd[b] == byte'((i_iter + b) & 8'hFF))
                    else $fatal(1, $sformatf("Data mismatch: block[%0d] offset %0d", i_iter, b));
        end
        $display("  Phase 3: Write/read verify passed for all %0d blocks", alloc_ok);

        // Phase 4: Free all
        for (i_iter = 0; i_iter < 256; i_iter++) begin
            if (big_addrs[i_iter] == '1) continue;
            `host_mem_free(big_mem, big_addrs[i_iter]);
        end
        `host_mem_leak_check(big_mem);

        big_mem.print_stats();
        $display("Test 11 PASSED: large-scale alloc stress OK");

        // ========================================
        // Test 12: Alloc-free-realloc cycle stress (fragmentation + merge)
        // ========================================
        $display("\n=== Test 12: Alloc-free-realloc cycle (fragmentation + buddy merge) ===");

        cycle_mem = new("cycle_mem");
        cycle_mem.init_region(64'h0, 64'h7_FFFF);  // 512KB

        for (cycle_count = 0; cycle_count < 5; cycle_count++) begin
            ok_count = 0;

            // Allocate 128 blocks of 512B each = 64KB total
            for (i_iter = 0; i_iter < 128; i_iter++) begin
                `host_mem_alloc(cycle_mem, cycle_addrs[i_iter], 512);
                if (cycle_addrs[i_iter] != '1) ok_count++;
            end
            $display("  Cycle %0d: allocated %0d / 128 blocks", cycle_count, ok_count);
            assert(ok_count == 128) else $fatal(1, $sformatf("Cycle %0d: only %0d allocs", cycle_count, ok_count));

            // Free odd-indexed blocks first (creates fragmentation)
            for (i_iter = 1; i_iter < 128; i_iter += 2)
                `host_mem_free(cycle_mem, cycle_addrs[i_iter]);

            // Free even-indexed blocks (should trigger buddy merges)
            for (i_iter = 0; i_iter < 128; i_iter += 2)
                `host_mem_free(cycle_mem, cycle_addrs[i_iter]);
        end

        // After all cycles, space should be fully recovered
        `host_mem_alloc(cycle_mem, big_addr, 262144);  // 256KB
        assert(big_addr != '1)
            else $fatal(1, "Failed to alloc 256KB after fragmentation cycles - merge broken");
        `host_mem_free(cycle_mem, big_addr);

        `host_mem_leak_check(cycle_mem);
        $display("Test 12 PASSED: 5 alloc-free cycles with full merge recovery");

        // ========================================
        // Test 13: Large-scale release_range (DMA batch scenario)
        // ========================================
        $display("\n=== Test 13: Large-scale release_range (DMA batch) ===");

        dma_mem = new("dma_mem");
        dma_mem.init_region(64'h0, 64'hF_FFFF);  // 1MB

        chunk_size = 64;  // MIN_BLOCK_SIZE

        // Allocate a 16KB block for DMA
        `host_mem_alloc(dma_mem, dma_addr, 16384, 4096);
        assert(dma_addr != '1) else $fatal(1, "DMA alloc failed");

        // Write data to entire block
        wd = new[16384];
        foreach (wd[i]) wd[i] = i & 8'hFF;
        `host_mem_write(dma_mem, dma_addr, wd);

        // Simulate DMA completing in 64B chunks, release each chunk
        total_chunks = 16384 / chunk_size;
        for (i_iter = 0; i_iter < int'(total_chunks); i_iter++) begin
            // Read before release to verify data integrity
            if (i_iter < 3) begin  // only check first few to keep test fast
                `host_mem_read(dma_mem, dma_addr + i_iter * chunk_size, chunk_size, rd);
                assert(rd[0] == byte'((i_iter * chunk_size) & 8'hFF))
                    else $fatal(1, $sformatf("DMA data mismatch at chunk %0d", i_iter));
            end
            `host_mem_release_range(dma_mem, dma_addr + i_iter * chunk_size, chunk_size);
        end
        // Block should have been auto-freed after last release_range

        // Verify space was recovered: alloc same size again
        `host_mem_alloc(dma_mem, realloc_addr, 16384, 4096);
        assert(realloc_addr != '1)
            else $fatal(1, "Re-alloc after full release_range failed - auto-free broken");
        `host_mem_free(dma_mem, realloc_addr);

        `host_mem_leak_check(dma_mem);
        $display("Test 13 PASSED: DMA batch release_range with auto-free OK");

        // ========================================
        // Test 14: Multi-region large allocation
        // ========================================
        $display("\n=== Test 14: Multi-region large allocation ===");

        mr_mem = new("mr_mem");
        mr_mem.init_region(64'h0000_0000, 64'h000F_FFFF);           // Region 0: 1MB
        mr_mem.init_region(64'h1000_0000, 64'h1001_FFFF);           // Region 1: 128KB

        // Alloc from region 0
        `host_mem_alloc(mr_mem, a1, 524288);   // 512KB
        assert(a1 != '1) else $fatal(1, "512KB alloc failed");
        assert(a1 >= 64'h0000_0000 && a1 < 64'h0010_0000)
            else $fatal(1, $sformatf("Expected alloc in region 0, got 0x%h", a1));

        // Alloc 64KB
        `host_mem_alloc(mr_mem, a2, 65536);    // 64KB
        assert(a2 != '1) else $fatal(1, "64KB alloc failed");

        // Alloc another 512KB - may or may not succeed
        `host_mem_alloc(mr_mem, a3, 524288);

        // Write and verify across regions
        wd = new[1024];
        foreach (wd[i]) wd[i] = 8'hAB;
        `host_mem_write(mr_mem, a1, wd);
        `host_mem_read(mr_mem, a1, 1024, rd);
        assert(rd[0] == 8'hAB && rd[1023] == 8'hAB)
            else $fatal(1, "Multi-region data verify failed");

        `host_mem_free(mr_mem, a1);
        `host_mem_free(mr_mem, a2);
        if (a3 != '1) `host_mem_free(mr_mem, a3);
        `host_mem_leak_check(mr_mem);
        mr_mem.print_stats();
        $display("Test 14 PASSED: multi-region large allocation OK");

        // ========================================
        // Test 15: Rapid alloc-free thrashing (same size)
        // ========================================
        $display("\n=== Test 15: Rapid alloc-free thrashing (1000 iterations) ===");

        thrash_mem = new("thrash_mem");
        thrash_mem.init_region(64'h0, 64'hFFFF);  // 64KB

        for (i_iter = 0; i_iter < 1000; i_iter++) begin
            `host_mem_alloc(thrash_mem, t_addr, 64);
            assert(t_addr != '1) else $fatal(1, $sformatf("thrash alloc failed at iter %0d", i_iter));
            `host_mem_free(thrash_mem, t_addr);
        end

        // After thrashing, full space should be available
        `host_mem_alloc(thrash_mem, t_addr, 32768);
        assert(t_addr != '1) else $fatal(1, "Large alloc after thrashing failed");
        `host_mem_free(thrash_mem, t_addr);

        `host_mem_leak_check(thrash_mem);
        $display("Test 15 PASSED: 1000 alloc-free thrash cycles OK");

        // ========================================
        // Test 16: Variable-size random alloc-free mix
        // ========================================
        $display("\n=== Test 16: Random alloc-free mix (500 ops) ===");

        rand_mem = new("rand_mem");
        rand_mem.init_region(64'h0, 64'h1F_FFFF);  // 2MB
        seed2 = 123;
        alloc_ops = 0;
        free_ops = 0;

        for (op_iter = 0; op_iter < 500; op_iter++) begin
            r = $urandom(seed2) % 100;

            if (pool.size() == 0 || r < 60) begin
                // 60% chance alloc (or forced if pool empty)
                sz = ($urandom(seed2) % 8189) + 4;  // 4 ~ 8192
                al = 1 << ($urandom(seed2) % 8);    // 1,2,4,...,128
                `host_mem_alloc(rand_mem, a, sz, al);
                if (a != '1) begin
                    pool.push_back(a);
                    pool_sizes[a] = sz;
                    // Write pattern
                    wd = new[sz];
                    foreach (wd[i]) wd[i] = (a + i) & 8'hFF;
                    `host_mem_write(rand_mem, a, wd);
                    alloc_ops++;
                end
            end else begin
                // 40% chance free random block
                idx = $urandom(seed2) % pool.size();
                fa = pool[idx];
                // Verify data before free
                `host_mem_read(rand_mem, fa, pool_sizes[fa], rd);
                assert(rd[0] == byte'(fa & 8'hFF))
                    else $fatal(1, $sformatf("Data corrupt before free at 0x%h", fa));
                `host_mem_free(rand_mem, fa);
                pool_sizes.delete(fa);
                pool.delete(idx);
                free_ops++;
            end
        end

        $display("  Performed %0d allocs, %0d frees, %0d blocks still live",
            alloc_ops, free_ops, pool.size());

        // Free remaining
        foreach (pool[i])
            `host_mem_free(rand_mem, pool[i]);

        `host_mem_leak_check(rand_mem);
        rand_mem.print_stats();
        $display("Test 16 PASSED: random alloc-free mix OK");

        // ========================================
        // Test 17: 10K+ stress test with duplicate address detection
        // ========================================
        $display("\n=== Test 17: 10K+ alloc/write/read/free stress with dup-addr detection ===");

        stress_mem = new("stress_mem");
        // 16MB region - large enough to hold many concurrent blocks
        stress_mem.init_region(64'h0, 64'hFF_FFFF);

        stress_seed = 9876;
        stress_alloc_ok = 0;
        stress_alloc_fail = 0;
        stress_free_ok = 0;
        stress_dup_detected = 0;
        stress_data_err = 0;
        stress_total_ops = 15000;

        for (op_iter = 0; op_iter < int'(stress_total_ops); op_iter++) begin
            stress_r = $urandom(stress_seed) % 100;

            // Dynamic bias based on pool size:
            //   pool=0       -> always alloc
            //   pool<200     -> 80% alloc
            //   pool 200~800 -> 50/50
            //   pool>800     -> 80% free
            if (stress_pool.size() == 0) begin
                stress_r = 0;  // force alloc
            end else if (stress_pool.size() < 200) begin
                if (stress_r < 80) stress_r = 0; else stress_r = 80;
            end else if (stress_pool.size() > 800) begin
                if (stress_r < 80) stress_r = 80; else stress_r = 0;
            end

            if (stress_r < 50) begin
                // === ALLOC ===
                stress_sz = (($urandom(stress_seed) % 2044) + 4);  // 4 ~ 2048 bytes
                stress_al = 1 << ($urandom(stress_seed) % 7);      // 1,2,4,...,64
                stress_tag = $urandom(stress_seed) & 8'hFF;

                `host_mem_alloc(stress_mem, stress_addr, stress_sz, stress_al);

                if (stress_addr != '1) begin
                    // *** DUPLICATE ADDRESS CHECK ***
                    if (stress_live_set.exists(stress_addr)) begin
                        $display("ERROR: DUPLICATE ADDR DETECTED! addr=0x%016h at op %0d (already live)", stress_addr, op_iter);
                        stress_dup_detected++;
                    end

                    // Also check overlap with all live blocks
                    foreach (stress_live_set[k]) begin
                        if (k == stress_addr) continue;
                        // Check [stress_addr, stress_addr+stress_sz) vs [k, k+stress_pool_sizes[k])
                        if (!(stress_addr + stress_sz <= k || k + stress_pool_sizes[k] <= stress_addr)) begin
                            $display("ERROR: OVERLAP! new=[0x%h +%0d] vs existing=[0x%h +%0d] at op %0d",
                                stress_addr, stress_sz, k, stress_pool_sizes[k], op_iter);
                            stress_dup_detected++;
                        end
                    end

                    stress_live_set[stress_addr] = 1;
                    stress_pool.push_back(stress_addr);
                    stress_pool_sizes[stress_addr] = stress_sz;
                    stress_pool_tags[stress_addr] = stress_tag;

                    // Write tag pattern: each byte = tag ^ (offset & 0xFF)
                    wd = new[stress_sz];
                    foreach (wd[b]) wd[b] = stress_tag ^ (b & 8'hFF);
                    `host_mem_write(stress_mem, stress_addr, wd);

                    stress_alloc_ok++;
                end else begin
                    stress_alloc_fail++;
                end
            end else begin
                // === FREE with data verify ===
                stress_idx = $urandom(stress_seed) % stress_pool.size();
                stress_fa = stress_pool[stress_idx];
                stress_sz = stress_pool_sizes[stress_fa];
                stress_tag = stress_pool_tags[stress_fa];

                // Read back and verify data integrity
                `host_mem_read(stress_mem, stress_fa, stress_sz, rd);
                foreach (rd[b]) begin
                    if (rd[b] != byte'(stress_tag ^ (b & 8'hFF))) begin
                        $display("ERROR: DATA CORRUPTION at addr=0x%h offset=%0d expected=0x%02h got=0x%02h op=%0d",
                            stress_fa, b, stress_tag ^ (b & 8'hFF), rd[b], op_iter);
                        stress_data_err++;
                        // Only report first mismatch per block
                        break;
                    end
                end

                `host_mem_free(stress_mem, stress_fa);
                stress_live_set.delete(stress_fa);
                stress_pool_sizes.delete(stress_fa);
                stress_pool_tags.delete(stress_fa);
                stress_pool.delete(stress_idx);
                stress_free_ok++;
            end

            // Progress report every 5000 ops
            if ((op_iter + 1) % 5000 == 0)
                $display("  ... %0d / %0d ops done (live=%0d, alloc_ok=%0d, alloc_fail=%0d, free=%0d, dup=%0d, data_err=%0d)",
                    op_iter + 1, stress_total_ops, stress_pool.size(),
                    stress_alloc_ok, stress_alloc_fail, stress_free_ok,
                    stress_dup_detected, stress_data_err);
        end

        // Final: verify all remaining live blocks
        $display("  Final verify: checking %0d remaining live blocks...", stress_pool.size());
        foreach (stress_pool[p]) begin
            stress_fa = stress_pool[p];
            stress_sz = stress_pool_sizes[stress_fa];
            stress_tag = stress_pool_tags[stress_fa];
            `host_mem_read(stress_mem, stress_fa, stress_sz, rd);
            foreach (rd[b]) begin
                if (rd[b] != byte'(stress_tag ^ (b & 8'hFF))) begin
                    $display("ERROR: FINAL DATA CORRUPTION at addr=0x%h offset=%0d", stress_fa, b);
                    stress_data_err++;
                    break;
                end
            end
        end

        // Free all remaining
        foreach (stress_pool[p])
            `host_mem_free(stress_mem, stress_pool[p]);

        `host_mem_leak_check(stress_mem);
        stress_mem.print_stats();

        $display("\n  === Test 17 RESULTS ===");
        $display("  Total ops:          %0d", stress_total_ops);
        $display("  Alloc OK:           %0d", stress_alloc_ok);
        $display("  Alloc FAIL (OOM):   %0d", stress_alloc_fail);
        $display("  Free OK:            %0d", stress_free_ok);
        $display("  Duplicate addrs:    %0d", stress_dup_detected);
        $display("  Data corruptions:   %0d", stress_data_err);

        if (stress_dup_detected > 0 || stress_data_err > 0) begin
            $display("  *** Test 17 FAILED ***");
            $fatal(1, "Stress test detected %0d duplicate addrs and %0d data corruptions",
                stress_dup_detected, stress_data_err);
        end else begin
            $display("  Test 17 PASSED: %0d allocs, %0d frees, 0 duplicates, 0 corruptions",
                stress_alloc_ok, stress_free_ok);
        end

        // ========================================
        // Test 18: Linear mode - small CPU memory (32KB), pow2-unfriendly sizes
        // ========================================
        $display("\n=== Test 18: Linear mode - small 32KB CPU memory ===");

        lin_mem = new("lin_mem");
        lin_mem.init_region(64'h0, 64'h7FFF, MODE_LINEAR);  // 32KB

        // Sizes 100/200/1000/17000 - buddy would round to 128/256/1024/32768
        // 32768 alone would exhaust 32KB region. Linear must succeed for all four.
        lin_total_occ = 0;
        for (i_iter = 0; i_iter < 4; i_iter++) begin
            `host_mem_alloc(lin_mem, lin_addrs[i_iter], lin_sizes[i_iter], 1);
            assert(lin_addrs[i_iter] != '1)
                else $fatal(1, $sformatf("Linear alloc[%0d] size=%0d FAILED - buddy would have failed too",
                    i_iter, lin_sizes[i_iter]));
            // Occupation = ceil(size/granule)*granule (uses current instance granule)
            lin_total_occ += ((lin_sizes[i_iter] + lin_mem.get_min_granule() - 1) / lin_mem.get_min_granule()) * lin_mem.get_min_granule();
            $display("  alloc[%0d]: addr=0x%016h size=%0d", i_iter, lin_addrs[i_iter], lin_sizes[i_iter]);
        end
        $display("  Total occupation: %0d bytes (vs 32KB region)", lin_total_occ);
        assert(lin_total_occ <= 32768) else $fatal(1, "Linear over-occupied");

        // Write/read verify across all blocks
        for (i_iter = 0; i_iter < 4; i_iter++) begin
            lin_wd = new[lin_sizes[i_iter]];
            foreach (lin_wd[b]) lin_wd[b] = (i_iter * 13 + b) & 8'hFF;
            `host_mem_write(lin_mem, lin_addrs[i_iter], lin_wd);
        end
        for (i_iter = 0; i_iter < 4; i_iter++) begin
            `host_mem_read(lin_mem, lin_addrs[i_iter], lin_sizes[i_iter], lin_rd);
            foreach (lin_rd[b])
                assert(lin_rd[b] == byte'((i_iter * 13 + b) & 8'hFF))
                    else $fatal(1, $sformatf("Linear data mismatch block[%0d] offset %0d", i_iter, b));
        end
        $display("  Write/read verify OK for all 4 blocks");

        // Verify no overlap between blocks
        for (i_iter = 0; i_iter < 4; i_iter++) begin
            for (j_iter = i_iter + 1; j_iter < 4; j_iter++) begin
                assert(lin_addrs[i_iter] + lin_sizes[i_iter] <= lin_addrs[j_iter] ||
                       lin_addrs[j_iter] + lin_sizes[j_iter] <= lin_addrs[i_iter])
                    else $fatal(1, $sformatf("Linear overlap: [%0d] vs [%0d]", i_iter, j_iter));
            end
        end
        $display("  No overlap detected");

        // Free all
        for (i_iter = 0; i_iter < 4; i_iter++)
            `host_mem_free(lin_mem, lin_addrs[i_iter]);

        // After all free, full region should reclaim - alloc 32KB-128 to leave headroom for alignment
        `host_mem_alloc(lin_mem, lin_big, 30000, 1);
        assert(lin_big != '1) else $fatal(1, "Linear failed to reclaim region after free");
        `host_mem_free(lin_mem, lin_big);

        `host_mem_leak_check(lin_mem);
        lin_mem.print_stats();
        $display("Test 18 PASSED: linear mode small CPU memory (4 blocks, %0d B total) fit in 32KB", lin_total_occ);

        // ========================================
        // Test 19: Linear mode - arbitrary-order free + merge
        // ========================================
        $display("\n=== Test 19: Linear mode - out-of-order free + merge ===");

        lin2_mem = new("lin2_mem");
        lin2_mem.init_region(64'h0, 64'hFFFFF, MODE_LINEAR);  // 1MB

        // Allocate 8 blocks of 4KB each
        for (i_iter = 0; i_iter < 8; i_iter++) begin
            `host_mem_alloc(lin2_mem, lin2_addrs[i_iter], 4096, 64);
            assert(lin2_addrs[i_iter] != '1) else $fatal(1, "Linear 4KB alloc failed");
        end

        // Free in scrambled order: 3,7,1,5,0,4,2,6
        `host_mem_free(lin2_mem, lin2_addrs[3]);
        `host_mem_free(lin2_mem, lin2_addrs[7]);
        `host_mem_free(lin2_mem, lin2_addrs[1]);
        `host_mem_free(lin2_mem, lin2_addrs[5]);
        `host_mem_free(lin2_mem, lin2_addrs[0]);
        `host_mem_free(lin2_mem, lin2_addrs[4]);
        `host_mem_free(lin2_mem, lin2_addrs[2]);
        `host_mem_free(lin2_mem, lin2_addrs[6]);

        // After all free + merge, full region should be one segment again
        // Alloc near-full to verify
        `host_mem_alloc(lin2_mem, lin2_after, 1048576 - 4096, 64);
        assert(lin2_after != '1)
            else $fatal(1, "Linear merge broken: cannot reclaim full region after out-of-order free");
        `host_mem_free(lin2_mem, lin2_after);

        `host_mem_leak_check(lin2_mem);
        $display("Test 19 PASSED: linear out-of-order free + merge OK");

        // ========================================
        // Test 20: Linear mode 15K random stress (dup-addr + data corruption)
        // ========================================
        $display("\n=== Test 20: Linear mode 15K random stress ===");

        lstr_mem = new("lstr_mem");
        lstr_mem.init_region(64'h0, 64'hFF_FFFF, MODE_LINEAR);  // 16MB linear

        lstr_seed = 31415;
        lstr_alloc_ok = 0;
        lstr_alloc_fail = 0;
        lstr_free_ok = 0;
        lstr_dup_detected = 0;
        lstr_data_err = 0;
        lstr_total_ops = 15000;

        for (op_iter = 0; op_iter < int'(lstr_total_ops); op_iter++) begin
            lstr_r = $urandom(lstr_seed) % 100;

            // Bias by pool size
            if (lstr_pool.size() == 0)
                lstr_r = 0;
            else if (lstr_pool.size() < 200) begin
                if (lstr_r < 80) lstr_r = 0; else lstr_r = 80;
            end else if (lstr_pool.size() > 800) begin
                if (lstr_r < 80) lstr_r = 80; else lstr_r = 0;
            end

            if (lstr_r < 50) begin
                // ALLOC: real size 4..2048, align 1..128 (linear enforces >=64)
                lstr_sz = (($urandom(lstr_seed) % 2044) + 4);
                lstr_al = 1 << ($urandom(lstr_seed) % 8);
                lstr_tag = $urandom(lstr_seed) & 8'hFF;

                `host_mem_alloc(lstr_mem, lstr_addr, lstr_sz, lstr_al);

                if (lstr_addr != '1) begin
                    // Duplicate detection
                    if (lstr_live_set.exists(lstr_addr)) begin
                        $display("LINEAR DUP! addr=0x%016h op=%0d", lstr_addr, op_iter);
                        lstr_dup_detected++;
                    end
                    // Overlap detection
                    foreach (lstr_live_set[k]) begin
                        if (k == lstr_addr) continue;
                        if (!(lstr_addr + lstr_sz <= k || k + lstr_pool_sizes[k] <= lstr_addr)) begin
                            $display("LINEAR OVERLAP! new=[0x%h +%0d] vs [0x%h +%0d] op=%0d",
                                lstr_addr, lstr_sz, k, lstr_pool_sizes[k], op_iter);
                            lstr_dup_detected++;
                        end
                    end

                    lstr_live_set[lstr_addr] = 1;
                    lstr_pool.push_back(lstr_addr);
                    lstr_pool_sizes[lstr_addr] = lstr_sz;
                    lstr_pool_tags[lstr_addr] = lstr_tag;

                    wd = new[lstr_sz];
                    foreach (wd[b]) wd[b] = lstr_tag ^ (b & 8'hFF);
                    `host_mem_write(lstr_mem, lstr_addr, wd);

                    lstr_alloc_ok++;
                end else begin
                    lstr_alloc_fail++;
                end
            end else begin
                // FREE with data verify
                lstr_idx = $urandom(lstr_seed) % lstr_pool.size();
                lstr_fa = lstr_pool[lstr_idx];
                lstr_sz = lstr_pool_sizes[lstr_fa];
                lstr_tag = lstr_pool_tags[lstr_fa];

                `host_mem_read(lstr_mem, lstr_fa, lstr_sz, rd);
                foreach (rd[b]) begin
                    if (rd[b] != byte'(lstr_tag ^ (b & 8'hFF))) begin
                        $display("LINEAR DATA CORRUPT addr=0x%h off=%0d exp=0x%02h got=0x%02h",
                            lstr_fa, b, lstr_tag ^ (b & 8'hFF), rd[b]);
                        lstr_data_err++;
                        break;
                    end
                end

                `host_mem_free(lstr_mem, lstr_fa);
                lstr_live_set.delete(lstr_fa);
                lstr_pool_sizes.delete(lstr_fa);
                lstr_pool_tags.delete(lstr_fa);
                lstr_pool.delete(lstr_idx);
                lstr_free_ok++;
            end

            if ((op_iter + 1) % 5000 == 0)
                $display("  ... %0d/%0d (live=%0d alloc_ok=%0d fail=%0d free=%0d dup=%0d err=%0d)",
                    op_iter + 1, lstr_total_ops, lstr_pool.size(),
                    lstr_alloc_ok, lstr_alloc_fail, lstr_free_ok,
                    lstr_dup_detected, lstr_data_err);
        end

        // Final verify
        foreach (lstr_pool[p]) begin
            lstr_fa = lstr_pool[p];
            lstr_sz = lstr_pool_sizes[lstr_fa];
            lstr_tag = lstr_pool_tags[lstr_fa];
            `host_mem_read(lstr_mem, lstr_fa, lstr_sz, rd);
            foreach (rd[b]) begin
                if (rd[b] != byte'(lstr_tag ^ (b & 8'hFF))) begin
                    $display("LINEAR FINAL CORRUPT addr=0x%h off=%0d", lstr_fa, b);
                    lstr_data_err++;
                    break;
                end
            end
        end
        foreach (lstr_pool[p])
            `host_mem_free(lstr_mem, lstr_pool[p]);

        `host_mem_leak_check(lstr_mem);
        lstr_mem.print_stats();

        $display("  Test 20: alloc_ok=%0d alloc_fail=%0d free=%0d dup=%0d data_err=%0d",
            lstr_alloc_ok, lstr_alloc_fail, lstr_free_ok, lstr_dup_detected, lstr_data_err);
        if (lstr_dup_detected > 0 || lstr_data_err > 0)
            $fatal(1, "Test 20 FAILED");
        $display("Test 20 PASSED: linear 15K random stress OK");

        // ========================================
        // Test 21: Buddy random mixed alloc/free/release_range
        // ========================================
        $display("\n=== Test 21: Buddy random alloc/free/release_range (3K ops) ===");

        bm_mem = new("bm_mem");
        bm_mem.init_region(64'h0, 64'h7F_FFFF);  // 8MB buddy

        bm_seed = 7777;
        bm_alloc_ok = 0;
        bm_free_ok = 0;
        bm_release_ok = 0;
        bm_data_err = 0;
        bm_total_ops = 3000;

        for (op_iter = 0; op_iter < int'(bm_total_ops); op_iter++) begin
            bm_r = $urandom_range(0, 99);

            // Lighter bias: force alloc only when truly empty
            if (bm_pool.size() == 0) bm_r = 0;
            else if (bm_pool.size() > 300 && bm_r < 40) bm_r = bm_r + 50;  // shift to free/release range

            if (bm_r < 40) begin
                // ALLOC (40%)
                bm_sz = $urandom_range(4, 4096);
                bm_al = 1 << $urandom_range(0, 7);
                bm_tag = $urandom_range(0, 255);

                `host_mem_alloc(bm_mem, bm_addr, bm_sz, bm_al);
                if (bm_addr != '1) begin
                    bm_pool.push_back(bm_addr);
                    bm_pool_sizes[bm_addr] = bm_sz;
                    bm_pool_tags[bm_addr] = bm_tag;

                    wd = new[bm_sz];
                    foreach (wd[b]) wd[b] = bm_tag ^ (b & 8'hFF);
                    `host_mem_write(bm_mem, bm_addr, wd);
                    bm_alloc_ok++;
                end
            end else if (bm_r < 75) begin
                // FREE with verify (35%)
                bm_idx = $urandom_range(0, bm_pool.size() - 1);
                bm_fa = bm_pool[bm_idx];
                bm_sz = bm_pool_sizes[bm_fa];
                bm_tag = bm_pool_tags[bm_fa];

                `host_mem_read(bm_mem, bm_fa, bm_sz, rd);
                foreach (rd[b]) begin
                    if (rd[b] != byte'(bm_tag ^ (b & 8'hFF))) begin
                        $display("BUDDY DATA CORRUPT addr=0x%h off=%0d", bm_fa, b);
                        bm_data_err++;
                        break;
                    end
                end

                `host_mem_free(bm_mem, bm_fa);
                bm_pool_sizes.delete(bm_fa);
                bm_pool_tags.delete(bm_fa);
                bm_pool.delete(bm_idx);
                bm_free_ok++;
            end else begin
                // RELEASE_RANGE (25%): pick block, release first 64B, then free() the rest
                bm_idx = $urandom_range(0, bm_pool.size() - 1);
                bm_fa = bm_pool[bm_idx];
                bm_sz = bm_pool_sizes[bm_fa];

                // Skip if buddy_size==64 (release_range covers all => auto-free,
                // then explicit free would be double-free). Need buddy_size>=128 i.e. req_size>64.
                if (bm_sz > 64) begin
                    `host_mem_release_range(bm_mem, bm_fa, 64);
                    `host_mem_free(bm_mem, bm_fa);
                    bm_release_ok++;
                    bm_pool_sizes.delete(bm_fa);
                    bm_pool_tags.delete(bm_fa);
                    bm_pool.delete(bm_idx);
                end
            end

            if ((op_iter + 1) % 1000 == 0)
                $display("  ... %0d/%0d (live=%0d alloc=%0d free=%0d release=%0d err=%0d)",
                    op_iter + 1, bm_total_ops, bm_pool.size(),
                    bm_alloc_ok, bm_free_ok, bm_release_ok, bm_data_err);
        end

        foreach (bm_pool[p])
            `host_mem_free(bm_mem, bm_pool[p]);

        `host_mem_leak_check(bm_mem);
        bm_mem.print_stats();

        $display("  Test 21: alloc=%0d free=%0d release_range=%0d data_err=%0d",
            bm_alloc_ok, bm_free_ok, bm_release_ok, bm_data_err);
        if (bm_data_err > 0) $fatal(1, "Test 21 FAILED");
        $display("Test 21 PASSED: buddy random alloc/free/release_range OK");

        // ========================================
        // Test 22: Linear fragmentation + merge stress
        // ========================================
        $display("\n=== Test 22: Linear fragmentation/merge stress (200 blocks) ===");

        lf_mem = new("lf_mem");
        lf_mem.init_region(64'h0, 64'h7F_FFFF, MODE_LINEAR);  // 8MB linear

        lf_seed = 555;
        lf_alive_count = 0;
        lf_free_count = 0;

        // Phase 1: alloc 200 random-sized blocks
        for (i_iter = 0; i_iter < 200; i_iter++) begin
            lf_sizes[i_iter] = ($urandom(lf_seed) % 8189) + 4;
            `host_mem_alloc(lf_mem, lf_addrs[i_iter], lf_sizes[i_iter], 64);
            if (lf_addrs[i_iter] != '1) begin
                lf_alive[i_iter] = 1;
                lf_alive_count++;
                // tag = i_iter
                wd = new[lf_sizes[i_iter]];
                foreach (wd[b]) wd[b] = (i_iter + b) & 8'hFF;
                `host_mem_write(lf_mem, lf_addrs[i_iter], wd);
            end else begin
                lf_alive[i_iter] = 0;
            end
        end
        $display("  Phase 1: %0d/200 allocated", lf_alive_count);

        // Phase 2: free indices where (i*7 + 3) % 3 == 0 - deterministic pattern, ~1/3 of blocks
        for (i_iter = 0; i_iter < 200; i_iter++) begin
            if (!lf_alive[i_iter]) continue;
            if (((i_iter * 7 + 3) % 3) == 0) begin
                `host_mem_read(lf_mem, lf_addrs[i_iter], lf_sizes[i_iter], rd);
                foreach (rd[b])
                    assert(rd[b] == byte'((i_iter + b) & 8'hFF))
                        else $fatal(1, $sformatf("Test22 corrupt block[%0d] off %0d", i_iter, b));
                `host_mem_free(lf_mem, lf_addrs[i_iter]);
                lf_alive[i_iter] = 0;
                lf_free_count++;
            end
        end
        $display("  Phase 2: freed %0d blocks, %0d alive (holes created)",
            lf_free_count, lf_alive_count - lf_free_count);

        // Phase 3: verify surviving blocks still intact
        for (i_iter = 0; i_iter < 200; i_iter++) begin
            if (!lf_alive[i_iter]) continue;
            `host_mem_read(lf_mem, lf_addrs[i_iter], lf_sizes[i_iter], rd);
            foreach (rd[b])
                assert(rd[b] == byte'((i_iter + b) & 8'hFF))
                    else $fatal(1, $sformatf("Test22 survivor corrupt block[%0d] off %0d", i_iter, b));
        end
        $display("  Phase 3: surviving blocks intact");

        // Phase 4: free rest
        for (i_iter = 0; i_iter < 200; i_iter++) begin
            if (!lf_alive[i_iter]) continue;
            `host_mem_free(lf_mem, lf_addrs[i_iter]);
        end

        // Phase 5: full merge check - alloc near-full region
        `host_mem_alloc(lf_mem, lf_big_addr, 32'h7F_0000, 64);  // ~8MB - 64KB headroom
        assert(lf_big_addr != '1)
            else $fatal(1, "Test22 merge broken: cannot reclaim large block after all-free");
        `host_mem_free(lf_mem, lf_big_addr);

        `host_mem_leak_check(lf_mem);
        lf_mem.print_stats();
        $display("Test 22 PASSED: linear fragmentation/merge stress OK");

        // ========================================
        // Test 23: Granule comparison - 16B-heavy workload on 4/16/64 configs
        // ========================================
        $display("\n=== Test 23: Granule comparison (16B workload, 4/16/64 granule) ===");

        for (g_idx = 0; g_idx < 3; g_idx++) begin
            g_mem[g_idx] = new($sformatf("g_mem_%0d", g_granules[g_idx]));
            g_mem[g_idx].init_region(64'h0, 64'hF_FFFF, MODE_LINEAR, g_granules[g_idx]);

            g_eff_granule = g_mem[g_idx].get_min_granule();
            // For 16B alloc, occ = ceil(16/granule)*granule
            g_per_block_occ = ((16 + g_eff_granule - 1) / g_eff_granule) * g_eff_granule;
            g_total_occ = 0;

            // Alloc 500 x 16B blocks
            for (i_iter = 0; i_iter < 500; i_iter++) begin
                `host_mem_alloc(g_mem[g_idx], g_addrs[i_iter], 16, 1);
                assert(g_addrs[i_iter] != '1)
                    else $fatal(1, $sformatf("granule=%0d: 16B alloc %0d failed", g_eff_granule, i_iter));
                g_total_occ += g_per_block_occ;
            end

            // Write/read verify a sample
            wd = new[16];
            foreach (wd[b]) wd[b] = 8'h5A;
            `host_mem_write(g_mem[g_idx], g_addrs[0], wd);
            `host_mem_read(g_mem[g_idx], g_addrs[0], 16, rd);
            foreach (rd[b])
                assert(rd[b] == 8'h5A) else $fatal(1, "granule data verify failed");

            $display("  granule=%0d: 500x16B blocks, per-block occ=%0d, total=%0d bytes (1MB region)",
                g_eff_granule, g_per_block_occ, g_total_occ);

            // Free all
            for (i_iter = 0; i_iter < 500; i_iter++)
                `host_mem_free(g_mem[g_idx], g_addrs[i_iter]);

            // Reclaim check: alloc near-full region
            `host_mem_alloc(g_mem[g_idx], g_big16, 1024*1024 - 4096, 64);
            assert(g_big16 != '1)
                else $fatal(1, $sformatf("granule=%0d: post-free reclaim failed", g_eff_granule));
            `host_mem_free(g_mem[g_idx], g_big16);

            `host_mem_leak_check(g_mem[g_idx]);
            g_mem[g_idx].print_stats();
        end
        $display("Test 23 PASSED: 3 granule configs (4/16/64) all functional");

        // ========================================
        $display("\n========================================");
        $display("ALL TESTS PASSED");
        $display("========================================\n");
        $finish;
    end

endprogram

`endif
