# QEMU Management SCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable the existing loopback-only QEMU management NIC to receive host files through SSH/SCP in the Ubuntu Guest, while retaining a no-custom-driver offline package.

**Architecture:** Preserve `MGMT_NET=1` and its e1000e + user-NAT + hostfwd implementation. Add a rootfs provisioning script which installs OpenSSH server and sudo, configures systemd-networkd DHCP only for e1000e, and creates a non-root management user from a build-time password environment variable. The script never accepts a password on its command line or writes it to Git. The final offline package contains the provisioned rootfs but no DPU bundle, module, driver configuration, or driver service.

**Tech Stack:** Bash, GNU Make, QEMU user-mode NAT/e1000e, Debian rootfs, systemd-networkd, OpenSSH, sudo, debugfs, VCS host 10.11.10.53.

---

## File structure

- `scripts/provision_guest_ssh.sh`: Privileged rootfs provisioning entry point.
- `tests/integration/test_guest_ssh_provisioning.sh`: Fast unprivileged command-contract test.
- `tests/integration/CMakeLists.txt`: Registers the command-contract test.
- `docs/GUEST-MANAGEMENT-SCP.md`: Documents launch, copy, and manual driver load steps.
- `guest/images/ubuntu/rootfs.ext4` on 53: Build artifact only, never committed.

### Task 1: Add the provisioning command contract test

**Files:**

- Create: `tests/integration/test_guest_ssh_provisioning.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo/scripts/provision_guest_ssh.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "[guest-ssh-provisioning] FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$1" <<<"$2" || fail "missing: $1"; }

help="$($script --help)"
assert_contains 'COSIM_GUEST_SSH_PASSWORD' "$help"
assert_contains '--rootfs' "$help"
assert_contains '--user' "$help"
if "$script" --dry-run --rootfs "$tmp/rootfs.ext4" --user ryan >/dev/null 2>&1; then
    fail 'missing password was accepted'
fi
if COSIM_GUEST_SSH_PASSWORD='not-to-be-printed' \
        "$script" --dry-run --rootfs "$tmp/rootfs.ext4" --user 'bad/user' >/dev/null 2>&1; then
    fail 'unsafe user name was accepted'
fi
output="$(COSIM_GUEST_SSH_PASSWORD='not-to-be-printed' \
    "$script" --dry-run --rootfs "$tmp/rootfs.ext4" --user ryan)"
assert_contains 'openssh-server sudo' "$output"
assert_contains 'Driver=e1000e' "$output"
assert_contains 'PasswordAuthentication yes' "$output"
[[ "$output" != *not-to-be-printed* ]] || fail 'password leaked to output'
echo '[guest-ssh-provisioning] PASS'
```

- [ ] **Step 2: Register it in CTest**

Append after `test_qemu_management_nic`:

```cmake
add_test(NAME test_guest_ssh_provisioning
         COMMAND bash ${CMAKE_CURRENT_SOURCE_DIR}/test_guest_ssh_provisioning.sh)
set_tests_properties(test_guest_ssh_provisioning PROPERTIES TIMEOUT 10)
```

- [ ] **Step 3: Verify RED**

Run: `bash tests/integration/test_guest_ssh_provisioning.sh`

Expected: it fails because `scripts/provision_guest_ssh.sh` does not exist.

- [ ] **Step 4: Commit the test-only change**

```bash
git add tests/integration/test_guest_ssh_provisioning.sh tests/integration/CMakeLists.txt
git commit -m "test: define guest SSH provisioning contract"
```

### Task 2: Implement reproducible SSH/SCP rootfs provisioning

**Files:**

- Create: `scripts/provision_guest_ssh.sh`
- Test: `tests/integration/test_guest_ssh_provisioning.sh`

- [ ] **Step 1: Implement strict argument and secret handling**

Implement this public interface:

```text
scripts/provision_guest_ssh.sh --rootfs IMAGE [--user ryan] [--dry-run]
```

Validate before mounting:

```bash
password="${COSIM_GUEST_SSH_PASSWORD:-}"
[[ -n "$password" ]] || fail 'COSIM_GUEST_SSH_PASSWORD must be set'
[[ "$user" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || fail 'invalid guest user'
[[ -n "$rootfs" ]] || fail '--rootfs is required'
```

`--dry-run` must print package/configuration names but never the password, and must not require a real rootfs or root. Normal mode must require a regular rootfs image and `sudo`, make a temporary mount, and trap unmounts for `/proc`, `/sys`, `/dev/pts`, `/dev`, and the image.

- [ ] **Step 2: Install SSH server and the non-root management user**

After loop-mounting the image, bind-mount `/dev`, `/dev/pts`, `/proc`, and `/sys`. Write a temporary executable `/usr/sbin/policy-rc.d` which exits 101, and run the following through `chroot`:

```bash
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server sudo
```

Remove `policy-rc.d`. Create the user only when absent, set the password through `chpasswd` stdin, and add the user to the `sudo` group. Do not enable root SSH login and do not create NOPASSWD sudo policy.

- [ ] **Step 3: Configure DHCP and sshd**

Write `/etc/systemd/network/10-cosim-management.network`:

```ini
[Match]
Driver=e1000e

[Network]
DHCP=yes
LinkLocalAddressing=no
```

Use `systemctl --root="$mount" enable systemd-networkd.service`. Write `/etc/ssh/sshd_config.d/99-cosim-management.conf`:

```text
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers ryan
```

