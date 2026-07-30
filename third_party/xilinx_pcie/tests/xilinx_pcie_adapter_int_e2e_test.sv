import uvm_pkg::*;
import pcie_tl_pkg::*;
import xilinx_pcie_adapter_pkg::*;
`include "uvm_macros.svh"

//=============================================================================
// 端到端中断测试: EP 拉高 cfg_interrupt_msi_int -> IP 桥转成 MemWr -> RC 收到 TLP
//
// 复用 adapter_base_test 的 pcie_tl_env (1RC+1EP over Xilinx AXIS)。加:
//   - 中断 agent (EP 侧驱动 cfg_interrupt 边带 + 本地 IP 应答)
//   - int2tlp 桥 (订阅中断 monitor, 把 MSI 断言转成到 msi_addr 的 MemWr, 在
//     EP sequencer 上发出 -> 经 AXIS 上行到 RC)
//   - RC 侧计数器 (订阅 rc_agent.monitor.tlp_ap, 统计到 msi_addr 的 MemWr)
//
// 确认: EP 每拉高一次 msi_int, RC 就在普通 TLP 接口收到一条对应的 MemWr。
//=============================================================================

// RC 侧: 统计收到的、写到 MSI 地址的 MemWr = 收到的中断数
class xilinx_rc_msi_counter extends uvm_subscriber #(pcie_tl_tlp);
    `uvm_component_utils(xilinx_rc_msi_counter)
    bit [63:0] msi_addr;
    int        hit_count = 0;
    function new(string n, uvm_component p); super.new(n, p); endfunction
    function void write(pcie_tl_tlp t);
        pcie_tl_mem_tlp m;
        if (t == null) return;
        if (t.kind == TLP_MEM_WR && $cast(m, t) && m.addr == msi_addr) begin
            hit_count++;
            `uvm_info("RC_MSI",
                $sformatf("RC 收到中断 MemWr #%0d @0x%016h len=%0d", hit_count, m.addr, m.length),
                UVM_LOW)
        end
    endfunction
endclass


class xilinx_pcie_adapter_int_e2e_test extends xilinx_pcie_adapter_base_test;
    `uvm_component_utils(xilinx_pcie_adapter_int_e2e_test)

    localparam bit [63:0] MSI_ADDR = 64'h0000_0000_FEE0_0000;

    xilinx_pcie_interrupt_agent int_agent;
    xilinx_pcie_int2tlp_bridge   bridge;
    xilinx_rc_msi_counter        rc_cnt;

    function new(string n, uvm_component p); super.new(n, p); endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);   // 建 env / poc_responder / e2e_chk
        uvm_config_db#(uvm_active_passive_enum)::set(this, "int_agent", "is_active", UVM_ACTIVE);
        int_agent = xilinx_pcie_interrupt_agent::type_id::create("int_agent", this);
        int_agent.role             = XILINX_PCIE_EP;
        int_agent.interrupt_mode   = XILINX_INT_MSI;
        int_agent.msi_vector_count = 4;
        bridge = xilinx_pcie_int2tlp_bridge::type_id::create("bridge", this);
        rc_cnt = xilinx_rc_msi_counter::type_id::create("rc_cnt", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // 中断 monitor -> 桥 -> EP sequencer 注入 MemWr
        int_agent.monitor.int_ap.connect(bridge.analysis_export);
        bridge.ep_seqr  = env.ep_agent.sequencer;
        bridge.msi_addr = MSI_ADDR;
        // RC monitor -> 计数器
        env.rc_agent.monitor.tlp_ap.connect(rc_cnt.analysis_export);
        rc_cnt.msi_addr = MSI_ADDR;
    endfunction

    task run_phase(uvm_phase phase);
        int n_msi = 2;
        phase.raise_objection(this);
        `uvm_info("INT_E2E", "=== 端到端中断 (EP msi_int -> RC MemWr) START ===", UVM_LOW)

        #200ns;  // IP 模型完成 MSI 使能

        int_agent.driver.send_msi_interrupt(0);
        int_agent.driver.send_msi_interrupt(1);

        #3us;    // 等 MemWr 经 AXIS 上行到 RC

        `uvm_info("INT_E2E",
            $sformatf("发出 msi_int=%0d 次, 桥注入 MemWr=%0d, RC 收到 MemWr=%0d",
                      n_msi, bridge.sent_memwr, rc_cnt.hit_count), UVM_LOW)
        if (rc_cnt.hit_count == n_msi)
            `uvm_info("INT_E2E",
                $sformatf("PASS: RC 收到全部 %0d 条中断 MemWr", n_msi), UVM_LOW)
        else
            `uvm_error("INT_E2E",
                $sformatf("RC 收到 %0d 条, 期望 %0d 条", rc_cnt.hit_count, n_msi))

        `uvm_info("INT_E2E", "=== END ===", UVM_LOW)
        phase.drop_objection(this);
    endtask
endclass
