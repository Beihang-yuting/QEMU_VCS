`ifndef HOST_MEM_MANAGER_SV
`define HOST_MEM_MANAGER_SV

import uvm_pkg::*;
import host_mem_pkg::*;
`include "uvm_macros.svh"

class host_mem_manager extends host_mem_pkg::host_mem_api;

    `uvm_object_utils(host_mem_manager)

    // ========== Configuration ==========
    byte         poison_pattern = DEFAULT_POISON;
    bit          warn_on_poison_read = 0;
    alloc_mode_e mode = MODE_BUDDY;
    // Granularity: minimum addressable block. Must be pow2 in [1, MAX_MIN_GRANULE].
    // Smaller value reduces waste for tiny allocs but inflates reverse-map size.
    protected int unsigned min_granule      = DEFAULT_MIN_GRANULE;
    protected int unsigned log2_min_granule = 4;  // log2(16)

    // ========== Buddy Free Lists ==========
    // free_blocks[level][base_addr] = 1; level 0=64B, 1=128B, ...
    protected bit free_blocks[int][bit[63:0]];

    // ========== Linear Free Segments (sorted ascending by addr) ==========
    protected free_seg_t free_list[$];

    // ========== Allocation Tracking ==========
    protected alloc_info_t alloc_table[bit[63:0]];

    // ========== Address Reverse Lookup ==========
    // Every 64B-aligned addr -> owning block base
    protected bit [63:0] addr_to_block[bit[63:0]];

    // ========== Data Storage ==========
    protected byte block_data[bit[63:0]][];

    // ========== Sub-block Validity ==========
    protected bit sub_block_valid[bit[63:0]][];

    // ========== History ==========
    protected mem_history_t history[$];

    // ========== Statistics ==========
    protected longint unsigned total_size;
    protected longint unsigned allocated_size;
    protected longint unsigned free_size;
    protected int unsigned     alloc_count;
    protected int unsigned     total_alloc_ops;
    protected int unsigned     total_free_ops;

    // ========== Region Tracking ==========
    protected region_info_t regions[$];

    // ========== Constructor ==========
    function new(string name = "host_mem_manager");
        super.new(name);
        total_size      = 0;
        allocated_size  = 0;
        free_size       = 0;
        alloc_count     = 0;
        total_alloc_ops = 0;
        total_free_ops  = 0;
    endfunction

    // ---- Method declarations (to be implemented in subsequent tasks) ----

    // Helpers
    extern protected function longint unsigned round_up_pow2(longint unsigned val);
    extern protected function int unsigned log2_floor(longint unsigned val);
    extern protected function int unsigned addr_to_level(longint unsigned size);
    extern protected function bit [63:0] get_buddy_addr(bit [63:0] addr, int unsigned level);
    extern protected function void add_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    extern protected function void remove_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    extern protected function void record_history(string op, bit [63:0] addr, int unsigned size, string file, int line);
    extern protected function bit check_addr_allocated(bit [63:0] addr, int unsigned size, string file, int line);
    extern protected function bit [63:0] floor_granule(bit [63:0] a);

    // Getters
    extern function int unsigned get_min_granule();

    // Init
    extern function void init_region(bit [63:0] base_addr, bit [63:0] end_addr,
                                     alloc_mode_e m = MODE_BUDDY,
                                     int unsigned granule = DEFAULT_MIN_GRANULE,
                                     byte poison = DEFAULT_POISON);

    // Alloc & Free
    extern function bit [63:0] alloc(int unsigned size, int unsigned align = 1, string file = "", int line = 0);
    extern function void free(bit [63:0] addr, string file = "", int line = 0);
    extern function void release_range(bit [63:0] addr, int unsigned size, string file = "", int line = 0);

    // Linear-mode internal helpers
    extern protected function bit [63:0] alloc_linear(int unsigned size, int unsigned align, string file, int line);
    extern protected function void       free_linear(bit [63:0] addr, alloc_info_t info, string file, int line);
    extern protected function void       insert_free_seg_merge(bit [63:0] addr, longint unsigned size);

    // Data Read/Write
    extern function void write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
    extern function void read_mem(bit [63:0] addr, int unsigned size, ref byte data[], input string file = "", input int line = 0);

    // Bulk Operations
    extern function void mem_set(bit [63:0] addr, byte value, int unsigned size, string file = "", int line = 0);
    extern function void mem_cpy(bit [63:0] dst_addr, bit [63:0] src_addr, int unsigned size, string file = "", int line = 0);
    extern function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size, output int unsigned mismatch_offset, input string file = "", input int line = 0);

    // Debug
    extern function void hexdump(bit [63:0] addr, int unsigned size);
    extern function void print_alloc_table();
    extern function void print_stats();
    extern function void print_history(int unsigned last_n = 0);
    extern function void leak_check(string file = "", int line = 0);

