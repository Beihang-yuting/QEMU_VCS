//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Tag Manager
//-----------------------------------------------------------------------------

class pcie_tl_tag_manager extends uvm_object;
    `uvm_object_utils(pcie_tl_tag_manager)

    //--- Tag pools: func_id -> available tags ---
    bit [9:0] tag_pool[int][$];

    //--- Outstanding transactions: tag -> TLP ---
    pcie_tl_tlp outstanding_txn[bit [9:0]];

    //--- Configuration ---
    bit  extended_tag_enable = 1;
    bit  phantom_func_enable = 0;
    int  max_outstanding     = 1024;

    function new(string name = "pcie_tl_tag_manager");
        super.new(name);
    endfunction

    //=========================================================================
    // Initialize tag pool for a function
    //=========================================================================
    function void init_pool(int func_id, bit extended = 1, bit phantom = 0);
        int max_tag;
        tag_pool[func_id] = {};

        if (extended)
            max_tag = 1024;  // 10-bit tag
        else
            max_tag = 256;   // 8-bit tag

        // With phantom function, upper tag bits map to function number
        if (phantom && func_id > 0)
            return;  // phantom functions share func 0's pool

        for (int i = 0; i < max_tag && i < max_outstanding; i++) begin
            tag_pool[func_id].push_back(i[9:0]);
        end
    endfunction

    //=========================================================================
    // Allocate a tag
    //=========================================================================
    function bit [9:0] alloc_tag(int func_id);
        int pool_id = phantom_func_enable ? 0 : func_id;

        // Fall back to pool 0 if requested function pool doesn't exist
        if (!tag_pool.exists(pool_id))
            pool_id = 0;

        if (!tag_pool.exists(pool_id) || tag_pool[pool_id].size() == 0) begin
            `uvm_error("TAG_MGR", $sformatf("No available tags for func %0d", func_id))
            return '1;
        end

        alloc_tag = tag_pool[pool_id].pop_front();
        outstanding_txn[alloc_tag] = null;  // placeholder, set by caller
    endfunction

    //=========================================================================
    // Register outstanding transaction (after alloc)
    //=========================================================================
    function void register_outstanding(bit [9:0] tag, pcie_tl_tlp tlp);
        outstanding_txn[tag] = tlp;
    endfunction

    //=========================================================================
    // Free a tag (on completion)
    //=========================================================================
    function void free_tag(bit [9:0] tag, int func_id = 0);
        int pool_id = phantom_func_enable ? 0 : func_id;

        if (outstanding_txn.exists(tag))
            outstanding_txn.delete(tag);

        // Fall back to pool 0 if the requested pool doesn't exist
        // (mirrors alloc_tag fallback behavior)
        if (!tag_pool.exists(pool_id))
            pool_id = 0;

        if (tag_pool.exists(pool_id))
            tag_pool[pool_id].push_back(tag);
    endfunction

    //=========================================================================
    // Match completion to outstanding request
    //=========================================================================
    function pcie_tl_tlp match_completion(pcie_tl_cpl_tlp cpl);
        bit [9:0] t = cpl.tag;

        if (outstanding_txn.exists(t) && outstanding_txn[t] != null) begin
            if (outstanding_txn[t].requester_id == cpl.requester_id)
                return outstanding_txn[t];
        end
        return null;
    endfunction

    //=========================================================================
    // Check if tag is already outstanding (duplicate detection)
    //=========================================================================
    function bit is_duplicate(bit [9:0] tag);
        return (outstanding_txn.exists(tag) && outstanding_txn[tag] != null);
    endfunction

    //=========================================================================
    // Error injection: allocate a duplicate tag
    //=========================================================================
    function bit [9:0] alloc_duplicate_tag();
        foreach (outstanding_txn[t]) begin
            if (outstanding_txn[t] != null)
                return t;
        end
        `uvm_warning("TAG_MGR", "No outstanding tags to duplicate")
        return 0;
    endfunction

    //=========================================================================
    // Get number of outstanding transactions
    //=========================================================================
    function int get_outstanding_count();
        int count = 0;
        foreach (outstanding_txn[t])
            if (outstanding_txn[t] != null) count++;
        return count;
    endfunction

    //=========================================================================
    // Check if tag pool is empty
    //=========================================================================
    function bit is_pool_empty(int func_id = 0);
        int pool_id = phantom_func_enable ? 0 : func_id;
        if (!tag_pool.exists(pool_id)) return 1;
        return (tag_pool[pool_id].size() == 0);
    endfunction

endclass
