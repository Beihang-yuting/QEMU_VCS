# Guest Build-Essential Offline Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a no-custom-driver QEMU-VCS offline package whose Ubuntu Guest includes GNU Make and the standard C/C++ build toolchain.

**Architecture:** Extend the existing SSH Guest provisioning path to install Debian's `build-essential` metapackage, then provision the existing Ubuntu rootfs on `10.11.10.53`. Validate the image through the host-only QEMU management NIC before packaging the current project without `--custom-driver`.

**Tech Stack:** Bash, Debian/Ubuntu APT and chroot, ext4/debugfs, QEMU 9.2, OpenSSH/SCP, ZIP, MD5, SHA256.

---

## File map

- `tests/integration/test_guest_ssh_provisioning.sh`: dry-run contract for packages installed into the Guest.
- `scripts/provision_guest_ssh.sh`: reproducible rootfs package installation and SSH provisioning.
- `guest/images/ubuntu/rootfs.ext4`: generated Guest image artifact; not committed.
- `scripts/prepare-offline.sh`: existing packager, used unchanged and without `--custom-driver`.

### Task 1: Add a failing provisioning contract

**Files:**

- Modify: `tests/integration/test_guest_ssh_provisioning.sh`
- Test: `tests/integration/test_guest_ssh_provisioning.sh`

- [ ] **Step 1: Change the package assertion**

Replace:

```bash
assert_contains 'openssh-server sudo' "$output"
```

with:

```bash
assert_contains 'openssh-server sudo build-essential' "$output"
```

- [ ] **Step 2: Run the test and confirm RED**

Run on `10.11.10.53`:

```bash
bash tests/integration/test_guest_ssh_provisioning.sh
```

Expected: nonzero exit with `missing: openssh-server sudo build-essential`, proving the current script does not promise the requested toolchain.

### Task 2: Install build-essential through the provisioning script

**Files:**

- Modify: `scripts/provision_guest_ssh.sh`
- Test: `tests/integration/test_guest_ssh_provisioning.sh`

- [ ] **Step 1: Update the help description**

Change the provisioning description to:

```text
Provision a Debian/Ubuntu Guest image with openssh-server, sudo,
build-essential, DHCP for the QEMU e1000e management NIC, and a non-root
management user.
```

- [ ] **Step 2: Update dry-run output**

Use this exact package line:

```bash
Would install: openssh-server sudo build-essential
```

- [ ] **Step 3: Update the APT install command**

Use:

```bash
run_root chroot "$mount_dir" /usr/bin/env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends openssh-server sudo build-essential
```

Do not add kernel headers or a DPU driver package.

- [ ] **Step 4: Run focused tests and confirm GREEN**

```bash
bash tests/integration/test_guest_ssh_provisioning.sh
bash tests/integration/test_qemu_management_nic.sh
git diff --check
```

Expected: both tests print `PASS`; `git diff --check` exits zero.

- [ ] **Step 5: Commit the source change**

```bash
git add scripts/provision_guest_ssh.sh tests/integration/test_guest_ssh_provisioning.sh
git commit -m "feat(guest): include standard build toolchain"
```

### Task 3: Provision and inspect the Ubuntu rootfs on 53

**Files:**

- Modify artifact: `guest/images/ubuntu/rootfs.ext4`

- [ ] **Step 1: Record the source image hash and filesystem health**

```bash
sha256sum guest/images/ubuntu/rootfs.ext4 | tee /tmp/cosim-rootfs-before.sha256
sudo -n e2fsck -fn guest/images/ubuntu/rootfs.ext4
```

Expected: the hash is recorded and `e2fsck` reports no unrepaired filesystem error.

- [ ] **Step 2: Provision the image without persisting credentials**

```bash
read -rsp 'Guest management password: ' COSIM_GUEST_SSH_PASSWORD
echo
export COSIM_GUEST_SSH_PASSWORD
sudo -n --preserve-env=COSIM_GUEST_SSH_PASSWORD \
  scripts/provision_guest_ssh.sh \
  --rootfs guest/images/ubuntu/rootfs.ext4 \
  --user ryan
export SSHPASS="$COSIM_GUEST_SSH_PASSWORD"
unset COSIM_GUEST_SSH_PASSWORD
```

Expected: the script prints `Provisioned SSH/SCP management service` and APT completes successfully.

