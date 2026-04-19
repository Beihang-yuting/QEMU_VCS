// cosim_scoreboard.sv — Checks TLP completions and tracks coverage

class cosim_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(cosim_scoreboard)

    uvm_analysis_imp #(cosim_tlp_tr, cosim_scoreboard) ap;

    int total_tlps    = 0;
    int mwr_count     = 0;
    int mrd_count     = 0;
    int cfgwr_count   = 0;
    int cfgrd_count   = 0;
    int cpl_received  = 0;
    int cpl_timeout   = 0;
    int errors        = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
    endfunction

    function void write(cosim_tlp_tr tr);
        total_tlps++;
        case (tr.tlp_type)
            3'd0: mwr_count++;
            3'd1: mrd_count++;
            3'd2: cfgwr_count++;
            3'd3: cfgrd_count++;
        endcase

        if (tr.tlp_type == 3'd1 || tr.tlp_type == 3'd3) begin
            if (tr.has_cpl) begin
                cpl_received++;
                check_known_values(tr);
            end else begin
                cpl_timeout++;
                `uvm_warning("SCB", $sformatf(
                    "No completion: type=%0d addr=0x%h tag=%0d",
                    tr.tlp_type, tr.addr, tr.tag))
            end
        end
    endfunction

    function void check_known_values(cosim_tlp_tr tr);
        // CfgRd 0x00: VID=0x1AF4, DID=0x1041
        if (tr.tlp_type == 3'd3 && tr.addr[15:0] == 16'h0000) begin
            if (tr.cpl_rdata == 32'h1041_1AF4)
                `uvm_info("SCB", $sformatf("PASS: VID/DID=0x%08h", tr.cpl_rdata), UVM_LOW)
            else begin
                `uvm_error("SCB", $sformatf("FAIL: VID/DID=0x%08h (exp 0x10411AF4)", tr.cpl_rdata))
                errors++;
            end
        end
        // CfgRd 0x08: Class=0x020000
        if (tr.tlp_type == 3'd3 && tr.addr[15:0] == 16'h0008) begin
            if (tr.cpl_rdata[31:8] == 24'h020000)
                `uvm_info("SCB", $sformatf("PASS: Class=0x%06h", tr.cpl_rdata[31:8]), UVM_LOW)
            else begin
                `uvm_error("SCB", $sformatf("FAIL: Class=0x%06h (exp 0x020000)", tr.cpl_rdata[31:8]))
                errors++;
            end
        end
        // MRd ISR (0x3000)
        if (tr.tlp_type == 3'd1 && tr.addr[15:0] == 16'h3000)
            `uvm_info("SCB", $sformatf("ISR=0x%08h", tr.cpl_rdata), UVM_MEDIUM)
    endfunction

    function void report_phase(uvm_phase phase);
        string r;
        r = "\n========== SCOREBOARD REPORT ==========\n";
        r = {r, $sformatf("Total TLPs:   %0d\n", total_tlps)};
        r = {r, $sformatf("  MWr:        %0d\n", mwr_count)};
        r = {r, $sformatf("  MRd:        %0d\n", mrd_count)};
        r = {r, $sformatf("  CfgWr:      %0d\n", cfgwr_count)};
        r = {r, $sformatf("  CfgRd:      %0d\n", cfgrd_count)};
        r = {r, $sformatf("Completions:  %0d\n", cpl_received)};
        r = {r, $sformatf("Timeouts:     %0d\n", cpl_timeout)};
        r = {r, $sformatf("Errors:       %0d\n", errors)};
        r = {r, "========================================\n"};
        if (errors == 0 && cpl_timeout == 0)
            `uvm_info("SCB", {r, "RESULT: ALL TESTS PASSED"}, UVM_LOW)
        else
            `uvm_error("SCB", {r, "RESULT: TESTS FAILED"})
    endfunction
endclass