Replace `ryan` with the validated selected user, run `ssh-keygen -A` and `sshd -t` inside the chroot, then run `systemctl --root="$mount" enable ssh.service`.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/integration/test_guest_ssh_provisioning.sh`

Expected: `[guest-ssh-provisioning] PASS`; the dry-run lists OpenSSH, sudo, e1000e DHCP and password auth, without revealing the environment password.

- [ ] **Step 5: Commit the implementation**

```bash
git add scripts/provision_guest_ssh.sh
git commit -m "feat: provision guest SSH management service"
```

### Task 3: Document host-to-Guest driver import

**Files:**

- Create: `docs/GUEST-MANAGEMENT-SCP.md`

- [ ] **Step 1: Document the QEMU and SCP commands**

Document that the port is host-loopback-only and does not traverse DUT/VCS. Include:

```bash
make run-qemu MGMT_NET=1 MGMT_SSH_PORT_BASE=2222
scp -P 2222 ./dpu_snd1.ko ryan@127.0.0.1:/tmp/
ssh -p 2222 ryan@127.0.0.1
```

Document `MGMT_NET=0` as the disable switch. Do not write an actual password in the document.

- [ ] **Step 2: Document manual load only**

Require checking `uname -r` and `modinfo -F vermagic`. For this driver bundle, document:

```bash
sudo insmod /tmp/bonding.ko
sudo insmod /tmp/dpu_snd1.ko
lsmod | grep -E 'bonding|dpu_snd1'
```

State clearly that the rootfs has no custom DPU driver and no automatic module load; reboot returns it to the no-driver baseline.

- [ ] **Step 3: Commit documentation**

```bash
git add docs/GUEST-MANAGEMENT-SCP.md
git commit -m "docs: describe guest SCP driver import"
```

### Task 4: Verify real SSH/SCP and produce the no-driver package on 53

**Files:**

- Modify (artifact only): 53 build copy of `guest/images/ubuntu/rootfs.ext4`
- Output: `/home/ubuntu/test_cosim/builds/qemu-vcs-offline-scp-nodriver-20260804/`

- [ ] **Step 1: Synchronize implementation to a fresh 53 build tree**

Start from the remote `feature/qemu-vcs-isolated-tcp` tip plus the local source commits, without changing older packages. Confirm the Makefile contains both `MGMT_NET ?= 1` and `hostfwd=tcp:127.0.0.1:$(MGMT_SSH_PORT_BASE)-:22`.

- [ ] **Step 2: Provision a private rootfs copy**

Copy the clean 0803 no-driver rootfs into the new build directory. Set `COSIM_GUEST_SSH_PASSWORD` only in the 53 process environment, call the provisioning script as user `ryan`, then unset it. Do not place the password in history, source files, archive names, package metadata, or logs.

- [ ] **Step 3: Run a real QEMU SSH/SCP round trip**

Start QEMU with `MGMT_NET=1 MGMT_SSH_PORT_BASE=2222`, the provisioned rootfs, and no DPU driver. Copy a generated 4 KiB host file and compare hashes:

```bash
dd if=/dev/urandom of=/tmp/cosim-scp-smoke.bin bs=4096 count=1 status=none
sshpass -p "$COSIM_GUEST_SSH_PASSWORD" scp -o StrictHostKeyChecking=accept-new -P 2222 \
  /tmp/cosim-scp-smoke.bin ryan@127.0.0.1:/tmp/cosim-scp-smoke.bin
host_hash=$(sha256sum /tmp/cosim-scp-smoke.bin | awk '{print $1}')
guest_hash=$(sshpass -p "$COSIM_GUEST_SSH_PASSWORD" ssh -o StrictHostKeyChecking=accept-new -p 2222 \
  ryan@127.0.0.1 'sha256sum /tmp/cosim-scp-smoke.bin' | awk '{print $1}')
test "$host_hash" = "$guest_hash"
```

Expected: both clients exit zero and the two hashes match.

- [ ] **Step 4: Package without a custom driver**

Run `scripts/prepare-offline.sh --guest ubuntu --skip-rootfs` without `--custom-driver`, replace staged `guest/ubuntu/rootfs.ext4` with the provisioned copy, and create:

```text
/home/ubuntu/test_cosim/builds/qemu-vcs-offline-scp-nodriver-20260804/
  qemu-vcs-offline-scp-nodriver-20260804.zip
  qemu-vcs-offline-scp-nodriver-20260804.zip.sha256
```

- [ ] **Step 5: Validate final package content**

Run `sha256sum -c` and `unzip -t`. Use `debugfs` to verify the rootfs contains `/usr/sbin/sshd`, enabled `ssh.service`, and `10-cosim-management.network`. Verify these are absent:

```text
/etc/cosim/driver.conf
/etc/cosim/load-custom-driver.sh
/etc/systemd/system/cosim-driver.service
/etc/systemd/system/multi-user.target.wants/cosim-driver.service
/lib/modules/cosim-drivers/dpu_snd1
```

- [ ] **Step 6: Run source regression and commit**

```bash
git diff --check
ctest --test-dir build --output-on-failure -R 'qemu_management_nic|guest_ssh_provisioning'
git add scripts/provision_guest_ssh.sh tests/integration/test_guest_ssh_provisioning.sh \
  tests/integration/CMakeLists.txt docs/GUEST-MANAGEMENT-SCP.md
git commit -m "feat: enable guest SCP management access"
```

Report only the package path, checksum path, successful SSH/SCP evidence, and verification that no custom DPU module is imported or auto-loaded.