- [ ] **Step 3: Check the generated image offline**

```bash
for path in /usr/bin/make /usr/bin/gcc /usr/bin/g++ /usr/bin/ld; do
  debugfs -R "stat $path" guest/images/ubuntu/rootfs.ext4 2>&1 | grep -q 'Inode:'
done
debugfs -R 'cat /var/lib/dpkg/status' guest/images/ubuntu/rootfs.ext4 2>/dev/null \
  | grep -A3 '^Package: build-essential$' \
  | grep -q '^Status: install ok installed$'
sudo -n e2fsck -fn guest/images/ubuntu/rootfs.ext4
sha256sum guest/images/ubuntu/rootfs.ext4 | tee /tmp/cosim-rootfs-after.sha256
```

Expected: all four binaries exist, `build-essential` is installed, filesystem health is clean, and the after hash differs from the before hash.

### Task 4: Boot the Guest and validate compilation plus SSH/SCP

**Files:**

- Read: `guest/images/ubuntu/vmlinuz`
- Read: `guest/images/ubuntu/rootfs.ext4`
- Create temporary: `/tmp/cosim-build-essential-smoke/`

- [ ] **Step 1: Start an isolated QEMU smoke boot**

Use the already-built QEMU from the prior verified import, omit the cosim PCIe device, and keep the current icount arguments:

```bash
PROJECT=/home/ubuntu/test_cosim/builds/qemu-vcs-offline-icount-nodriver-20260805/project
QEMU_BIN=/home/ubuntu/test_cosim/builds/qemu-vcs-offline-icount-nodriver-20260805/import-check/third_party/qemu/build/qemu-system-x86_64
TEST_SSH_PORT=22345
mkdir -p /tmp/cosim-build-essential-smoke
env LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib/x86_64-linux-gnu:$PROJECT/build/lib" \
  "$QEMU_BIN" -accel tcg -icount shift=auto,align=off,sleep=on \
  -M q35 -m 2G -smp 1 -snapshot \
  -kernel "$PROJECT/guest/images/ubuntu/vmlinuz" \
  -drive file="$PROJECT/guest/images/ubuntu/rootfs.ext4",format=raw,if=none,id=rootdisk0 \
  -device virtio-blk-pci,drive=rootdisk0,addr=0x10 \
  -append 'console=ttyS0 root=/dev/vda rw' \
  -netdev user,id=mgmtnet0,hostfwd=tcp:127.0.0.1:${TEST_SSH_PORT}-:22 \
  -device e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01 \
  -display none -serial file:/tmp/cosim-build-essential-smoke/serial.log \
  -monitor none >/tmp/cosim-build-essential-smoke/qemu.log 2>&1 &
QEMU_PID=$!
```

- [ ] **Step 2: Wait for SSH and inspect tool versions**

```bash
for attempt in $(seq 1 120); do
  if sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=2 \
       -p "$TEST_SSH_PORT" ryan@127.0.0.1 true 2>/dev/null; then
    break
  fi
  sleep 2
done
sshpass -e ssh -p "$TEST_SSH_PORT" ryan@127.0.0.1 \
  'make --version | head -1; gcc --version | head -1; g++ --version | head -1; ld --version | head -1'
```

Expected: SSH succeeds and all four commands print GNU tool versions.

- [ ] **Step 3: Compile and run a C program with Make**

```bash
sshpass -e ssh -p "$TEST_SSH_PORT" ryan@127.0.0.1 'bash -s' <<'GUEST_BUILD'
set -eu
mkdir -p /tmp/build-smoke
printf '%s\n' '#include <stdio.h>' \
  'int main(void) { puts("build-essential-ok"); return 0; }' \
  > /tmp/build-smoke/main.c
printf 'all:\n\tcc -Wall -Wextra -Werror -o hello main.c\n' \
  > /tmp/build-smoke/Makefile
make -C /tmp/build-smoke
/tmp/build-smoke/hello
GUEST_BUILD
```

Expected: compilation exits zero and prints `build-essential-ok`.

- [ ] **Step 4: Verify an SCP round trip**

