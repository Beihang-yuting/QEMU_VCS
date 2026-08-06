
# Ubuntu Server Guest and DPU Debug Utilities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a selectable Ubuntu Server 24.04 Guest that can build the PF0-only/QID128 DPU driver offline, while installing `pci_debug` and `reg_display` in both the existing compact Guest and the new server Guest.

**Architecture:** Import a sanitized, checksummed snapshot of the debug utility source and build static binaries through one focused script. Keep `GUEST_TYPE=ubuntu` as the default compact image, add `GUEST_TYPE=ubuntu-server` with an independently built Noble rootfs and exact `6.8.0-107-generic` headers, and extend setup/offline import paths without changing QEMU/VCS transport behavior. Generated images and offline archives remain build artifacts and are validated on `10.11.10.53`.

**Tech Stack:** Bash, GNU Make, C, debootstrap, Ubuntu Noble APT, ext4/loop mounts, QEMU 9.2, OpenSSH/SCP, Linux Kbuild, VCS/UVM, ZIP/MD5/SHA-256.

---

## File map

- Create `third_party/dpu-debugutils/`: sanitized source snapshot containing only `README.md`, `Makefile`, `pcie_debug/`, and `reg_display/`; never copy the nested `.git` directory or FPGA scripts.
- Create `third_party/dpu-debugutils/SOURCE.md`: source path, archive checksum, imported revision, and exclusions.
- Create `scripts/build_dpu_debugutils.sh`: reproducible static build into `build/guest_tools/dpu-debugutils/`; all temporary work stays below project `build/tmp/`.
- Create `scripts/stage_guest_debugutils.sh`: install validated binaries and optional source under an already mounted root directory.
- Create `scripts/install_guest_debugutils.sh`: mount an ext4 image, call the staging helper, run filesystem checks, and unmount safely.
- Create `scripts/build_rootfs_ubuntu_server.sh`: build the Noble server image, install exact headers and development tools, configure SSH/networking, disable background timers, and stage debug tools/source.
- Modify `scripts/build_rootfs_debian.sh`: stage the two static debug binaries into newly built compact/Debian base images.
- Modify `scripts/inject-modules.sh`: retain debug tools when generating the compact Ubuntu-kernel image and support explicit `ubuntu-server` paths.
- Modify `scripts/setup-ubuntu-kernel.sh`: accept an optional output directory so the same exact kernel assets can be emitted for both profiles.
- Modify `scripts/build_cosim_nic.sh`: treat `ubuntu-server` as an Ubuntu kernel/header source.
- Modify `Makefile`: select 2 GiB for `ubuntu-server`, retain the compact default, and document the new selector.
- Modify `setup.sh`: accept/build/import `ubuntu-server` and use profile-relative image paths.
- Modify `scripts/prepare-offline.sh`: stage/import metadata for both Ubuntu profiles, validate debug tools, and preserve old `--guest ubuntu|debian` behavior.
- Create `tests/integration/test_dpu_debugutils_build.sh`: static-build and provenance contract.
- Create `tests/integration/test_stage_guest_debugutils.sh`: root-directory installation contract.
- Create `tests/integration/test_ubuntu_server_profile.sh`: Makefile/setup/rootfs-builder contract.
- Create `tests/integration/test_offline_ubuntu_server.sh`: relocated offline import contract.
- Modify `tests/integration/CMakeLists.txt`: register the four fast tests.
- Modify `docs/GUEST-MANAGEMENT-SCP.md`: profile selection, tool use, and native/prebuilt driver workflows.

## Task 1: Import and build the debug utilities reproducibly

**Files:**

- Create: `third_party/dpu-debugutils/**`
- Create: `third_party/dpu-debugutils/SOURCE.md`
- Create: `scripts/build_dpu_debugutils.sh`
- Create: `tests/integration/test_dpu_debugutils_build.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write the failing static-build contract**

Create `tests/integration/test_dpu_debugutils_build.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-debugutils-test.XXXXXX")
trap 'rm -rf "$work"' EXIT

test -f "$repo/third_party/dpu-debugutils/SOURCE.md"
grep -Fq '1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab' \
    "$repo/third_party/dpu-debugutils/SOURCE.md"
