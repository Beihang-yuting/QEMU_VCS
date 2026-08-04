# DPU PF1 Disable and VNET Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a DPU driver that binds PF0 (`20f9:5011`) only and reads the VNET queue count once per module lifetime.

**Architecture:** Keep the PCI driver's existing registration path unchanged, but remove the PF1 (`20f9:5012`) PCI ID from its match table. Change `dpu_get_vnet_num()` to cache its first register read in the requested function-local static `u16`; the single supported PF makes the cache intentionally module-wide.

**Tech Stack:** Linux PCI kernel module C, Ubuntu `6.8.0-107-generic` kernel headers, 53 build host.

---

### Task 1: Define and prove the requested source contract

**Files:**

- Source: `/home/ubuntu/test_cosim/releases/dpu-qid128-20260731/source/host-driver-net/main.c:893-904`
- Source: `/home/ubuntu/test_cosim/releases/dpu-qid128-20260731/source/host-driver-net/common.h:1068-1077`

- [ ] **Step 1: Run a source-contract check before modification**

Run:

```bash
src=/home/ubuntu/test_cosim/releases/dpu-qid128-20260731/source/host-driver-net
! grep -q 'DPU_DEVICE_ID_PF1' "$src/main.c"
grep -A9 'static inline u16 dpu_get_vnet_num' "$src/common.h" | grep -q 'static u16 queue_num = 0;'
```

Expected: FAIL, because the original table matches PF1 and the original helper has a non-static local cache variable.

- [ ] **Step 2: Apply the minimal source changes**

`main.c` must retain only the PF0 entry in `dpu_id_table`:

```c
static const struct pci_device_id dpu_id_table[] = {
	{ PCI_DEVICE(DPU_VENDOR_ID, DPU_DEVICE_ID_PF) },
	/* required as sentinel */
	{
		0,
	}
};
```

`common.h` must use the requested first-read cache:

```c
static inline u16 dpu_get_vnet_num(struct dpu_hw *hw)
{
	struct greg_vnet_spec vnet_spec = {0};
	static u16 queue_num = 0;

	if (!queue_num) {
		*(u32 *)&vnet_spec = rd32(hw, GREG_INFO_VNET_SPEC_REG);
		queue_num = vnet_spec.vnet_que_num;
	}

	return queue_num;
}
```

- [ ] **Step 3: Re-run the source-contract check**

Run:

```bash
src=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net
! grep -q 'DPU_DEVICE_ID_PF1' "$src/main.c"
grep -A10 'static inline u16 dpu_get_vnet_num' "$src/common.h" | grep -q 'static u16 queue_num = 0;'
grep -A10 'static inline u16 dpu_get_vnet_num' "$src/common.h" | grep -q 'if (!queue_num)'
```

Expected: PASS.

### Task 2: Build and validate the importable module on 53

**Files:**

- Input: modified `host-driver-net` source tree
- Output: `dpu_snd1.ko` in a new date-stamped release directory on 53

- [ ] **Step 1: Compile against the installed 6.8.0-107 headers**

Run the existing DPU build script with the modified source archive and its project-local temporary build directory. Do not use `/tmp` for driver build output:

```bash
project=/home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804
TMPDIR="$project/build/tmp" "$project/scripts/build_dpu_driver_bundle.sh" \
  --archive "$release/source/host-driver-net-pf0only-vnetcache.tar.gz" \
  --kernel-build "$project/build/kheaders-6.8.0-107-generic/usr/src/linux-headers-6.8.0-107-generic" \
  --compat-runtime-deb "$project/build/compat-runtime/libc6_2.39-0ubuntu8_amd64.deb" \
  --use-system-bonding \
  --output "$release/bundle"
```

- [ ] **Step 2: Validate binding and kernel compatibility metadata**

Run:

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804
modinfo -F vermagic "$release/bundle/dpu_snd1.ko"
modinfo -F alias "$release/bundle/dpu_snd1.ko" | grep -q 'v000020F9d00005011'
! modinfo -F alias "$release/bundle/dpu_snd1.ko" | grep -q 'v000020F9d00005012'
```

Expected: `vermagic` contains `6.8.0-107-generic`; PF0 alias exists; PF1 alias does not exist.

- [ ] **Step 3: Produce a source archive and module manifest**

Create a date-stamped source archive, `dpu_snd1.ko`, and SHA-256 manifest in the new 53 release directory so the module can be imported without overwriting the earlier QID128 release.
