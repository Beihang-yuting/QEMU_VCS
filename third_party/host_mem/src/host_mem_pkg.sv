`ifndef HOST_MEM_PKG_SV
`define HOST_MEM_PKG_SV

package host_mem_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    parameter int unsigned DEFAULT_MIN_GRANULE = 16;
    parameter int unsigned MAX_MIN_GRANULE     = 64;
    parameter byte         DEFAULT_POISON      = 8'hDE;

    typedef enum { MODE_BUDDY, MODE_LINEAR } alloc_mode_e;

    typedef struct {
        bit [63:0]       addr;
        longint unsigned size;
    } free_seg_t;

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

    // Abstract base so package-level code can hold a typed handle to
    // host_mem_manager without referencing the $unit-scope class directly.
    // Exposes the full method set BFM package code (env/seq/agent) calls.
    virtual class host_mem_api extends uvm_object;
        function new(string name = "host_mem_api"); super.new(name); endfunction
        pure virtual function void init_region(bit [63:0] base_addr, bit [63:0] end_addr,
                                               alloc_mode_e m = MODE_BUDDY,
                                               int unsigned granule = DEFAULT_MIN_GRANULE,
                                               byte poison = DEFAULT_POISON);
        pure virtual function bit [63:0] alloc(int unsigned size, int unsigned align = 1, string file = "", int line = 0);
        pure virtual function void free(bit [63:0] addr, string file = "", int line = 0);
        pure virtual function void write_mem(bit [63:0] addr, byte data[], string file = "", int line = 0);
        pure virtual function void read_mem(bit [63:0] addr, int unsigned size, ref byte data[], input string file = "", input int line = 0);
        pure virtual function bit mem_compare(bit [63:0] addr1, bit [63:0] addr2, int unsigned size, output int unsigned mismatch_offset, input string file = "", input int line = 0);
        pure virtual function void leak_check(string file = "", int line = 0);
    endclass

endpackage

// ========== Convenience Macros ==========
// Auto-inject `__FILE__ and `__LINE__ so callers don't need to pass them manually.
//
// Usage:
//   `host_mem_alloc(mem, addr, 1024, .align(64))
//   `host_mem_free(mem, addr)
//   `host_mem_write(mem, addr, wdata)
//   `host_mem_read(mem, addr, 100, rdata)
//   `host_mem_set(mem, addr, 8'hAA, 256)
//   `host_mem_cpy(mem, dst, src, 256)
//   `host_mem_compare(mem, result, addr1, addr2, 256, mismatch)
//   `host_mem_release_range(mem, addr, 64)
//   `host_mem_leak_check(mem)

`define host_mem_alloc(mem, addr, size, align = 1) \
    addr = mem.alloc(size, align, `__FILE__, `__LINE__)

`define host_mem_free(mem, addr) \
    mem.free(addr, `__FILE__, `__LINE__)

`define host_mem_write(mem, addr, data) \
    mem.write_mem(addr, data, `__FILE__, `__LINE__)

`define host_mem_read(mem, addr, size, data) \
    mem.read_mem(addr, size, data, `__FILE__, `__LINE__)

`define host_mem_set(mem, addr, value, size) \
    mem.mem_set(addr, value, size, `__FILE__, `__LINE__)

`define host_mem_cpy(mem, dst, src, size) \
    mem.mem_cpy(dst, src, size, `__FILE__, `__LINE__)

`define host_mem_compare(mem, result, addr1, addr2, size, mismatch) \
    result = mem.mem_compare(addr1, addr2, size, mismatch, `__FILE__, `__LINE__)

`define host_mem_release_range(mem, addr, size) \
    mem.release_range(addr, size, `__FILE__, `__LINE__)

`define host_mem_leak_check(mem) \
    mem.leak_check(`__FILE__, `__LINE__)

`endif
