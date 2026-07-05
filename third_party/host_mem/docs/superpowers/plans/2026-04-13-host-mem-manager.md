# Host Memory Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a SystemVerilog Buddy System memory manager (`uvm_object`) for verification environments, supporting 64-bit address space allocation, byte-level read/write, safety checks, and debug diagnostics.

**Architecture:** Single-class design (`host_mem_manager` extends `uvm_object`). Buddy allocator manages address space with 64B minimum granularity. Data stored in per-block dynamic byte arrays. Sub-block validity bitmap enables partial release for DMA scenarios. All read/write operations checked against allocation state with caller tracing via `__FILE__`/`__LINE__`.

**Tech Stack:** SystemVerilog, UVM (`uvm_object`, `uvm_info`/`uvm_warning`/`uvm_fatal`/`uvm_error` macros)

---

## File Structure

```
host_mem/
  src/
    host_mem_pkg.sv        -- package: typedefs (alloc_info_t, mem_history_t, region_info_t), constants
    host_mem_manager.sv    -- class host_mem_manager extends uvm_object: all functionality
  tb/
    host_mem_tb.sv         -- testbench: unit tests for all features
```

- `host_mem_pkg.sv`: Contains all `typedef struct`, constants (`MIN_BLOCK_SIZE`, `DEFAULT_POISON`), and `import uvm_pkg::*`. Small file (~60 lines).
- `host_mem_manager.sv`: The main class. Organized into method groups: helpers, init, alloc/free, read/write, bulk ops, debug. (~700 lines).
- `host_mem_tb.sv`: Self-checking testbench using UVM report catcher to verify FATAL/ERROR conditions. (~400 lines).

---

### Task 1: Package and Class Skeleton

**Files:**
- Create: `src/host_mem_pkg.sv`
- Create: `src/host_mem_manager.sv`

- [ ] **Step 1: Create `host_mem_pkg.sv` with typedefs and constants**

```sv
`ifndef HOST_MEM_PKG_SV
`define HOST_MEM_PKG_SV

package host_mem_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    parameter int unsigned MIN_BLOCK_SIZE = 64;
    parameter byte         DEFAULT_POISON = 8'hDE;

    typedef struct {
        bit [63:0]   base_addr;
        int unsigned buddy_size;
        int unsigned req_size;
        int unsigned align;
        string       caller_file;
        int          caller_line;
        realtime     alloc_time;
    } alloc_info_t;

    typedef struct {
        string       op;
        bit [63:0]   base_addr;
        int unsigned size;
        string       caller_file;
        int          caller_line;
        realtime     timestamp;
    } mem_history_t;

    typedef struct {
        bit [63:0] base_addr;
        bit [63:0] end_addr;
    } region_info_t;

endpackage

`endif
```

- [ ] **Step 2: Create `host_mem_manager.sv` class skeleton with data structures**

```sv
`ifndef HOST_MEM_MANAGER_SV
`define HOST_MEM_MANAGER_SV

class host_mem_manager extends uvm_object;

    `uvm_object_utils(host_mem_manager)

    // ========== Configuration ==========
    byte poison_pattern = DEFAULT_POISON;
    bit  warn_on_poison_read = 0;

    // ========== Buddy Free Lists ==========
    // free_blocks[level][base_addr] = 1; level 0=64B, 1=128B, ...
    protected bit free_blocks[int][bit[63:0]];

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
    extern protected function int unsigned round_up_pow2(int unsigned val);
    extern protected function int unsigned log2_floor(int unsigned val);
    extern protected function int unsigned addr_to_level(int unsigned size);
    extern protected function bit [63:0] get_buddy_addr(bit [63:0] addr, int unsigned level);
    extern protected function void add_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    extern protected function void remove_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    extern protected function void record_history(string op, bit [63:0] addr, int unsigned size, string file, int line);
    extern protected function bit check_addr_allocated(bit [63:0] addr, int unsigned size, string file, int line);

    // Init
    extern function void init_region(bit [63:0] base_addr, bit [63:0] end_addr, byte poison = DEFAULT_POISON);

    // Alloc & Free
    extern function bit [63:0] alloc(int unsigned size, int unsigned align = 1, string file = "", int line = 0);
    extern function void free(bit [63:0] addr, string file = "", int line = 0);
    extern function void release_range(bit [63:0] addr, int unsigned size, string file = "", int line = 0);

    // Data Read/Write
    extern function void write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
    extern function void read_mem(bit [63:0] addr, int unsigned size, ref byte data[], string file = "", int line = 0);

    // Bulk Operations
    extern function void mem_set(bit [63:0] addr, byte value, int unsigned size, string file = "", int line = 0);
    extern function void mem_cpy(bit [63:0] dst_addr, bit [63:0] src_addr, int unsigned size, string file = "", int line = 0);
    extern function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size, output int unsigned mismatch_offset, string file = "", int line = 0);

    // Debug
    extern function void hexdump(bit [63:0] addr, int unsigned size);
    extern function void print_alloc_table();
    extern function void print_stats();
    extern function void print_history(int unsigned last_n = 0);
    extern function void leak_check(string file = "", int line = 0);

endclass

`endif
```

Note: SV 中 `free`, `write`, `read` 是保留字或可能与 UVM 方法冲突，因此使用 `free`(非保留字可用), `write_mem`, `read_mem`, `mem_set`, `mem_cpy`, `mem_compare` 作为方法名以避免冲突。

- [ ] **Step 3: Verify compilation**

Run: `cd /home/ubuntu/ryan/shm_work/host_mem && ls src/`
Expected: `host_mem_pkg.sv  host_mem_manager.sv`

- [ ] **Step 4: Commit**

```bash
git add src/host_mem_pkg.sv src/host_mem_manager.sv
git commit -m "feat: add host_mem_manager package and class skeleton"
```

---

### Task 2: Helper Functions

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `round_up_pow2`**

```sv
// Returns the smallest power of 2 >= val. If val is 0, returns 1.
function int unsigned host_mem_manager::round_up_pow2(int unsigned val);
    int unsigned result;
    if (val == 0) return 1;
    if (val == 1) return 1;
    result = 1;
    while (result < val)
        result = result << 1;
    return result;
