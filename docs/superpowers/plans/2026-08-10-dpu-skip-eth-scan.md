# DPU periodic ETH scan bypass implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and validate a PF0-only 128-QID DPU driver whose opt-in `skip_eth_scan=1` mode stops periodic ETH status MMIO while presenting both ETH ports as Link Up.

**Architecture:** A read-only module parameter selects between the existing hardware-derived ETH service path and a new read-free helper. The helper reuses the driver's existing carrier/VLAN action layer, so its first execution initializes both ports and later executions are idempotent. QEMU/VCS transport, configuration bypass, and the service timer remain unchanged.

**Tech Stack:** Linux kernel module C/Kbuild, Bash source-contract tests, Ubuntu `6.8.0-107-generic` headers, QEMU 9.2, PCIe TL UVM/VCS, SSH/SCP, SHA-256.

---

## File map

- Create `tests/integration/test_dpu_skip_eth_scan_source.sh`: reusable contract test for an external `host-driver-net` tree.
- Modify external driver `main.c`: add the module parameter and select the periodic ETH path.
- Modify external driver `af_mng.h`: expose the forced-Link-Up helper.
- Modify external driver `af_mng.c`: implement locked, read-free, idempotent Link Up.
- Create remote release `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/`: clean source, source archive, module bundle, logs, and checksums.
- Do not modify QEMU, bridge, PCIe VIP, Xilinx adapter, setup, or offline-import runtime code.

### Task 1: Add the external-driver source contract

**Files:**

- Create: `tests/integration/test_dpu_skip_eth_scan_source.sh`
- Test input: `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net`

- [x] **Step 1: Add the focused contract test**

Create the executable script below:

```bash
#!/usr/bin/env bash
set -euo pipefail

src=${1:-}
if [ -z "$src" ] || [ ! -d "$src" ]; then
    echo "Usage: $0 DRIVER_SOURCE_DIR" >&2
    exit 2
fi

main="$src/main.c"
af_c="$src/af_mng.c"
af_h="$src/af_mng.h"
common="$src/common.h"
for file in "$main" "$af_c" "$af_h" "$common"; do
    [ -f "$file" ] || {
        echo "FAIL: missing driver source file: $file" >&2
        exit 1
    }
done

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local signature=$1
    local file=$2
    sed -n "/$signature/,/^}/p" "$file"
}

grep -Eq '^static bool skip_eth_scan;$' "$main" || \
    fail 'skip_eth_scan must be a default-false static bool'
grep -Fq 'module_param(skip_eth_scan, bool, 0444);' "$main" || \
    fail 'skip_eth_scan must be a read-only bool module parameter'
grep -Fq 'MODULE_PARM_DESC(skip_eth_scan,' "$main" || \
    fail 'skip_eth_scan parameter description is missing'

task1=$(extract_function 'static void dpu_service_task1(' "$main")
grep -Fq 'dpu_purge_mailbox_event(adapter);' <<<"$task1" || \
    fail 'service task1 lost mailbox purge'
grep -Fq 'if (!skip_eth_scan)' <<<"$task1" || \
    fail 'service task1 does not gate the optical scan'
grep -Fq 'dpu_optical_link_subtask(adapter);' <<<"$task1" || \
    fail 'service task1 lost the default optical scan'

task2=$(extract_function 'static void dpu_service_task2(' "$main")
grep -Fq 'dpu_notify_backend_virtqueue_subtask(adapter);' <<<"$task2" || \
    fail 'service task2 lost virtqueue notification'
grep -Fq 'dpu_reset_subtask(adapter);' <<<"$task2" || \
    fail 'service task2 lost reset handling'
grep -Fq 'if (skip_eth_scan)' <<<"$task2" || \
    fail 'service task2 does not select bypass mode'
grep -Fq 'dpu_force_eth_link_up_subtask(&adapter->hw);' <<<"$task2" || \
    fail 'service task2 does not invoke forced Link Up'
grep -Fq 'dpu_process_eth_status_subtask(&adapter->hw);' <<<"$task2" || \
    fail 'service task2 lost the default status path'

grep -Fq 'void dpu_force_eth_link_up_subtask(struct dpu_hw *hw);' "$af_h" || \
    fail 'forced Link Up declaration is missing'
force_body=$(extract_function 'void dpu_force_eth_link_up_subtask(' "$af_c")
[ -n "$force_body" ] || fail 'forced Link Up implementation is missing'
grep -Fq 'spin_lock_irqsave(&adapter->eth_status_lock, flags);' <<<"$force_body" || \
    fail 'forced Link Up does not use the ETH status lock'
grep -Fq 'DPU_ADD_ETH_2_BC' <<<"$force_body" || \
    fail 'forced Link Up does not add offline ports'
grep -Fq 'DPU_ETH_ACTION_BUILD' <<<"$force_body" || \
    fail 'forced Link Up does not make online ports idempotent'
grep -Fq 'dpu_cfg_eth_2_bc(hw, &action_mng);' <<<"$force_body" || \
    fail 'AF carrier/VLAN action path is not reused'
grep -Fq 'dpu_cfg_host_eth_stats(hw, &action_mng);' <<<"$force_body" || \
    fail 'host ETH carrier action path is not reused'
if grep -Fq 'rd32(' <<<"$force_body"; then
    fail 'forced Link Up must not read DUT registers'
fi

grep -Fq '#define DPU_QID_MAP_TABLE_ENTRIES(hw) (128)' "$common" || \
    fail '128-QID baseline was not preserved'
grep -A10 'static inline u16 dpu_get_vnet_num' "$common" | \
    grep -Fq 'static u16 queue_num = 0;' || \
    fail 'VNET queue-count cache was not preserved'
if grep -Fq 'DPU_DEVICE_ID_PF1' "$main"; then
    fail 'PF1 binding must remain disabled'
fi

echo 'PASS: DPU skip_eth_scan source contract'
```

