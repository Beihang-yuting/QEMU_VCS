// cosim_env.sv — UVM environment

class cosim_env extends uvm_env;
    `uvm_component_utils(cosim_env)

    cosim_agent      agt;
    cosim_scoreboard scb;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agt = cosim_agent::type_id::create("agt", this);
        scb = cosim_scoreboard::type_id::create("scb", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        agt.drv.completed_ap.connect(scb.ap);
    endfunction
endclass