test ! -e "$repo/third_party/dpu-debugutils/.git"

"$repo/scripts/build_dpu_debugutils.sh" "$work/out"
for tool in pci_debug reg_display; do
    test -x "$work/out/$tool"
    file "$work/out/$tool" | grep -Fq 'statically linked'
    if ldd "$work/out/$tool" 2>&1 | grep -Fq '=>'; then
        echo "FAIL: $tool has shared-library dependencies" >&2
        exit 1
    fi
    "$work/out/$tool" -h >"$work/$tool.help" 2>&1 || true
    grep -Fq 'Usage:' "$work/$tool.help"
done
echo '[dpu-debugutils-build] PASS'
```

Register it in `tests/integration/CMakeLists.txt` with a 60-second timeout.

- [ ] **Step 2: Run the new test and verify RED**

```bash
bash tests/integration/test_dpu_debugutils_build.sh
```

Expected: nonzero exit because the source marker and build script do not exist.

- [ ] **Step 3: Import the sanitized source snapshot from 53**

```bash
mkdir -p build/source-import third_party/dpu-debugutils
scp ubuntu@10.11.10.53:/home/ubuntu/workspace/dpu-debugutils.tar build/source-import/
printf '%s  %s\n' \
  '1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab' \
  'build/source-import/dpu-debugutils.tar' | sha256sum -c -
tar -xf build/source-import/dpu-debugutils.tar -C build/source-import \
  dpu-debugutils/README.md dpu-debugutils/Makefile \
  dpu-debugutils/pcie_debug dpu-debugutils/reg_display
cp -a build/source-import/dpu-debugutils/README.md \
      build/source-import/dpu-debugutils/Makefile \
      build/source-import/dpu-debugutils/pcie_debug \
      build/source-import/dpu-debugutils/reg_display \
      third_party/dpu-debugutils/
find third_party/dpu-debugutils \( -name .git -o -name '*.o' -o -name bin -o -name obj \)
```

Expected: the final `find` prints nothing. Remove generated outputs if present. Write `SOURCE.md` with the original path, SHA-256, branch `V2-DISPLAY-DEVELOP`, file list, and `.git`/`fpga` exclusions.

- [ ] **Step 4: Add the static build script**

Create `scripts/build_dpu_debugutils.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(dirname "$script_dir")
out=${1:-"$repo/build/guest_tools/dpu-debugutils"}
src="$repo/third_party/dpu-debugutils"
mkdir -p "$repo/build/tmp"
work=$(mktemp -d "$repo/build/tmp/dpu-debugutils.XXXXXX")
trap 'rm -rf "$work"' EXIT

for cmd in make gcc file install; do
    command -v "$cmd" >/dev/null || { echo "missing build dependency: $cmd" >&2; exit 1; }
done
test -f "$src/pcie_debug/Makefile"
test -f "$src/reg_display/Makefile"
cp -a "$src/." "$work/src/"
make -C "$work/src" clean >/dev/null 2>&1 || true
make -C "$work/src" -j"$(nproc)" LDFLAGS=-static LIBS='-lreadline -ltinfo'
install -d "$out"
install -m 0755 "$work/src/pcie_debug/bin/pci_debug" "$out/pci_debug"
install -m 0755 "$work/src/reg_display/bin/reg_display" "$out/reg_display"
for tool in pci_debug reg_display; do
    file "$out/$tool" | grep -Fq 'statically linked' || {
        echo "$tool is not statically linked" >&2
        exit 1
    }
done
printf 'built DPU debug utilities: %s\n' "$out"
```

- [ ] **Step 5: Run GREEN checks**

```bash
bash tests/integration/test_dpu_debugutils_build.sh
git diff --check
```

Expected: `[dpu-debugutils-build] PASS`.

- [ ] **Step 6: Commit**

```bash
git add third_party/dpu-debugutils scripts/build_dpu_debugutils.sh \
  tests/integration/test_dpu_debugutils_build.sh tests/integration/CMakeLists.txt
