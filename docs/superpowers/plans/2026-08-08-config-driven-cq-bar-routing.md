# Config-driven PCIe CQ BAR Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Preserve RC requester versus runtime PF/VF target identity, decode
every QEMU host-memory request against the live VIP configuration model, and
deliver correct PF/VF, BAR ID, BAR aperture, and target-function sideband to
the real DUT.

**Architecture:** Each cosim_xrc_driver owns a pcie_tl_bar_decoder backed by its own pcie_tl_func_manager. Configuration writes advance a per-RC generation; the decoder rebuilds a compact PF/VF range cache on generation changes, attaches validated CQ routing metadata to the TLP, and the Xilinx adapter encodes that metadata. Decode failures are stopped before VIP tag allocation, with UR propagated through the bridge for reads and posted writes dropped with rate-limited diagnostics.

**Tech Stack:** SystemVerilog, UVM 1.2, Xilinx PCIe CQ descriptor codec, C11 bridge, QEMU device model, CMake/CTest, Synopsys VCS on 10.11.10.53.

---

## File map

New files:

- pcie_tl_vip/src/shared/pcie_tl_bar_decoder.sv: generation-keyed PF/VF BAR range cache and pure decode result.
- pcie_tl_vip/tests/pcie_tl_route_metadata_test.sv: route metadata initialization/copy regression.
- pcie_tl_vip/tests/pcie_tl_bar_state_test.sv: configuration generation and MSE/VF-state regression.
- pcie_tl_vip/tests/pcie_tl_bar_decoder_test.sv: PF/VF, boundary, overlap, and BDF decode matrix.
- tests/integration/test_bridge_completion_status.c: SC/UR Completion transport round trip.
- qemu-plugin/cosim_pcie_request.h: pure full-BDF construction and
  QEMU-host-request field initialization.
- tests/unit/test_cosim_pcie_request.c: requester/target separation and PF8
  no-alias unit regression.
- tests/integration/test_qemu_request_routing_source.sh: dynamic PF BDF and
  directional requester-ID source contract.
- tests/integration/test_cq_bar_routing_source.sh: integration ordering and compatibility contract.

Modified files:

- pcie_tl_vip/src/types/pcie_tl_types.sv: decode result and CQ route record.
- pcie_tl_vip/src/types/pcie_tl_tlp.sv: non-random runtime route metadata.
- pcie_tl_vip/src/shared/pcie_tl_func_manager.sv: maintained command state and config_generation.
- pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv: route-state updates on bypassed CfgWr.
- pcie_tl_vip/src/pcie_tl_pkg.sv: decoder include.
- pcie_tl_vip/sim/filelist_local.f and filelist_cosim.f: focused tests.
- third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv: metadata-driven CQ descriptor.
- third_party/xilinx_pcie/tests/xilinx_pcie_adapter_codec_test.sv: adapter-level CQ sideband regression.
- third_party/xilinx_pcie/sim/filelist_adapter_local.f: include codec test.
- bridge/common/cosim_types.h: named PCIe Completion status values and helpers.
- bridge/vcs/bridge_vcs.c and bridge/vcs/bridge_vcs.sv: status-aware scalar Completion API.
- qemu-plugin/cosim_pcie_rc.c and cosim_pcie_rc.h: sample the current PF BDF,
  keep host requester and target identities separate, reject non-SC reads, and
  rate-limit logs.
- vcs-tb/cosim_xrc_driver.sv: decode-before-tag-map integration and error policy.
- tests/unit/CMakeLists.txt and tests/integration/CMakeLists.txt: register new
  request-routing, bridge, and source tests.

## Remote VCS convention

All SystemVerilog compilation and simulation runs on 10.11.10.53. Use a fresh
directory so paths from earlier offline packages cannot leak into the result:

~~~bash
tar --exclude=.git -cf - . |
  ssh ubuntu@10.11.10.53 \
  "mkdir -p /home/ubuntu/test_cosim/builds/cq-bar-routing && tar -C /home/ubuntu/test_cosim/builds/cq-bar-routing -xf -"
ssh ubuntu@10.11.10.53 \
  "bash -ic 'command -v vcs; vcs -ID | head -1'"
~~~

Expected: command -v prints the W-2024.09-SP1 VCS binary.

### Task 1: Add a typed CQ route record to every TLP

**Files:**
- Modify: pcie_tl_vip/src/types/pcie_tl_types.sv
- Modify: pcie_tl_vip/src/types/pcie_tl_tlp.sv
- Create: pcie_tl_vip/tests/pcie_tl_route_metadata_test.sv
- Modify: pcie_tl_vip/sim/filelist_local.f
- Modify: pcie_tl_vip/sim/filelist_cosim.f

- [ ] **Step 1: Write the failing route-copy test**

Create pcie_tl_route_metadata_test with this body:

