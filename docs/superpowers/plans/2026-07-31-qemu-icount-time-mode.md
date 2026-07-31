# QEMU iCount Time Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `QEMU_TIME_MODE=icount` launch mode while preserving the existing realtime QEMU command line by default.

**Architecture:** The Makefile validates a two-value mode and derives one shared argument variable.  All three `run-qemu` launch variants consume that variable, so topology and console choice cannot silently omit iCount.  Integration tests inspect dry-run Make output rather than booting QEMU.

**Tech Stack:** GNU Make, Bash, QEMU 9.2 TCG iCount, existing integration-test shell scripts.

---

### Task 1: Add a failing launch-mode regression test

**Files:**
- Create: `tests/integration/test_qemu_time_mode.sh`
- Read: `Makefile:20-230`

- [x] **Step 1: Write the test for the desired interface**

```bash
#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
make_cmd=(make -s -n -C "$repo" run-qemu QEMU=/bin/true KERNEL=/bin/true ROOTFS=/bin/true)

for console in login login-multi file; do
    realtime="$("${make_cmd[@]}" CONSOLE="$console" QEMU_TIME_MODE=realtime)"
    ! grep -Fq -- '-icount ' <<<"$realtime"

    icount="$("${make_cmd[@]}" CONSOLE="$console" QEMU_TIME_MODE=icount)"
    grep -Fq -- '-accel tcg' <<<"$icount"
    grep -Fq -- '-icount shift=auto,align=off,sleep=off' <<<"$icount"
done

make -s -C "$repo" validate-qemu-time-mode QEMU_TIME_MODE=realtime
make -s -C "$repo" validate-qemu-time-mode QEMU_TIME_MODE=icount
if make -s -C "$repo" validate-qemu-time-mode QEMU_TIME_MODE=invalid; then
    exit 1
fi
```

- [x] **Step 2: Run the test and confirm it fails because the mode is absent**

Run: `bash tests/integration/test_qemu_time_mode.sh`

Expected: failure because `validate-qemu-time-mode` does not exist and the iCount arguments are absent.

### Task 2: Derive and validate QEMU time arguments

**Files:**
- Modify: `Makefile:54-60`
- Modify: `Makefile:122-130`
- Modify: `Makefile:147-155`
- Modify: `Makefile:162-172`
- Modify: `Makefile:197-204`
- Modify: `Makefile:296-305`

- [x] **Step 1: Add an opt-in mode and validation target**

Add `QEMU_TIME_MODE ?= realtime`.  Derive an empty `QEMU_TIME_ARGS` for
`realtime` and the exact string `-accel tcg -icount shift=auto,align=off,sleep=off`
for `icount`.  Add `validate-qemu-time-mode`, accepting only those two values,
and add it as a prerequisite of `run-qemu`.

- [x] **Step 2: Append the shared argument variable to every QEMU launch**

Place `$(QEMU_TIME_ARGS)` immediately before `-M q35` in the `login`,
`login-multi`, and `file` launch commands.  Do not change device properties,
`MMIO_TIMEOUT_MS`, console wiring, image paths, or TCP port behavior.

- [x] **Step 3: Document the new make parameter in `make help`**

Add a help line that states the default realtime behavior and the iCount TCG
arguments used when `QEMU_TIME_MODE=icount`.

- [x] **Step 4: Run the new test and the existing PCIe launch-topology smoke test**

Run:

```bash
bash tests/integration/test_qemu_time_mode.sh
bash tests/integration/test_pcie_launch_topology.sh
```

Expected: both exit zero. The baseline's separate `test_launch_smoke.sh` is
currently stale: it invokes `scripts/launch_dual.py`, deleted by baseline
commit `cb45e4b`.

### Task 3: Verify QEMU and real-driver co-simulation on 53

**Files:**
- Read: `scripts/inject_driver_bundle.sh`
- Read: `Makefile`
- Read: `/home/ubuntu/test_cosim/releases/dpu-qid128-20260731/bundle/`

- [x] **Step 1: Copy only required project changes to an isolated 53 test checkout and reuse QEMU**

Use the 53 QEMU/VCS host and its login shell.  Do not change its shared project
checkout or original Guest images. No QEMU model source changes are needed for
this Makefile-only option, so reuse the existing QEMU 9.2 binary.

- [x] **Step 2: Verify QEMU option parsing**

Run the QEMU 9.2 binary with `-machine none -display none -nodefaults -accel tcg
-icount shift=auto,align=off,sleep=off -S`; a timeout signal after successful
startup is acceptable, but an iCount option error is not.

- [x] **Step 3: Inject the existing fixed-QID bundle into a test-image copy and load it through the external VCS flow**

Keep the VCS response configuration identical for realtime and iCount runs.
Record driver `dmesg`, QEMU errors, and VCS request/Completion logs.  The
iCount run passes when the driver proceeds without a guest-time timeout while
the VCS Completion is received within `MMIO_TIMEOUT_MS`.

## 53 validation result

The isolated test directory is
`/home/ubuntu/test_cosim/qemu-icount-validate-20260731`. QEMU accepted the
iCount command line, the VCS bridge completed its three-channel handshake, and
the guest enumerated `20f9:5011` through `20f9:5014`. The fixed-QID module
loaded from the copied image. Its current probe then stopped with
`AF has not been declared` / `-22`; this is a driver configuration error after
enumeration, not a guest-time or VCS-completion timeout. The run therefore
validates iCount launch, config-bypass discovery, and module loading, but does
not claim a fully initialized DPU dataplane.
