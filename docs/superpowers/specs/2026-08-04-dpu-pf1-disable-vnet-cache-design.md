# DPU PF1 Disable and VNET Cache Design

## Goal

Produce an importable `dpu_snd1.ko` that binds the DPU PF0 device (`20f9:5011`) only and avoids repeated reads of `GREG_INFO_VNET_SPEC_REG` during PF0 initialization.

## Changes

`main.c` removes the `DPU_DEVICE_ID_PF1` (`20f9:5012`) entry from `dpu_id_table`. Linux PCI matching therefore never invokes this driver's probe path for PF1. PF0 remains listed, while PF2 and PF3 remain unsupported as in the baseline.

`common.h` changes `dpu_get_vnet_num()` to retain the first non-zero VNET queue count in a function-local static `u16`. The cache is intentionally module-wide because the resulting driver binds PF0 only.

## Validation

The build must use the Ubuntu `6.8.0-107-generic` headers and project-local `build/tmp` workspace on 53. The resulting module must have the PF0 PCI modalias, no PF1 modalias, and matching `vermagic`. Source and module SHA-256 entries are included in the new release manifest.