- [x] **Step 2: Validate the test syntax and make it executable**

Run:

```bash
chmod +x tests/integration/test_dpu_skip_eth_scan_source.sh
bash -n tests/integration/test_dpu_skip_eth_scan_source.sh
```

Expected: both commands exit zero.

- [x] **Step 3: Run RED against the 2026-08-04 baseline on 53**

Copy the test to the established 53 driver-build worktree, then run:

```bash
sshpass -p '123' scp \
  tests/integration/test_dpu_skip_eth_scan_source.sh \
  ubuntu@10.11.10.53:/home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver/tests/integration/
sshpass -p '123' ssh ubuntu@10.11.10.53 \
  'chmod +x /home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver/tests/integration/test_dpu_skip_eth_scan_source.sh'
sshpass -p '123' ssh ubuntu@10.11.10.53 \
  '/home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver/tests/integration/test_dpu_skip_eth_scan_source.sh \
   /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net'
```

Expected: nonzero exit with:

```text
FAIL: skip_eth_scan must be a default-false static bool
```

- [x] **Step 4: Commit the RED contract**

```bash
git add tests/integration/test_dpu_skip_eth_scan_source.sh
git commit -m "test(driver): define periodic ETH scan bypass contract"
```

### Task 2: Create the new source release and implement bypass mode

**Files:**

- Baseline: `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net`
- Create: `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net`
- Modify: new release `source/host-driver-net/main.c`
- Modify: new release `source/host-driver-net/af_mng.h`
- Modify: new release `source/host-driver-net/af_mng.c`

- [x] **Step 1: Create a clean source copy without touching the old release**

On 53, first require that the destination does not exist, then copy source-only
content:

```bash
baseline=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
test ! -e "$release"
mkdir -p "$release/source/host-driver-net" "$release/logs"
sha256sum \
  "$baseline/../../SHA256SUMS" \
  "$baseline/../host-driver-net-pf0only-vnetcache.tar.gz" \
  "$baseline/../../bundle/dpu_snd1.ko" \
  > "$release/logs/old-release-before.sha256"
rsync -a \
  --exclude='.git/' --exclude='*.o' --exclude='*.ko' --exclude='*.cmd' \
  --exclude='*.mod' --exclude='*.mod.c' --exclude='Module.symvers' \
  --exclude='modules.order' --exclude='*.bak' \
  "$baseline/" "$release/source/host-driver-net/"
```

Expected: the new source has `Makefile`, `main.c`, `af_mng.c`, `af_mng.h`, and
`common.h`, contains no `.git`, `.o`, or `.ko`, and the old release timestamps
and hashes remain unchanged.

- [x] **Step 2: Add the module parameter and task selection in `main.c`**