git commit -m "feat(guest): add static DPU debug utilities"
```

## Task 2: Stage debug utilities into either Guest type

**Files:**

- Create: `scripts/stage_guest_debugutils.sh`
- Create: `scripts/install_guest_debugutils.sh`
- Create: `tests/integration/test_stage_guest_debugutils.sh`
- Modify: `tests/integration/CMakeLists.txt`

- [ ] **Step 1: Write the failing staging test**

Create a fake root and fake static binaries, then invoke:

```bash
scripts/stage_guest_debugutils.sh \
  --root "$work/root" --bin-dir "$work/bin" \
  --source-dir third_party/dpu-debugutils
```

Assert executable files at `usr/local/bin/{pci_debug,reg_display}`, no source under `/opt`, and a usage note under `usr/local/share/doc/cosim-dpu-debugutils/`. Invoke again with `--include-source` and assert `/opt/dpu-debugutils/Makefile`. Supplying dynamically linked `/bin/true` must fail before the target root changes.

- [ ] **Step 2: Run RED**

```bash
bash tests/integration/test_stage_guest_debugutils.sh
```

Expected: missing staging script.

- [ ] **Step 3: Implement the root-directory helper**

Parse `--root`, `--bin-dir`, optional `--source-dir`, and `--include-source`. Validate both tools with `file ... | grep 'statically linked'` before the first installation. Install binaries mode 0755 and documentation mode 0644. With `--include-source`, replace only `$root/opt/dpu-debugutils`, copy the sanitized source tree, and remove generated `bin/` and `obj/`.

- [ ] **Step 4: Implement the ext4 wrapper**

`scripts/install_guest_debugutils.sh` accepts:

```text
--rootfs IMAGE --bin-dir DIR [--source-dir DIR] [--include-source]
```

It creates mount paths under `build/tmp`, mounts with `sudo -n -o loop`, calls the staging helper through `sudo -n`, always unmounts in a trap, and runs `sudo -n e2fsck -fy IMAGE` after unmounting. Reject a missing or non-ext4 image before mounting.

- [ ] **Step 5: Run tests and commit**

```bash
bash tests/integration/test_stage_guest_debugutils.sh
bash tests/integration/test_dpu_debugutils_build.sh
git diff --check
git add scripts/stage_guest_debugutils.sh scripts/install_guest_debugutils.sh \
  tests/integration/test_stage_guest_debugutils.sh tests/integration/CMakeLists.txt
git commit -m "feat(guest): stage debug tools into rootfs images"
```

## Task 3: Add the `ubuntu-server` profile contract

**Files:**

- Create: `tests/integration/test_ubuntu_server_profile.sh`
- Modify: `tests/integration/CMakeLists.txt`
- Modify: `Makefile`
- Modify: `setup.sh`
- Modify: `scripts/build_cosim_nic.sh`
- Modify: `scripts/setup-ubuntu-kernel.sh`

- [ ] **Step 1: Write the profile test**

The test verifies:

```bash
help=$(bash "$repo/setup.sh" --help)
grep -Fq 'ubuntu-server' <<<"$help"
make -s -C "$repo" info GUEST_TYPE=ubuntu-server \
  KERNEL=/bin/true ROOTFS=/bin/true | grep -Fq 'ubuntu-server'
make -s -pn -C "$repo" GUEST_TYPE=ubuntu-server | \
  grep -Eq '^GUEST_MEMORY[[:space:]]*[:?]?=[[:space:]]*2G$'
grep -Fq 'ubuntu|ubuntu-server)' "$repo/scripts/build_cosim_nic.sh"
scripts/setup-ubuntu-kernel.sh --dry-run 6.8.0-107-generic "$work/out" \
  | grep -Fq "$work/out"
test ! -e "$work/out"
```

- [ ] **Step 2: Run RED**

Expected: missing selector and unsupported `--dry-run`.

- [ ] **Step 3: Modify Makefile minimally**

```make
ifeq ($(GUEST_TYPE),ubuntu-server)
  GUEST_MEMORY ?= 2G
else ifeq ($(GUEST_TYPE),debian)
  GUEST_MEMORY ?= 512M
else
  GUEST_MEMORY ?= 256M
