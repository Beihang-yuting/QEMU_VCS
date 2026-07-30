// Unified memory read/write sequence.
// User passes op (READ/WRITE), addr, and a REAL byte length; the sequence
// auto-derives the DW length field and first_be/last_be per PCIe BE rules.
//
// WRITE: posted, fire-and-forget (no wait).
// READ : non-posted; the sequence waits for the Completion(s) to return and
//        copies the read-back bytes into `rdata`. `status` reflects the result.
typedef enum { PCIE_RW_READ, PCIE_RW_WRITE } pcie_rw_op_e;
typedef enum { PCIE_RW_OK, PCIE_RW_ERR, PCIE_RW_TIMEOUT } pcie_rw_status_e;

class pcie_tl_rw_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_rw_seq)

    rand pcie_rw_op_e op;       // READ or WRITE
    rand bit [63:0]   addr;     // target address
    int               byte_len; // REAL length in bytes (1..4096)
    rand bit          is_64bit; // auto-derived from addr if high bits set
    tlp_constraint_mode_e mode = CONSTRAINT_LEGAL;
    pcie_tl_prefix    prefixes[$];
    bit               has_prefix;

    // WRITE payload: real data bytes (byte_len long). Optional; zero-filled if empty.
    bit [7:0]         wdata[];

    // READ results (valid after body() returns for a READ op).
    bit [7:0]         rdata[];              // byte_len read-back bytes
    pcie_rw_status_e  status = PCIE_RW_OK;  // OK / ERR (UR/CA/...) / TIMEOUT
    int               rb_timeout_ns = 50000; // read-back wait budget (50us)

    function new(string name = "pcie_tl_rw_seq"); super.new(name); endfunction

    // Compute DW length field + byte enables from a byte-granular request.
    function void calc_be_len(input bit [63:0] a, input int blen,
                              output bit [9:0] len_dw,
                              output bit [3:0] fbe, output bit [3:0] lbe);
        int start_off  = a[1:0];              // byte offset within first DW
        int total_byte = start_off + blen;    // bytes from first DW start
        int ndw        = (total_byte + 3) / 4;
        int last_idx   = (total_byte - 1) & 3; // valid byte index in last DW
        fbe = 4'h0; lbe = 4'h0;
        if (ndw == 1) begin
            // single-DW transfer: enable start_off .. (start_off+blen-1)
            for (int i = start_off; i <= start_off + blen - 1; i++) fbe[i] = 1'b1;
        end else begin
            for (int i = start_off; i <= 3;        i++) fbe[i] = 1'b1;
            for (int i = 0;         i <= last_idx; i++) lbe[i] = 1'b1;
        end
        len_dw = (ndw == 1024) ? 10'd0 : ndw[9:0]; // length==0 encodes 1024 DW
    endfunction

    task body();
        pcie_tl_mem_tlp tlp;
        bit [9:0]  len_dw;
        bit [3:0]  fbe, lbe;
        tlp_kind_e k;

        if (byte_len < 1 || byte_len > 4096)
            `uvm_fatal("RW_SEQ", $sformatf("byte_len=%0d out of range [1:4096]", byte_len))

        if (addr[63:32] != 0) is_64bit = 1;   // auto 4DW header for high address
        calc_be_len(addr, byte_len, len_dw, fbe, lbe);
        k = (op == PCIE_RW_WRITE) ? TLP_MEM_WR : TLP_MEM_RD;

        // Manual start/finish (not `uvm_do) so the WRITE payload is set BEFORE
        // finish_item sends the item. In SV_IF/adapter mode adapter.send drives
        // the bus synchronously inside finish_item, so a payload set afterwards
        // would be too late (the randomized payload would go out instead).
        tlp = pcie_tl_mem_tlp::type_id::create("rw_tlp");
        start_item(tlp);
        if (!tlp.randomize() with { tlp.kind == k; tlp.addr == local::addr;
                tlp.length == len_dw; tlp.first_be == fbe; tlp.last_be == lbe;
                tlp.is_64bit == local::is_64bit;
                tlp.constraint_mode_sel == local::mode; })
            `uvm_fatal("RW_SEQ", "randomize() failed")

        if (has_prefix) begin
            tlp.prefixes   = prefixes;
            tlp.has_prefix = 1;
        end

        // WRITE payload: DW-aligned, real bytes start at addr[1:0] offset.
        // Overwrite the randomized payload BEFORE the item is sent.
        if (op == PCIE_RW_WRITE) begin
            int off = addr[1:0];
            tlp.payload = new[len_dw * 4];
            for (int i = 0; i < byte_len && i < wdata.size(); i++)
                tlp.payload[off + i] = wdata[i];
        end

        finish_item(tlp);

        // WRITE is posted: fire-and-forget, no completion to wait for.
        if (op == PCIE_RW_WRITE) return;

        // READ: wait for the requester driver to fold the CplD(s) back onto
        // this TLP object (rb_done), bounded by rb_timeout_ns.
        fork begin : rb_wait
            fork
                wait (tlp.rb_done);
                #(rb_timeout_ns * 1ns);
            join_any
            disable fork;
        end join

        rdata = new[byte_len];
        if (!tlp.rb_done) begin
            status = PCIE_RW_TIMEOUT;
            `uvm_error("RW_SEQ", $sformatf("READ timeout: addr=0x%016h len=%0d tag=0x%03h",
                                            addr, byte_len, tlp.tag))
            return;
        end
        // Completer returns data starting at the requested address; slice byte_len.
        foreach (rdata[i])
            rdata[i] = (i < tlp.rb_data.size()) ? tlp.rb_data[i] : 8'h00;
        status = (tlp.rb_status == CPL_STATUS_SC) ? PCIE_RW_OK : PCIE_RW_ERR;
        if (status == PCIE_RW_ERR)
            `uvm_warning("RW_SEQ", $sformatf("READ completed with status=%s addr=0x%016h",
                                              tlp.rb_status.name(), addr))
    endtask
endclass