Add this beside the existing module parameters:

```c
static bool skip_eth_scan;
module_param(skip_eth_scan, bool, 0444);
MODULE_PARM_DESC(skip_eth_scan,
		 "Skip periodic ETH hardware scans and force ETH links up");
```

Change task 1 to:

```c
static void dpu_service_task1(struct work_struct *work)
{
	struct dpu_adapter *adapter =
		container_of(work, struct dpu_adapter, serv_task1);

	dpu_purge_mailbox_event(adapter);

	if (!skip_eth_scan)
		dpu_optical_link_subtask(adapter);
}
```

Change only the final ETH selection in task 2:

```c
	if (skip_eth_scan)
		dpu_force_eth_link_up_subtask(&adapter->hw);
	else
		dpu_process_eth_status_subtask(&adapter->hw);
```

Keep `dpu_notify_backend_virtqueue_subtask()` and `dpu_reset_subtask()` before
that selection.

- [x] **Step 3: Declare the helper in `af_mng.h`**

Place the declaration next to `dpu_process_eth_status_subtask()`:

```c
void dpu_process_eth_status_subtask(struct dpu_hw *hw);
void dpu_force_eth_link_up_subtask(struct dpu_hw *hw);
```

- [x] **Step 4: Implement the helper in `af_mng.c`**

Place this immediately after `dpu_process_eth_status_subtask()` so it can reuse
the two file-local config helpers:

```c
void dpu_force_eth_link_up_subtask(struct dpu_hw *hw)
{
	struct dpu_eth_action_mng action_mng = {0};
	struct dpu_adapter *adapter = hw->adapter;
	unsigned long flags;
	int port_index;
	int eth_num;

	if (is_af(hw))
		eth_num = hw->af_res->spec_info.dpu_max_eth_num;
	else if (adapter->host_id == 1 && adapter->pfvf_id == 0)
		eth_num = adapter->eth_num;
	else
		return;

	spin_lock_irqsave(&adapter->eth_status_lock, flags);

	for (port_index = 0; port_index < eth_num; port_index++) {
		if (IS_PORT_ONLINE(adapter->eth_modules_status, port_index))
			action_mng.action_type[port_index] =
				DPU_ETH_ACTION_BUILD;
		else
			action_mng.action_type[port_index] =
				DPU_ADD_ETH_2_BC;
	}

	if (is_af(hw))
		dpu_cfg_eth_2_bc(hw, &action_mng);
	else
		dpu_cfg_host_eth_stats(hw, &action_mng);

	spin_unlock_irqrestore(&adapter->eth_status_lock, flags);
}
```

No `rd32()`, timer change, new workqueue, or bridge-side address filter is
allowed in this helper.

- [x] **Step 5: Run GREEN source-contract validation**

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
/home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver/tests/integration/test_dpu_skip_eth_scan_source.sh \
  "$release/source/host-driver-net" \
  | tee "$release/logs/source-contract.log"
```

Expected:

```text
PASS: DPU skip_eth_scan source contract
```

### Task 3: Build and validate the new module and bundle on 53

**Files:**

- Input: new `source/host-driver-net`
- Create: `source/host-driver-net-skipeth.tar.gz`
- Create: `bundle/dpu_snd1.ko`
- Create: `bundle/driver.conf`
- Create: top-level `dpu_snd1.ko`
- Create: build and metadata logs

- [x] **Step 1: Create a deterministic source archive**

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
tar --sort=name --mtime='UTC 2026-08-10 00:00:00' \
  --owner=0 --group=0 --numeric-owner \
  -C "$release/source" -czf "$release/source/host-driver-net-skipeth.tar.gz" \
  host-driver-net
```

Validate its single safe root:

```bash
project=/home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver
"$project/scripts/build_dpu_driver_bundle.sh" --validate-only \
  --archive "$release/source/host-driver-net-skipeth.tar.gz" \
  | tee "$release/logs/source-archive-check.log"
```

Expected: `validated archive:` and no unsafe or unexpected entry error.

- [x] **Step 2: Build against the exact guest kernel headers**