endfunction
```

- [ ] **Step 2: Implement `log2_floor`**

```sv
// Returns floor(log2(val)). val must be > 0.
function int unsigned host_mem_manager::log2_floor(int unsigned val);
    int unsigned result = 0;
    val = val >> 1;
    while (val > 0) begin
        result++;
        val = val >> 1;
    end
    return result;
endfunction
```

- [ ] **Step 3: Implement `addr_to_level` and `get_buddy_addr`**

```sv
// Convert block size to buddy level. level 0 = MIN_BLOCK_SIZE (64B).
function int unsigned host_mem_manager::addr_to_level(int unsigned size);
    return log2_floor(size / MIN_BLOCK_SIZE);
endfunction

// Calculate buddy address by XOR with block size at given level.
function bit [63:0] host_mem_manager::get_buddy_addr(bit [63:0] addr, int unsigned level);
    longint unsigned block_size = MIN_BLOCK_SIZE << level;
    return addr ^ block_size;
endfunction
```

- [ ] **Step 4: Implement reverse mapping helpers**

```sv
// Add 64B-granularity reverse mappings for a block.
function void host_mem_manager::add_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    int unsigned num_entries = buddy_size / MIN_BLOCK_SIZE;
    for (int unsigned i = 0; i < num_entries; i++) begin
        addr_to_block[base + i * MIN_BLOCK_SIZE] = base;
    end
endfunction

// Remove 64B-granularity reverse mappings for a block.
function void host_mem_manager::remove_reverse_mapping(bit [63:0] base, int unsigned buddy_size);
    int unsigned num_entries = buddy_size / MIN_BLOCK_SIZE;
    for (int unsigned i = 0; i < num_entries; i++) begin
        addr_to_block.delete(base + i * MIN_BLOCK_SIZE);
    end
endfunction
```

- [ ] **Step 5: Implement `record_history`**

```sv
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
```

- [ ] **Step 6: Implement `check_addr_allocated`**

```sv
// Verify addr..addr+size-1 is within a single allocated block and all sub-blocks are valid.
// Returns 1 if OK, 0 if FATAL was issued.
function bit host_mem_manager::check_addr_allocated(bit [63:0] addr, int unsigned size, string file, int line);
    bit [63:0] aligned_addr;
    bit [63:0] block_base;
    alloc_info_t info;
    int unsigned start_idx, end_idx;

    // Check start address
    aligned_addr = (addr >> 6) << 6;  // align to 64B
    if (!addr_to_block.exists(aligned_addr)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "Accessing unallocated address 0x%016h\n  -> Called from: %s:%0d",
            addr, file, line))
        return 0;
    end

    block_base = addr_to_block[aligned_addr];
    info = alloc_table[block_base];

    // Check within req_size boundary
    if (addr < block_base || (addr + size) > (block_base + info.req_size)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "Access [0x%016h +%0d] exceeds block boundary [0x%016h +%0d]\n  -> Called from: %s:%0d",
            addr, size, block_base, info.req_size, file, line))
        return 0;
    end

    // Check sub_block_valid for all touched 64B sub-blocks
    start_idx = (addr - block_base) / MIN_BLOCK_SIZE;
    end_idx   = (addr + size - 1 - block_base) / MIN_BLOCK_SIZE;
    for (int unsigned i = start_idx; i <= end_idx; i++) begin
        if (!sub_block_valid[block_base][i]) begin
            `uvm_fatal("HOST_MEM", $sformatf(
                "Accessing released sub-range at 0x%016h (sub-block index %0d)\n  -> Called from: %s:%0d",
                block_base + i * MIN_BLOCK_SIZE, i, file, line))
            return 0;
        end
    end

    return 1;
endfunction
```

