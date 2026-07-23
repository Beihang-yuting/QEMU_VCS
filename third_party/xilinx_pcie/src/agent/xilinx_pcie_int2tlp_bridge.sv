//=============================================================================
// xilinx_pcie_int2tlp_bridge
//
// 建模 Xilinx PCIe IP 把 cfg_interrupt 边带断言转换为上行 TLP 的行为:
//   订阅 interrupt_monitor 的 int_ap; 每收到一个中断事件, 在 EP 侧 sequencer
//   上发一条到 MSI 地址的 Memory Write TLP (MSI/MSI-X = MemWr), 经 EP 适配器
//   打到 AXIS, 由交换/环回路由上行到 RC —— RC 于是在普通 TLP 接口收到该中断。
//
//   MSI   : MemWr -> msi_addr,      payload = {marker, vector}
//   MSI-X : MemWr -> item.msix_addr, payload = item.msix_data
//   INTx  : 本桥不产 TLP (真实为 Assert_INTx Message; 见 note), 仅记数
//=============================================================================
class xilinx_pcie_int2tlp_bridge extends uvm_subscriber #(xilinx_interrupt_item);
    `uvm_component_utils(xilinx_pcie_int2tlp_bridge)

    // EP 侧 sequencer (由测试连到 env.ep_agent.sequencer)
    uvm_sequencer #(pcie_tl_tlp) ep_seqr;

    // RC 为该 EP 配置的 MSI 目标地址 (MSI capability Message Address)
    bit [63:0] msi_addr = 64'h0000_0000_FEE0_0000;

    int sent_memwr = 0;   // 已注入的中断 MemWr 计数

    xilinx_interrupt_item q[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // analysis 回调 (非阻塞): 入队, 由 run_phase 发送
    function void write(xilinx_interrupt_item t);
        if (t != null) q.push_back(t);
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            xilinx_interrupt_item it;
            wait (q.size() > 0);
            it = q.pop_front();
            if (it.mode == XILINX_INT_LEGACY) begin
                // Legacy INTx 真实为 Assert_INTx Message TLP; 本桥暂不产, 仅记录
                `uvm_info(get_type_name(),
                    $sformatf("INTx vector=%0d (Message TLP 未建模)", it.vector_num), UVM_MEDIUM)
                continue;
            end
            _send_msi_memwr(it);
        end
    endtask

    protected task _send_msi_memwr(xilinx_interrupt_item it);
        pcie_tl_rw_seq wr;
        bit [63:0] a;
        bit [31:0] d;
        if (ep_seqr == null) begin
            `uvm_error(get_type_name(), "ep_seqr 未设置, 无法注入中断 MemWr")
            return;
        end
        a = (it.mode == XILINX_INT_MSIX) ? it.msix_addr : msi_addr;
        // MSI 消息数据: MSI-X 用表项 data; MSI 用 {marker, vector} 便于 RC 辨识
        d = (it.mode == XILINX_INT_MSIX) ? it.msix_data
                                         : (32'h1500_0000 | (it.vector_num & 32'hFF));
        wr = pcie_tl_rw_seq::type_id::create("int_memwr");
        wr.op = PCIE_RW_WRITE; wr.addr = a; wr.byte_len = 4;
        wr.wdata = new[4];
        for (int i = 0; i < 4; i++) wr.wdata[i] = d[i*8 +: 8];
        `uvm_info(get_type_name(),
            $sformatf("注入中断 MemWr: mode=%s addr=0x%016h data=0x%08h",
                      it.mode.name(), a, d), UVM_MEDIUM)
        wr.start(ep_seqr);
        sent_memwr++;
    endtask
endclass : xilinx_pcie_int2tlp_bridge
