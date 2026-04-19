// cosim_driver.sv — UVM driver: polls TLPs from QEMU or sequence, drives DUT
//
// Two modes:
//   STANDALONE (default): TLPs come from UVM sequences
//   COSIM:                TLPs come from QEMU via bridge_vcs_poll_tlp() DPI-C
//
// Mode selected via uvm_config_db#(bit)::set(..., "cosim_mode", 1/0)

class cosim_driver extends uvm_driver #(cosim_tlp_tr);
    `uvm_component_utils(cosim_driver)

    virtual cosim_if vif;

    // Configuration
    bit    cosim_mode = 0;     // 0=standalone, 1=cosim (needs QEMU)
    string shm_name   = "/cosim0";
    string sock_path  = "/tmp/cosim.sock";
    int    poll_idle_cycles = 2;

    // State
    bit    bridge_ok  = 0;
    bit    shutdown   = 0;

    // Analysis port: completed transactions
    uvm_analysis_port #(cosim_tlp_tr) completed_ap;

    // Statistics
    int tlp_count = 0;
    int cpl_count = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        completed_ap = new("completed_ap", this);
        void'(uvm_config_db#(bit)::get(this, "", "cosim_mode", cosim_mode));
        void'(uvm_config_db#(string)::get(this, "", "shm_name", shm_name));
        void'(uvm_config_db#(string)::get(this, "", "sock_path", sock_path));
    endfunction

    task run_phase(uvm_phase phase);
        wait (vif.rst_n === 1'b1);
        repeat(2) @(posedge vif.clk);

        if (cosim_mode) begin
            `uvm_info("DRV", "Running in COSIM mode (TLPs from QEMU)", UVM_LOW)
            run_cosim_mode(phase);
        end else begin
            `uvm_info("DRV", "Running in STANDALONE mode (TLPs from sequences)", UVM_LOW)
            run_standalone_mode(phase);
        end
    endtask

    // ========== STANDALONE MODE ==========
    task run_standalone_mode(uvm_phase phase);
        cosim_tlp_tr tr;
        forever begin
            seq_item_port.get_next_item(tr);
            if (tr.is_shutdown) begin
                seq_item_port.item_done();
                break;
            end
            drive_tlp(tr);
            completed_ap.write(tr);
            seq_item_port.item_done();
        end
    endtask

    // ========== COSIM MODE ==========
    task run_cosim_mode(uvm_phase phase);
        phase.raise_objection(this, "cosim_driver polling");

        init_bridge();
        if (!bridge_ok) begin
            `uvm_fatal("DRV", "Bridge init failed")
            phase.drop_objection(this);
            return;
        end

        poll_and_drive();

        cleanup_bridge();
        phase.drop_objection(this);
    endtask

    task init_bridge();
        int ret;
        ret = cosim_bridge_pkg::bridge_vcs_init(shm_name, sock_path);
        if (ret != 0) begin
            `uvm_error("DRV", $sformatf("bridge_vcs_init failed: shm=%s sock=%s",
                                         shm_name, sock_path))
            bridge_ok = 0;
            return;
        end
        bridge_ok = 1;
        `uvm_info("DRV", $sformatf("Bridge initialized: shm=%s", shm_name), UVM_LOW)
    endtask

    task poll_and_drive();
        byte unsigned    poll_type;
        longint unsigned poll_addr;
        int unsigned     poll_data[16];
        int              poll_len;
        int              poll_tag;

        forever begin
            int ret;
            if (shutdown) break;

            ret = cosim_bridge_pkg::bridge_vcs_poll_tlp(
                poll_type, poll_addr, poll_data, poll_len, poll_tag);

            case (ret)
                0: begin
                    cosim_tlp_tr tr;
                    tr = cosim_tlp_tr::type_id::create("tr");
                    tr.tlp_type = poll_type[2:0];
                    tr.addr     = poll_addr;
                    tr.data     = poll_data[0];
                    tr.len      = poll_len;
                    tr.tag      = poll_tag;
                    drive_tlp(tr);
                    completed_ap.write(tr);
                end
                1: begin
                    // No TLP — yield simulation time to other components
                    repeat (poll_idle_cycles) @(posedge vif.clk);
                end
                -1: begin
                    `uvm_info("DRV", "Bridge shutdown or error", UVM_LOW)
                    shutdown = 1;
                end
            endcase
        end
    endtask

    // ========== DRIVE TLP ==========
    task drive_tlp(cosim_tlp_tr tr);
        @(posedge vif.clk);
        vif.tlp_valid <= 1;
        vif.tlp_type  <= tr.tlp_type;
        vif.tlp_addr  <= tr.addr;
        vif.tlp_wdata <= tr.data;
        vif.tlp_len   <= tr.len[15:0];
        vif.tlp_tag   <= tr.tag[7:0];

        @(posedge vif.clk);
        vif.tlp_valid <= 0;
        tlp_count++;

        // Read requests: wait for DUT completion
        if (tr.tlp_type == 3'd1 || tr.tlp_type == 3'd3) begin
            wait_completion(tr);
        end

        `uvm_info("DRV", tr.convert2string(), UVM_HIGH)
    endtask

    // ========== WAIT COMPLETION ==========
    task wait_completion(cosim_tlp_tr tr);
        int timeout = 100;
        for (int i = 0; i < timeout; i++) begin
            @(posedge vif.clk);
            if (vif.cpl_valid) begin
                tr.has_cpl    = 1;
                tr.cpl_rdata  = vif.cpl_rdata;
                tr.cpl_status = vif.cpl_status;
                cpl_count++;

                if (cosim_mode) begin
                    int unsigned cpl_data[16];
                    int rc;
                    cpl_data[0] = vif.cpl_rdata;
                    for (int j = 1; j < 16; j++) cpl_data[j] = 0;
                    rc = cosim_bridge_pkg::bridge_vcs_send_completion(
                        int'(vif.cpl_tag), cpl_data, 4);
                    if (rc < 0)
                        `uvm_error("DRV", "send_completion failed")
                end
                return;
            end
        end
        `uvm_warning("DRV", $sformatf("Completion timeout: type=%0d addr=0x%h tag=%0d",
                                       tr.tlp_type, tr.addr, tr.tag))
    endtask

    task cleanup_bridge();
        if (bridge_ok) begin
            cosim_bridge_pkg::bridge_vcs_cleanup();
            `uvm_info("DRV", "Bridge cleaned up", UVM_LOW)
        end
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("DRV", $sformatf("Stats: TLPs=%0d Completions=%0d",
                                    tlp_count, cpl_count), UVM_LOW)
    endfunction
endclass