endif
```

Update help to `GUEST_TYPE=ubuntu|ubuntu-server|debian` and display the resolved Guest type in `make info`.

- [ ] **Step 4: Extend setup and kernel-header selection**

Add `ubuntu-server` to setup help, interactive selection, validation, import, and build routing. Use:

```bash
IMAGES_DIR="${PROJECT_DIR}/guest/images/${GUEST_TYPE}"
```

Import `guest/ubuntu-server/{vmlinuz,modules.tar.gz,rootfs.ext4}` to that relative path. Do not change the default from `ubuntu`.

Use `ubuntu|ubuntu-server)` in `build_cosim_nic.sh`. Extend `setup-ubuntu-kernel.sh` to accept:

```text
scripts/setup-ubuntu-kernel.sh [--dry-run] [KVER] [OUTPUT_DIR]
```

Keep `guest/images/ubuntu` as the default output for old callers.

- [ ] **Step 5: Run GREEN and regressions**

```bash
bash tests/integration/test_ubuntu_server_profile.sh
bash tests/integration/test_guest_ssh_provisioning.sh
bash tests/integration/test_qemu_management_nic.sh
bash tests/integration/test_qemu_time_mode.sh
bash -n setup.sh scripts/setup-ubuntu-kernel.sh scripts/build_cosim_nic.sh
git diff --check
```

- [ ] **Step 6: Commit**

```bash
git add Makefile setup.sh scripts/setup-ubuntu-kernel.sh scripts/build_cosim_nic.sh \
  tests/integration/test_ubuntu_server_profile.sh tests/integration/CMakeLists.txt
git commit -m "feat(guest): add Ubuntu Server profile selection"
```

## Task 4: Build a real Ubuntu Server 24.04 image

**Files:**

- Create: `scripts/build_rootfs_ubuntu_server.sh`
- Extend: `tests/integration/test_ubuntu_server_profile.sh`

- [ ] **Step 1: Add the rootfs dry-run contract**

```bash
COSIM_GUEST_SSH_PASSWORD=not-printed \
  scripts/build_rootfs_ubuntu_server.sh --dry-run "$work/images/ubuntu-server"
```

Assert output contains `noble`, `8G`, `6.8.0-107-generic`, `ubuntu-minimal`, `ubuntu-standard`, `build-essential`, `linux-headers-6.8.0-107-generic`, `libreadline-dev`, `/opt/dpu-debugutils`, `apt-daily.timer`, `apt-daily-upgrade.timer`, and `unattended-upgrades.service`. Assert the password is absent and no output directory was created.

- [ ] **Step 2: Run RED**

Expected: builder missing.

- [ ] **Step 3: Implement the builder**

The script must:

1. Require root except for `--dry-run` and require `debootstrap`, `truncate`, `mkfs.ext4`, `mount`, `chroot`, `tar`, and `e2fsck`.
2. Keep every work/mount path under `${PROJECT_DIR}/build/tmp`; trap and unmount `dev/pts`, `dev`, `proc`, `sys`, and root in reverse order.
3. Ensure `guest/images/ubuntu/{vmlinuz,modules.tar.gz}` exists, invoking `setup-ubuntu-kernel.sh 6.8.0-107-generic` only when necessary.
4. Create the image with `truncate -s 8G` and `mkfs.ext4 -F`, never by writing eight GiB of zeros.
5. Run `debootstrap --variant=minbase noble ROOT http://archive.ubuntu.com/ubuntu` and configure Noble, Noble updates, and Noble security.
6. Install exactly:

```text
ubuntu-minimal ubuntu-standard systemd systemd-sysv openssh-server sudo
build-essential git bc flex bison pkg-config libelf-dev libreadline-dev
linux-headers-6.8.0-107-generic pciutils kmod iproute2 iputils-ping
ethtool tcpdump curl wget vim-tiny less file ca-certificates
```

7. Extract `modules.tar.gz`, run `depmod -b ROOT 6.8.0-107-generic`, and verify `/lib/modules/6.8.0-107-generic/build/Makefile`.
8. Configure hostname, serial getty, `/dev/vda` fstab, `ryan` user/sudo/password from `COSIM_GUEST_SSH_PASSWORD`, SSH password auth, and the e1000e networkd profile.
9. Copy the cosim overlay and run `stage_guest_debugutils.sh --include-source`.
10. Enable SSH/networkd; mask cloud-init when installed, APT timers, and unattended upgrades; clean APT data.
11. Copy `vmlinuz`, unmount, run `e2fsck -fy`, and restore output ownership to `SUDO_USER`.

