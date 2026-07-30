# MPS/RCB Long-Read Completion Design

## Goal

Verify and enforce PCIe completion fragmentation for long Memory Read requests
in both directions of the TL VIP.

## Scope

The regression sweeps MPS values 128, 256, 512, 1024, 2048, and 4096 bytes
against both PCIe Read Completion Boundary values, 64 and 128 bytes.  Each
case sends long reads from offsets that are RCB-aligned and immediately before
an RCB boundary.

For every Completion with data, the checker requires all of the following:

1. payload length is no greater than the configured MPS;
2. the payload does not cross a configured RCB boundary;
3. `lower_addr` identifies the first byte of that Completion;
4. `byte_count` represents the remaining request bytes; and
5. all Completion payloads concatenate to the requested data stream.

The test exercises RC-to-EP reads (EP Completion generation) and EP-to-RC
reads (RC Completion generation).  It does not use the QEMU MMIO path because
normal CPU MMIO callbacks are at most eight bytes and cannot originate a
single long PCIe Memory Read TLP.

## Completion Rule

At every iteration, not only the first Completion, the generated payload size
is:

`min(remaining_bytes, mps_bytes, bytes_to_next_rcb_boundary)`.

This rule is shared semantically by `pcie_tl_ep_driver`, `pcie_tl_rc_driver`,
and the legacy RC auto-responder in `pcie_tl_env`.

## Acceptance

The MPS/RCB matrix must run on the VCS host with zero UVM errors or fatals.
It must report all 12 configurations, both directions, and no boundary,
length, byte-count, lower-address, or data-integrity violation.