- [ ] **Step 7: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement buddy helper functions"
```

---

### Task 3: Region Init

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `init_region`**

```sv
function void host_mem_manager::init_region(bit [63:0] base_addr, bit [63:0] end_addr, byte poison = DEFAULT_POISON);
    longint unsigned region_size;
    bit [63:0] current_addr;
    int unsigned block_size;
    int unsigned level;
    region_info_t r;

    if (end_addr <= base_addr) begin
        `uvm_error("HOST_MEM", $sformatf(
            "Invalid region: base=0x%016h end=0x%016h (end must be > base)", base_addr, end_addr))
        return;
    end

    poison_pattern = poison;
    region_size = end_addr - base_addr + 1;

    // Record region
    r.base_addr = base_addr;
    r.end_addr  = end_addr;
    regions.push_back(r);

    // Decompose region into power-of-2 blocks (greedy, largest first)
    current_addr = base_addr;
    while (current_addr <= end_addr) begin
        longint unsigned remaining = end_addr - current_addr + 1;

        // Find largest power-of-2 block that:
        // 1. Fits in remaining space
        // 2. Is naturally aligned at current_addr
        block_size = MIN_BLOCK_SIZE;
        while ((block_size << 1) <= remaining &&
               (current_addr % (block_size << 1)) == 0 &&
               (block_size << 1) > 0)  // overflow guard
            block_size = block_size << 1;

        level = addr_to_level(block_size);
        free_blocks[level][current_addr] = 1;

        `uvm_info("HOST_MEM", $sformatf(
            "init_region: added free block at 0x%016h, size=%0dB (level=%0d)",
            current_addr, block_size, level), UVM_HIGH)

        current_addr = current_addr + block_size;
    end

    total_size = total_size + region_size;
    free_size  = free_size + region_size;
endfunction
```

- [ ] **Step 2: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement init_region with greedy power-of-2 decomposition"
```

---

### Task 4: Alloc

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `alloc`**

```sv
function bit [63:0] host_mem_manager::alloc(int unsigned size, int unsigned align = 1, string file = "", int line = 0);
    int unsigned buddy_size;
    int unsigned target_level;
    int unsigned search_level;
    bit [63:0] block_addr;
    bit found;
    alloc_info_t info;
    int unsigned num_sub_blocks;

    // Validate
    if (size == 0) begin
        `uvm_error("HOST_MEM", $sformatf("alloc: size=0 is invalid\n  -> Called from: %s:%0d", file, line))
        return '1;  // return -1
    end

    // Calculate buddy_size: max of round_up(size), align, MIN_BLOCK_SIZE
    buddy_size = round_up_pow2(size);
    if (align > buddy_size) buddy_size = round_up_pow2(align);
    if (buddy_size < MIN_BLOCK_SIZE) buddy_size = MIN_BLOCK_SIZE;

    target_level = addr_to_level(buddy_size);

    // Search for free block: from target_level upward
    found = 0;
    for (search_level = target_level; ; search_level++) begin
        if (free_blocks.exists(search_level) && free_blocks[search_level].num() > 0) begin
            // Get first available block
            void'(free_blocks[search_level].first(block_addr));
            found = 1;
            break;
        end
        // Stop if we've checked all existing levels
        if (!free_blocks.exists(search_level) && search_level > target_level + 40)
            break;  // max 40 levels = 64B * 2^40 = 64TB, more than enough
    end

    if (!found) begin
        `uvm_error("HOST_MEM", $sformatf(
            "alloc: insufficient space for size=%0d align=%0d (buddy_size=%0d)\n  -> Called from: %s:%0d",
            size, align, buddy_size, file, line))
        return '1;
    end

    // Remove the found block from free list
    free_blocks[search_level].delete(block_addr);
    if (free_blocks[search_level].num() == 0)
        free_blocks.delete(search_level);

    // Split down to target level
    while (search_level > target_level) begin
        search_level--;
        // Put the upper buddy half into free list
        bit [63:0] buddy = block_addr + (MIN_BLOCK_SIZE << search_level);
        free_blocks[search_level][buddy] = 1;
        // Keep the lower half (block_addr stays the same)
    end

    // Record allocation
    info.base_addr   = block_addr;
    info.buddy_size  = buddy_size;
    info.req_size    = size;
    info.align       = align;
    info.caller_file = file;
    info.caller_line = line;
    info.alloc_time  = $realtime;
    alloc_table[block_addr] = info;

    // Reverse mapping
    add_reverse_mapping(block_addr, buddy_size);

    // Data storage
    block_data[block_addr] = new[buddy_size];

    // Sub-block validity bitmap: all valid
    num_sub_blocks = buddy_size / MIN_BLOCK_SIZE;
    sub_block_valid[block_addr] = new[num_sub_blocks];
    foreach (sub_block_valid[block_addr][i])
        sub_block_valid[block_addr][i] = 1;

    // Statistics
    allocated_size  += buddy_size;
    free_size       -= buddy_size;
    alloc_count++;
    total_alloc_ops++;

    // History
    record_history("ALLOC", block_addr, size, file, line);

    `uvm_info("HOST_MEM", $sformatf(
        "alloc: addr=0x%016h req_size=%0d buddy_size=%0d align=%0d\n  -> Called from: %s:%0d",
        block_addr, size, buddy_size, align, file, line), UVM_HIGH)

    return block_addr;