- [ ] **Step 4: Run fast tests**

```bash
bash tests/integration/test_ubuntu_server_profile.sh
bash -n scripts/build_rootfs_ubuntu_server.sh
git diff --check
```

- [ ] **Step 5: Commit**

```bash
git add scripts/build_rootfs_ubuntu_server.sh tests/integration/test_ubuntu_server_profile.sh
git commit -m "feat(guest): build Ubuntu Server 24.04 image"
```

## Task 5: Integrate tools into compact-image build paths

**Files:**

- Modify: `scripts/build_rootfs_debian.sh`
- Modify: `scripts/inject-modules.sh`
- Extend: `tests/integration/test_stage_guest_debugutils.sh`

- [ ] **Step 1: Add failing call-site assertions**

Assert both image builders invoke `build_dpu_debugutils.sh` and `stage_guest_debugutils.sh`, and `inject-modules.sh` invokes `install_guest_debugutils.sh` after module injection.

- [ ] **Step 2: Run RED**

Expected: call-site assertions fail.

- [ ] **Step 3: Update compact image construction**

Before Debian rootfs construction:

```bash
"${PROJECT_DIR}/scripts/build_dpu_debugutils.sh"
```

While mounted:

```bash
"${PROJECT_DIR}/scripts/stage_guest_debugutils.sh" \
  --root "$MOUNT_DIR" \
  --bin-dir "${PROJECT_DIR}/build/guest_tools/dpu-debugutils"
```

After module injection and filesystem closure, use `install_guest_debugutils.sh` on the destination image. This retrofits old Debian bases and guarantees the compact `ubuntu` image contains both tools.

- [ ] **Step 4: Run and commit**

```bash
bash tests/integration/test_stage_guest_debugutils.sh
bash tests/integration/test_inject_modules_debugfs_paths.sh
bash -n scripts/build_rootfs_debian.sh scripts/inject-modules.sh
git diff --check
git add scripts/build_rootfs_debian.sh scripts/inject-modules.sh \
  tests/integration/test_stage_guest_debugutils.sh
git commit -m "feat(guest): install debug tools in compact images"
```

## Task 6: Extend offline packaging and relocated import

**Files:**

- Create: `tests/integration/test_offline_ubuntu_server.sh`
- Modify: `tests/integration/CMakeLists.txt`
- Modify: `scripts/prepare-offline.sh`
- Modify: `setup.sh`

- [ ] **Step 1: Write the failing relocated-import test**

Create a small ZIP fixture containing text placeholders at:

```text
guest/ubuntu/vmlinuz
guest/ubuntu/rootfs.ext4
guest/ubuntu-server/vmlinuz
guest/ubuntu-server/modules.tar.gz
guest/ubuntu-server/rootfs.ext4
offline-meta.env
```

Metadata is:

```text
OFFLINE_VERSION=3
OFFLINE_GUEST_TYPE=ubuntu-server
OFFLINE_KVER=6.8.0-107-generic
OFFLINE_HAS_UBUNTU_ROOTFS=true
OFFLINE_HAS_UBUNTU_SERVER_ROOTFS=true
OFFLINE_UBUNTU_SERVER_HAS_HEADERS=true
OFFLINE_DPU_DEBUGUTILS_SHA256=1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab
```

Move the ZIP and MD5 sidecar to another directory and run:

```bash
"$test_project/setup.sh" --import "$relocated/archive.zip" --import-only
```

Assert both Guest directories import below the new project, no original absolute path appears, and no `.ko` appears.

- [ ] **Step 2: Run RED**

Expected: `guest/ubuntu-server` not imported.

- [ ] **Step 3: Extend the packager compatibly**

Accept `--guest ubuntu-server`, stage `guest/ubuntu-server`, and copy its artifacts when present. Preserve old `--guest ubuntu|debian`. When `--guest ubuntu-server` is selected, require complete compact and server images, guaranteeing the new deliverable contains both without breaking old workflows.

