//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Bandwidth Shaper (Token Bucket)
//-----------------------------------------------------------------------------

class pcie_tl_bw_shaper extends uvm_component;
    `uvm_component_utils(pcie_tl_bw_shaper)

    //--- Token bucket parameters ---
    real         avg_rate    = 0.0;    // bytes per ns
    int          burst_size  = 4096;   // max burst in bytes
    real         token_count = 0.0;    // current tokens
    realtime     last_refill_time;

    //--- Switch ---
    bit          shaper_enable = 0;

    function new(string name = "pcie_tl_bw_shaper", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        token_count = burst_size;
        last_refill_time = 0;
    endfunction

    //=========================================================================
    // Check if enough tokens to send
    //=========================================================================
    function bit can_send(int bytes);
        if (!shaper_enable) return 1;
        refill();
        return (token_count >= bytes);
    endfunction

    //=========================================================================
    // Consume tokens after sending
    //=========================================================================
    function void on_sent(int bytes);
        if (!shaper_enable) return;
        token_count -= bytes;
        if (token_count < 0) token_count = 0;
    endfunction

    //=========================================================================
    // Refill tokens based on elapsed time
    //=========================================================================
    function void refill();
        realtime now = $realtime;
        real elapsed_ns;
        real new_tokens;

        if (last_refill_time == 0) begin
            last_refill_time = now;
            return;
        end

        elapsed_ns = (now - last_refill_time) / 1ns;
        new_tokens = avg_rate * elapsed_ns;
        token_count = token_count + new_tokens;
        if (token_count > burst_size)
            token_count = burst_size;
        last_refill_time = now;
    endfunction

    //=========================================================================
    // Reset shaper state
    //=========================================================================
    function void reset();
        token_count = burst_size;
        last_refill_time = $realtime;
    endfunction

    //=========================================================================
    // Configure shaper
    //=========================================================================
    function void configure(real rate, int burst);
        avg_rate   = rate;
        burst_size = burst;
        reset();
    endfunction

endclass