endfunction
```

- [ ] **Step 2: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement buddy alloc with split and alignment"
```

---

### Task 5: Free and Release Range

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `free`**

```sv
function void host_mem_manager::free(bit [63:0] addr, string file = "", int line = 0);
    alloc_info_t info;
    int unsigned buddy_size;
    int unsigned level;
    bit [63:0] current_addr;
    bit [63:0] buddy_addr;

    // Check if it's a valid alloc base
    if (!alloc_table.exists(addr)) begin
        // Check history for double-free detection
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
    level = addr_to_level(buddy_size);

    // Poison fill
    foreach (block_data[addr][i])
        block_data[addr][i] = poison_pattern;

    // Remove data, alloc_table, reverse mapping, sub_block_valid
    block_data.delete(addr);
    alloc_table.delete(addr);
    remove_reverse_mapping(addr, buddy_size);
    sub_block_valid.delete(addr);

    // Buddy merge loop
    current_addr = addr;
    while (1) begin
        buddy_addr = get_buddy_addr(current_addr, level);
        if (free_blocks.exists(level) && free_blocks[level].exists(buddy_addr)) begin
            // Merge: remove buddy from free list
            free_blocks[level].delete(buddy_addr);
            if (free_blocks[level].num() == 0)
                free_blocks.delete(level);
            // Take the lower address
            if (buddy_addr < current_addr)
                current_addr = buddy_addr;
            level++;
        end else begin
            break;
        end
    end

    // Add merged block to free list
    free_blocks[level][current_addr] = 1;

    // Statistics
    allocated_size -= buddy_size;
    free_size      += buddy_size;
    alloc_count--;
    total_free_ops++;

    // History
    record_history("FREE", addr, info.req_size, file, line);

    `uvm_info("HOST_MEM", $sformatf(
        "free: addr=0x%016h buddy_size=%0d merged to level=%0d at 0x%016h\n  -> Called from: %s:%0d",
        addr, buddy_size, level, current_addr, file, line), UVM_HIGH)
endfunction
```

- [ ] **Step 2: Implement `release_range`**

```sv
function void host_mem_manager::release_range(bit [63:0] addr, int unsigned size, string file = "", int line = 0);
    bit [63:0] aligned_addr;
    bit [63:0] block_base;
    alloc_info_t info;
    int unsigned start_idx, end_idx;
    bit all_released;

    // Check 64B alignment
    if ((addr % MIN_BLOCK_SIZE) != 0 || (size % MIN_BLOCK_SIZE) != 0) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "release_range: addr=0x%016h size=%0d must be %0dB-aligned\n  -> Called from: %s:%0d",
            addr, size, MIN_BLOCK_SIZE, file, line))
        return;
    end

    // Find owning block
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

    // Check range is within block
    if ((addr + size) > (block_base + info.buddy_size)) begin
        `uvm_fatal("HOST_MEM", $sformatf(
            "release_range: range [0x%016h +%0d] exceeds block [0x%016h +%0d]\n  -> Called from: %s:%0d",
            addr, size, block_base, info.buddy_size, file, line))
        return;
    end

    // Calculate sub-block indices
    start_idx = (addr - block_base) / MIN_BLOCK_SIZE;
    end_idx   = start_idx + (size / MIN_BLOCK_SIZE) - 1;

    // Check for double-release and poison fill
    for (int unsigned i = start_idx; i <= end_idx; i++) begin
        if (!sub_block_valid[block_base][i]) begin
            `uvm_warning("HOST_MEM", $sformatf(
                "release_range: sub-block %0d at 0x%016h already released\n  -> Called from: %s:%0d",
                i, block_base + i * MIN_BLOCK_SIZE, file, line))
        end else begin
            sub_block_valid[block_base][i] = 0;
            // Poison fill this 64B sub-block in block_data
            for (int unsigned b = 0; b < MIN_BLOCK_SIZE; b++) begin
                int unsigned offset = i * MIN_BLOCK_SIZE + b;
                if (offset < info.buddy_size)
                    block_data[block_base][offset] = poison_pattern;
            end
        end
    end

    // Record history
    record_history("RELEASE_RANGE", addr, size, file, line);

    // Check if all sub-blocks are released -> auto free
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
```

- [ ] **Step 3: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement free with buddy merge and release_range with auto-free"
```