endclass

// ========== Helper Function Implementations ==========

function longint unsigned host_mem_manager::round_up_pow2(longint unsigned val);
    longint unsigned result;
    if (val == 0) return 1;
    if (val == 1) return 1;
    result = 1;
    while (result < val)
        result = result << 1;
    return result;
endfunction

function int unsigned host_mem_manager::log2_floor(longint unsigned val);
    int unsigned result = 0;
    val = val >> 1;
    while (val > 0) begin
        result++;
        val = val >> 1;
    end
    return result;
endfunction

function int unsigned host_mem_manager::addr_to_level(longint unsigned size);
    return log2_floor(size / min_granule);
endfunction

function bit [63:0] host_mem_manager::floor_granule(bit [63:0] a);
    return (a >> log2_min_granule) << log2_min_granule;
endfunction

function int unsigned host_mem_manager::get_min_granule();
    return min_granule;
endfunction

function bit [63:0] host_mem_manager::get_buddy_addr(bit [63:0] addr, int unsigned level);
    longint unsigned block_size = longint'(min_granule) << level;
    return addr ^ block_size;
endfunction

function void host_mem_manager::add_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    int unsigned num_entries = buddy_size / min_granule;
    for (int unsigned i = 0; i < num_entries; i++) begin
        addr_to_block[base + longint'(i) * min_granule] = base;
    end
endfunction

function void host_mem_manager::remove_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    int unsigned num_entries = buddy_size / min_granule;
    for (int unsigned i = 0; i < num_entries; i++) begin
        addr_to_block.delete(base + longint'(i) * min_granule);
    end
endfunction

function void host_mem_manager::record_history(string op, bit [63:0] addr, int unsigned size, string file, int line);
    mem_history_t h;
    h.op          = op;
    h.base_addr   = addr;
    h.size        = size;
    h.caller_file = file;
    h.caller_line = line;
    h.timestamp   = $realtime;
    history.push_back(h);
endfunction

function bit host_mem_manager::check_addr_allocated(bit [63:0] addr, int unsigned size, string file, int line);
    bit [63:0] aligned_addr;
    bit [63:0] block_base;
    alloc_info_t info;
    int unsigned start_idx, end_idx;

    aligned_addr = floor_granule(addr);
    if (!addr_to_block.exists(aligned_addr)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "Accessing unallocated address 0x%016h\n  -> Called from: %s:%0d",
            addr, file, line))
        return 0;
    end

    block_base = addr_to_block[aligned_addr];
    info = alloc_table[block_base];

    if (addr < block_base || (addr + size) > (block_base + info.req_size)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "Access [0x%016h +%0d] exceeds block boundary [0x%016h +%0d]\n  -> Called from: %s:%0d",
            addr, size, block_base, info.req_size, file, line))
        return 0;
    end

    start_idx = (addr - block_base) / min_granule;
    end_idx   = (addr + size - 1 - block_base) / min_granule;
    for (int unsigned i = start_idx; i <= end_idx; i++) begin
        if (!sub_block_valid[block_base][i]) begin
            `uvm_fatal("HOST_MEM", $sformatf(
                "Accessing released sub-range at 0x%016h (sub-block index %0d)\n  -> Called from: %s:%0d",
                block_base + i * min_granule, i, file, line))
            return 0;
        end
    end

    return 1;
endfunction

function void host_mem_manager::init_region(bit [63:0] base_addr, bit [63:0] end_addr,
                                             alloc_mode_e m = MODE_BUDDY,
                                             int unsigned granule = DEFAULT_MIN_GRANULE,
                                             byte poison = DEFAULT_POISON);
    longint unsigned region_size;
    bit [63:0] current_addr;
    longint unsigned block_size;
    int unsigned level;
    region_info_t r;

    if (end_addr <= base_addr) begin
        `uvm_error("HOST_MEM", $sformatf(
            "Invalid region: base=0x%016h end=0x%016h (end must be > base)", base_addr, end_addr))
        return;
    end

    // Validate granule: pow2, [1, MAX_MIN_GRANULE]
    if (granule == 0 || granule > MAX_MIN_GRANULE || (granule & (granule - 1)) != 0) begin
        `uvm_error("HOST_MEM", $sformatf(
            "Invalid granule=%0d: must be pow2 in [1, %0d]", granule, MAX_MIN_GRANULE))
        return;
    end

    min_granule      = granule;
    log2_min_granule = log2_floor(granule);
    poison_pattern   = poison;
    mode             = m;
    region_size    = end_addr - base_addr + 1;

    r.base_addr = base_addr;
    r.end_addr  = end_addr;
    regions.push_back(r);

    if (m == MODE_LINEAR) begin
        // Linear mode: align region to min_granule granularity, install as one big free segment
        bit [63:0]       aligned_base;
        bit [63:0]       aligned_end_excl;
        longint unsigned usable;

        aligned_base     = ((base_addr + min_granule - 1) / min_granule) * min_granule;
        aligned_end_excl = ((end_addr + 1) / min_granule) * min_granule;
        if (aligned_end_excl <= aligned_base) begin
            `uvm_error("HOST_MEM", $sformatf(
                "init_region(LINEAR): region [0x%016h - 0x%016h] too small after %0dB alignment",
                base_addr, end_addr, min_granule))
            return;
        end
        usable = aligned_end_excl - aligned_base;

        insert_free_seg_merge(aligned_base, usable);

        total_size = total_size + usable;
        free_size  = free_size + usable;

        `uvm_info("HOST_MEM", $sformatf(
            "init_region(LINEAR): base=0x%016h size=%0dB",
            aligned_base, usable), UVM_HIGH)
        return;
    end

    // Buddy mode (original)
    current_addr = base_addr;
    while (current_addr <= end_addr) begin
        longint unsigned remaining = end_addr - current_addr + 1;

        block_size = min_granule;
        while ((block_size << 1) <= remaining &&
               (current_addr % (block_size << 1)) == 0 &&
               (block_size << 1) > 0)
            block_size = block_size << 1;

        level = addr_to_level(block_size);
        free_blocks[level][current_addr] = 1;

        `uvm_info("HOST_MEM", $sformatf(
            "init_region: added free block at 0x%016h, size=%0dB (level=%0d)",
            current_addr, block_size, level), UVM_HIGH)

        current_addr = current_addr + block_size;
        if (current_addr == 0) break;  // overflow guard for max address space
    end

    total_size = total_size + region_size;
    free_size  = free_size + region_size;