```bash
head -c 4096 /dev/urandom > /tmp/cosim-build-essential-smoke/scp.bin
sshpass -e scp -P "$TEST_SSH_PORT" /tmp/cosim-build-essential-smoke/scp.bin \
  ryan@127.0.0.1:/tmp/scp.bin
host_hash=$(sha256sum /tmp/cosim-build-essential-smoke/scp.bin | awk '{print $1}')
guest_hash=$(sshpass -e ssh -p "$TEST_SSH_PORT" ryan@127.0.0.1 \
  'sha256sum /tmp/scp.bin' | awk '{print $1}')
test "$host_hash" = "$guest_hash"
```

Expected: SCP exits zero and the hashes match.

- [ ] **Step 5: Stop the smoke Guest and clear the password environment**

```bash
kill "$QEMU_PID"
wait "$QEMU_PID" 2>/dev/null || true
unset SSHPASS
```

### Task 5: Produce and verify the no-driver offline package

**Files:**

- Output: `/home/ubuntu/test_cosim/builds/qemu-vcs-offline-build-essential-nodriver-20260805/qemu-vcs-offline-build-essential-nodriver-20260805.zip`
- Output: `/home/ubuntu/test_cosim/builds/qemu-vcs-offline-build-essential-nodriver-20260805/qemu-vcs-offline-build-essential-nodriver-20260805.zip.md5`
- Output: `/home/ubuntu/test_cosim/builds/qemu-vcs-offline-build-essential-nodriver-20260805/qemu-vcs-offline-build-essential-nodriver-20260805.zip.sha256`

- [ ] **Step 1: Build the archive without a custom-driver argument**

```bash
OUT_DIR=/home/ubuntu/test_cosim/builds/qemu-vcs-offline-build-essential-nodriver-20260805
ZIP="$OUT_DIR/qemu-vcs-offline-build-essential-nodriver-20260805.zip"
mkdir -p "$OUT_DIR"
scripts/prepare-offline.sh --guest ubuntu --skip-rootfs --output "$ZIP"
(cd "$OUT_DIR" && sha256sum "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
```

Expected: packager exits zero; no `--custom-driver` or `--compat-runtime-deb` is supplied.

- [ ] **Step 2: Validate archive and checksum integrity**

```bash
unzip -t "$ZIP"
(cd "$OUT_DIR" && md5sum -c "$(basename "$ZIP").md5")
(cd "$OUT_DIR" && sha256sum -c "$(basename "$ZIP").sha256")
```

Expected: ZIP reports no errors and both checksum checks report `OK`.

- [ ] **Step 3: Validate metadata and driver absence**

```bash
unzip -p "$ZIP" offline-meta.env | tee "$OUT_DIR/offline-meta.env.check"
unzip -p "$ZIP" offline-meta.env | grep -qx 'OFFLINE_HAS_CUSTOM_DPU=false'
unzip -p "$ZIP" offline-meta.env | grep -qx 'OFFLINE_HAS_COSIM_NIC=false'
if unzip -Z1 "$ZIP" | grep -Eq '\.ko$|^custom-driver/[^/]+$'; then
  echo 'unexpected driver payload in archive' >&2
  exit 1
fi
```

Expected: both metadata flags are false and no kernel module or custom-driver payload is listed.

- [ ] **Step 4: Verify the packaged rootfs itself**

```bash
VERIFY_DIR=$(mktemp -d /home/ubuntu/test_cosim/builds/cosim-make-verify.XXXXXX)
unzip -p "$ZIP" guest/ubuntu/rootfs.ext4 > "$VERIFY_DIR/rootfs.ext4"
for path in /usr/bin/make /usr/bin/gcc /usr/bin/g++ /usr/bin/ld; do
  debugfs -R "stat $path" "$VERIFY_DIR/rootfs.ext4" 2>&1 | grep -q 'Inode:'
done
rm -f "$VERIFY_DIR/rootfs.ext4"
rmdir "$VERIFY_DIR"
```

Expected: all required tool binaries are present in the exact rootfs embedded in the final ZIP.

- [ ] **Step 5: Record final evidence**

```bash
git status --short
git log -3 --oneline
ls -lh "$ZIP" "$ZIP.md5" "$ZIP.sha256"
md5sum "$ZIP"
sha256sum "$ZIP"
```

Report the archive paths, sizes and checksums; the Guest version/compile/SCP evidence; the source commits; and explicit confirmation that the archive contains no custom DPU driver or `.ko` file.