---

### Task 6: Data Read/Write

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `write_mem`**

```sv
function void host_mem_manager::write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
    bit [63:0] block_base;
    int unsigned offset;

    if (data.size() == 0) return;

    if (!check_addr_allocated(addr, data.size(), file, line))
        return;

    block_base = addr_to_block[(addr >> 6) << 6];
    offset = addr - block_base;

    foreach (data[i])
        block_data[block_base][offset + i] = data[i];
endfunction
```

- [ ] **Step 2: Implement `read_mem`**

```sv
function void host_mem_manager::read_mem(bit [63:0] addr, int unsigned size, ref byte data[], string file = "", int line = 0);
    bit [63:0] block_base;
    int unsigned offset;
    bit all_poison;

    if (size == 0) return;

    if (!check_addr_allocated(addr, size, file, line))
        return;

    block_base = addr_to_block[(addr >> 6) << 6];
    offset = addr - block_base;

    data = new[size];
    foreach (data[i])
        data[i] = block_data[block_base][offset + i];

    // Optional poison read warning
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
```

- [ ] **Step 3: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement write_mem and read_mem with safety checks"
```

---

### Task 7: Bulk Operations

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `mem_set`**

```sv
function void host_mem_manager::mem_set(bit [63:0] addr, byte value, int unsigned size, string file = "", int line = 0);
    bit [63:0] block_base;
    int unsigned offset;

    if (size == 0) return;

    if (!check_addr_allocated(addr, size, file, line))
        return;

    block_base = addr_to_block[(addr >> 6) << 6];
    offset = addr - block_base;

    for (int unsigned i = 0; i < size; i++)
        block_data[block_base][offset + i] = value;
endfunction
```

- [ ] **Step 2: Implement `mem_cpy`**

```sv
function void host_mem_manager::mem_cpy(bit [63:0] dst_addr, bit [63:0] src_addr, int unsigned size, string file = "", int line = 0);
    byte temp_data[];

    if (size == 0) return;

    // Validate both src and dst
    if (!check_addr_allocated(src_addr, size, file, line))
        return;
    if (!check_addr_allocated(dst_addr, size, file, line))
        return;

    // Read from src into temp buffer (handles overlap safely)
    begin
        bit [63:0] src_base = addr_to_block[(src_addr >> 6) << 6];
        int unsigned src_offset = src_addr - src_base;
        temp_data = new[size];
        for (int unsigned i = 0; i < size; i++)
            temp_data[i] = block_data[src_base][src_offset + i];
    end

    // Write to dst
    begin
        bit [63:0] dst_base = addr_to_block[(dst_addr >> 6) << 6];
        int unsigned dst_offset = dst_addr - dst_base;
        for (int unsigned i = 0; i < size; i++)
            block_data[dst_base][dst_offset + i] = temp_data[i];
    end
endfunction
```

- [ ] **Step 3: Implement `mem_compare`**

```sv
function bit host_mem_manager::mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size, output int unsigned mismatch_offset, string file = "", int line = 0);
    bit [63:0] base1, base2;
    int unsigned off1, off2;

    mismatch_offset = 0;
    if (size == 0) return 1;

    if (!check_addr_allocated(addr1, size, file, line))
        return 0;
    if (!check_addr_allocated(addr2, size, file, line))
        return 0;

    base1 = addr_to_block[(addr1 >> 6) << 6];
    base2 = addr_to_block[(addr2 >> 6) << 6];
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
```

- [ ] **Step 4: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement mem_set, mem_cpy, mem_compare bulk operations"
```

---

### Task 8: Debug Interface

**Files:**
- Modify: `src/host_mem_manager.sv`

