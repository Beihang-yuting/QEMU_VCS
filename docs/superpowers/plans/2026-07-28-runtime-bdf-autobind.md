# Runtime BDF Auto-Bind Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep configuration bypass and per-function QEMU proxies, while making the VCS configuration model learn the firmware-assigned PF BDF before answering the first Vendor ID read.

**Architecture:** QEMU places the cosim endpoint behind a fixed q35 PCIe Root Port and creates all PF proxy functions before firmware enumeration. The first PF0 configuration read already carries the runtime `target_bdf`; the VCS config proxy atomically rekeys every PF/VF context from its bootstrap BDF to that observed base before lookup, then continues answering configuration requests locally while real-DUT MMIO/DMA/interrupt traffic remains on the DUT path.

**Tech Stack:** QEMU 9.2 PCI device model, SystemVerilog/UVM 1.2, VCS DPI-C/TCP bridge, GNU Make, Icarus Verilog smoke tests, Linux PCI enumeration.

---

### Task 1: Add red tests for BDF arithmetic and launch topology

**Files:**
- Create: `tests/sv/test_runtime_bdf_utils.sv`
- Create: `tests/integration/test_pcie_launch_topology.sh`

- [ ] **Step 1: Write a standalone SV test that imports `pcie_tl_bdf_utils_pkg` and asserts:** observed `02:00.0` maps PF0..PF3 to `0x0200..0x0203`; VF0/VF1 for PF0 with offset/stride four map to `0x0204/0x0208`; observed `00:03.0` maps to PF base `0x0018`.
- [ ] **Step 2: Run `iverilog -g2012 -s test_runtime_bdf_utils -o /tmp/test_runtime_bdf_utils tests/sv/test_runtime_bdf_utils.sv` and verify RED because `pcie_tl_bdf_utils_pkg.sv` does not exist.
- [ ] **Step 3: Write a launch-source regression that checks every `cosim-pcie-rc` QEMU launch is attached to `bus=cosim_rp`, contains `num_pfs=$(NUM_PFS)`, and has a preceding fixed `pcie-root-port` declaration.
- [ ] **Step 4: Run `bash tests/integration/test_pcie_launch_topology.sh` and verify RED against the current direct-root-bus Makefile.

### Task 2: Add pure BDF helpers and runtime rebind

**Files:**
- Create: `pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv`
- Modify: `pcie_tl_vip/src/shared/pcie_tl_func_manager.sv`
- Modify: `pcie_tl_vip/src/shared/pcie_tl_config_proxy.sv`

- [ ] **Step 1: Implement pure helpers:**

```systemverilog
function automatic bit [15:0] pcie_pf_base_bdf(bit [15:0] observed_pf0_bdf);
    return observed_pf0_bdf & 16'hFFF8;
endfunction

function automatic bit [15:0] pcie_pf_bdf(bit [15:0] base_bdf, int pf_index);
    return base_bdf + pf_index;
endfunction

function automatic bit [15:0] pcie_vf_bdf(bit [15:0] pf_bdf,
                                           int first_vf_offset,
                                           int vf_stride,
                                           int vf_index);
    return pf_bdf + first_vf_offset + vf_index * vf_stride;
endfunction
```

- [ ] **Step 2: Run `iverilog -g2012 -s test_runtime_bdf_utils -o /tmp/test_runtime_bdf_utils pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv tests/sv/test_runtime_bdf_utils.sv && vvp /tmp/test_runtime_bdf_utils` and verify GREEN.**
- [ ] **Step 3: Add `runtime_bdf_bound` and `bind_runtime_pf_base(observed_pf0_bdf)` to `pcie_tl_func_manager`. The method deletes old PF and enabled-VF LUT keys, updates `pf_base_bus/dev`, every PF context, every SR-IOV `pf_bdf`, every VF context RID, and reinserts active keys.**
- [ ] **Step 4: In `handle_cfg_read_bdf`, invoke the bind only when bypass is active, no runtime bind exists, `dw_addr == 0`, and the observed function is PF0. Perform it before `lookup_by_bdf` so the first Vendor ID read succeeds.**
- [ ] **Step 5: Add a concise `FUNC_MGR` log showing old and new PF bases and PF count.**

### Task 3: Synchronize the missing upstream VIP sequence

**Files:**
- Create: `pcie_tl_vip/src/seq/base/pcie_tl_rw_seq.sv`
- Modify: `pcie_tl_vip/src/pcie_tl_pkg.sv`
- Modify: `pcie_tl_vip/src/types/pcie_tl_tlp.sv`

