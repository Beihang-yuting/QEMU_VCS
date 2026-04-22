//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Link Delay Model (Pipeline Latency Simulation)
//-----------------------------------------------------------------------------

class pcie_tl_link_delay_model extends uvm_component;
    `uvm_component_utils(pcie_tl_link_delay_model)

    //--- Configuration ---
    bit     enable          = 0;
    int     latency_min_ns  = 0;
    int     latency_max_ns  = 0;
    int     update_interval = 16;

    //--- Runtime state ---
    int      current_latency_ns = 0;
    int      tlp_count          = 0;
    realtime last_arrival_time  = 0;

    //--- Statistics ---
    int      total_forwarded = 0;
    int      total_delayed   = 0;
    int      min_applied_ns  = 0;
    int      max_applied_ns  = 0;
    int      delay_updates   = 0;

    function new(string name = "pcie_tl_link_delay_model", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (latency_min_ns > 0 || latency_max_ns > 0)
            update_latency();
    endfunction

    //=========================================================================
    // Core: Forward TLP through the delay pipeline
    //=========================================================================
    task forward(input pcie_tl_tlp tlp, input uvm_tlm_fifo #(pcie_tl_tlp) dst);
        // Bypass when disabled
        if (!enable) begin
            dst.put(tlp);
            total_forwarded++;
            return;
        end

        // Update delay value every N TLPs
        tlp_count++;
        if (tlp_count >= update_interval) begin
            update_latency();
            tlp_count = 0;
        end

        begin
            // Capture current state for this TLP's forked delay
            int this_latency_ns = current_latency_ns;
            realtime entry_time = $realtime;
            realtime arrival_time = entry_time + this_latency_ns * 1ns;

            // Ordering guard: ensure monotonic arrival
            if (arrival_time <= last_arrival_time)
                arrival_time = last_arrival_time + 1ns;

            last_arrival_time = arrival_time;

            // Track statistics
            total_forwarded++;
            if (this_latency_ns > 0) total_delayed++;
            if (total_delayed == 1 || this_latency_ns < min_applied_ns)
                min_applied_ns = this_latency_ns;
            if (this_latency_ns > max_applied_ns)
                max_applied_ns = this_latency_ns;

            // Pipeline: fork so multiple TLPs can be in-flight
            fork
                begin
                    pcie_tl_tlp fwd_tlp = tlp;
                    realtime fwd_arrival = arrival_time;
                    realtime wait_time = fwd_arrival - $realtime;
                    if (wait_time > 0)
                        #(wait_time);
                    dst.put(fwd_tlp);
                end
            join_none
        end
    endtask

    //=========================================================================
    // Randomize delay value
    //=========================================================================
    function void update_latency();
        if (latency_min_ns == latency_max_ns)
            current_latency_ns = latency_min_ns;
        else
            current_latency_ns = $urandom_range(latency_max_ns, latency_min_ns);
        delay_updates++;
        `uvm_info(get_name(), $sformatf("Delay updated: %0d ns (range: %0d-%0d)",
                  current_latency_ns, latency_min_ns, latency_max_ns), UVM_HIGH)
    endfunction

    //=========================================================================
    // Runtime reconfiguration
    //=========================================================================
    function void set_latency(int min_ns, int max_ns);
        latency_min_ns = min_ns;
        latency_max_ns = max_ns;
        update_latency();
    endfunction

    function void set_update_interval(int n);
        update_interval = n;
    endfunction

    function void force_update();
        update_latency();
        tlp_count = 0;
    endfunction

    function void reset();
        tlp_count          = 0;
        last_arrival_time  = 0;
        total_forwarded    = 0;
        total_delayed      = 0;
        min_applied_ns     = 0;
        max_applied_ns     = 0;
        delay_updates      = 0;
        update_latency();
    endfunction

    //=========================================================================
    // Report Phase
    //=========================================================================
    function void report_phase(uvm_phase phase);
        if (!enable) return;
        `uvm_info(get_name(), $sformatf(
            "\n========== Link Delay Report [%s] ==========\n  Total forwarded:  %0d\n  Total delayed:    %0d\n  Delay range cfg:  %0d-%0d ns\n  Applied range:    %0d-%0d ns\n  Update interval:  %0d TLPs\n  Delay updates:    %0d\n================================================",
            get_name(), total_forwarded, total_delayed,
            latency_min_ns, latency_max_ns,
            min_applied_ns, max_applied_ns,
            update_interval, delay_updates
        ), UVM_LOW)
    endfunction

endclass
