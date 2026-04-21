class pcie_tl_bar_enum_seq extends uvm_sequence #(pcie_tl_tlp);
    `uvm_object_utils(pcie_tl_bar_enum_seq)
    rand bit [15:0] target_bdf;
    rand int num_bars;
    constraint c_default { num_bars inside {[1:6]}; }
    function new(string name = "pcie_tl_bar_enum_seq"); super.new(name); endfunction
    task body();
        for (int i = 0; i < num_bars; i++) begin
            bit [9:0] bar_reg = (10'h4 + i);
            pcie_tl_cfg_wr_seq wr1, wr2;
            pcie_tl_cfg_rd_seq rd;
            // Write all 1s to BAR
            wr1 = pcie_tl_cfg_wr_seq::type_id::create($sformatf("wr1_%0d",i));
            wr1.target_bdf = target_bdf; wr1.reg_num = bar_reg;
            wr1.first_be = 4'hF; wr1.wr_data = 32'hFFFFFFFF;
            wr1.start(m_sequencer);
            // Read back BAR
            rd = pcie_tl_cfg_rd_seq::type_id::create($sformatf("rd_%0d",i));
            rd.target_bdf = target_bdf; rd.reg_num = bar_reg; rd.first_be = 4'hF;
            rd.start(m_sequencer);
            // Write assigned address
            wr2 = pcie_tl_cfg_wr_seq::type_id::create($sformatf("wr2_%0d",i));
            wr2.target_bdf = target_bdf; wr2.reg_num = bar_reg;
            wr2.first_be = 4'hF; wr2.wr_data = 32'h1000_0000 + (i * 32'h0100_0000);
            wr2.start(m_sequencer);
        end
        // Enable Memory Space in Command register
        begin
            pcie_tl_cfg_wr_seq cmd_wr;
            cmd_wr = pcie_tl_cfg_wr_seq::type_id::create("cmd_wr");
            cmd_wr.target_bdf = target_bdf; cmd_wr.reg_num = 1; // Command at 04h
            cmd_wr.first_be = 4'hF; cmd_wr.wr_data = 32'h0000_0006; // MemSpace + BusMaster
            cmd_wr.start(m_sequencer);
        end
    endtask
endclass
