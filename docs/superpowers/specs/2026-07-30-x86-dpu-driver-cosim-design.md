# x86 DPU Driver CoSim Design

## Goal

Rebuild the supplied `host-driver-net` source for the existing x86_64 Guest
(`6.8.0-107-generic`), inject both required modules, and probe it through the
QEMU/VCS DPU configuration-space path.

## Decisions

- The default x86 stub-driver flow remains unchanged.
- The supplied ARM64 `.ko` is never injected. Only modules rebuilt with the
  exact Guest header tree are accepted.
- Archive entries with absolute paths or `..` components are rejected before
  extraction. The archive must have one `host-driver-net/` source root.
- The builder must produce both `dpu_snd1.ko` and `bonding/bonding.ko`, prove
  they are x86-64, and prove their `vermagic` starts with the Guest release.
- A custom bundle is written below `/lib/modules/cosim-drivers/dpu_snd1/`.
  The boot hook loads `bonding.ko` first and then `dpu_snd1.ko` by pathname,
  avoiding an ambiguous distribution module named `bonding`.
- `setup.sh --driver custom --ko <path>` retains single-`.ko` compatibility.
  A `.tar.gz` path invokes the DPU builder and bundle injector. The optional
  `CUSTOM_DRIVER_KDIR` variable selects an exact cached header tree.

## CoSim Startup and Profile Evidence

The VCS driver intentionally waits for UCLI `start_cosim`; `+COSIM` alone does
not open TCP. `+AUTO_START_COSIM` will be an opt-in control that has RC0 call
`notify_start(-1)` after run-phase registration. After topology creation the
driver logs the selected profile and PF0 identity. The earlier Config Proxy
creation log is not evidence because it predates its function-manager binding.

## Verification

1. Shell tests reject malicious archives and validate a two-module bundle.
2. The real archive rebuilds with exact `6.8.0-107-generic` headers.
3. A disposable rootfs contains both modules and ordered custom config.
4. VCS with `+CFG_PROFILE=DPU_20F9_501X +AUTO_START_COSIM` logs `20f9:5011`
   and connects to QEMU.
5. The Guest exposes `[20f9:5011]` and loads the rebuilt modules without a
   vermagic or architecture error.

## Non-goals

This does not emulate DUT data-plane registers, assert link-up, change ARM64
support, or change legacy PCI profiles.