```bash
project=/home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
headers="$project/build/kheaders-6.8.0-107-generic/usr/src/linux-headers-6.8.0-107-generic"
compat="$project/build/compat-runtime/libc6_2.39-0ubuntu8_amd64.deb"
mkdir -p "$project/build/tmp"
DPU_DRIVER_TMPDIR="$project/build/tmp" \
  "$project/scripts/build_dpu_driver_bundle.sh" \
  --archive "$release/source/host-driver-net-skipeth.tar.gz" \
  --kernel-build "$headers" \
  --compat-runtime-deb "$compat" \
  --use-system-bonding \
  --output "$release/bundle" \
  2>&1 | tee "$release/logs/build.log"
cp "$release/bundle/dpu_snd1.ko" "$release/dpu_snd1.ko"
```

Expected: the command exits zero, uses project-local `build/tmp`, and prints
`built DPU driver bundle:`.

- [x] **Step 3: Verify architecture, vermagic, binding, and parameter metadata**

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
module="$release/bundle/dpu_snd1.ko"
file "$module" | tee "$release/logs/module-metadata.log"
modinfo "$module" | tee -a "$release/logs/module-metadata.log"
file "$module" | grep -q 'x86-64'
modinfo -F vermagic "$module" | grep -q '^6.8.0-107-generic '
modinfo -F alias "$module" | grep -q 'v000020F9d00005011'
! modinfo -F alias "$module" | grep -q 'v000020F9d00005012'
modinfo -F parm "$module" | grep -q '^skip_eth_scan:'
```

Expected: all assertions pass; the module is x86-64, matches the guest kernel,
binds PF0 only, and exposes `skip_eth_scan`.

- [x] **Step 4: Run the existing bundle/import regressions**

In the established QEMU_VCS driver-build checkout on 53:

```bash
cd /home/ubuntu/test_cosim/worktrees/qemu-vcs-x86-dpu-driver
tests/integration/test_dpu_driver_bundle.sh
tests/integration/test_dpu_driver_injection.sh
tests/integration/test_offline_custom_driver.sh
```

Expected: all three scripts print `PASS` and exit zero. This proves the new
module feature does not alter the existing generic setup/import paths.

### Task 4: Verify both driver modes in QEMU/VCS co-simulation on 53

**Files:**

- QEMU: `/home/ubuntu/test_cosim/builds/qemu-vcs-offline-icount-nodriver-20260805/import-check/third_party/qemu/build-cq-route-00968c2/qemu-system-x86_64`
- Guest: `/home/ubuntu/test_cosim/worktrees/ubuntu-server-debugutils/guest/images/ubuntu-server/`
- VCS: `/home/ubuntu/test_cosim/builds/cq-bar-routing-final-20260809-00968c2/build/cosim-route-latest-20260809/simv`
- Logs: new release `logs/runtime/`

- [x] **Step 1: Launch QEMU with iCount, management SSH, and request debug**

Use port `28210` for co-simulation and `22410` for guest SSH. Launch QEMU first
in the background with `debug=on` on `cosim-pcie-rc`:

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
runtime="$release/logs/runtime"
qemu=/home/ubuntu/test_cosim/builds/qemu-vcs-offline-icount-nodriver-20260805/import-check/third_party/qemu/build-cq-route-00968c2/qemu-system-x86_64
guest=/home/ubuntu/test_cosim/worktrees/ubuntu-server-debugutils/guest/images/ubuntu-server
mkdir -p "$runtime"
nohup "$qemu" \
  -accel tcg -icount shift=auto,align=off,sleep=on \
  -M q35 -m 2G -smp 1 -snapshot \
  -kernel "$guest/vmlinuz" \
  -drive file="$guest/rootfs.ext4",format=raw,if=none,id=rootdisk0 \
  -device virtio-blk-pci,drive=rootdisk0,addr=0x10 \
  -append 'console=ttyS0 root=/dev/vda rw' \
  -netdev user,id=mgmtnet0,hostfwd=tcp:127.0.0.1:22410-:22 \
  -device e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01 \
  -device pcie-root-port,id=cosim_rp0,bus=pcie.0,addr=0x3,slot=3,chassis=1,mem-reserve=64M,pref64-reserve=256M \
  -device cosim-pcie-rc,bus=cosim_rp0,addr=0x0,num_pfs=1,transport=tcp,port_base=28210,instance_id=0,mmio_timeout_ms=180000,debug=on \
  -display none -serial file:"$runtime/guest-console.log" \
  -monitor unix:"$runtime/qemu-monitor.sock",server=on,wait=off \
  > "$runtime/qemu-debug.log" 2>&1 &
echo $! > "$runtime/qemu.pid"
```