Mount selected rootfs images read-only and require `/usr/local/bin/{pci_debug,reg_display}`. Additionally require these in Ubuntu Server:

```text
/etc/os-release: ID=ubuntu, VERSION_ID="24.04"
/usr/bin/gcc
/usr/bin/make
/usr/src/linux-headers-6.8.0-107-generic/Makefile
/lib/modules/6.8.0-107-generic/build
/opt/dpu-debugutils/Makefile
```

Emit `OFFLINE_VERSION=3` and the tested metadata. Do not include a custom driver unless existing `--custom-driver` is supplied.

- [ ] **Step 4: Extend import/build routing**

Import `guest/ubuntu-server/*` relative to `PROJECT_DIR`. If setup selects an absent Ubuntu Server image, invoke `build_rootfs_ubuntu_server.sh`; never derive it from the compact image. Keep no-auto-load behavior.

- [ ] **Step 5: Run GREEN and regressions**

```bash
bash tests/integration/test_offline_ubuntu_server.sh
bash tests/integration/test_offline_custom_driver.sh
bash tests/integration/test_offline_qemu_archive.sh
bash -n setup.sh scripts/prepare-offline.sh
git diff --check
```

- [ ] **Step 6: Commit**

```bash
git add setup.sh scripts/prepare-offline.sh \
  tests/integration/test_offline_ubuntu_server.sh tests/integration/CMakeLists.txt
git commit -m "feat(offline): package both Ubuntu Guest profiles"
```

## Task 7: Document workflows and run the fast suite

**Files:**

- Modify: `docs/GUEST-MANAGEMENT-SCP.md`

- [ ] **Step 1: Document exact commands**

```bash
make run-qemu GUEST_TYPE=ubuntu MGMT_SSH_PORT_BASE=2222
make run-qemu GUEST_TYPE=ubuntu-server MGMT_SSH_PORT_BASE=2222

ssh -p 2222 ryan@127.0.0.1
sudo pci_debug -s 01:00.0 -b 0
sudo reg_display -s 01:00.0 -b 0

scp -P 2222 host-driver-net-pf0only-vnetcache.tar.gz ryan@127.0.0.1:/tmp/
ssh -p 2222 ryan@127.0.0.1
cd /tmp
tar -xf host-driver-net-pf0only-vnetcache.tar.gz
cd host-driver-net
make KERNELDIR=/lib/modules/$(uname -r)/build CFLAGS=-UDPU_LACP
modinfo ./dpu_snd1.ko | grep vermagic
sudo insmod ./dpu_snd1.ko
```

State that QEMU uses `-snapshot`, port 2222 is management rather than `PORT_BASE`, BAR access needs sudo, and no DPU module loads automatically.
State that `CFLAGS=-UDPU_LACP` skips the Linux 6.8-incompatible bundled LACP
compatibility sources and uses system bonding; this workflow is not a bare
`make KERNELDIR=...` build.

- [ ] **Step 2: Run all fast tests**

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
bash tests/integration/test_dpu_debugutils_build.sh
bash tests/integration/test_stage_guest_debugutils.sh
bash tests/integration/test_ubuntu_server_profile.sh
bash tests/integration/test_offline_ubuntu_server.sh
git diff --check
```

- [ ] **Step 3: Commit**

```bash
git add docs/GUEST-MANAGEMENT-SCP.md
git commit -m "docs: describe Ubuntu Server driver workflow"
```

## Task 8: Build and inspect both real images on 53

**Artifacts:**

- Generate: `guest/images/ubuntu/{vmlinuz,modules.tar.gz,rootfs.ext4}`
- Generate: `guest/images/ubuntu-server/{vmlinuz,modules.tar.gz,rootfs.ext4}`

- [ ] **Step 1: Sync to a clean 53 worktree and check VCS**

Use `/home/ubuntu/test_cosim/worktrees/ubuntu-server-debugutils`, then:

```bash
bash -lc 'cd /home/ubuntu/test_cosim/worktrees/ubuntu-server-debugutils && \
  git status --short && source ~/.bashrc && vcs -ID'
