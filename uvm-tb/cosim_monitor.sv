// cosim_monitor.sv — Passively observes TLP interface and broadcasts transactions

class cosim_monitor extends uvm_monitor;
    `uvm_component_utils(cosim_monitor)

    virtual cosim_if vif;

    uvm_analysis_port #(cosim_tlp_tr) ap;

    int observed_tlps = 0;
    int observed_cpls = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
    endfunction

    task run_phase(uvm_phase phase);
        wait (vif.rst_n === 1'b1);

        forever begin
            cosim_tlp_tr tr;
            @(posedge vif.clk);

            if (vif.tlp_valid) begin
                tr = cosim_tlp_tr::type_id::create("mon_tr");
                tr.tlp_type = vif.tlp_type;
                tr.addr     = vif.tlp_addr;
                tr.data     = vif.tlp_wdata;
                tr.len      = vif.tlp_len;
                tr.tag      = vif.tlp_tag;
                observed_tlps++;

                // For read requests, wait for completion
                if (tr.tlp_type == 3'd1 || tr.tlp_type == 3'd3) begin
                    for (int i = 0; i < 10; i++) begin
                        @(posedge vif.clk);
                        if (vif.cpl_valid) begin
                            tr.has_cpl    = 1;
                            tr.cpl_rdata  = vif.cpl_rdata;
                            tr.cpl_status = vif.cpl_status;
                            observed_cpls++;
                            break;
                        end
                    end
                end

                ap.write(tr);
                `uvm_info("MON", tr.convert2string(), UVM_HIGH)
            end
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("MON", $sformatf("Stats: TLPs=%0d Completions=%0d",
                                    observed_tlps, observed_cpls), UVM_LOW)
    endfunction
endclass