Expected: QEMU listens on TCP `28210` and guest SSH `22410`; the process remains
alive while waiting for VCS.

- [x] **Step 2: Launch the VCS cosim endpoint in the 53 login environment**

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
runtime="$release/logs/runtime"
simv=/home/ubuntu/test_cosim/builds/cq-bar-routing-final-20260809-00968c2/build/cosim-route-latest-20260809/simv
nohup "$simv" \
  +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART \
  +BYPASS_CONFIG=1 +CFG_PROFILE=DPU_20F9_501X \
  +NUM_PFS=1 +MAX_VFS=16 +NUM_VFS=0 +TAG_BIT=8 +TOPO=0 \
  +REMOTE_HOST=127.0.0.1 +PORT_BASE=28210 +INSTANCE_ID=0 \
  +SIM_TIMEOUT_MS=20000000 +STOP_AFTER_TLPS=20000 \
  +UVM_VERBOSITY=UVM_MEDIUM -l "$runtime/vcs.log" \
  > "$runtime/vcs-stdout.log" 2>&1 &
echo $! > "$runtime/vcs.pid"
```

This repository-owned cosim top supplies deterministic completions for the
driver validation. The user's real-DUT top later uses the same arguments plus
`+REAL_DUT`; no driver source or load-command difference is required.

- [x] **Step 3: Copy the module into the running guest**

Wait until SSH accepts connections, then:

```bash
sshpass -p '123' scp -P 22410 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/dpu_snd1.ko \
  ryan@127.0.0.1:/tmp/dpu_snd1.ko
```

Expected: SCP exits zero and `/tmp/dpu_snd1.ko` exists in the guest.

- [ ] **Step 4: Run bypass mode and prove Link Up plus zero periodic reads**

Before loading, record the current line count in `qemu-debug.log`, then load:

```bash
runtime=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/logs/runtime
wc -l < "$runtime/qemu-debug.log" > "$runtime/skip-start-line"
sshpass -p '123' ssh -p 22410 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ryan@127.0.0.1 \
  "sudo insmod /tmp/dpu_snd1.ko skip_eth_scan=1 && \
   cat /sys/module/dpu_snd1/parameters/skip_eth_scan && sleep 5 && \
   cat /sys/class/net/dpu_port0/carrier && \
   cat /sys/class/net/dpu_port1/carrier"
```

Expected output contains `Y`, then carrier `1` for both ports.

Read BAR0 base, compute the two full PCIe addresses, and search only the new
debug-log lines:

```bash
bar0=$(sshpass -p '123' ssh -p 22410 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ryan@127.0.0.1 \
  "sudo awk 'NR == 1 { print \$1 }' /sys/bus/pci/devices/0000:01:00.0/resource")
addr24=$(printf '0x%x' $((bar0 + 0x0c00024)))
addr2c=$(printf '0x%x' $((bar0 + 0x0c0002c)))
start=$(cat "$runtime/skip-start-line")
tail -n "+$((start + 1))" "$runtime/qemu-debug.log" > "$runtime/skip-window.log"
count24=$(grep -Fc "addr=$addr24" "$runtime/skip-window.log" || true)
count2c=$(grep -Fc "addr=$addr2c" "$runtime/skip-window.log" || true)
printf 'addr24=%s count=%s\naddr2c=%s count=%s\n' \
  "$addr24" "$count24" "$addr2c" "$count2c" > "$runtime/skip-counts.txt"
test "$count24" -eq 0
test "$count2c" -eq 0
kill -0 "$(cat "$runtime/qemu.pid")"
kill -0 "$(cat "$runtime/vcs.pid")"
! grep -Fq 'completion with no qemu tag' "$runtime/vcs.log"
! grep -Eq 'UVM_FATAL[^:]*: [1-9]' "$runtime/vcs.log"
```

Expected: both counts are zero across the five guest service periods, both
processes remain alive, and neither tag-map nor UVM fatal error is present.

- [ ] **Step 5: Reload without the option and prove compatibility**

```bash
wc -l < "$runtime/qemu-debug.log" > "$runtime/default-start-line"
sshpass -p '123' ssh -p 22410 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ryan@127.0.0.1 \
  "sudo rmmod dpu_snd1 && sudo insmod /tmp/dpu_snd1.ko && \
   cat /sys/module/dpu_snd1/parameters/skip_eth_scan && sleep 5"

