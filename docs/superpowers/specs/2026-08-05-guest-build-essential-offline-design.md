# Guest Build-Essential Offline Package Design

## Goal

Produce a new QEMU-VCS offline package whose Ubuntu Guest can compile ordinary
C and C++ programs with GNU Make, while preserving the current icount and
loopback-only SSH/SCP behavior and excluding the custom DPU driver.

## Selected approach

Extend the existing Guest provisioning script so that every image provisioned
through it installs `build-essential` together with `openssh-server` and
`sudo`. This keeps the image content reproducible; directly modifying only one
rootfs would make the next provisioned image lose the compiler toolchain.

The package will contain the updated Ubuntu rootfs. It will not contain a
custom DPU driver, a custom-driver archive, or a service that automatically
loads such a driver. Matching Guest kernel headers are outside this change, so
the toolchain supports normal user-space C/C++ builds but does not promise
in-Guest kernel-module builds.

## Code and image changes

- Update `tests/integration/test_guest_ssh_provisioning.sh` first so its dry-run
  contract requires `build-essential`.
- Update `scripts/provision_guest_ssh.sh` to install and report
  `build-essential`.
- Run that script against `guest/images/ubuntu/rootfs.ext4` on the VCS host
  `10.11.10.53`.
- Leave QEMU launch networking, icount settings, topology, tag settings, and
  PCIe/VCS behavior unchanged.

## Validation

The implementation is accepted only when all of the following are observed on
`10.11.10.53`:

1. The provisioning integration test fails before the script change and passes
   after it.
2. The updated Guest boots and can be reached through the existing host-only
   SSH forwarding.
3. Inside the Guest, `make --version`, `gcc --version`, `g++ --version`, and
   `ld --version` succeed.
4. A small C program is compiled with Make and runs successfully.
5. SCP transfers a temporary file from the host to the Guest and the content
   matches.
6. The offline archive passes ZIP, MD5, and SHA256 checks.
7. Archive inspection finds no custom DPU driver payload or kernel module.

## Deliverables

Create a new dated build directory under `/home/ubuntu/test_cosim/builds/`
containing the ZIP archive, its MD5 file, and its SHA256 file. Keep older source
trees untouched; the new archive is produced from the current clean project at
commit `dead865f20b4` plus this reproducible provisioning change.
