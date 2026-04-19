// cosim_agent.sv — Encapsulates driver, monitor, sequencer

class cosim_agent extends uvm_agent;
    `uvm_component_utils(cosim_agent)

    cosim_driver              drv;
    cosim_monitor             mon;
    uvm_sequencer #(cosim_tlp_tr) sqr;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        drv = cosim_driver::type_id::create("drv", this);
        mon = cosim_monitor::type_id::create("mon", this);
        if (is_active == UVM_ACTIVE)
            sqr = uvm_sequencer#(cosim_tlp_tr)::type_id::create("sqr", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        begin
            virtual cosim_if vif;
            if (!uvm_config_db#(virtual cosim_if)::get(this, "", "vif", vif))
                `uvm_fatal("AGT", "No virtual interface found in config_db")
            drv.vif = vif;
            mon.vif = vif;
        end
        if (is_active == UVM_ACTIVE)
            drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
endclass