start=$(cat "$runtime/default-start-line")
tail -n "+$((start + 1))" "$runtime/qemu-debug.log" > "$runtime/default-window.log"
count24=$(grep -Fc "addr=$addr24" "$runtime/default-window.log" || true)
count2c=$(grep -Fc "addr=$addr2c" "$runtime/default-window.log" || true)
printf 'addr24=%s count=%s\naddr2c=%s count=%s\n' \
  "$addr24" "$count24" "$addr2c" "$count2c" > "$runtime/default-counts.txt"
test "$count2c" -ge 2
test "$count24" -ge 2
```

Expected parameter output is `N`. Search only log lines emitted after this
second load marker. The default path must show repeated
`BAR0+0x0c0002c` optical-status reads and, once mailbox/ETH readiness is set,
repeated `BAR0+0x0c00024` link-status reads. Require zero `UVM_FATAL`; this is
the compatibility proof that hardware-derived scanning remains intact.

- [x] **Step 6: Stop QEMU/VCS and preserve runtime evidence**

Save guest state, then terminate only the recorded validation PIDs:

```bash
sshpass -p '123' ssh -p 22410 \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  ryan@127.0.0.1 'sudo dmesg; ip -br link' \
  > "$runtime/guest-final.log"
kill "$(cat "$runtime/vcs.pid")" "$(cat "$runtime/qemu.pid")"
wait "$(cat "$runtime/vcs.pid")" 2>/dev/null || true
wait "$(cat "$runtime/qemu.pid")" 2>/dev/null || true
grep -E 'UVM_(ERROR|FATAL)' "$runtime/vcs.log" \
  > "$runtime/uvm-summary.log" || true
```

### Task 5: Finalize release integrity and repository history

**Files:**

- Create: remote release `SHA256SUMS`
- Modify: `docs/superpowers/plans/2026-08-10-dpu-skip-eth-scan.md` checkboxes only while executing

- [x] **Step 1: Create and verify the release checksum manifest**

From the new release directory, hash the source archive, top-level module,
bundle module, bundle manifest, and all validation logs using relative paths;
then verify the manifest:

```bash
release=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810
cd "$release"
(
  find source -maxdepth 1 -type f -name '*.tar.gz' -print0
  find bundle -maxdepth 1 -type f -print0
  find logs -type f -print0
  printf '%s\0' dpu_snd1.ko
) | sort -z | xargs -0 sha256sum > SHA256SUMS
sha256sum -c SHA256SUMS
```

Expected: every listed artifact reports `OK`. Record the manifest hash
separately in the handoff.

- [x] **Step 2: Confirm the old release is unchanged**

Verify the absolute-path snapshot captured before copying:

```bash
sha256sum -c \
  /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/logs/old-release-before.sha256
```

Expected: all three old-release files report `OK`; no file under
`dpu-qid128-pf0only-vnetcache-20260804` was written.

- [x] **Step 3: Run repository verification**

```bash
git diff --check
bash -n tests/integration/test_dpu_skip_eth_scan_source.sh
tests/integration/test_dpu_skip_eth_scan_source.sh \
  /home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net
git status --short
```

Expected: no whitespace errors, syntax PASS, source contract PASS, and only the
plan checkbox/evidence updates intended for the final commit remain.

- [x] **Step 4: Commit final plan evidence**

```bash
git add docs/superpowers/plans/2026-08-10-dpu-skip-eth-scan.md
git commit -m "docs: record DPU ETH scan bypass validation"
```

- [x] **Step 5: Handoff exact usage**

Report the new release path, module SHA-256, manifest SHA-256, source archive,
build/result logs, and both load commands:

```bash
# Co-simulation bypass: fixed Link Up, no periodic ETH status MMIO
sudo insmod dpu_snd1.ko skip_eth_scan=1

# Hardware-compatible default: retain real ETH polling
sudo insmod dpu_snd1.ko
```

Do not claim real-DUT runtime success from the repository-owned stand-in top.
Label that run as deterministic QEMU/VCS driver validation; the same module is
ready for the user's `+REAL_DUT +BYPASS_CONFIG=1` environment.