- [ ] **Step 1: Copy `pcie_tl_rw_seq.sv` exactly from `Beihang-yuting/pcie_work` main commit `6913793`.**
- [ ] **Step 2: Include it after `pcie_tl_mem_wr_seq.sv`, matching the reference package order.**
- [ ] **Step 3: Sync the reference read-back fields and registry from `pcie_tl_tlp.sv`, which are compile-time dependencies of `pcie_tl_rw_seq`.**
- [ ] **Step 4: Compare the sequence and TLP dependency changes against the GitHub API content with `diff`; separately verify the package include order.**

### Task 4: Make REAL_DUT plusarg precedence explicit

**Files:**
- Modify: `vcs-tb/cosim_xrc_driver.sv`
- Test: `tests/integration/test_pcie_launch_topology.sh`

- [ ] **Step 1: Parse `+BYPASS_CONFIG=<0|1>` in the parent driver when it creates the proxy. If explicitly present, it overrides the `REAL_DUT` default; otherwise retain the current stand-in default-on and real-DUT default-off behavior.
- [ ] **Step 2: Log the effective mode as one of `REAL_DUT + VIP_CONFIG_BYPASS`, `REAL_DUT_CONFIG_PASSTHRU`, or `STAND_IN`.**
- [ ] **Step 3: Add a source regression requiring the explicit override branch and run it GREEN.**

### Task 5: Put the endpoint behind a fixed Root Port

**Files:**
- Modify: `Makefile`
- Test: `tests/integration/test_pcie_launch_topology.sh`

- [ ] **Step 1: Add `NUM_PFS ?= 1` to runtime variables.**
- [ ] **Step 2: In login, login-multi, and file modes add:

```make
-device pcie-root-port,id=cosim_rp...,bus=pcie.0,addr=0x3,slot=3,chassis=1
-device cosim-pcie-rc,bus=cosim_rp,addr=0x0,num_pfs=$(NUM_PFS),...
```

Use instance-qualified IDs in multi-QEMU loops to avoid object-name collisions.
- [ ] **Step 3: Document `NUM_PFS` in `make help` and include it in the connection descriptor.
- [ ] **Step 4: Run the launch topology regression GREEN.**

### Task 6: Local verification

**Files:**
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Register the shell launch regression when CMake is available.
- [ ] **Step 2: Run the standalone Icarus BDF test.
- [ ] **Step 3: Run the shell launch regression.
- [ ] **Step 4: Run whitespace checks and inspect the complete Git diff.
- [ ] **Step 5: If CMake becomes available, build and run the full CTest suite; otherwise record the missing tool and rely on the remote build gate.**

### Task 7: Remote VCS/QEMU/real-DUT verification

**Files:**
- Deploy only the changed files into `/home/ubuntu/test_cosim/QEMU_VCS-feature-qemu-vcs-isolated-tcp` after making a timestamped backup.

- [ ] **Step 1: Capture remote process state, tool versions, current file hashes, and the existing VCS/QEMU launch commands.**
- [ ] **Step 2: Stage changed files, verify their hashes, then rebuild the bridge, QEMU device, and VCS simulation. Use the upstream `pcie_tl_rw_seq` sync to remove the prior undefined-class blocker.
- [ ] **Step 3: Start QEMU with one fixed Root Port and matching `num_pfs`; start VCS with `+REAL_DUT +COSIM_AUTOSTART +BYPASS_CONFIG=1` plus the DUT PF/VF identity parameters.
- [ ] **Step 4: Require logs proving `Config Proxy: bypass=1`, runtime BDF bind before the first successful Vendor ID completion, no Config TLP enters the DUT request path, and MMIO still enters the DUT path.
- [ ] **Step 5: In the guest require `lspci`/`dmesg` to show every configured PF behind the Root Port with valid BAR resources. Exercise one safe BAR access if the existing real-DUT test provides a non-destructive register.
- [ ] **Step 6: Stop all test processes and report exact commands, logs, observed BDFs, and any remaining DUT-specific capability mismatch.

---

## Self-review

- Spec coverage: Root Port, QEMU PF creation, automatic runtime BDF binding, REAL_DUT/config-bypass precedence, latest VIP compile blocker, and remote real-DUT verification are all assigned concrete tasks.
- Placeholder scan: no implementation step is deferred; DUT-specific numeric IDs remain runtime inputs rather than code placeholders.
- Type consistency: helpers and manager state use 16-bit PCI Routing IDs; QEMU/VCS continue carrying them through existing `target_bdf` fields.
