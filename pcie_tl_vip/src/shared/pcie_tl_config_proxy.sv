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
    bit bar0_sizing_lo = 0;
    bit bar0_sizing_hi = 0;
    bit [63:0] bar0_addr = 0;
    bit bar0_is_64bit = 1;      // 默认 64-bit BAR

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

        // ============================================================
        // PCI Header (Type 0)
        // ============================================================
        // DW0: Device ID | Vendor ID
        config_space[0]  = {device_id, vendor_id};
        // DW1: Status(cap_list=1) | Command
        config_space[1]  = {16'h0010, 16'h0007};
        // DW2: Class Code | Revision
        config_space[2]  = {class_code, revision_id};
        // DW3: BIST|HdrType=0|LatTimer|CacheLine
        config_space[3]  = 32'h0000_0010;
        // DW4: BAR0_lo — type=10(64-bit), mem space
        config_space[4]  = 32'h0000_0004;   // bit[2:1]=10 → 64-bit BAR
        // DW5: BAR0_hi
        config_space[5]  = 32'h0000_0000;
        // DW6-DW9: BAR1-BAR4 (未使用)
        // DW11: Subsystem ID | Subsystem Vendor ID
        config_space[11] = {16'h0001, vendor_id};
        // DW13: Capabilities Pointer → 0x40 (MSI cap)
        //   PCI spec 要求 cap offset >= 0x40（0x00-0x3F 是标准头）
        config_space[13] = 32'h0000_0040;
        // DW15 (0x3C): INT_PIN = INTA (低 8 位), INT_LINE (由 BIOS/OS 分配)
        config_space[15] = 32'h0000_0100;

        // ============================================================
        // MSI Capability stub (offset 0x40, DW16-DW19)
        //   QEMU realize 通过 cap 链遍历发现此 MSI cap 并调用 msi_init
        //   PCI spec 要求 cap offset >= 0x40
        // ============================================================
        // DW16 (0x40): {msg_ctrl=0x0080(64bit,1vec), next=0x50, cap_id=0x05}
        config_space[16] = 32'h0080_50_05;
        // DW17 (0x44): MSI msg_addr_lo (guest 通过 CfgWr 配置)
        config_space[17] = 32'h0000_0000;
        // DW18 (0x48): MSI msg_addr_hi
        config_space[18] = 32'h0000_0000;
        // DW19 (0x4C): MSI msg_data
        config_space[19] = 32'h0000_0000;

        // ============================================================
        // Virtio PCI Capabilities (偏移与 QEMU realize 对齐)
        // ============================================================

        // 0x50 (DW20): VIRTIO_PCI_CAP_COMMON_CFG
        //   cap_vndr=0x09, cap_next=0x64, cap_len=0x10, cfg_type=1
        config_space[20] = 32'h01_10_64_09;
        config_space[21] = 32'h00_00_00_00;   // bar=0
        config_space[22] = 32'h0000_1000;     // offset in BAR = 0x1000
        config_space[23] = 32'h0000_0038;     // length = 56 bytes

        // 0x64 (DW25): VIRTIO_PCI_CAP_NOTIFY_CFG
        //   cap_vndr=0x09, cap_next=0x78, cap_len=0x14, cfg_type=2
        config_space[25] = 32'h02_14_78_09;
        config_space[26] = 32'h00_00_00_00;   // bar=0
        config_space[27] = 32'h0000_2000;     // offset = 0x2000
        config_space[28] = 32'h0000_0004;     // length = 4
        config_space[29] = 32'h0000_0000;     // notify_off_multiplier = 0

        // 0x78 (DW30): VIRTIO_PCI_CAP_ISR_CFG
        //   cap_vndr=0x09, cap_next=0x88, cap_len=0x10, cfg_type=3
        config_space[30] = 32'h03_10_88_09;
        config_space[31] = 32'h00_00_00_00;   // bar=0
        config_space[32] = 32'h0000_3000;     // offset = 0x3000
        config_space[33] = 32'h0000_0004;     // length = 4

        // 0x88 (DW34): VIRTIO_PCI_CAP_DEVICE_CFG
        //   cap_vndr=0x09, cap_next=0x00 (end), cap_len=0x10, cfg_type=4
        config_space[34] = 32'h04_10_00_09;
        config_space[35] = 32'h00_00_00_00;   // bar=0
        config_space[36] = 32'h0000_4000;     // offset = 0x4000
        config_space[37] = 32'h0000_0010;     // length = 16
    endfunction

    //=========================================================================
    // 处理 CfgRd — 返回 1 表示已拦截，0 表示穿透
    //=========================================================================
    function bit handle_cfg_read(int dw_addr, output bit [31:0] data);
        if (!bypass_enable) return 0;

        // BAR0_lo sizing 响应
        if (dw_addr == 4 && bar0_sizing_lo) begin
            data = ~(bar0_size - 1) | 32'h4;  // BAR mask, preserve type=10(64-bit)
            `uvm_info("CFG_PROXY", $sformatf("BAR0_lo sizing read: mask=0x%08h", data), UVM_MEDIUM)
            return 1;
        end

        // BAR0_hi sizing 响应 (64-bit BAR: hi DW sizing 返回全 F)
        if (dw_addr == 5 && bar0_sizing_hi && bar0_is_64bit) begin
            data = 32'hFFFF_FFFF;  // 64-bit BAR hi 全 1 表示支持完整 64 位
            `uvm_info("CFG_PROXY", $sformatf("BAR0_hi sizing read: mask=0x%08h", data), UVM_MEDIUM)
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
    function bit handle_cfg_write(int dw_addr, bit [31:0] data,
                                     int byte_off = 0, int byte_len = 4);
        if (!bypass_enable) return 0;

        // BAR0_lo: 检测 sizing（写 0xFFFFFFFF）
        if (dw_addr == 4) begin
            if (data == 32'hFFFF_FFFF) begin
                bar0_sizing_lo = 1;
                `uvm_info("CFG_PROXY", "BAR0_lo sizing write detected", UVM_MEDIUM)
            end else begin
                bar0_sizing_lo = 0;
                bar0_addr[31:0] = data & ~(bar0_size - 1);
                config_space[4] = bar0_addr[31:0] | 32'h4;  // preserve type=10
                `uvm_info("CFG_PROXY", $sformatf("BAR0_lo assigned: 0x%08h (full=0x%016h)",
                    bar0_addr[31:0], bar0_addr), UVM_MEDIUM)
            end
            return 1;
        end

        // BAR0_hi (64-bit BAR: DW5 是 BAR0 的高 32 位)
        if (dw_addr == 5 && bar0_is_64bit) begin
            if (data == 32'hFFFF_FFFF) begin
                bar0_sizing_hi = 1;
                `uvm_info("CFG_PROXY", "BAR0_hi sizing write detected", UVM_MEDIUM)
            end else begin
                bar0_sizing_hi = 0;
                bar0_addr[63:32] = data;
                config_space[5] = data;
                `uvm_info("CFG_PROXY", $sformatf("BAR0_hi assigned: 0x%08h (full=0x%016h)",
                    data, bar0_addr), UVM_MEDIUM)
            end
            return 1;
        end

        // Command register (DW1 low 16 bits)
        if (dw_addr == 1) begin
            config_space[1] = (config_space[1] & 32'hFFFF_0000) | (data & 32'h0000_FFFF);
            `uvm_info("CFG_PROXY", $sformatf("Command reg: 0x%04h", data[15:0]), UVM_HIGH)
            return 1;
        end

        // 其他 config space 写（字节级合并，避免覆盖同 DW 内未写字节）
        if (dw_addr < 1024) begin
            bit [31:0] merged = config_space[dw_addr];
            for (int b = 0; b < 4; b++) begin
                if (b >= byte_off && b < byte_off + byte_len)
                    merged[(b*8) +: 8] = data[((b - byte_off)*8) +: 8];
            end
            config_space[dw_addr] = merged;
            `uvm_info("CFG_PROXY", $sformatf("CfgWr DW[%0d] off=%0d len=%0d: 0x%08h (bypass)",
                      dw_addr, byte_off, byte_len, merged), UVM_HIGH)
            return 1;
        end

        return 1;
    endfunction

endclass