- [ ] **Step 1: Implement `hexdump`**

```sv
function void host_mem_manager::hexdump(bit [63:0] addr, int unsigned size);
    bit [63:0] block_base;
    int unsigned offset;
    string hex_str, ascii_str, line_str;
    byte prev_line[16];
    bit is_repeat;
    bit in_repeat;
    alloc_info_t info;

    if (size == 0) return;

    // Verify address is allocated (use silent check - just find the block)
    if (!addr_to_block.exists((addr >> 6) << 6)) begin
        `uvm_warning("HOST_MEM", $sformatf("hexdump: address 0x%016h not allocated", addr))
        return;
    end

    block_base = addr_to_block[(addr >> 6) << 6];
    info = alloc_table[block_base];

    $display("[HOST_MEM] hexdump: 0x%016h - 0x%016h (%0d bytes, block base=0x%016h, req_size=%0d)",
        addr, addr + size - 1, size, block_base, info.req_size);

    offset = addr - block_base;
    in_repeat = 0;

    for (int unsigned row = 0; row < size; row += 16) begin
        int unsigned row_size = (size - row) < 16 ? (size - row) : 16;
        byte current_line[16];

        // Read current line
        for (int unsigned i = 0; i < 16; i++) begin
            if (i < row_size)
                current_line[i] = block_data[block_base][offset + row + i];
            else
                current_line[i] = 0;
        end

        // Check for repeat (skip first row)
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

            // Format hex
            hex_str = "";
            for (int unsigned i = 0; i < 16; i++) begin
                if (i < row_size)
                    hex_str = {hex_str, $sformatf("%02h ", current_line[i])};
                else
                    hex_str = {hex_str, "   "};
                if (i == 7) hex_str = {hex_str, " "};
            end

            // Format ASCII
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
```

- [ ] **Step 2: Implement `print_alloc_table`**

```sv
function void host_mem_manager::print_alloc_table();
    int idx = 0;
    bit [63:0] addr;

    $display("[HOST_MEM] Allocation Table (%0d blocks):", alloc_count);

    if (alloc_table.first(addr)) begin
        do begin
            alloc_info_t info = alloc_table[addr];
            $display("  #%0d  base=0x%016h  req_size=%-8d  buddy_size=%-8d  align=%-4d  alloc @ %0t  from %s:%0d",
                idx, info.base_addr, info.req_size, info.buddy_size, info.align,
                info.alloc_time, info.caller_file, info.caller_line);
            idx++;
        end while (alloc_table.next(addr));
    end
endfunction
```

- [ ] **Step 3: Implement `print_stats`**

```sv
function void host_mem_manager::print_stats();
    int unsigned free_chunks = 0;
    int unsigned free_levels = 0;
    int level;

    // Count free chunks and levels
    if (free_blocks.first(level)) begin
        do begin
            int unsigned count = free_blocks[level].num();
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

    $display("  Fragmentation:  %0d free chunks across %0d levels", free_chunks, free_levels);
    $display("  Total alloc ops:  %0d", total_alloc_ops);
    $display("  Total free ops:   %0d", total_free_ops);
    $display("  History entries:  %0d", history.size());
endfunction
```

- [ ] **Step 4: Implement `print_history`**

```sv
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
```

- [ ] **Step 5: Implement `leak_check`**

```sv
function void host_mem_manager::leak_check(string file = "", int line = 0);
    bit [63:0] addr;
    longint unsigned leak_bytes = 0;

    if (alloc_count == 0) begin
        `uvm_info("HOST_MEM", "Leak check passed: 0 blocks outstanding", UVM_LOW)
        return;
    end

    // Calculate total leaked bytes
    if (alloc_table.first(addr)) begin
        do begin
            leak_bytes += alloc_table[addr].req_size;
        end while (alloc_table.next(addr));
    end

    // Report
    begin
        string msg;
        msg = $sformatf("Leak check: %0d blocks not freed (total %0d bytes):", alloc_count, leak_bytes);

        if (alloc_table.first(addr)) begin
            do begin
                alloc_info_t info = alloc_table[addr];
                msg = {msg, $sformatf("\n  base=0x%016h  req_size=%-8d  alloc @ %0t  from %s:%0d",
                    info.base_addr, info.req_size, info.alloc_time,
                    info.caller_file, info.caller_line)};
            end while (alloc_table.next(addr));
        end

        `uvm_warning("HOST_MEM", msg)
    end
endfunction
```

- [ ] **Step 6: Commit**

```bash
git add src/host_mem_manager.sv
git commit -m "feat: implement debug interface - hexdump, stats, history, leak_check"
```

---

### Task 9: Testbench

**Files:**
- Create: `tb/host_mem_tb.sv`

- [ ] **Step 1: Create testbench with basic alloc/free tests**

```sv
`ifndef HOST_MEM_TB_SV
`define HOST_MEM_TB_SV