```

Expected: clean worktree and a VCS version.

- [ ] **Step 2: Build tools and retrofit compact image**

```bash
cd /home/ubuntu/test_cosim/worktrees/ubuntu-server-debugutils
scripts/build_dpu_debugutils.sh
scripts/install_guest_debugutils.sh \
  --rootfs guest/images/ubuntu/rootfs.ext4 \
  --bin-dir build/guest_tools/dpu-debugutils
```

Record before/after rootfs SHA-256; require clean `e2fsck -fn`.

- [ ] **Step 3: Build Ubuntu Server**

```bash
read -rsp 'Guest password: ' COSIM_GUEST_SSH_PASSWORD
echo
export COSIM_GUEST_SSH_PASSWORD
sudo -n --preserve-env=COSIM_GUEST_SSH_PASSWORD \
  scripts/build_rootfs_ubuntu_server.sh guest/images/ubuntu-server
unset COSIM_GUEST_SSH_PASSWORD
```

Expected: all three artifacts exist, rootfs is sparse, and `e2fsck -fn` is clean.

- [ ] **Step 4: Inspect both images offline**

Mount each read-only below `build/tmp`. Confirm both static tools. For Ubuntu Server also check OS identity, GCC/Make, exact headers, `/opt/dpu-debugutils`, SSH/network units, and disabled timers. Confirm neither image contains `dpu_snd1.ko`, DPU modprobe config, or an autoload service.

## Task 9: Boot validation, native driver build, and VCS BAR read

**Artifacts:**

- Driver source: `/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net-pf0only-vnetcache.tar.gz`
- Logs: `/home/ubuntu/test_cosim/builds/ubuntu-server-debugutils-validation-20260806/`

- [ ] **Step 1: Boot both profiles without cosim for OS checks**

Use the built QEMU with `-snapshot`, icount, root disk, e1000e, and ports 22345/22346; omit the cosim device. Wait for SSH and capture:

```bash
cat /etc/os-release
uname -r
command -v pci_debug reg_display
make --version | head -1 || true
gcc --version | head -1 || true
lsmod | grep dpu_snd1 || true
```

Expected: both profiles have tools and no DPU module; only server must report Ubuntu 24.04 and compiler tools.

- [ ] **Step 2: Validate native builds in Ubuntu Server**

SCP debug and driver source. Rebuild debug programs, compile C/C++ smoke programs, then:

```bash
make KERNELDIR=/lib/modules/$(uname -r)/build CFLAGS=-UDPU_LACP
test "$(modinfo -F vermagic ./dpu_snd1.ko | awk '{print $1}')" = "$(uname -r)"
modinfo ./dpu_snd1.ko | grep -F 'pci:v000020F9d00005011'
if modinfo ./dpu_snd1.ko | grep -Fq 'pci:v000020F9d00005012'; then exit 1; fi
```

`CFLAGS=-UDPU_LACP` selects system bonding instead of compiling the bundled LACP
compatibility sources that are incompatible with Linux 6.8.

Expected: matching vermagic, PF0 alias present, PF1 absent.

- [ ] **Step 3: Compile the VCS cosim test in a login shell**

```bash
source ~/.bashrc
scripts/build_cosim_lib.sh
mkdir -p build/ubuntu-server-vcs
vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  +define+PCIE_COSIM_ENABLE \
  -CFLAGS "-I bridge/common -I bridge/vcs" \
  -LDFLAGS "-Wl,--whole-archive $PWD/build/lib/libcosim_bridge.a -Wl,--no-whole-archive -lrt -lpthread" \
  -f pcie_tl_vip/sim/filelist_cosim.f \
  -o build/ubuntu-server-vcs/simv_cosim \
  -l build/ubuntu-server-vcs/compile.log
```

The archive path must remain absolute because VCS performs the final link from
its generated `csrc/` directory.

Expected: zero compile errors.

- [ ] **Step 4: Run QEMU and VCS together**

QEMU:

```bash
make run-qemu GUEST_TYPE=ubuntu-server CONSOLE=file \
  PORT_BASE=28100 MGMT_SSH_PORT_BASE=22347 NUM_PFS=1 TAG_BIT=8