endfunction

function bit [63:0] host_mem_manager::alloc(int unsigned size, int unsigned align = 1, string file = "", int line = 0);
    int unsigned buddy_size;
    int unsigned target_level;
    int unsigned search_level;
    bit [63:0] block_addr;
    bit [63:0] buddy;
    bit found;
    alloc_info_t info;
    int unsigned num_sub_blocks;

    if (size == 0) begin
        `uvm_error("HOST_MEM", $sformatf("alloc: size=0 is invalid\n  -> Called from: %s:%0d", file, line))
        return '1;
    end

    if (mode == MODE_LINEAR)
        return alloc_linear(size, align, file, line);

    buddy_size = round_up_pow2(size);
    if (align > buddy_size) buddy_size = round_up_pow2(align);
    if (buddy_size < min_granule) buddy_size = min_granule;

    target_level = addr_to_level(buddy_size);

    found = 0;
    for (search_level = target_level; ; search_level++) begin
        if (free_blocks.exists(search_level) && free_blocks[search_level].num() > 0) begin
            void'(free_blocks[search_level].first(block_addr));
            found = 1;
            break;
        end
        if (!free_blocks.exists(search_level) && search_level > target_level + 40)
            break;
    end

    if (!found) begin
        `uvm_error("HOST_MEM", $sformatf(
            "alloc: insufficient space for size=%0d align=%0d (buddy_size=%0d)\n  -> Called from: %s:%0d",
            size, align, buddy_size, file, line))
        return '1;
    end

    free_blocks[search_level].delete(block_addr);
    if (free_blocks[search_level].num() == 0)
        free_blocks.delete(search_level);

    while (search_level > target_level) begin
        search_level--;
        buddy = block_addr + (longint'(min_granule) << search_level);
        free_blocks[search_level][buddy] = 1;
    end

    info.base_addr   = block_addr;
    info.buddy_size  = buddy_size;
    info.req_size    = size;
    info.align       = align;
    info.caller_file = file;
    info.caller_line = line;
    info.alloc_time  = $realtime;
    alloc_table[block_addr] = info;

    add_reverse_mapping(block_addr, buddy_size);

    block_data[block_addr] = new[buddy_size];

    num_sub_blocks = buddy_size / min_granule;
    sub_block_valid[block_addr] = new[num_sub_blocks];
    foreach (sub_block_valid[block_addr][i])
        sub_block_valid[block_addr][i] = 1;

    allocated_size  += buddy_size;
    free_size       -= buddy_size;
    alloc_count++;
    total_alloc_ops++;

    record_history("ALLOC", block_addr, size, file, line);

    `uvm_info("HOST_MEM", $sformatf(
        "alloc: addr=0x%016h req_size=%0d buddy_size=%0d align=%0d\n  -> Called from: %s:%0d",
        block_addr, size, buddy_size, align, file, line), UVM_HIGH)

    return block_addr;
endfunction

function void host_mem_manager::free(bit [63:0] addr, string file = "", int line = 0);
    alloc_info_t info;
    int unsigned buddy_size;
    int unsigned level;
    bit [63:0] current_addr;
    bit [63:0] buddy_addr;

    if (!alloc_table.exists(addr)) begin
        foreach (history[i]) begin
            if (history[i].op == "FREE" && history[i].base_addr == addr) begin
                `uvm_fatal("HOST_MEM", $sformatf(
                    "Double-free detected at 0x%016h\n  -> Called from: %s:%0d\n  -> Previously freed at %0t from %s:%0d",
                    addr, file, line, history[i].timestamp, history[i].caller_file, history[i].caller_line))
                return;
            end
        end
        `uvm_fatal("HOST_MEM", $sformatf(
            "free: address 0x%016h is not an alloc base\n  -> Called from: %s:%0d",
            addr, file, line))
        return;
    end

    info = alloc_table[addr];
    buddy_size = info.buddy_size;

    if (mode == MODE_LINEAR) begin
        free_linear(addr, info, file, line);
        return;
    end

    level = addr_to_level(buddy_size);

    foreach (block_data[addr][i])
        block_data[addr][i] = poison_pattern;

    block_data.delete(addr);
    alloc_table.delete(addr);
    remove_reverse_mapping(addr, buddy_size);
    sub_block_valid.delete(addr);

    current_addr = addr;
    while (1) begin
        buddy_addr = get_buddy_addr(current_addr, level);
        if (free_blocks.exists(level) && free_blocks[level].exists(buddy_addr)) begin
            free_blocks[level].delete(buddy_addr);
            if (free_blocks[level].num() == 0)
                free_blocks.delete(level);
            if (buddy_addr < current_addr)
                current_addr = buddy_addr;
            level++;
        end else begin
            break;
        end
    end

    free_blocks[level][current_addr] = 1;

    allocated_size -= buddy_size;
    free_size      += buddy_size;
    alloc_count--;
    total_free_ops++;

    record_history("FREE", addr, info.req_size, file, line);

    `uvm_info("HOST_MEM", $sformatf(
        "free: addr=0x%016h buddy_size=%0d merged to level=%0d at 0x%016h\n  -> Called from: %s:%0d",
        addr, buddy_size, level, current_addr, file, line), UVM_HIGH)
endfunction

function void host_mem_manager::release_range(bit [63:0] addr, int unsigned size, string file = "", int line = 0);
    bit [63:0] aligned_addr;
    bit [63:0] block_base;
    alloc_info_t info;
    int unsigned start_idx, end_idx;
    bit all_released;

    if ((addr % min_granule) != 0 || (size % min_granule) != 0) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "release_range: addr=0x%016h size=%0d must be %0dB-aligned\n  -> Called from: %s:%0d",
            addr, size, min_granule, file, line))
        return;
    end

    if (!addr_to_block.exists(addr)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "release_range: address 0x%016h not in any allocated block\n  -> Called from: %s:%0d",
            addr, file, line))
        return;
    end

    block_base = addr_to_block[addr];
    if (!alloc_table.exists(block_base)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "release_range: block at 0x%016h already freed\n  -> Called from: %s:%0d",
            block_base, file, line))
        return;
    end

    info = alloc_table[block_base];

    if ((addr + size) > (block_base + info.buddy_size)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "release_range: range [0x%016h +%0d] exceeds block [0x%016h +%0d]\n  -> Called from: %s:%0d",
            addr, size, block_base, info.buddy_size, file, line))
        return;
    end

    start_idx = (addr - block_base) / min_granule;
    end_idx   = start_idx + (size / min_granule) - 1;

    for (int unsigned i = start_idx; i <= end_idx; i++) begin
        if (!sub_block_valid[block_base][i]) begin
            `uvm_warning("HOST_MEM", $sformatf(
                "release_range: sub-block %0d at 0x%016h already released\n  -> Called from: %s:%0d",
                i, block_base + longint'(i) * min_granule, file, line))
        end else begin
            sub_block_valid[block_base][i] = 0;
            for (int unsigned b = 0; b < min_granule; b++) begin
                longint unsigned offset = longint'(i) * min_granule + b;
                if (offset < info.buddy_size)
                    block_data[block_base][offset] = poison_pattern;
            end
        end
    end

    record_history("RELEASE_RANGE", addr, size, file, line);

    all_released = 1;
    foreach (sub_block_valid[block_base][i]) begin
        if (sub_block_valid[block_base][i]) begin
            all_released = 0;
            break;
        end
    end

    if (all_released) begin
        `uvm_info("HOST_MEM", $sformatf(
            "release_range: all sub-blocks released for block 0x%016h, auto-freeing",
            block_base), UVM_MEDIUM)
        free(block_base, file, line);
    end
