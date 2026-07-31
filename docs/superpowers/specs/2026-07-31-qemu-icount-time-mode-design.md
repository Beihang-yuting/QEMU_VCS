# QEMU iCount Time Mode Design

## Goal

Add an opt-in QEMU time mode for real-DUT/VCS co-simulation.  It prevents a
synchronous BAR-read wait on a VCS Completion from advancing Guest virtual
time and exhausting the real driver's guest-time polling deadlines.

## Interface

`make run-qemu QEMU_TIME_MODE=icount` enables the mode.  The default is
`QEMU_TIME_MODE=realtime`, which emits exactly the existing QEMU command line.
Only `realtime` and `icount` are accepted; any other value fails before QEMU is
started.

## Launch behavior

When `QEMU_TIME_MODE=icount`, every `run-qemu` console variant appends:

```text
-accel tcg -icount shift=auto,align=off,sleep=off
```

TCG is explicit because iCount is not compatible with a KVM accelerator.
`align=off` prevents host wall-clock waiting on a VCS Completion from advancing
Guest time.  `sleep=off` keeps the co-simulation Guest from adding a host-time
sleep to its virtual-timer behavior.  `shift=auto` lets QEMU select a practical
instruction-to-virtual-clock scale.

The mode does not change `MMIO_TIMEOUT_MS`: it remains a host-time upper bound
for a missing Completion, not a driver-timeout mechanism.  A missing or invalid
Completion must still be fixed in VCS/DUT.

## Verification

A shell integration test uses `make -n run-qemu` for `login`, `login-multi`,
and `file` console modes.  It proves that realtime commands do not contain an
iCount option, and iCount commands contain the exact accelerator and iCount
arguments once.  It also runs the validation target with valid and invalid
mode values.

On 10.11.10.53, QEMU 9.2 command-line parsing is checked with `-machine none`.
The real-DUT validation uses the fixed-QID external driver bundle, an isolated
Guest image copy, and the external VCS flow.  The comparison records Driver
load progress, BAR-read/Completion traffic, and whether driver guest-time
timeouts occur with the same VCS response behavior.