~~~systemverilog
import uvm_pkg::*;
import pcie_tl_pkg::*;
`include "uvm_macros.svh"

class pcie_tl_route_metadata_test extends uvm_test;
    `uvm_component_utils(pcie_tl_route_metadata_test)

    function new(string name = "pcie_tl_route_metadata_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        pcie_tl_mem_tlp src;
        pcie_tl_mem_tlp dst;

        phase.raise_objection(this);
        src = pcie_tl_mem_tlp::type_id::create("src");
        src.cq_route = pcie_tl_cq_route_default();
        if (src.cq_route.valid || src.cq_route.vf_index != -1)
            `uvm_error("CQ_ROUTE", "default route must be invalid with vf_index=-1")

        src.cq_route.valid        = 1'b1;
        src.cq_route.target_bdf   = 16'h0114;
        src.cq_route.target_func  = 8'h14;
        src.cq_route.bar_id       = 3'd2;
        src.cq_route.bar_aperture = 6'd2;
        src.cq_route.bar_offset   = 64'h123;
        src.cq_route.is_vf        = 1'b1;
        src.cq_route.pf_index     = 1;
        src.cq_route.vf_index     = 3;

        if (!$cast(dst, src.clone()))
            `uvm_fatal("CQ_ROUTE", "clone did not preserve pcie_tl_mem_tlp type")
        if (dst.cq_route != src.cq_route)
            `uvm_error("CQ_ROUTE", "clone lost CQ route metadata")
        phase.drop_objection(this);
    endtask
endclass
~~~

Add the new test before pcie_tl_tb_top.sv in both relative filelists.

- [ ] **Step 2: Run red on 53**

~~~bash
tar --exclude=.git -cf - pcie_tl_vip third_party/host_mem |
  ssh ubuntu@10.11.10.53 \
  "mkdir -p /home/ubuntu/test_cosim/builds/cq-bar-routing && tar -C /home/ubuntu/test_cosim/builds/cq-bar-routing -xf -"
ssh ubuntu@10.11.10.53 \
  "bash -ic 'cd /home/ubuntu/test_cosim/builds/cq-bar-routing; mkdir -p build/route-meta; vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f pcie_tl_vip/sim/filelist_local.f -o build/route-meta/simv -l build/route-meta/compile.log'"
~~~

Expected: compile fails because the route type, default function, and TLP field
do not exist.

- [ ] **Step 3: Add the route types**

Insert after cpl_status_e in pcie_tl_types.sv:

~~~systemverilog
typedef enum int {
    PCIE_BAR_DECODE_OK,
    PCIE_BAR_DECODE_DISABLED,
    PCIE_BAR_DECODE_NO_MATCH,
    PCIE_BAR_DECODE_CROSS_BOUNDARY,
    PCIE_BAR_DECODE_BDF_MISMATCH,
    PCIE_BAR_DECODE_OVERLAP,
    PCIE_BAR_DECODE_MALFORMED,
    PCIE_BAR_DECODE_INVALID_CONFIG
} pcie_bar_decode_result_e;

typedef struct packed {
    bit        valid;
    bit [15:0] target_bdf;
    bit [7:0]  target_func;
    bit [2:0]  bar_id;
    bit [5:0]  bar_aperture;
    bit [63:0] bar_offset;
    bit        is_vf;
    int        pf_index;
    int        vf_index;
} pcie_tl_cq_route_t;

function automatic pcie_tl_cq_route_t pcie_tl_cq_route_default();
    pcie_tl_cq_route_t route;
    route = '{default:0};
    route.vf_index = -1;
    return route;
endfunction
~~~

Add pcie_tl_cq_route_t cq_route to pcie_tl_tlp. Initialize it in new(), copy
it in do_copy(), and print the fields when valid:

~~~systemverilog
cq_route = pcie_tl_cq_route_default();
~~~

~~~systemverilog
this.cq_route = rhs_.cq_route;
~~~

~~~systemverilog
if (cq_route.valid) begin
    printer.print_field("cq_target_bdf", cq_route.target_bdf, 16, UVM_HEX);
    printer.print_field("cq_target_func", cq_route.target_func, 8, UVM_HEX);
    printer.print_field("cq_bar_id", cq_route.bar_id, 3, UVM_DEC);
    printer.print_field("cq_bar_aperture", cq_route.bar_aperture, 6, UVM_DEC);
    printer.print_field("cq_bar_offset", cq_route.bar_offset, 64, UVM_HEX);
end
~~~

- [ ] **Step 4: Rebuild and run green**

~~~bash
ssh ubuntu@10.11.10.53 \
  "bash -ic 'cd /home/ubuntu/test_cosim/builds/cq-bar-routing; rm -rf build/route-meta; mkdir -p build/route-meta; vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f pcie_tl_vip/sim/filelist_local.f -o build/route-meta/simv -l build/route-meta/compile.log && build/route-meta/simv +UVM_TESTNAME=pcie_tl_route_metadata_test -l build/route-meta/run.log'"
~~~

Expected: UVM_ERROR : 0 and UVM_FATAL : 0.

- [ ] **Step 5: Commit**

~~~bash
git add pcie_tl_vip/src/types/pcie_tl_types.sv \
        pcie_tl_vip/src/types/pcie_tl_tlp.sv \
        pcie_tl_vip/tests/pcie_tl_route_metadata_test.sv \
        pcie_tl_vip/sim/filelist_local.f \
        pcie_tl_vip/sim/filelist_cosim.f
git commit -m "feat(vip): add CQ BAR route metadata"
~~~

### Task 2: Maintain route-affecting configuration state

**Files:**
- Modify: pcie_tl_vip/src/shared/pcie_tl_func_manager.sv
- Modify: pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv
- Create: pcie_tl_vip/tests/pcie_tl_bar_state_test.sv
- Modify: pcie_tl_vip/sim/filelist_local.f
- Modify: pcie_tl_vip/sim/filelist_cosim.f

- [ ] **Step 1: Write the failing generation/state test**

Create a normal UVM test with a proxy created in build_phase. Its run_phase
must execute these checks:

~~~systemverilog
mgr = pcie_tl_func_manager::type_id::create("mgr");
mgr.cfg_profile = PCIE_CFG_PROFILE_DPU_20F9_501X;
mgr.build_topology(0, 1, 16, 16'h20f9, 16'h5011, 16'h8689);
proxy.func_mgr = mgr;
proxy.multi_function_mode = 1;
proxy.bypass_enable = 1;
pf_bdf = mgr.pf_ctx[0].bdf;

g0 = mgr.config_generation;
void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0006, 0, 4));
if (!mgr.pf_ctx[0].memory_space_en ||
    !mgr.pf_ctx[0].bus_master_en ||
    !mgr.pf_ctx[0].bar_enable[0] ||
    !mgr.pf_ctx[0].bar_enable[2] ||
    !mgr.pf_ctx[0].bar_enable[4] ||
    mgr.config_generation != g0 + 1)
    `uvm_error("BAR_STATE", "Command.MSE/BME was not mirrored exactly")

g0 = mgr.config_generation;
void'(proxy.handle_cfg_write_bdf(pf_bdf, 1, 32'h0000_0002, 0, 4));
if (mgr.pf_ctx[0].bus_master_en || mgr.config_generation != g0)
    `uvm_error("BAR_STATE", "BME-only change must not invalidate BAR routing")

g0 = mgr.config_generation;
void'(proxy.handle_cfg_write_bdf(pf_bdf, 6, 32'hffff_ffff, 0, 4));
if (mgr.config_generation != g0)
    `uvm_error("BAR_STATE", "BAR sizing write changed the active generation")

void'(proxy.handle_cfg_write_bdf(pf_bdf, 6, 32'h0800_000c, 0, 4));
void'(proxy.handle_cfg_write_bdf(pf_bdf, 7, 32'h0000_0009, 0, 4));
if (mgr.pf_ctx[0].bar_base[2] != 64'h0000_0009_0800_0000 ||
    mgr.config_generation != g0 + 2)
    `uvm_error("BAR_STATE", "paired BAR2 assignment/generation mismatch")

sriov_dw = int'(mgr.sriov_caps[0].offset >> 2);
g0 = mgr.config_generation;
void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 4, 32'd16, 0, 2));
void'(proxy.handle_cfg_write_bdf(pf_bdf, sriov_dw + 2, 32'h0000_0011, 0, 2));
if (!mgr.sriov_caps[0].vf_enable || !mgr.sriov_caps[0].vf_mse ||
    mgr.sriov_caps[0].num_vfs != 16 || mgr.config_generation <= g0)
    `uvm_error("BAR_STATE", "SR-IOV state was not mirrored")