endfunction

function void host_mem_manager::write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
    bit [63:0] block_base;
    int unsigned offset;

    if (data.size() == 0) return;

    if (!check_addr_allocated(addr, data.size(), file, line))
        return;

    block_base = addr_to_block[floor_granule(addr)];
    offset = addr - block_base;

    foreach (data[i])
        block_data[block_base][offset + i] = data[i];
endfunction

function void host_mem_manager::read_mem(bit [63:0] addr, int unsigned size, ref byte data[], input string file = "", input int line = 0);
    bit [63:0] block_base;
    int unsigned offset;
    bit all_poison;

    if (size == 0) return;

    if (!check_addr_allocated(addr, size, file, line))
        return;

    block_base = addr_to_block[floor_granule(addr)];
    offset = addr - block_base;

    data = new[size];
    foreach (data[i])
        data[i] = block_data[block_base][offset + i];

    if (warn_on_poison_read) begin
        all_poison = 1;
        foreach (data[i]) begin
            if (data[i] != poison_pattern) begin
                all_poison = 0;
                break;
            end
        end
        if (all_poison && size > 0) begin
            `uvm_warning("HOST_MEM", $sformatf(
                "read_mem: all %0d bytes at 0x%016h are poison (0x%02h) - possible use-after-free?\n  -> Called from: %s:%0d",
                size, addr, poison_pattern, file, line))
        end
    end
endfunction

function void host_mem_manager::mem_set(bit [63:0] addr, byte value, int unsigned size, string file = "", int line = 0);
    bit [63:0] block_base;
    int unsigned offset;

    if (size == 0) return;

    if (!check_addr_allocated(addr, size, file, line))
        return;

    block_base = addr_to_block[floor_granule(addr)];
    offset = addr - block_base;

    for (int unsigned i = 0; i < size; i++)
        block_data[block_base][offset + i] = value;
endfunction

function void host_mem_manager::mem_cpy(bit [63:0] dst_addr, bit [63:0] src_addr, int unsigned size, string file = "", int line = 0);
    byte temp_data[];
    bit [63:0] src_base;
    int unsigned src_offset;
    bit [63:0] dst_base;
    int unsigned dst_offset;

    if (size == 0) return;

    if (!check_addr_allocated(src_addr, size, file, line))
        return;
    if (!check_addr_allocated(dst_addr, size, file, line))
        return;

    src_base = addr_to_block[floor_granule(src_addr)];
    src_offset = src_addr - src_base;
    temp_data = new[size];
    for (int unsigned i = 0; i < size; i++)
        temp_data[i] = block_data[src_base][src_offset + i];

    dst_base = addr_to_block[floor_granule(dst_addr)];
    dst_offset = dst_addr - dst_base;
    for (int unsigned i = 0; i < size; i++)
        block_data[dst_base][dst_offset + i] = temp_data[i];
endfunction

function bit host_mem_manager::mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size, output int unsigned mismatch_offset, input string file = "", input int line = 0);
    bit [63:0] base1, base2;
    int unsigned off1, off2;

    mismatch_offset = 0;
    if (size == 0) return 1;

    if (!check_addr_allocated(addr1, size, file, line))
        return 0;
    if (!check_addr_allocated(addr2, size, file, line))
        return 0;

    base1 = addr_to_block[floor_granule(addr1)];
    base2 = addr_to_block[floor_granule(addr2)];
    off1  = addr1 - base1;
    off2  = addr2 - base2;

    for (int unsigned i = 0; i < size; i++) begin
        if (block_data[base1][off1 + i] != block_data[base2][off2 + i]) begin
            mismatch_offset = i;
            return 0;
        end
    end

    return 1;
endfunction

function void host_mem_manager::hexdump(bit [63:0] addr, int unsigned size);
    bit [63:0] block_base;
    int unsigned offset;
    string hex_str, ascii_str;
    byte prev_line[16];
    byte current_line[16];
    int unsigned row_size;
    bit is_repeat;
    bit in_repeat;
    alloc_info_t info;

    if (size == 0) return;

    if (!addr_to_block.exists(floor_granule(addr))) begin
        `uvm_warning("HOST_MEM", $sformatf("hexdump: address 0x%016h not allocated", addr))
        return;
    end

    block_base = addr_to_block[floor_granule(addr)];
    info = alloc_table[block_base];

    // Bounds check
    offset = addr - block_base;
    if ((offset + size) > info.buddy_size) begin
        `uvm_warning("HOST_MEM", $sformatf(
            "hexdump: range [0x%016h +%0d] exceeds block size %0d, truncating",
            addr, size, info.buddy_size))
        size = info.buddy_size - offset;
    end

    $display("[HOST_MEM] hexdump: 0x%016h - 0x%016h (%0d bytes, block base=0x%016h, req_size=%0d)",
        addr, addr + size - 1, size, block_base, info.req_size);

    in_repeat = 0;

    for (int unsigned row = 0; row < size; row += 16) begin
        row_size = (size - row) < 16 ? (size - row) : 16;

        for (int unsigned i = 0; i < 16; i++) begin
            if (i < row_size)
                current_line[i] = block_data[block_base][offset + row + i];
            else
                current_line[i] = 0;
        end

        if (row > 0 && row_size == 16) begin
            is_repeat = 1;
            for (int i = 0; i < 16; i++) begin
                if (current_line[i] != prev_line[i]) begin
                    is_repeat = 0;
                    break;
                end
            end
        end else begin
            is_repeat = 0;
        end

        if (is_repeat) begin
            if (!in_repeat) begin
                $display("*");
                in_repeat = 1;
            end
        end else begin
            in_repeat = 0;

            hex_str = "";
            for (int unsigned i = 0; i < 16; i++) begin
                if (i < row_size)
                    hex_str = {hex_str, $sformatf("%02h ", current_line[i])};
                else
                    hex_str = {hex_str, "   "};
                if (i == 7) hex_str = {hex_str, " "};
            end

            ascii_str = "";
            for (int unsigned i = 0; i < row_size; i++) begin
                if (current_line[i] >= 8'h20 && current_line[i] <= 8'h7E)
                    ascii_str = {ascii_str, string'(current_line[i])};
                else
                    ascii_str = {ascii_str, "."};
            end

            $display("0x%016h: %s |%s|", addr + row, hex_str, ascii_str);
        end

        prev_line = current_line;
    end
endfunction

function void host_mem_manager::print_alloc_table();
    int idx = 0;
    bit [63:0] addr;
    alloc_info_t info;

    $display("[HOST_MEM] Allocation Table (%0d blocks):", alloc_count);

    if (alloc_table.first(addr)) begin
        do begin
            info = alloc_table[addr];
            $display("  #%0d  base=0x%016h  req_size=%-8d  buddy_size=%-8d  align=%-4d  alloc @ %0t  from %s:%0d",
                idx, info.base_addr, info.req_size, info.buddy_size, info.align,
                info.alloc_time, info.caller_file, info.caller_line);
            idx++;
        end while (alloc_table.next(addr));
    end
endfunction

function void host_mem_manager::print_stats();
    int unsigned free_chunks = 0;
    int unsigned free_levels = 0;
    int unsigned count;
    int level;

    if (free_blocks.first(level)) begin
        do begin
            count = free_blocks[level].num();
            if (count > 0) begin
                free_chunks += count;
                free_levels++;
            end
        end while (free_blocks.next(level));
    end

    $display("[HOST_MEM] Memory Statistics:");
    foreach (regions[i])
        $display("  Region[%0d]:      0x%016h - 0x%016h (%0d bytes)",
            i, regions[i].base_addr, regions[i].end_addr,
            regions[i].end_addr - regions[i].base_addr + 1);

    $display("  Allocated:      %0d bytes (%0d blocks)", allocated_size, alloc_count);
    $display("  Free:           %0d bytes", free_size);

    if (total_size > 0)
        $display("  Utilization:    %0.2f%%", real'(allocated_size) * 100.0 / real'(total_size));
    else
        $display("  Utilization:    N/A");

    if (mode == MODE_LINEAR)
        $display("  Fragmentation:  %0d free segments (linear mode)", free_list.size());
    else
        $display("  Fragmentation:  %0d free chunks across %0d levels", free_chunks, free_levels);
    $display("  Total alloc ops:  %0d", total_alloc_ops);
    $display("  Total free ops:   %0d", total_free_ops);
    $display("  History entries:  %0d", history.size());
endfunction

function void host_mem_manager::print_history(int unsigned last_n = 0);
    int unsigned start_idx;
    int unsigned total = history.size();

    if (last_n == 0 || last_n >= total)
        start_idx = 0;
    else
        start_idx = total - last_n;

    if (last_n > 0 && last_n < total)
        $display("[HOST_MEM] Memory History (last %0d of %0d):", last_n, total);
    else
        $display("[HOST_MEM] Memory History (%0d entries):", total);

    for (int i = total - 1; i >= int'(start_idx); i--) begin
        $display("  [%0d] %-14s @ %0t  addr=0x%016h  size=%-8d  from %s:%0d",
            i + 1, history[i].op, history[i].timestamp,
            history[i].base_addr, history[i].size,
            history[i].caller_file, history[i].caller_line);
    end
endfunction

function void host_mem_manager::leak_check(string file = "", int line = 0);
    bit [63:0] addr;
    longint unsigned leak_bytes = 0;
    string msg;
    alloc_info_t info;

    if (alloc_count == 0) begin
        `uvm_info("HOST_MEM", "Leak check passed: 0 blocks outstanding", UVM_LOW)
        return;
    end

    if (alloc_table.first(addr)) begin
        do begin
            leak_bytes += alloc_table[addr].req_size;
        end while (alloc_table.next(addr));
    end

    msg = $sformatf("Leak check: %0d blocks not freed (total %0d bytes):", alloc_count, leak_bytes);

    if (alloc_table.first(addr)) begin
        do begin
            info = alloc_table[addr];
            msg = {msg, $sformatf("\n  base=0x%016h  req_size=%-8d  alloc @ %0t  from %s:%0d",
                info.base_addr, info.req_size, info.alloc_time,
                info.caller_file, info.caller_line)};
        end while (alloc_table.next(addr));
    end

    `uvm_warning("HOST_MEM", msg)
endfunction

// ========== Linear Allocator Implementations ==========

function void host_mem_manager::insert_free_seg_merge(bit [63:0] addr, longint unsigned size);
    int insert_idx = -1;
    free_seg_t new_seg;

    if (size == 0) return;

    new_seg.addr = addr;
    new_seg.size = size;

    foreach (free_list[i]) begin
        if (free_list[i].addr > addr) begin
            insert_idx = i;
            break;
        end
    end
    if (insert_idx == -1)
        insert_idx = free_list.size();

    free_list.insert(insert_idx, new_seg);

    // Merge with right neighbor
    if (insert_idx + 1 < free_list.size() &&
        free_list[insert_idx].addr + free_list[insert_idx].size == free_list[insert_idx + 1].addr) begin
        free_list[insert_idx].size += free_list[insert_idx + 1].size;
        free_list.delete(insert_idx + 1);
    end

    // Merge with left neighbor
    if (insert_idx > 0 &&
        free_list[insert_idx - 1].addr + free_list[insert_idx - 1].size == free_list[insert_idx].addr) begin
        free_list[insert_idx - 1].size += free_list[insert_idx].size;
        free_list.delete(insert_idx);
    end
endfunction

function bit [63:0] host_mem_manager::alloc_linear(int unsigned size, int unsigned align, string file, int line);
    int unsigned occ_size;       // physical occupation, min_granule-aligned
    int unsigned eff_align;
    int found_idx = -1;
    bit [63:0] aligned_start;
    longint unsigned pre_gap;
    longint unsigned post_size;
    bit [63:0] seg_addr;
    longint unsigned seg_size;
    bit [63:0] cand_start;
    bit [63:0] seg_end;
    alloc_info_t info;
    int unsigned num_sub_blocks;

    // Round occupation up to min_granule
    occ_size = ((size + min_granule - 1) / min_granule) * min_granule;

    // Enforce minimum alignment so reverse-mapping stays unambiguous
    eff_align = (align < min_granule) ? min_granule : round_up_pow2(align);

    // First-fit scan
    foreach (free_list[i]) begin
        cand_start = ((free_list[i].addr + eff_align - 1) / eff_align) * eff_align;
        seg_end    = free_list[i].addr + free_list[i].size;
        if (cand_start + occ_size <= seg_end) begin
            found_idx     = i;
            aligned_start = cand_start;
            seg_addr      = free_list[i].addr;
            seg_size      = free_list[i].size;
            break;
        end
    end

    if (found_idx == -1) begin
        `uvm_error("HOST_MEM", $sformatf(
            "alloc(LINEAR): no segment fits size=%0d align=%0d (occ=%0d, eff_align=%0d)\n  -> Called from: %s:%0d",
            size, align, occ_size, eff_align, file, line))
        return '1;
    end

    pre_gap   = aligned_start - seg_addr;
    post_size = seg_size - pre_gap - occ_size;

    // Remove old segment, reinsert remainders
    free_list.delete(found_idx);
    if (pre_gap > 0)
        insert_free_seg_merge(seg_addr, pre_gap);
    if (post_size > 0)
        insert_free_seg_merge(aligned_start + occ_size, post_size);

    // Track allocation
    info.base_addr   = aligned_start;
    info.buddy_size  = occ_size;
    info.req_size    = size;
    info.align       = align;
    info.caller_file = file;
    info.caller_line = line;
    info.alloc_time  = $realtime;
    alloc_table[aligned_start] = info;

    add_reverse_mapping(aligned_start, occ_size);
    block_data[aligned_start] = new[occ_size];

    num_sub_blocks = occ_size / min_granule;
    sub_block_valid[aligned_start] = new[num_sub_blocks];
    foreach (sub_block_valid[aligned_start][i])
        sub_block_valid[aligned_start][i] = 1;

    allocated_size += occ_size;
    free_size      -= occ_size;
    alloc_count++;
    total_alloc_ops++;

    record_history("ALLOC", aligned_start, size, file, line);

    `uvm_info("HOST_MEM", $sformatf(
        "alloc(LINEAR): addr=0x%016h req_size=%0d occ=%0d align=%0d\n  -> Called from: %s:%0d",
        aligned_start, size, occ_size, align, file, line), UVM_HIGH)

    return aligned_start;
endfunction

function void host_mem_manager::free_linear(bit [63:0] addr, alloc_info_t info, string file, int line);
    int unsigned occ_size = info.buddy_size;

    // Poison data
    foreach (block_data[addr][i])
        block_data[addr][i] = poison_pattern;

    block_data.delete(addr);
    alloc_table.delete(addr);
    remove_reverse_mapping(addr, occ_size);
    sub_block_valid.delete(addr);

    // Return to free list + merge neighbors
    insert_free_seg_merge(addr, occ_size);

    allocated_size -= occ_size;
    free_size      += occ_size;
    alloc_count--;
    total_free_ops++;

    record_history("FREE", addr, info.req_size, file, line);

    `uvm_info("HOST_MEM", $sformatf(
        "free(LINEAR): addr=0x%016h occ=%0d\n  -> Called from: %s:%0d",
        addr, occ_size, file, line), UVM_HIGH)
endfunction

`endif
