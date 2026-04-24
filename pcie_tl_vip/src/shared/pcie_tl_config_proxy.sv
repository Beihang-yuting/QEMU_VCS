//-----------------------------------------------------------------------------
// PCIe TL VIP - Config Space Bypass Proxy
//
// 当 bypass_enable=1 时，CfgRd0/CfgWr0 TLP 由此组件直接回 completion，
// 不穿透到 RTL。支持 BAR sizing、Capability 链、MSI-X 配置。
//
// 用法:
//   +BYPASS_CONFIG=1          启用（默认）
//   +BYPASS_CONFIG=0          关闭（TLP 穿透到 DUT RTL）
//   +CFG_VENDOR_ID=0x1AF4     配置 Vendor ID
//   +CFG_DEVICE_ID=0x1041     配置 Device ID
//   +CFG_BAR0_SIZE=65536      配置 BAR0 大小（字节，必须 2^N）
//   +CFG_MSIX_VECTORS=4       配置 MSI-X 向量数
//-----------------------------------------------------------------------------

class pcie_tl_config_proxy extends uvm_component;
    `uvm_component_utils(pcie_tl_config_proxy)

    //--- Bypass 开关 ---
    bit bypass_enable = 1;

    //--- 4KB Config Space 寄存器 ---
    bit [31:0] config_space[1024];  // 4KB = 1024 DWORDs

    //--- 可配置参数 ---
    bit [15:0] vendor_id    = 16'h1AF4;
    bit [15:0] device_id    = 16'h1041;
    bit [7:0]  revision_id  = 8'h01;
    bit [23:0] class_code   = 24'h020000;  // Network controller
    bit [31:0] bar0_size    = 32'h10000;   // 64KB
    bit [31:0] bar1_size    = 32'h0;       // disabled
    int        msix_vectors = 4;

    //--- BAR sizing 状态 ---
    bit bar0_sizing = 0;
    bit bar1_sizing = 0;
    bit [31:0] bar0_addr = 0;
    bit [31:0] bar1_addr = 0;

    function new(string name = "pcie_tl_config_proxy", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        int tmp;
        super.build_phase(phase);

        // plusarg 配置
        if ($test$plusargs("BYPASS_CONFIG")) begin
            if ($value$plusargs("BYPASS_CONFIG=%d", tmp))
                bypass_enable = (tmp != 0);
        end

        if ($value$plusargs("CFG_VENDOR_ID=%h", tmp))
            vendor_id = tmp[15:0];
        if ($value$plusargs("CFG_DEVICE_ID=%h", tmp))
            device_id = tmp[15:0];
        if ($value$plusargs("CFG_BAR0_SIZE=%d", tmp))
            bar0_size = tmp;
        if ($value$plusargs("CFG_MSIX_VECTORS=%d", msix_vectors))
            ;

        init_config_space();

        `uvm_info("CFG_PROXY", $sformatf(
            "Config Proxy: bypass=%0d vendor=0x%04h device=0x%04h bar0_size=0x%08h msix=%0d",
            bypass_enable, vendor_id, device_id, bar0_size, msix_vectors), UVM_MEDIUM)
    endfunction

    //=========================================================================
    // 初始化 config space 默认值
    //=========================================================================
    function void init_config_space();
        foreach (config_space[i]) config_space[i] = 32'h0;

        // DW0: Vendor ID + Device ID
        config_space[0] = {device_id, vendor_id};

        // DW1: Command + Status
        config_space[1] = 32'h0010_0000;  // Status: Capabilities List

        // DW2: Revision + Class Code
        config_space[2] = {class_code, revision_id};

        // DW3: Cache Line, Latency, Header Type, BIST
        config_space[3] = 32'h0000_0000;  // Type 0 header

        // DW4: BAR0 (Memory, 32-bit, non-prefetchable)
        config_space[4] = 32'h0000_0000;

        // DW5: BAR1
        config_space[5] = 32'h0000_0000;

        // DW11: Subsystem Vendor + Device
        config_space[11] = {device_id, vendor_id};

        // DW13: Capability Pointer
        config_space[13] = 32'h0000_0040;  // Cap starts at 0x40

        // DW15: Interrupt Line/Pin
        config_space[15] = 32'h0000_0100;  // INTA

        // ---- Capability: MSI (at 0x40 = DW16) ----
        config_space[16] = 32'h0050_0005;  // Cap ID=05(MSI), Next=0x50
        config_space[17] = 32'h0000_0000;  // MSI Address
        config_space[18] = 32'h0000_0000;  // MSI Data

        // ---- Capability: MSI-X (at 0x50 = DW20) ----
        config_space[20] = {16'h0060, msix_vectors[9:0] - 10'd1, 6'h0, 8'h11};
        //                  Next=0x60   table_size-1                   Cap ID=0x11
        config_space[21] = 32'h0000_2000;  // Table offset (BAR0 + 0x2000)
        config_space[22] = 32'h0000_3000;  // PBA offset (BAR0 + 0x3000)

        // ---- Capability: PCIe (at 0x60 = DW24) ----
        config_space[24] = 32'h0000_0010;  // Cap ID=0x10 (PCI Express), Next=0
        config_space[25] = 32'h0000_0001;  // PCIe Capabilities: EP, v1
    endfunction

    //=========================================================================
    // 处理 CfgRd — 返回 1 表示已拦截，0 表示穿透
    //=========================================================================
    function bit handle_cfg_read(int dw_addr, output bit [31:0] data);
        if (!bypass_enable) return 0;

        // BAR0 sizing 响应
        if (dw_addr == 4 && bar0_sizing) begin
            data = ~(bar0_size - 1) | 32'h0;  // BAR mask
            `uvm_info("CFG_PROXY", $sformatf("BAR0 sizing read: mask=0x%08h", data), UVM_MEDIUM)
            return 1;
        end

        // BAR1 sizing 响应
        if (dw_addr == 5 && bar1_sizing) begin
            if (bar1_size == 0)
                data = 32'h0;
            else
                data = ~(bar1_size - 1) | 32'h0;
            return 1;
        end

        if (dw_addr < 1024) begin
            data = config_space[dw_addr];
            `uvm_info("CFG_PROXY", $sformatf("CfgRd DW[%0d]=0x%08h (bypass)", dw_addr, data), UVM_HIGH)
            return 1;
        end

        data = 32'hFFFF_FFFF;
        return 1;
    endfunction

    //=========================================================================
    // 处理 CfgWr — 返回 1 表示已拦截，0 表示穿透
    //=========================================================================
    function bit handle_cfg_write(int dw_addr, bit [31:0] data);
        if (!bypass_enable) return 0;

        // BAR0: 检测 sizing（写 0xFFFFFFFF）
        if (dw_addr == 4) begin
            if (data == 32'hFFFF_FFFF) begin
                bar0_sizing = 1;
                `uvm_info("CFG_PROXY", "BAR0 sizing write detected", UVM_MEDIUM)
            end else begin
                bar0_sizing = 0;
                bar0_addr = data & ~(bar0_size - 1);
                config_space[4] = bar0_addr;
                `uvm_info("CFG_PROXY", $sformatf("BAR0 assigned: 0x%08h", bar0_addr), UVM_MEDIUM)
            end
            return 1;
        end

        // BAR1
        if (dw_addr == 5) begin
            if (data == 32'hFFFF_FFFF) begin
                bar1_sizing = 1;
            end else begin
                bar1_sizing = 0;
                bar1_addr = (bar1_size > 0) ? (data & ~(bar1_size - 1)) : 0;
                config_space[5] = bar1_addr;
            end
            return 1;
        end

        // Command register (DW1 low 16 bits)
        if (dw_addr == 1) begin
            config_space[1] = (config_space[1] & 32'hFFFF_0000) | (data & 32'h0000_FFFF);
            `uvm_info("CFG_PROXY", $sformatf("Command reg: 0x%04h", data[15:0]), UVM_HIGH)
            return 1;
        end

        // 其他 config space 写
        if (dw_addr < 1024) begin
            config_space[dw_addr] = data;
            `uvm_info("CFG_PROXY", $sformatf("CfgWr DW[%0d]=0x%08h (bypass)", dw_addr, data), UVM_HIGH)
            return 1;
        end

        return 1;
    endfunction

endclass
