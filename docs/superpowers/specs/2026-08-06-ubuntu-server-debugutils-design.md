# Ubuntu Server Guest and DPU Debug Utilities Design

## Goal

Add a real Ubuntu Server Guest without changing the behavior of the existing
compact Guest, and make the DPU PCIe debug utilities available by default in
both Guests. The new Ubuntu Server Guest must also be able to build an external
kernel module for its running kernel entirely offline.

The existing `GUEST_TYPE=ubuntu` remains the default. Although that image uses
an Ubuntu kernel, its user space is Debian 12 minbase; this design calls it the
compact Guest to avoid implying that it is a full Ubuntu installation. The new
profile is selected explicitly with `GUEST_TYPE=ubuntu-server`.

## Verified baseline

- The compact Guest currently runs Ubuntu kernel `6.8.0-107-generic` over a
  Debian 12 minbase root filesystem.
- The current compact image does not contain `gcc`, `g++`, `make`, binutils,
  `libreadline-dev`, or matching kernel headers. It therefore cannot currently
  build `dpu-debugutils` or an out-of-tree kernel module.
- The source archive on the VCS host is
  `/home/ubuntu/workspace/dpu-debugutils.tar`, SHA-256
  `1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab`.
- That archive builds two x86-64 programs successfully on `10.11.10.53`:
  `pci_debug` and `reg_display`.
- `pci_debug` links with readline. Both tools can be linked statically on the
  VCS host by adding `-static` and linking `-lreadline -ltinfo`; the resulting
  executables do not depend on Guest shared-library versions.
- The VCS host itself is Ubuntu 20.04 with kernel 5.15 and GCC 9. The existing
  `dpu_snd1.ko` was nevertheless built there for `6.8.0-107-generic` by using
  the target kernel headers. This demonstrates that the build host distribution
  and running host kernel do not need to match the Guest.

## Selected architecture

### Guest profiles

The project will expose these two profiles:

| Profile | User space | Kernel | Intended use |
| --- | --- | --- | --- |
| `ubuntu` | Existing Debian 12 minbase | `6.8.0-107-generic` | Fast, compact simulation Guest |
| `ubuntu-server` | Ubuntu Server 24.04 Noble | `6.8.0-107-generic` | Interactive development and in-Guest driver builds |

The compact profile retains its current boot flow, memory default, networking,
icount behavior, PCIe topology, package-provisioning policy, and no-driver
default. The debug-utility integration adds only the prebuilt executables and
associated documentation; it does not add kernel headers or promise native
kernel-module builds. The already committed `build-essential` provisioning for
ordinary user-space C/C++ builds remains intact.

The Ubuntu Server profile uses an 8 GiB sparse ext4 image and defaults to 2 GiB
of Guest RAM. It reuses the exact `6.8.0-107-generic` kernel and module tree
already supported by the project. Its package set includes:

- `ubuntu-minimal`, `ubuntu-standard`, systemd, OpenSSH, and sudo;
- `build-essential`, git, bc, flex, bison, pkg-config, and `libelf-dev`;
- `linux-headers-6.8.0-107-generic` and its matching common header package;
- `libreadline-dev`, pciutils, kmod, iproute2, ethtool, tcpdump, and common
  troubleshooting utilities.

`/lib/modules/6.8.0-107-generic/build` must resolve to the installed matching
headers. The rootfs build fails if `uname` metadata, module tree, and headers do
not all name the same kernel release.

To avoid simulated-time noise and unwanted traffic, cloud-init, apt daily
timers, unattended upgrades, and other periodic package jobs are disabled in
the generated image. The management e1000e NIC, loopback-only SSH forwarding,
`ryan` management account, serial console, default icount mode, and `-snapshot`
semantics remain unchanged. No DPU driver is installed or loaded automatically.

### DPU debug utilities

The repository will contain a sanitized source snapshot of the required
`dpu-debugutils` files, excluding the archive's embedded `.git` directory and
FPGA-only content. Provenance and the source archive checksum are recorded next
to the snapshot.

A dedicated build script produces statically linked x86-64 binaries:

```text
build/guest_tools/dpu-debugutils/pci_debug
build/guest_tools/dpu-debugutils/reg_display
```

Both Guest images install them as:

```text
/usr/local/bin/pci_debug
/usr/local/bin/reg_display
```

The Ubuntu Server image additionally installs the sanitized source tree at
`/opt/dpu-debugutils`, so the user can modify and rebuild it natively. The
compact image contains only the binaries and a short usage note. BAR access is
performed through `/sys/bus/pci/devices/<BDF>/resourceN`, so normal operation
requires root privileges, for example:

