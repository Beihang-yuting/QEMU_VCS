# x86 DPU Driver CoSim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild and inject the supplied DPU driver for the x86 Guest and
make VCS/QEMU startup automatic only when requested.

**Architecture:** A dedicated builder creates a validated two-module DPU
bundle; a bundle injector writes its explicit load order into the existing
Guest image formats. `setup.sh` dispatches archive input while retaining its
single-module path. VCS receives only an opt-in auto-start plusarg and a
resolved-profile log.

**Tech Stack:** Bash, Linux kbuild, ext4 `debugfs`, SystemVerilog/UVM, VCS,
QEMU.

---

### Task 1: Test and implement archive validation

**Files:** `tests/integration/test_dpu_driver_bundle.sh`,
`scripts/build_dpu_driver_bundle.sh`

- [ ] Write a regression that creates safe and traversal fixture archives and
  requires `--validate-only` to accept only the safe input.
- [ ] Run it red because the builder is absent.
- [ ] Implement validation: reject absolute/parent paths and require one
  `host-driver-net/` root.
- [ ] Run the regression green.

### Task 2: Build an exact x86 two-module bundle

**Files:** `scripts/build_dpu_driver_bundle.sh`

- [ ] Add `--archive`, `--kernel-build`, and `--output` arguments.
- [ ] Extract into `mktemp -d`, run `make KERNELDIR=<headers> clean modules`,
  then copy only `dpu_snd1.ko` and `bonding/bonding.ko` to output.
- [ ] Reject non-x86-64 modules and vermagic values that do not match
  `include/generated/utsrelease.h`.
- [ ] Run the real supplied archive against the exact Guest headers.

### Task 3: Inject and load an ordered custom bundle

**Files:** `scripts/inject_driver_bundle.sh`,
`guest/overlay/etc/local.d/cosim-driver.start`, `guest/cosim-init`

- [ ] Write a disposable-ext4 regression that checks both modules and
  `mode=custom`, `ko_deps=bonding.ko`, and `ko_name=dpu_snd1.ko` through
  `debugfs`.
- [ ] Implement rootfs/initramfs injection under
  `/lib/modules/cosim-drivers/dpu_snd1/`.
- [ ] Extend only the custom startup branch to load dependencies then primary
  module by full path; preserve the stub branch.
- [ ] Run the injector regression green.

### Task 4: Dispatch archive input from setup

**Files:** `setup.sh`, `tests/integration/test_dpu_driver_bundle.sh`

- [ ] Add red assertions for `.tar.gz` dispatch to builder then injector, and
  retain `build_cosim_nic.sh --inject-only` for a single `.ko`.
- [ ] Implement archive dispatch, respecting `CUSTOM_DRIVER_KDIR`.
- [ ] Run custom-driver and existing setup option checks.

### Task 5: Make VCS startup explicit and observable

**Files:** `vcs-tb/cosim_xrc_driver.sv`,
`tests/integration/test_pcie_launch_topology.sh`

- [ ] Add red policy assertions for `+AUTO_START_COSIM`, RC0-only
  `notify_start(-1)`, and resolved PF0 profile logging.
- [ ] Schedule the auto-start from RC0 after a short delay; retain the default
  UCLI wait when the plusarg is absent.
- [ ] Log profile, PF count, and PF0 identity after `build_topology`.
- [ ] Run policy checks and compile the VCS enumerator.

### Task 6: Prove the integrated path

- [ ] Build the real bundle and inject it into a disposable Ubuntu rootfs.
- [ ] Start QEMU and VCS with DPU profile, bypass config, and auto-start.
- [ ] Capture Guest `lspci`, module-load output, and `dmesg`; pass only with
  `[20f9:5011]`, an established TCP session, and no module ABI error.
- [ ] Run `git diff --check` and relevant profile/launch regressions.