```

VCS:

```bash
build/ubuntu-server-vcs/simv_cosim \
  +UVM_TESTNAME=pcie_tl_cosim_test +COSIM +COSIM_AUTOSTART \
  +REMOTE_HOST=127.0.0.1 +PORT_BASE=28100 +INSTANCE_ID=0 \
  +BYPASS_CONFIG=1 +CFG_PROFILE=DPU_20F9_501X \
  +NUM_PFS=1 +MAX_VFS=16 +NUM_VFS=0 +TAG_BIT=8 \
  +UVM_VERBOSITY=UVM_MEDIUM \
  -l build/ubuntu-server-vcs/run.log
```

This is a non-interactive batch run, so it opts in to `+COSIM_AUTOSTART`
instead of waiting for the staged UCLI `start_cosim` event.

Expected: Guest enumerates `0000:01:00.0 [20f9:5011]` without tag-map/completion errors before smoke actions.

- [ ] **Step 5: Load driver and run a read-only BAR command**

```bash
sudo insmod /tmp/dpu_snd1.ko
lsmod | grep dpu_snd1
lspci -Dnn -d 20f9:5011
printf 'bar0\nd32 0 1\n' >/tmp/pci-read.cmd
sudo pci_debug -s 01:00.0 -b 0 -f /tmp/pci-read.cmd -q -v 3
```

Capture Guest/QEMU/VCS logs. Acceptance requires a Memory Read in VCS, completion at QEMU, and no endian reversal. Unload and stop both processes cleanly.

## Task 10: Produce and relocate-test the offline archive

**Artifact directory:**

`/home/ubuntu/test_cosim/builds/qemu-vcs-offline-ubuntu-server-debugutils-20260806/`

- [ ] **Step 1: Build the no-driver archive**

```bash
out=/home/ubuntu/test_cosim/builds/qemu-vcs-offline-ubuntu-server-debugutils-20260806
mkdir -p "$out"
scripts/prepare-offline.sh --guest ubuntu-server --skip-rootfs \
  --output "$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip"
(cd "$out" && sha256sum qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip \
  >qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip.sha256)
```

Do not supply `--custom-driver`.

- [ ] **Step 2: Validate archive**

```bash
unzip -t "$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip"
(cd "$out" && md5sum -c qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip.md5)
(cd "$out" && sha256sum -c qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip.sha256)
unzip -Z1 "$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip" \
  | grep -E '^guest/(ubuntu|ubuntu-server)/'
if unzip -Z1 "$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip" \
    | grep -Eq 'dpu_snd1\.ko|custom-driver/[^/]+$'; then exit 1; fi
```

- [ ] **Step 3: Import under another absolute path**

```bash
verify="$out/import-check"
mkdir -p "$verify"
cd "$verify"
unzip -q "$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip" setup.sh
chmod +x setup.sh
./setup.sh --import "$out/qemu-vcs-offline-ubuntu-server-debugutils-20260806.zip" --import-only
```

Verify both image directories, no original path, and repeat both boot/tool smoke checks.

- [ ] **Step 4: Record evidence**

Save commits, image hashes, archive hashes/size, `e2fsck`, OS identity, tools, native module build/vermagic, enumeration, BAR read, VCS log, and relocated-import output as `validation-summary.txt`.

## Task 11: Final regression review and publication

- [ ] **Step 1: Run the complete 53 regression set**

```bash
source ~/.bashrc
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
bash tests/sv/run_test_dpu_501x_profile.sh
bash tests/sv/run_test_runtime_bdf_utils.sh
git diff --check
git status --short
```

Expected: all pass; only ignored generated artifacts exist.

- [ ] **Step 2: Review scope**

Confirm default compact Guest, icount, management NIC, no-driver behavior, PCIe topology, cfg bypass, tag width, and VCS transaction logic are unchanged. Confirm no image, ZIP, password, token, or nested `.git` is staged.

- [ ] **Step 3: Push**

```bash
git push origin feature/qemu-vcs-isolated-tcp
```

Report remote commit, archive/checksum paths, validation evidence, and launch commands.