`include "uvm_macros.svh"

module host_mem_tb;

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

    initial begin
        host_mem_manager mem;
        bit [63:0] addr1, addr2, addr3;
        byte wdata[], rdata[];
        int unsigned mismatch;
        expected_msg_catcher catcher;

        // ========================================
        // Test 1: Basic init and alloc
        // ========================================
        $display("\n=== Test 1: Basic init and alloc ===");
        mem = new("mem0");
        mem.init_region(64'h0, 64'hFFFF);  // 64KB

        addr1 = mem.alloc(100, .align(64), .file(`__FILE__), .line(`__LINE__));
        assert(addr1 != '1) else $fatal(1, "alloc failed");
        assert((addr1 % 64) == 0) else $fatal(1, "alignment check failed");
        $display("Test 1 PASSED: alloc returned 0x%016h", addr1);

        // ========================================
        // Test 2: Write and read back
        // ========================================
        $display("\n=== Test 2: Write and read back ===");
        wdata = new[100];
        foreach (wdata[i]) wdata[i] = i;
        mem.write_mem(addr1, wdata, `__FILE__, `__LINE__);

        mem.read_mem(addr1, 100, rdata, `__FILE__, `__LINE__);
        foreach (rdata[i])
            assert(rdata[i] == wdata[i]) else $fatal(1, $sformatf("data mismatch at %0d", i));
        $display("Test 2 PASSED: write/read 100 bytes OK");

        // ========================================
        // Test 3: Multiple allocations, no overlap
        // ========================================
        $display("\n=== Test 3: Multiple allocations ===");
        addr2 = mem.alloc(200, .align(128), .file(`__FILE__), .line(`__LINE__));
        addr3 = mem.alloc(4, .align(4), .file(`__FILE__), .line(`__LINE__));
        assert(addr2 != '1 && addr3 != '1) else $fatal(1, "alloc failed");
        // Verify no overlap
        assert(addr2 + 200 <= addr3 || addr3 + 4 <= addr2)
            else $fatal(1, "allocations overlap!");
        $display("Test 3 PASSED: addr2=0x%016h addr3=0x%016h", addr2, addr3);

        // ========================================
        // Test 4: Free and re-alloc (buddy merge)
        // ========================================
        $display("\n=== Test 4: Free and re-alloc ===");
        mem.free(addr1, `__FILE__, `__LINE__);
        mem.free(addr2, `__FILE__, `__LINE__);
        mem.free(addr3, `__FILE__, `__LINE__);
        // After freeing all, should be able to alloc large block
        addr1 = mem.alloc(32768, .file(`__FILE__), .line(`__LINE__));
        assert(addr1 != '1) else $fatal(1, "large alloc after free failed");
        mem.free(addr1, `__FILE__, `__LINE__);
        $display("Test 4 PASSED: free+merge+realloc OK");

        // ========================================
        // Test 5: memset, memcpy, compare
        // ========================================
        $display("\n=== Test 5: Bulk operations ===");
        addr1 = mem.alloc(256, .file(`__FILE__), .line(`__LINE__));
        addr2 = mem.alloc(256, .file(`__FILE__), .line(`__LINE__));

        mem.mem_set(addr1, 8'hAA, 256, `__FILE__, `__LINE__);
        mem.mem_cpy(addr2, addr1, 256, `__FILE__, `__LINE__);
        assert(mem.mem_compare(addr1, addr2, 256, mismatch, `__FILE__, `__LINE__))
            else $fatal(1, $sformatf("compare failed at offset %0d", mismatch));

        // Modify one byte and verify compare detects it
        begin
            byte one_byte[] = '{8'hBB};
            mem.write_mem(addr2 + 100, one_byte, `__FILE__, `__LINE__);
        end
        assert(!mem.mem_compare(addr1, addr2, 256, mismatch, `__FILE__, `__LINE__))
            else $fatal(1, "compare should have found mismatch");
        assert(mismatch == 100) else $fatal(1, $sformatf("expected mismatch at 100, got %0d", mismatch));
        $display("Test 5 PASSED: memset/memcpy/compare OK");

        mem.free(addr1, `__FILE__, `__LINE__);
        mem.free(addr2, `__FILE__, `__LINE__);

        // ========================================
        // Test 6: release_range partial free
        // ========================================
        $display("\n=== Test 6: release_range ===");
        addr1 = mem.alloc(256, .file(`__FILE__), .line(`__LINE__));
        wdata = new[256];
        foreach (wdata[i]) wdata[i] = i;
        mem.write_mem(addr1, wdata, `__FILE__, `__LINE__);

        // Release first 64B
        mem.release_range(addr1, 64, `__FILE__, `__LINE__);

        // Writing to the released range should trigger FATAL (caught)
        catcher = new("catcher6");
        catcher.expected_id = "HOST_MEM";
        uvm_report_cb::add(null, catcher);
        begin
            byte small[] = '{8'h00};
            mem.write_mem(addr1, small, `__FILE__, `__LINE__);
        end
        assert(catcher.caught) else $fatal(1, "Expected FATAL for write to released range");
        uvm_report_cb::delete(null, catcher);

        // Reading from non-released range should still work
        mem.read_mem(addr1 + 64, 64, rdata, `__FILE__, `__LINE__);
        assert(rdata[0] == 64) else $fatal(1, "read from valid range failed");

        // Release remaining
        mem.release_range(addr1 + 64, 64, `__FILE__, `__LINE__);
        mem.release_range(addr1 + 128, 128, `__FILE__, `__LINE__);
        // Block should auto-free now (alloc_table entry removed)
        $display("Test 6 PASSED: release_range OK");

        // ========================================
        // Test 7: Debug output
        // ========================================
        $display("\n=== Test 7: Debug output ===");
        addr1 = mem.alloc(128, .file(`__FILE__), .line(`__LINE__));
        wdata = new[128];
        foreach (wdata[i]) wdata[i] = i;
        mem.write_mem(addr1, wdata, `__FILE__, `__LINE__);

        mem.hexdump(addr1, 128);
        mem.print_alloc_table();
        mem.print_stats();
        mem.print_history(5);

        // ========================================
        // Test 8: Leak check
        // ========================================
        $display("\n=== Test 8: Leak check ===");
        // addr1 is still allocated - should report leak
        mem.leak_check(`__FILE__, `__LINE__);

        mem.free(addr1, `__FILE__, `__LINE__);
        mem.leak_check(`__FILE__, `__LINE__);  // should pass now

        // ========================================
        // Test 9: Double-free detection
        // ========================================
        $display("\n=== Test 9: Double-free detection ===");
        addr1 = mem.alloc(64, .file(`__FILE__), .line(`__LINE__));
        mem.free(addr1, `__FILE__, `__LINE__);

        catcher = new("catcher9");
        catcher.expected_id = "HOST_MEM";
        uvm_report_cb::add(null, catcher);
        mem.free(addr1, `__FILE__, `__LINE__);  // should FATAL
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
        begin
            byte dummy[];
            mem.read_mem(64'hDEAD_0000, 4, dummy, `__FILE__, `__LINE__);
        end
        assert(catcher.caught) else $fatal(1, "Expected FATAL for unallocated read");
        uvm_report_cb::delete(null, catcher);
        $display("Test 10 PASSED: unallocated access detected");

        // ========================================
        $display("\n========================================");
        $display("ALL TESTS PASSED");
        $display("========================================\n");
        $finish;
    end

endmodule

`endif
```

- [ ] **Step 2: Commit**

```bash
git add tb/host_mem_tb.sv
git commit -m "feat: add comprehensive testbench with 10 test cases"
```

---

### Task 10: Final Integration and Verification

**Files:**
- Review: `src/host_mem_pkg.sv`, `src/host_mem_manager.sv`, `tb/host_mem_tb.sv`

- [ ] **Step 1: Verify all files are consistent**

Check that all method names, types, and signatures match between the class skeleton declarations (`extern`) and implementations. Verify:
- `write_mem`, `read_mem`, `mem_set`, `mem_cpy`, `mem_compare` naming is consistent
- All `extern` declarations have matching implementations
- All typedefs in `host_mem_pkg.sv` are used correctly in `host_mem_manager.sv`

- [ ] **Step 2: Run compilation check (if simulator available)**

```bash
# Example with VCS:
vcs -sverilog -ntb_opts uvm src/host_mem_pkg.sv src/host_mem_manager.sv tb/host_mem_tb.sv -o host_mem_test
./host_mem_test

# Example with Questa:
vlog -sv +incdir+src src/host_mem_pkg.sv src/host_mem_manager.sv tb/host_mem_tb.sv
vsim -c host_mem_tb -do "run -all; quit"
```

Expected output should include:
```
=== Test 1: Basic init and alloc ===
Test 1 PASSED: alloc returned 0x...
...
ALL TESTS PASSED
```

- [ ] **Step 3: Final commit**

```bash
git add -A
git commit -m "feat: host_mem_manager complete - buddy allocator with safety checks and debug"
```
