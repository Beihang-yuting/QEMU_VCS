// cosim_test.sv — UVM test cases

class cosim_base_test extends uvm_test;
    `uvm_component_utils(cosim_base_test)
    cosim_env env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = cosim_env::type_id::create("env", this);
    endfunction
endclass

// Test 1: Config Space Read
class cosim_cfgrd_test extends cosim_base_test;
    `uvm_component_utils(cosim_cfgrd_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        cosim_cfgrd_seq seq;
        phase.raise_objection(this);
        seq = cosim_cfgrd_seq::type_id::create("seq");
        seq.start(env.agt.sqr);
        #100;
        phase.drop_objection(this);
    endtask
endclass

// Test 2: BAR0 Register R/W
class cosim_bar_rw_test extends cosim_base_test;
    `uvm_component_utils(cosim_bar_rw_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        cosim_bar_rw_seq seq;
        phase.raise_objection(this);
        seq = cosim_bar_rw_seq::type_id::create("seq");
        seq.start(env.agt.sqr);
        #100;
        phase.drop_objection(this);
    endtask
endclass

// Test 3: Random Traffic
class cosim_random_test extends cosim_base_test;
    `uvm_component_utils(cosim_random_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        cosim_random_seq seq;
        phase.raise_objection(this);
        seq = cosim_random_seq::type_id::create("seq");
        seq.start(env.agt.sqr);
        #100;
        phase.drop_objection(this);
    endtask
endclass

// Test 4: Full Functional
class cosim_functional_test extends cosim_base_test;
    `uvm_component_utils(cosim_functional_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
        cosim_functional_seq seq;
        phase.raise_objection(this);
        seq = cosim_functional_seq::type_id::create("seq");
        seq.start(env.agt.sqr);
        #100;
        phase.drop_objection(this);
    endtask
endclass