g0 = mgr.config_generation;
if (!mgr.bind_runtime_pf_base(16'h0200) ||
    mgr.pf_ctx[0].bdf != 16'h0200 ||
    mgr.config_generation != g0 + 1)
    `uvm_error("BAR_STATE", "runtime BDF bind did not invalidate routing once")
~~~

Add the test to both filelists.

The generation deltas are intentional: one Command write creates one MSE
edge, while programming both low and high DWORDs of a 64-bit BAR creates two
successive canonical-base changes. BME-only changes do not affect routing.

- [ ] **Step 2: Run red**

Run pcie_tl_bar_state_test with the Task 1 VCS build.

Expected: compile fails on config_generation/memory_space_en or runtime checks
fail because bar_enable and vf_mse are not maintained.

- [ ] **Step 3: Add maintained state and generation helpers**

Add memory_space_en to pcie_tl_func_context and initialize it to zero. Add to
pcie_tl_func_manager:

~~~systemverilog
longint unsigned config_generation = 1;

function void mark_routing_dirty(string reason);
    config_generation++;
    `uvm_info("FUNC_MGR", $sformatf(
        "routing generation=%0d reason=%s", config_generation, reason),
        UVM_HIGH)
endfunction

function void update_command_state(
    pcie_tl_func_context ctx,
    bit memory_space_en,
    bit bus_master_en
);
    bit old_mse;
    old_mse = ctx.memory_space_en;
    ctx.memory_space_en = memory_space_en;
    ctx.bus_master_en = bus_master_en;
    foreach (ctx.bar_enable[bar])
        ctx.bar_enable[bar] =
            memory_space_en &&
            ctx.bar_owner[bar] == bar &&
            ctx.bar_size[bar] != 0;
    if (old_mse != memory_space_en)
        mark_routing_dirty($sformatf("BDF %04h Command.MSE", ctx.bdf));
endfunction
~~~

Reset generation to one at build start. Mark exactly once after an effective
runtime BDF bind (after the PF/VF LUT rekey completes), VF enable/disable
transition, or BAR-base change.

- [ ] **Step 4: Update the configuration proxy**

After byte merging and before BAR handling:

~~~systemverilog
if (dw_addr == 1 && (write_be[0] || write_be[1])) begin
    func_mgr.update_command_state(ctx, merged_dw[1], merged_dw[2]);
    func_mgr.cfg_write(target_bdf, 12'h004, merged_dw, write_be);
    return 1;
end
~~~

For PF/VF BAR programming, save old_base and mark only if the canonical
64-bit base changes. For SR-IOV Control, assign vf_mse from merged_dw[4]
before enable_vfs/disable_vfs, call build_data(), and mark on a VF-MSE edge.
For NumVFs, compare the previous count before marking.

- [ ] **Step 5: Run green and profile regression**

Recompile, then run pcie_tl_bar_state_test and
pcie_tl_dpu_501x_profile_test. Both must have zero UVM errors/fatals.

- [ ] **Step 6: Commit**

~~~bash
git add pcie_tl_vip/src/shared/pcie_tl_func_manager.sv \
        pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv \
        pcie_tl_vip/tests/pcie_tl_bar_state_test.sv \
        pcie_tl_vip/sim/filelist_local.f \
        pcie_tl_vip/sim/filelist_cosim.f
git commit -m "feat(vip): track BAR routing configuration generation"
~~~

### Task 3: Implement the shared PF/VF BAR decoder

**Files:**
- Create: pcie_tl_vip/src/shared/pcie_tl_bar_decoder.sv
- Modify: pcie_tl_vip/src/pcie_tl_pkg.sv
- Create: pcie_tl_vip/tests/pcie_tl_bar_decoder_test.sv
- Modify: pcie_tl_vip/sim/filelist_local.f
- Modify: pcie_tl_vip/sim/filelist_cosim.f

- [ ] **Step 1: Write the failing decode matrix**

Use the configuration proxy for all BAR/Command/SR-IOV writes and construct
requests with:

~~~systemverilog
function pcie_tl_mem_tlp make_read(bit [63:0] addr);
    pcie_tl_mem_tlp req;
    req = pcie_tl_mem_tlp::type_id::create($sformatf("rd_%016h", addr));
    req.kind = TLP_MEM_RD;
    req.fmt = FMT_4DW_NO_DATA;
    req.type_f = TLP_TYPE_MEM_RD;
    req.is_64bit = 1;
    req.addr = addr;
    req.length = 1;
    req.first_be = 4'hf;
    req.last_be = 4'h0;
    return req;
endfunction
~~~

The mailbox assertion is:

~~~systemverilog
result = decoder.decode(
    make_read(64'h0000_0009_0800_002c),
    mgr.pf_ctx[0].bdf, route, reason);
if (result != PCIE_BAR_DECODE_OK ||
    route.bar_id != 2 ||
    route.bar_aperture != 4 ||
    route.target_func != 0 ||
    route.bar_offset != 64'h2c)
    `uvm_error("BAR_DECODE", $sformatf(
        "mailbox route mismatch result=%s reason=%s",
        result.name(), reason))
~~~

The same test asserts PF1-PF3 target functions 1-3; PF apertures 13/4/4; first
and last valid bytes; one-byte boundary crossing; MSE disabled; wrong target
BDF; overlapping enabled BARs; every VF0-VF15 on all four PFs for VF apertures
2/2/3; cross-VF requests; and two independent decoder caches. In a separate
synthetic manager instance, build nine PF contexts, enable and assign only PF8
BAR0 through the configuration proxy, and require PF8 BDF/base+8,
`target_func=8'h08`, and a result distinct from PF0. This is a no-truncation
unit regression, not an expansion of the one-to-four-PF real-DUT matrix.

- [ ] **Step 2: Run red**

Add the test to both filelists and add the nonexistent decoder include after
pcie_tl_func_manager.sv. Compile on 53.

Expected: compile fails because pcie_tl_bar_decoder is absent.

- [ ] **Step 3: Implement the cache entry and public interface**

~~~systemverilog
class pcie_tl_bar_decode_entry extends uvm_object;
    `uvm_object_utils(pcie_tl_bar_decode_entry)
    bit is_vf;
    bit enabled;
    bit [63:0] base;
    bit [63:0] span;
    bit [63:0] function_size;
    bit [15:0] pf_bdf;
    bit [15:0] first_vf_bdf;
    int vf_bdf_stride;
    int num_vfs;
    int pf_index;
    bit [2:0] bar_id;
    bit [5:0] bar_aperture;
    function new(string name = "pcie_tl_bar_decode_entry");
        super.new(name);
    endfunction
endclass

class pcie_tl_bar_decoder extends uvm_object;
    `uvm_object_utils(pcie_tl_bar_decoder)
    pcie_tl_func_manager func_mgr;
    longint unsigned cached_generation = '1;
    pcie_tl_bar_decode_entry entries[$];
    pcie_bar_decode_result_e cache_result = PCIE_BAR_DECODE_OK;
    string cache_reason;

    function new(string name = "pcie_tl_bar_decoder");
        super.new(name);
    endfunction

    protected function automatic bit size_is_valid(bit [63:0] size);
        return size >= 4096 && (size & (size - 1)) == 0;
    endfunction

    protected function automatic bit be_is_contiguous(bit [3:0] be);
        return be inside {4'h1, 4'h2, 4'h3, 4'h4, 4'h6, 4'h7,
                          4'h8, 4'hc, 4'he, 4'hf};
    endfunction

    protected function automatic int first_lane(bit [3:0] be);
        for (int lane = 0; lane < 4; lane++)
            if (be[lane]) return lane;
        return -1;
    endfunction

    protected function automatic int last_lane(bit [3:0] be);
        for (int lane = 3; lane >= 0; lane--)
            if (be[lane]) return lane;
        return -1;
    endfunction

    protected function automatic int unsigned log2_size(bit [63:0] size);
        int unsigned value;
        bit [63:0] remaining;
        value = 0;
        remaining = size;
        while (remaining > 1) begin
            remaining >>= 1;
            value++;
        end
        return value;
    endfunction

    protected function pcie_bar_decode_result_e rebuild_cache(
        output string reason
    );
        pcie_tl_bar_decode_entry entry;
        pcie_tl_func_context ctx;
        pcie_tl_sriov_cap sc;
        bit [63:0] span;

        entries.delete();
        reason = "";
        if (func_mgr == null) begin
            reason = "BAR decoder has no function manager";
            return PCIE_BAR_DECODE_INVALID_CONFIG;
        end

        for (int pf = 0; pf < func_mgr.num_pfs; pf++) begin
            ctx = func_mgr.pf_ctx[pf];
            for (int bar = 0; bar < 6; bar++) begin
                if (ctx.bar_owner[bar] != bar || ctx.bar_size[bar] == 0)
                    continue;
                if (!size_is_valid(ctx.bar_size[bar]) ||
                    ctx.bar_base[bar] > (~64'b0 - ctx.bar_size[bar])) begin
                    reason = $sformatf(
                        "invalid PF%0d BAR%0d base=%016h size=%016h",
                        pf, bar, ctx.bar_base[bar], ctx.bar_size[bar]);
                    return PCIE_BAR_DECODE_INVALID_CONFIG;
                end
                entry = pcie_tl_bar_decode_entry::type_id::create(
                    $sformatf("pf%0d_bar%0d", pf, bar));
                entry.is_vf = 0;
                entry.enabled = ctx.enabled && ctx.bar_enable[bar];
                entry.base = ctx.bar_base[bar];
                entry.span = ctx.bar_size[bar];
                entry.function_size = ctx.bar_size[bar];
                entry.pf_bdf = ctx.bdf;
                entry.first_vf_bdf = 0;
                entry.vf_bdf_stride = 0;
                entry.num_vfs = 0;
                entry.pf_index = pf;
                entry.bar_id = bar[2:0];
                entry.bar_aperture = log2_size(ctx.bar_size[bar]) - 12;
                entries.push_back(entry);
            end

            sc = func_mgr.sriov_caps[pf];
            for (int bar = 0; bar < 6; bar++) begin
                if (sc.vf_bar_owner[bar] != bar ||
                    sc.vf_bar_size[bar] == 0 ||
                    sc.num_vfs == 0)
                    continue;
                if (!size_is_valid(sc.vf_bar_size[bar]) ||
                    sc.vf_bar_size[bar] > (~64'b0 / sc.num_vfs)) begin
                    reason = $sformatf(
                        "invalid PF%0d VF BAR%0d size=%016h NumVFs=%0d",
                        pf, bar, sc.vf_bar_size[bar], sc.num_vfs);
                    return PCIE_BAR_DECODE_INVALID_CONFIG;
                end
                span = sc.vf_bar_size[bar] * sc.num_vfs;
                if (sc.vf_bar[bar] > (~64'b0 - span)) begin
                    reason = $sformatf(
                        "overflow PF%0d VF BAR%0d base=%016h span=%016h",
                        pf, bar, sc.vf_bar[bar], span);
                    return PCIE_BAR_DECODE_INVALID_CONFIG;
                end
                entry = pcie_tl_bar_decode_entry::type_id::create(
                    $sformatf("pf%0d_vf_bar%0d", pf, bar));
                entry.is_vf = 1;
                entry.enabled = sc.vf_enable && sc.vf_mse;
                entry.base = sc.vf_bar[bar];
                entry.span = span;
                entry.function_size = sc.vf_bar_size[bar];
                entry.pf_bdf = func_mgr.pf_ctx[pf].bdf;
                entry.first_vf_bdf = sc.get_vf_rid(0);
                entry.vf_bdf_stride = sc.vf_stride;
                entry.num_vfs = sc.num_vfs;
                entry.pf_index = pf;
                entry.bar_id = bar[2:0];
                entry.bar_aperture = log2_size(sc.vf_bar_size[bar]) - 12;
                entries.push_back(entry);
            end
        end
        return PCIE_BAR_DECODE_OK;
    endfunction

    function pcie_bar_decode_result_e decode(
        pcie_tl_mem_tlp req,
        bit [15:0] qemu_target_bdf,
        output pcie_tl_cq_route_t route,
        output string reason
    );
        pcie_tl_bar_decode_entry enabled_hits[$];
        pcie_tl_bar_decode_entry disabled_hits[$];
        pcie_tl_bar_decode_entry selected;
        pcie_tl_func_context vf_ctx;
        longint unsigned dwords;
        bit [63:0] first_byte;
        bit [63:0] last_byte;
        bit [63:0] tail_bytes;
        bit [63:0] first_index;
        bit [63:0] last_index;
        bit [63:0] function_base;
        bit [15:0] decoded_bdf;
        int first_be_lane;
        int last_be_lane;

        route = pcie_tl_cq_route_default();
        reason = "";
        if (func_mgr == null || req == null) begin
            reason = "null function manager or memory request";
            return PCIE_BAR_DECODE_INVALID_CONFIG;
        end
        if (cached_generation != func_mgr.config_generation) begin
            cache_result = rebuild_cache(cache_reason);
            cached_generation = func_mgr.config_generation;
        end
        if (cache_result != PCIE_BAR_DECODE_OK) begin
            reason = cache_reason;
            return cache_result;
        end
        if (req.addr[1:0] != 0 || !be_is_contiguous(req.first_be)) begin
            reason = $sformatf("malformed addr=%016h first_be=%h",
                               req.addr, req.first_be);
            return PCIE_BAR_DECODE_MALFORMED;
        end

        dwords = (req.length == 0) ? 1024 : req.length;
        first_be_lane = first_lane(req.first_be);
        if (dwords == 1) begin
            if (req.last_be != 0) begin
                reason = "one-DW request has nonzero last_be";
                return PCIE_BAR_DECODE_MALFORMED;
            end
            last_be_lane = last_lane(req.first_be);
        end else begin
            if (!be_is_contiguous(req.last_be)) begin
                reason = $sformatf("multi-DW request has last_be=%h",
                                   req.last_be);
                return PCIE_BAR_DECODE_MALFORMED;
            end
            last_be_lane = last_lane(req.last_be);
        end

        tail_bytes = (dwords - 1) * 4 + last_be_lane;
        if (req.addr > (~64'b0 - tail_bytes)) begin
            reason = "request byte range overflows 64-bit address";
            return PCIE_BAR_DECODE_MALFORMED;
        end
        first_byte = req.addr + first_be_lane;
        last_byte = req.addr + tail_bytes;

        foreach (entries[i]) begin
            if (first_byte >= entries[i].base &&
                first_byte < entries[i].base + entries[i].span) begin
                if (entries[i].enabled)
                    enabled_hits.push_back(entries[i]);
                else
                    disabled_hits.push_back(entries[i]);
            end
        end
        if (enabled_hits.size() > 1) begin
            reason = $sformatf("%0d enabled BARs overlap at %016h",
                               enabled_hits.size(), first_byte);
            return PCIE_BAR_DECODE_OVERLAP;
        end
        if (enabled_hits.size() == 0) begin
            if (disabled_hits.size() != 0) begin
                reason = $sformatf("BAR at %016h is disabled", first_byte);
                return PCIE_BAR_DECODE_DISABLED;
            end
            reason = $sformatf("no BAR contains %016h", first_byte);
            return PCIE_BAR_DECODE_NO_MATCH;
        end

        selected = enabled_hits[0];
        if (!selected.is_vf) begin
            if (last_byte >= selected.base + selected.function_size) begin
                reason = "request crosses PF BAR boundary";
                return PCIE_BAR_DECODE_CROSS_BOUNDARY;
            end
            decoded_bdf = selected.pf_bdf;
            function_base = selected.base;
            route.vf_index = -1;
        end else begin
            if (last_byte >= selected.base + selected.span) begin
                reason = "request crosses VF aperture boundary";
                return PCIE_BAR_DECODE_CROSS_BOUNDARY;
            end
            first_index = (first_byte - selected.base) /
                          selected.function_size;
            last_index = (last_byte - selected.base) /
                         selected.function_size;
            if (first_index != last_index ||
                first_index >= selected.num_vfs) begin
                reason = "request crosses VF function BAR boundary";
                return PCIE_BAR_DECODE_CROSS_BOUNDARY;
            end
            decoded_bdf = selected.first_vf_bdf +
                          first_index * selected.vf_bdf_stride;
            vf_ctx = func_mgr.lookup_by_bdf(decoded_bdf);
            if (vf_ctx == null || !vf_ctx.enabled ||
                !vf_ctx.is_vf || vf_ctx.pf_index != selected.pf_index ||
                vf_ctx.vf_index != first_index) begin
                reason = $sformatf("decoded VF BDF %04h is not enabled",
                                   decoded_bdf);
                return PCIE_BAR_DECODE_DISABLED;
            end
            function_base = selected.base +
                            first_index * selected.function_size;
            route.vf_index = first_index;
        end

        if (decoded_bdf != qemu_target_bdf) begin
            reason = $sformatf("address decoded BDF=%04h QEMU BDF=%04h",
                               decoded_bdf, qemu_target_bdf);
            return PCIE_BAR_DECODE_BDF_MISMATCH;
        end
        route.valid = 1;
        route.target_bdf = decoded_bdf;
        route.target_func = decoded_bdf[7:0];
        route.bar_id = selected.bar_id;
        route.bar_aperture = selected.bar_aperture;
        route.bar_offset = req.addr - function_base;
        route.is_vf = selected.is_vf;
        route.pf_index = selected.pf_index;
        reason = "BAR decode success";
        return PCIE_BAR_DECODE_OK;
    endfunction
endclass
~~~

Keep this class after pcie_tl_func_manager in package include order. The test
must also exercise length=1 and length>1 BE range calculations.

- [ ] **Step 4: Run the full matrix**

Recompile and run pcie_tl_bar_decoder_test on 53.

Expected: mailbox PASS, 192 VF BAR routes plus PF/boundary/error cases pass,
PF8 target-function no-alias passes, and zero UVM errors/fatals.

- [ ] **Step 5: Commit**

~~~bash
git add pcie_tl_vip/src/shared/pcie_tl_bar_decoder.sv \
        pcie_tl_vip/src/pcie_tl_pkg.sv \
        pcie_tl_vip/tests/pcie_tl_bar_decoder_test.sv \
        pcie_tl_vip/sim/filelist_local.f \
        pcie_tl_vip/sim/filelist_cosim.f
git commit -m "feat(vip): decode PF and VF BAR routes from config state"
~~~

### Task 4: Encode validated metadata on Xilinx CQ

**Files:**
- Modify: third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv
- Modify: third_party/xilinx_pcie/tests/xilinx_pcie_adapter_codec_test.sv
- Modify: third_party/xilinx_pcie/sim/filelist_adapter_local.f

- [ ] **Step 1: Add a failing adapter test**

Add the codec test to filelist_adapter_local.f. Define:

~~~systemverilog
class xilinx_cq_route_probe extends xilinx_pcie_if_adapter;
    `uvm_component_utils(xilinx_cq_route_probe)
    function new(string name = "xilinx_cq_route_probe",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction
    function bit [127:0] probe(pcie_tl_tlp tlp);
        return encode_descriptor(tlp, XILINX_CH_CQ);
    endfunction
endclass
~~~

Create a MemRd with cq_route valid, bar_id=2, aperture=4, target_func=3. Assert
get_cq_bar_id/aperture/target_func return those exact values.

- [ ] **Step 2: Run red on 53**

~~~bash
ssh ubuntu@10.11.10.53 \
  "bash -ic 'cd /home/ubuntu/test_cosim/builds/cq-bar-routing; mkdir -p build/xilinx-route; vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f third_party/xilinx_pcie/sim/filelist_adapter_local.f +define+DATA_WIDTH=256 +define+STRADDLE_EN=0 -o build/xilinx-route/simv -l build/xilinx-route/compile.log && build/xilinx-route/simv +UVM_TESTNAME=xilinx_pcie_adapter_codec_test -l build/xilinx-route/run-red.log'"
~~~

Expected: route checks see zeros.

- [ ] **Step 3: Replace the hard-coded sideband**

~~~systemverilog
XILINX_CH_CQ: begin
    pcie_tl_cq_route_t route;
    route = tlp.cq_route;
    desc = xilinx_desc_codec::encode_cq(
        tlp,
        .bar_id(route.valid ? route.bar_id : 3'h0),
        .bar_aperture(route.valid ? route.bar_aperture : 6'h0),
        .target_func(route.valid ? route.target_func : 8'h0));
end
~~~

Invalid metadata retains legacy zero-sideband behavior. Config-driven mode
will refuse to send invalid metadata.

- [ ] **Step 4: Run green and smoke**

Run xilinx_pcie_adapter_codec_test and xilinx_pcie_adapter_smoke_test. Both
must report zero UVM errors/fatals.

- [ ] **Step 5: Commit**

~~~bash
git add third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv \
        third_party/xilinx_pcie/tests/xilinx_pcie_adapter_codec_test.sv \
        third_party/xilinx_pcie/sim/filelist_adapter_local.f
git commit -m "fix(xilinx): encode decoded BAR route on CQ"
~~~

### Task 5: Fix QEMU host-request identity and carry UR status

**Files:**
- Create: qemu-plugin/cosim_pcie_request.h
- Modify: bridge/common/cosim_types.h
- Modify: bridge/vcs/bridge_vcs.c
- Modify: bridge/vcs/bridge_vcs.sv
- Modify: qemu-plugin/cosim_pcie_rc.c
- Modify: qemu-plugin/cosim_pcie_rc.h
- Create: tests/unit/test_cosim_pcie_request.c
- Modify: tests/unit/CMakeLists.txt
- Create: tests/integration/test_qemu_request_routing_source.sh
- Create: tests/integration/test_bridge_completion_status.c
- Modify: tests/integration/CMakeLists.txt

- [ ] **Step 1: Write failing request-identity tests**

Create tests/unit/test_cosim_pcie_request.c:

~~~c
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include "cosim_pcie_request.h"

int main(void)
{
    tlp_entry_t req;
    memset(&req, 0xff, sizeof(req));

    assert(cosim_pcie_bdf(1, 0) == 0x0100);
    assert(cosim_pcie_bdf(1, 8) == 0x0108);
    assert(cosim_pcie_bdf(1, 8) != cosim_pcie_bdf(1, 0));

    cosim_route_host_to_device(&req, cosim_pcie_bdf(1, 8));
    assert(req.requester_id == 0x0000);
    assert(req.target_bdf == 0x0108);
    return 0;
}
~~~

Register the executable in tests/unit/CMakeLists.txt with include directories
qemu-plugin and bridge/common.

Create tests/integration/test_qemu_request_routing_source.sh:

~~~bash
#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo/qemu-plugin/cosim_pcie_rc.c" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")

def fail(message):
    print(f"[qemu-request-routing] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)

def function_body(name):
    match = re.search(rf"\b{re.escape(name)}\s*\([^;]*?\)\s*\{{", source,
                      re.S)
    if not match:
        fail(f"function not found: {name}")
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    fail(f"unterminated function: {name}")

for name in ("cosim_mmio_do_read", "cosim_mmio_do_write",
             "cosim_config_read", "cosim_config_write",
             "cosim_cfgrd", "cosim_cfgwr",
             "cosim_rc_vf_config_read", "cosim_rc_vf_config_write",
             "cosim_vf_invalidate_atc"):
    if "cosim_route_host_to_device" not in function_body(name):
        fail(f"{name} does not use the host-request routing helper")

live_bdf = re.compile(
    r"cosim_current_bdf\s*\(\s*PCI_DEVICE\s*\(\s*bc->dev\s*\)\s*\)")
for name in ("cosim_mmio_read", "cosim_mmio_write"):
    if not live_bdf.search(function_body(name)):
        fail(f"{name} does not sample the PF BDF at access time")

for pattern in (r"requester_id\s*=\s*[^;]*target_bdf",
                r"requester_id\s*=\s*[^;]*vf_bdf",
                r"requester_id\s*=\s*[^;]*pf_bdf"):
    if re.search(pattern, source):
        fail(f"direct requester/target alias remains: {pattern}")

if "req->requester_id" not in function_body("cosim_dma_cb"):
    fail("device-to-host DMA no longer consumes the PF/VF requester ID")

print("[qemu-request-routing] PASS")
PY
~~~

Register the shell test in tests/integration/CMakeLists.txt.

- [ ] **Step 2: Run request-identity red**

~~~bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j"$(nproc)"
ctest --test-dir build \
  -R "test_cosim_pcie_request|test_qemu_request_routing_source" \
  --output-on-failure
~~~

Expected: the C test cannot include cosim_pcie_request.h and the source
contract reports the current requester/target copies and realize-time PF BDF.

- [ ] **Step 3: Add the host-request helper and use the live PF BDF**

Create qemu-plugin/cosim_pcie_request.h:

~~~c
#ifndef COSIM_PCIE_REQUEST_H
#define COSIM_PCIE_REQUEST_H

#include <stdint.h>
#include "cosim_types.h"

static inline uint16_t cosim_pcie_bdf(uint8_t bus, uint8_t devfn)
{
    return (uint16_t)(((uint16_t)bus << 8) | devfn);
}

static inline void cosim_route_host_to_device(tlp_entry_t *req,
                                               uint16_t target_bdf)
{
    req->requester_id = 0x0000;
    req->target_bdf = target_bdf;
}

#endif
~~~

In cosim_pcie_rc.c add:

~~~c
static uint16_t cosim_current_bdf(PCIDevice *dev)
{
    return cosim_pcie_bdf((uint8_t)pci_bus_num(pci_get_bus(dev)), dev->devfn);
}
~~~

Use cosim_route_host_to_device for QEMU-originated CfgRd/CfgWr, MRd/MWr, VF
config, legacy discovery, and ATS invalidation. PF MMIO callbacks calculate
their target with cosim_current_bdf(PCI_DEVICE(bc->dev)) on every access; they
must not use the target cached by cosim_register_pf_bars during realize. VF
aperture callbacks retain the runtime-bound first_vf_bdf plus stride. Do not
change any dma_req_t/MSI device-requester handling.

- [ ] **Step 4: Run request-identity green**

Run the two Step 2 tests and tests/sv/run_test_runtime_bdf_utils.sh. Require
PF8=0x0108, requester=0, dynamic target checks, and the existing 16-PF
no-alias matrix to pass.

- [ ] **Step 5: Write the failing bridge round-trip test**

Create the complete test:

~~~c
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include "bridge_qemu.h"
#include "cosim_types.h"

static const char *SHM_NAME = "/cosim_test_cpl_status";
static const char *SOCK_PATH = "/tmp/cosim_test_cpl_status.sock";

extern int bridge_vcs_init(const char *shm_name, const char *sock_path);
extern int bridge_vcs_poll_tlp_scalar(void);
extern int bridge_vcs_get_poll_tag(void);
extern int bridge_vcs_send_cpl_scalar_status(int tag, int len, int status);
extern void bridge_vcs_cleanup(void);

static void vcs_ur_stub(void)
{
    assert(bridge_vcs_init(SHM_NAME, SOCK_PATH) == 0);
    while (bridge_vcs_poll_tlp_scalar() != 0)
        usleep(1000);
    assert(bridge_vcs_send_cpl_scalar_status(
        bridge_vcs_get_poll_tag(), 0, COSIM_CPL_STATUS_UR) == 0);
    bridge_vcs_cleanup();
}

int main(void)
{
    pid_t child;
    bridge_ctx_t *ctx;
    tlp_entry_t req;
    cpl_entry_t cpl;
    int ret;
    int status;

    child = fork();
    assert(child >= 0);
    if (child == 0) {
        usleep(100000);
        vcs_ur_stub();
        _exit(0);
    }

    ctx = bridge_init(SHM_NAME, SOCK_PATH);
    assert(ctx != NULL);
    assert(bridge_connect(ctx) == 0);

    memset(&req, 0, sizeof(req));
    req.type = TLP_MRD;
    req.addr = 0x90800002cULL;
    req.len = 4;
    memset(&cpl, 0, sizeof(cpl));
    ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
    assert(ret == 0);
    assert(cpl.status == COSIM_CPL_STATUS_UR);
    assert(cpl.len == 0);
    assert(!cosim_cpl_status_is_success(cpl.status));

    bridge_destroy(ctx);
    waitpid(child, &status, 0);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    unlink(SOCK_PATH);
    puts("PASS: status-aware UR completion round trip");
    return 0;
}
~~~

Register it in tests/integration/CMakeLists.txt:

~~~cmake
add_executable(test_bridge_completion_status test_bridge_completion_status.c)
target_link_libraries(test_bridge_completion_status
                      cosim_bridge cosim_bridge_vcs)
add_test(NAME test_bridge_completion_status
         COMMAND test_bridge_completion_status)
set_tests_properties(test_bridge_completion_status PROPERTIES TIMEOUT 10)
~~~

- [ ] **Step 6: Run Completion-status red**

~~~bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j"$(nproc)"
ctest --test-dir build -R test_bridge_completion_status --output-on-failure
~~~

Expected: compile/link fails because the status constants/helper/API are absent.

- [ ] **Step 7: Define statuses without changing the wire ABI**

Insert before cpl_entry_t:

~~~c
typedef enum {
    COSIM_CPL_STATUS_SC  = 0,
    COSIM_CPL_STATUS_UR  = 1,
    COSIM_CPL_STATUS_CRS = 2,
    COSIM_CPL_STATUS_CA  = 4,
} cosim_cpl_status_t;

static inline int cosim_cpl_status_is_valid(uint8_t status)
{
    return status == COSIM_CPL_STATUS_SC ||
           status == COSIM_CPL_STATUS_UR ||
           status == COSIM_CPL_STATUS_CRS ||
           status == COSIM_CPL_STATUS_CA;
}

static inline int cosim_cpl_status_is_success(uint8_t status)
{
    return status == COSIM_CPL_STATUS_SC;
}
~~~

cpl_entry_t and its 84-byte static assertion remain unchanged.

- [ ] **Step 8: Add status-aware scalar bridge APIs**

Change the internal Completion builder to accept status and preserve the
existing TCP/SHM send body:

~~~c
static int send_completion_status_ctx(
    rc_ctx_t *ctx,
    int tag,
    const unsigned int *data,
    int len,
    int status)
{
    cpl_entry_t cpl;
    if (!cosim_cpl_status_is_valid((uint8_t)status))
        return -1;
    memset(&cpl, 0, sizeof(cpl));
    cpl.type = TLP_CPL;
    cpl.tag = (uint16_t)tag;
    cpl.status = (uint8_t)status;
    cpl.len = (uint32_t)len;

    int bytes = (len < COSIM_TLP_DATA_SIZE) ? len : COSIM_TLP_DATA_SIZE;
    int words = (bytes + 3) / 4;
    for (int i = 0; i < words; i++)
        memcpy(&cpl.data[i * 4], &data[i], 4);

    if (ctx->transport) {
        if (ctx->transport->send_cpl(ctx->transport, &cpl) < 0)
            return -1;
        sync_msg_t msg = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
        return ctx->transport->send_sync(ctx->transport, &msg);
    }

    if (ring_buf_enqueue(&g_shm.cpl_ring, &cpl) < 0)
        return -1;
    sync_msg_t msg = { .type = SYNC_MSG_CPL_READY, .payload = 0 };
    return sock_sync_send(g_sock_fd, &msg);
}

static int send_completion_ctx(
    rc_ctx_t *ctx,
    int tag,
    const unsigned int *data,
    int len)
{
    return send_completion_status_ctx(
        ctx, tag, data, len, COSIM_CPL_STATUS_SC);
}
~~~

Keep send_completion_ctx as an SC wrapper. Add:

~~~c
int bridge_vcs_send_cpl_scalar_status_rc(
    int rc, int tag, int len, int status)
{
    if (!rc_ok(rc))
        return -1;
    return send_completion_status_ctx(
        &g_rc[rc], tag, g_send_cpl_buf[rc], len, status);
}

int bridge_vcs_send_cpl_scalar_status(int tag, int len, int status)
{
    return bridge_vcs_send_cpl_scalar_status_rc(0, tag, len, status);
}
~~~

The existing scalar APIs call these with COSIM_CPL_STATUS_SC. Import both new
functions in bridge_vcs.sv with argument order rc, tag, len, status.

- [ ] **Step 9: Make QEMU honor non-SC status**

Add uint64_t mmio_cpl_error_count to CosimPCIeRC. After a successful bridge
wait and before payload copy:

~~~c
if (!cosim_cpl_status_is_success(cpl.status)) {
    s->mmio_cpl_error_count++;
    if (s->mmio_cpl_error_count <= 8 ||
        (s->mmio_cpl_error_count % 1024) == 0) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim: MRd completion status=%u pcie=0x%lx "
                      "bdf=0x%04x count=%lu\n",
                      cpl.status, (unsigned long)pcie_addr, target_bdf,
                      (unsigned long)s->mmio_cpl_error_count);
    }
    return UINT64_MAX;
}
~~~

- [ ] **Step 10: Run green and C regressions**

~~~bash
cmake --build build -j"$(nproc)"
ctest --test-dir build \
  -R "test_cosim_pcie_request|test_qemu_request_routing_source|test_bridge_completion_status|test_runtime_bdf_utils" \
  --output-on-failure
make test-unit
make test-integration
~~~

Expected: host request identity, dynamic BDF sampling, PF8 no-alias, the new
UR round trip, and all existing bridge tests pass.

- [ ] **Step 11: Commit**

~~~bash
git add bridge/common/cosim_types.h bridge/vcs/bridge_vcs.c \
        bridge/vcs/bridge_vcs.sv qemu-plugin/cosim_pcie_rc.c \
        qemu-plugin/cosim_pcie_rc.h qemu-plugin/cosim_pcie_request.h \
        tests/unit/test_cosim_pcie_request.c tests/unit/CMakeLists.txt \
        tests/integration/test_qemu_request_routing_source.sh \
        tests/integration/test_bridge_completion_status.c \
        tests/integration/CMakeLists.txt
git commit -m "fix(cosim): preserve host request routing identity"
~~~

### Task 6: Integrate decode before QEMU/VIP tag mapping

**Files:**
- Modify: vcs-tb/cosim_xrc_driver.sv
- Create: tests/integration/test_cq_bar_routing_source.sh
- Modify: tests/integration/CMakeLists.txt

- [ ] **Step 1: Write the failing source contract**

Create this complete shell test:

~~~bash
#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$repo/vcs-tb/cosim_xrc_driver.sv" \
           "$repo/third_party/xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv" <<'PY'
import sys
from pathlib import Path

def fail(message):
    print(f"[cq-bar-routing] FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)

source = Path(sys.argv[1]).read_text(encoding="utf-8")
adapter = Path(sys.argv[2]).read_text(encoding="utf-8")
try:
    decode_pos = source.index("bar_decoder.decode(")
    map_pos = source.index("pending_qemu_tag_by_inst[request_inst_id]")
except ValueError as error:
    fail(str(error))

if decode_pos >= map_pos:
    fail("BAR decode must run before QEMU/VIP tag-map allocation")
if "bridge_vcs_send_cpl_scalar_status_rc(" not in source:
    fail("MRd decode failures do not return status-aware Completion")
if "bridge_vcs_get_tlp_requester_id_rc(" not in source:
    fail("VCS ingress does not validate the QEMU requester ID")
if "m.requester_id = requester_id;" not in source:
    fail("MMIO TLP does not explicitly preserve the validated RC requester")
if "PCIE_BAR_DECODE_OVERLAP" not in source or "uvm_fatal" not in source:
    fail("overlap is not fatal")
if ".bar_id(3'h0), .bar_aperture(6'h0), .target_func(8'h0)" in adapter:
    fail("Xilinx adapter still hard-codes PF0/BAR0")
print("[cq-bar-routing] PASS")
PY
~~~

Register it:

~~~cmake
add_test(NAME test_cq_bar_routing_source
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_cq_bar_routing_source.sh)
set_tests_properties(test_cq_bar_routing_source PROPERTIES TIMEOUT 10)
~~~

- [ ] **Step 2: Run red**

~~~bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
ctest --test-dir build -R test_cq_bar_routing_source --output-on-failure
~~~

Expected: failure because the RC driver has no decoder call.

- [ ] **Step 3: Add per-RC decode state**

Add:

~~~systemverilog
pcie_tl_bar_decoder bar_decoder;
bit config_bar_decode_enable;
longint unsigned bar_decode_error_count[int];
longint unsigned host_requester_error_count;
int dpi_requester_id;
~~~

After build_topology:

~~~systemverilog
bar_decoder = pcie_tl_bar_decoder::type_id::create("bar_decoder");
bar_decoder.func_mgr = func_mgr;
config_bar_decode_enable =
    real_dut ||
    cfg_profile != pcie_tl_device_profile_pkg::PCIE_CFG_PROFILE_LEGACY;
~~~

- [ ] **Step 4: Validate the directional requester role**

Immediately after the existing DPI field getters and before ATS/config bypass,
add:

~~~systemverilog
dpi_requester_id = bridge_vcs_get_tlp_requester_id_rc(rc_index);
if ((dpi_type inside {BV_TLP_CFGRD0, BV_TLP_CFGWR0,
                      BV_TLP_MRD, BV_TLP_MWR, BV_TLP_ATS_INVAL}) &&
    dpi_requester_id != 0) begin
    host_requester_error_count++;
    `uvm_error(get_name(), $sformatf(
        "RC%0d QEMU host request has requester=0x%04h type=0x%02h",
        rc_index, dpi_requester_id[15:0], dpi_type))
    if (dpi_type inside {BV_TLP_CFGRD0, BV_TLP_MRD, BV_TLP_ATS_INVAL})
        void'(bridge_vcs_send_cpl_scalar_status_rc(
            rc_index, dpi_tag, 0, int'(CPL_STATUS_UR)));
    total_tlp_count++;
    #1;
    continue;
end
~~~

This check is deliberately absent from rx_loop and every DMA callback, where
a PF/VF requester ID is correct.

Extend build_mmio_tlp with a `bit [15:0] requester_id` argument and assign it
explicitly in both MRd and MWr construction:

~~~systemverilog
m.requester_id = requester_id;
~~~

Change the call and signature together:

~~~systemverilog
vip_tlp = build_mmio_tlp(
    dpi_type, dpi_addr, dpi_data, dpi_len, dpi_tag,
    dpi_requester_id[15:0], dpi_first_be[3:0], dpi_last_be[3:0]);
~~~

- [ ] **Step 5: Decode pass-through MRd/MWr**

Immediately after build_mmio_tlp succeeds and before request_inst_id creation:

~~~systemverilog
if (config_bar_decode_enable) begin
    pcie_tl_mem_tlp mem_tlp;
    pcie_tl_cq_route_t route;
    pcie_bar_decode_result_e decode_result;
    bit [15:0] target_bdf;
    string decode_reason;

    target_bdf = bridge_vcs_get_tlp_target_bdf_rc(rc_index);
    if (!$cast(mem_tlp, vip_tlp))
        `uvm_fatal(get_name(), "config BAR decode received non-memory TLP")
    decode_result = bar_decoder.decode(
        mem_tlp, target_bdf, route, decode_reason);
    if (decode_result != PCIE_BAR_DECODE_OK) begin
        bar_decode_error_count[int'(decode_result)]++;
        if (decode_result == PCIE_BAR_DECODE_OVERLAP ||
            decode_result == PCIE_BAR_DECODE_INVALID_CONFIG)
            `uvm_fatal(get_name(), decode_reason)
        if (bar_decode_error_count[int'(decode_result)] <= 8 ||
            (bar_decode_error_count[int'(decode_result)] % 1024) == 0)
            `uvm_error(get_name(), $sformatf(
                "RC%0d BAR decode result=%s count=%0d: %s",
                rc_index, decode_result.name(),
                bar_decode_error_count[int'(decode_result)],
                decode_reason))
        if (dpi_type == BV_TLP_MRD)
            void'(bridge_vcs_send_cpl_scalar_status_rc(
                rc_index, dpi_tag, 0, int'(CPL_STATUS_UR)));
        total_tlp_count++;
        continue;
    end
    vip_tlp.cq_route = route;
end
~~~

MWr failure is posted and receives no Completion. Add report_phase output for
each counter.

- [ ] **Step 6: Preserve DUT Completion status**

In forward_completion_to_qemu():

~~~systemverilog
if (bridge_vcs_send_cpl_scalar_status_rc(
        rc_index, qemu_tag, 1, int'(cpl.cpl_status)) != 0)
    `uvm_error(get_name(), $sformatf(
        "RC%0d send_cpl failed qemu_tag=0x%03h status=%s",
        rc_index, qemu_tag, cpl.cpl_status.name()))
~~~

Config-bypass and ATS synthesized successes keep the old SC wrapper.

- [ ] **Step 7: Run contracts and VCS compile**

~~~bash
ctest --test-dir build \
  -R "test_qemu_request_routing_source|test_cq_bar_routing_source|test_cosim_tag_map_order|test_cosim_completion_ownership" \
  --output-on-failure
~~~

On 53:

~~~bash
ssh ubuntu@10.11.10.53 \
  "bash -ic 'cd /home/ubuntu/test_cosim/builds/cq-bar-routing; make cosim-lib; mkdir -p build/cosim-route; vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps +define+PCIE_COSIM_ENABLE -CFLAGS \"-I bridge/common -I bridge/vcs\" -LDFLAGS \"-Wl,--whole-archive \$PWD/build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread\" -f pcie_tl_vip/sim/filelist_cosim.f -o build/cosim-route/simv -l build/cosim-route/compile.log'"
~~~

Expected: no undefined DPI symbol and no VCS compile errors.

- [ ] **Step 8: Commit**

~~~bash
git add vcs-tb/cosim_xrc_driver.sv \
        tests/integration/test_cq_bar_routing_source.sh \
        tests/integration/CMakeLists.txt
git commit -m "fix(cosim): route QEMU MMIO through live BAR decode"
~~~

### Task 7: Run focused and compatibility regressions on 53

**Files:**
- Test only.

- [ ] **Step 1: Synchronize the exact commit**

~~~bash
tar --exclude=.git -cf - . |
  ssh ubuntu@10.11.10.53 \
  "mkdir -p /home/ubuntu/test_cosim/builds/cq-bar-routing && tar -C /home/ubuntu/test_cosim/builds/cq-bar-routing -xf -"
~~~

- [ ] **Step 2: Run focused VIP tests**

Compile filelist_local.f once and run:

~~~text
pcie_tl_route_metadata_test
pcie_tl_bar_state_test
pcie_tl_bar_decoder_test
pcie_tl_dpu_501x_profile_test
pcie_tl_smoke_mem_test
pcie_tl_smoke_cfg_test
~~~

Expected for every log: UVM_ERROR : 0 and UVM_FATAL : 0.

- [ ] **Step 3: Run Xilinx adapter tests**

Run:

~~~text
xilinx_pcie_adapter_codec_test
xilinx_pcie_adapter_smoke_test
xilinx_pcie_adapter_rdwr_test
xilinx_pcie_adapter_backpressure_test
~~~

Compile the 512-bit non-straddled and 256-bit straddled variants directly in
the same remote directory, using the interactive shell so ~/.bashrc exports
the VCS license and tool paths:

~~~bash
ssh ubuntu@10.11.10.53 \
  "bash -ic 'cd /home/ubuntu/test_cosim/builds/cq-bar-routing; vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f third_party/xilinx_pcie/sim/filelist_adapter_local.f +define+DATA_WIDTH=512 +define+STRADDLE_EN=0 -o build/xilinx-route/simv_dw512 -l build/xilinx-route/compile_dw512.log'"
ssh ubuntu@10.11.10.53 \
  "bash -ic 'cd /home/ubuntu/test_cosim/builds/cq-bar-routing; vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps -f third_party/xilinx_pcie/sim/filelist_adapter_local.f +define+DATA_WIDTH=256 +define+STRADDLE_EN=1 -o build/xilinx-route/simv_straddle -l build/xilinx-route/compile_straddle.log'"
~~~

Expected: exact CQ sideband checks and all functional matrices pass.

- [ ] **Step 4: Run bridge/source tests**

~~~bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
~~~

- [ ] **Step 5: Compile the QEMU device**

~~~bash
make qemu-device \
  QEMU_SRC_DIR=/home/ubuntu/test_cosim/builds/qemu-vcs-offline-icount-nodriver-20260805/import-check/third_party/qemu
~~~

Expected: qemu-system-x86_64 links and cosim_pcie_rc.o is rebuilt.

- [ ] **Step 6: Inspect logs and diff**

~~~bash
git diff --check
git status --short
git log --oneline 4caaf91..HEAD
~~~

No simv, csrc, logs, build output, images, or unrelated files may be staged.

### Task 8: Run QEMU/VCS topology smoke and mailbox route proof

**Files:**
- Test only.

- [ ] **Step 1: Start QEMU**

~~~bash
make run-qemu NUM_PFS=4 TAG_BIT=8 QEMU_TIME_MODE=icount \
  CONSOLE=file PORT_BASE=28100 PCIE_PREF64_RESERVE=256M
~~~

- [ ] **Step 2: Start VCS on 53**

~~~bash
/home/ubuntu/test_cosim/builds/cq-bar-routing/build/cosim-route/simv \
  +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART \
  +REAL_DUT +BYPASS_CONFIG=1 +CFG_PROFILE=DPU_20F9_501X \
  +NUM_PFS=4 +MAX_VFS=16 +NUM_VFS=0 +TAG_BIT=8 +TOPO=0 \
  +REMOTE_HOST=10.11.10.59 +PORT_BASE=28100 \
  +UVM_VERBOSITY=UVM_MEDIUM \
  -l /home/ubuntu/test_cosim/builds/cq-bar-routing/build/cosim-route/run.log
~~~

10.11.10.59 is the QEMU execution host recorded for this plan; re-check its
address with hostname -I immediately before starting if the host network was
reconfigured.

- [ ] **Step 3: Verify PF/VF enumeration**

Inside the guest:

~~~bash
lspci -Dnn | grep '^0000:01:'
for pf in 0 1 2 3; do
  echo 16 | sudo tee /sys/bus/pci/devices/0000:01:00.$pf/sriov_numvfs
done
lspci -Dnn | grep '20f9:8689' | wc -l
~~~

Expected: PF IDs 5011-5014 and 64 VFs with ID 8689.

- [ ] **Step 4: Prove mailbox sideband**

Use the driver or pci-debug to write one to PF0 BAR2+0x2c and poll it. Require:

~~~text
requester_id=0x0000
target_bdf=0x0100
bar_id=2
bar_aperture=4
target_func=0
bar_offset=0x2c
~~~

Repeat on PF1-PF3; target_bdf/target_func must be 0x0101/1 through 0x0103/3,
while requester_id remains zero. The target must match the guest `lspci` BDF
observed in the same run. No no-qemu-tag warning or overlap fatal is allowed.

- [ ] **Step 5: Re-run data-plane coverage**

Run TAG_BIT=8 and 10 random DMA, odd lengths, all first/last-BE combinations,
MPS long packets, and RCB splits.

Expected:

~~~text
BE_MATRIX PASS cases=240
UVM_ERROR : 0
UVM_FATAL : 0
qemu_data_faults=0
~~~

### Task 9: Final synchronization and commits

**Files:**
- QEMU_VCS files from Tasks 1-6.
- Matching pcie_tl_vip and xilinx_pcie files in pcie_work.

- [ ] **Step 1: Review QEMU_VCS scope**

~~~bash
git status --short
git diff 4caaf91..HEAD --stat
git diff 4caaf91..HEAD --check
~~~

- [ ] **Step 2: Synchronize shared sources to pcie_work**

Use apply_patch in the pcie_work checkout for:

~~~text
pcie_tl_vip/src/types/pcie_tl_types.sv
pcie_tl_vip/src/types/pcie_tl_tlp.sv
pcie_tl_vip/src/shared/pcie_tl_func_manager.sv
pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv
pcie_tl_vip/src/shared/pcie_tl_bar_decoder.sv
pcie_tl_vip/src/pcie_tl_pkg.sv
pcie_tl_vip/tests/pcie_tl_route_metadata_test.sv
pcie_tl_vip/tests/pcie_tl_bar_state_test.sv
pcie_tl_vip/tests/pcie_tl_bar_decoder_test.sv
xilinx_pcie/src/adapter/xilinx_pcie_if_adapter.sv
xilinx_pcie/tests/xilinx_pcie_adapter_codec_test.sv
~~~

Do not copy bridge, QEMU, setup, offline-package, or generated artifacts into
pcie_work.

- [ ] **Step 3: Re-run pcie_work VCS tests on 53**

Compile and run the focused VIP and Xilinx codec/smoke tests from pcie_work.
Expected: byte-equivalent routing and zero UVM errors/fatals.

- [ ] **Step 4: Commit pcie_work separately**

~~~bash
git add pcie_tl_vip xilinx_pcie
git commit -m "fix(vip): decode and encode live PF VF BAR routes"
~~~

- [ ] **Step 5: Report, then push only with user authorization**

Report both commit IDs, the exact 53 log directory, PF/VF counts, mailbox
sideband, and regression summaries. Never store a GitHub token in a remote
URL, credential helper, script, or proxy setting.