```bash
sudo pci_debug -s 01:00.0 -b 0
sudo reg_display -s 01:00.0 -b 0
```

Static linking is used for the installed copies so that readline and glibc
versions cannot make the same binary work in one Guest but fail in the other.

### Driver build workflows

Kernel-module compatibility is determined by the target architecture, running
kernel release, kernel configuration and symbol versions, rather than by the
distribution release of the machine performing the build.

The Ubuntu Server Guest supports native builds:

```bash
tar -xf host-driver-net-pf0only-vnetcache.tar.gz
cd host-driver-net
make KERNELDIR=/lib/modules/$(uname -r)/build
modinfo ./dpu_snd1.ko | grep vermagic
sudo insmod ./dpu_snd1.ko
```

The compact Guest does not promise in-Guest module builds. It continues to use
the existing workflow in which `10.11.10.53` builds against the exact Guest
headers and the resulting `.ko` is copied through the management SSH port.
This keeps the compact image small and avoids duplicating the purpose of the
Ubuntu Server profile.

The PF0-only/QID128 driver remains a separately managed artifact. Adding the
Ubuntu Server profile does not embed it, auto-probe it, or change its logging.

## Setup and offline packaging

`setup.sh`, the Makefile, the offline packager, and the offline importer accept
`ubuntu-server` everywhere that currently accepts `ubuntu` or `debian`.

The build flow adds a dedicated Ubuntu Server rootfs builder. It uses Noble
repositories while network access is available, installs all packages and
matching headers into the image, injects the existing kernel modules and cosim
overlay, builds/installs the debug utilities, then removes package caches.

The final offline archive contains both `guest/ubuntu` and
`guest/ubuntu-server`, allowing the imported project to select either profile
without network access or a second import. Existing Debian image handling is
left intact. The importer uses only paths relative to the imported project and
does not depend on any `/home/ubuntu/test_cosim/...` build path.

Runtime selection is:

```bash
make run-qemu                         # existing compact Guest
make run-qemu GUEST_TYPE=ubuntu-server
```

The packager rejects an image if either required debug executable is absent.
It also records the Guest type, kernel release, debug-utility source checksum,
and whether kernel headers are present in `offline-meta.env`.

## Failure handling

- Fail the Ubuntu Server build when the requested Noble packages or exact
  kernel headers cannot be obtained; do not silently substitute another
  release.
- Fail the debug-utility build when static readline/tinfo dependencies are
  unavailable or either output is dynamically linked.
- Fail packaging when a selected image is missing its kernel, rootfs, module
  tree, or debug executables.
- Fail the in-Guest driver-build smoke test when `modinfo` reports a vermagic
  different from `uname -r`.
- Do not enable automatic driver loading as a fallback. Driver load failures
  must remain visible to the user.

## Validation

All simulation validation runs on `10.11.10.53` in a login shell so that the
VCS environment and license settings from `~/.bashrc` are active.

1. Shell tests cover `ubuntu-server` option parsing, Makefile memory selection,
   offline staging/import paths, and required artifact checks.
2. Offline inspection verifies OS identity, kernel/module/header agreement,
   compiler tools, debug binaries, management SSH configuration, disabled
   background services, and absence of an automatically installed DPU module.
3. Boot both profiles and verify serial login plus host-only SSH/SCP.
4. In both profiles, run `pci_debug -h` and `reg_display -h`.
5. In Ubuntu Server, compile and run a C and C++ smoke program, rebuild the
   debug utilities from `/opt/dpu-debugutils`, and build the PF0-only/QID128
   driver source against `/lib/modules/$(uname -r)/build`.
6. Confirm the built module's vermagic is `6.8.0-107-generic`, load it in a
   QEMU/VCS run with the simulated device, and capture `lspci`, `lsmod`, and
   `dmesg` evidence.
7. Perform a read-only BAR smoke operation with `pci_debug` against the
   enumerated PF0 BDF and confirm the transaction reaches the VCS side.
8. Generate the offline archive, test archive integrity and checksums, import
   it under a different absolute directory, and repeat boot/SSH/tool checks.

## Non-goals

- Converting the existing compact Guest user space into Ubuntu.
- Adding ARM64 Guest support.
- Automatically installing or loading the custom DPU driver.
- Changing PCIe topology, BDF assignment, BAR sizing, tag width, cfg bypass,
  icount policy, or VCS transaction behavior.
- Including desktop packages or a graphical environment.
