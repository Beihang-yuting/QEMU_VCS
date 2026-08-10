# DPU periodic ETH scan bypass design

Date: 2026-08-10

Status: written, pending user review

## 1. Problem statement

The real-DUT co-simulation driver runs two service work items once per second.
Before useful virtio traffic starts, these workers repeatedly read Ethernet
status through QEMU, the TCP bridge, the PCIe VIP, and VCS. A single register
access is inexpensive on hardware but expensive in co-simulation, so the
polling consumes substantial simulation time even when the two DUT Ethernet
interfaces are connected directly and their physical module state is not part
of the test.

The active driver baseline is the previously delivered 128-QID, PF0-only,
VNET-cache source tree:

```text
/home/ubuntu/test_cosim/releases/
  dpu-qid128-pf0only-vnetcache-20260804/source/host-driver-net
```

The periodic path is:

```text
dpu_service_timer()                  once per HZ (currently one second)
  -> dpu_service_task_schedule()
     -> serv_task1
        -> dpu_optical_link_subtask()
     -> serv_task2
        -> dpu_process_eth_status_subtask()
```

`dpu_optical_link_subtask()` starts by reading
`INTF_ETH0_ZSFP_STATUS_REG_ADDR` (`BAR0 + 0x0c0002c`) and can continue into
module-speed, I2C, LOS, and link-fault accesses. `dpu_process_eth_status_subtask()`
reads `INTF_ETH0_STATUS_REG_ADDR` (`BAR0 + 0x0c00024`) on every invocation.

The timer and workqueues must remain active because the same service tasks also
purge mailbox events, notify virtqueues, process resets, and schedule host reset
restore work. The change must suppress only the unnecessary periodic ETH
inspection.

## 2. Goals

- Add an opt-in runtime mode for co-simulation:

  ```bash
  insmod dpu_snd1.ko skip_eth_scan=1
  ```

- In bypass mode, perform no periodic optical-module, LOS, link-fault, I2C, or
  ETH link-status register reads.
- Present both implemented ETH ports as Link Up to the existing driver state,
  carrier, VLAN, and broadcast configuration paths.
- Preserve mailbox, reset, virtqueue, TX/RX, and all other service processing.
- Preserve the exact existing behavior when the parameter is omitted or set to
  zero.
- Produce a new driver release without modifying the 2026-08-04 artifacts.

## 3. Non-goals

- Filtering MMIO addresses in the QEMU/VCS bridge. Such filtering could hide
  legitimate explicit ETH configuration accesses.
- Stopping the service timer or either workqueue.
- Faking return values for arbitrary direct register reads.
- Suppressing an explicit user-triggered ethtool/module EEPROM operation. The
  feature targets the periodic service path only.
- Changing mailbox, virtio queue, DMA, PCIe BAR routing, configuration-space,
  tag, or time-freeze behavior.
- Permanently compiling out ETH handling for hardware deployments.

## 4. Module parameter

`main.c` adds a module-wide, read-only boolean parameter:

```c
static bool skip_eth_scan;
module_param(skip_eth_scan, bool, 0444);
MODULE_PARM_DESC(skip_eth_scan,
		 "Skip periodic ETH hardware scans and force ETH links up");
```

The default is `false`. Permission `0444` intentionally prevents changing the
mode after probe; switching modes requires unloading and reloading the module.
This avoids partially initialized state and races with the service workqueues.

The resulting semantics are:

| Load command | Periodic hardware scan | Driver-visible ETH state |
|---|---|---|
| `insmod dpu_snd1.ko` | Existing behavior | Derived from DUT registers |
| `insmod dpu_snd1.ko skip_eth_scan=0` | Existing behavior | Derived from DUT registers |
| `insmod dpu_snd1.ko skip_eth_scan=1` | Suppressed | All implemented ports forced Link Up |

## 5. Service-task behavior

`dpu_service_task1()` keeps `dpu_purge_mailbox_event(adapter)` unconditionally.
It calls `dpu_optical_link_subtask(adapter)` only when `skip_eth_scan` is false.
This removes periodic reads of module presence, LOS, module I2C/speed state, and
link faults while leaving mailbox event handling unchanged.

`dpu_service_task2()` keeps these calls unconditional and in their current
order:

```text
dpu_notify_backend_virtqueue_subtask()
dpu_reset_subtask()
```

It then selects exactly one ETH state path:

```text
skip_eth_scan == 0 -> dpu_process_eth_status_subtask()
skip_eth_scan == 1 -> dpu_force_eth_link_up_subtask()
```

The existing mailbox-ready and ETH-port-ready scheduling gates remain
unchanged. Therefore forced Link Up is initialized only at the same safe point
where the original status worker would have initialized link state.

## 6. Forced Link Up helper

`af_mng.h` declares and `af_mng.c` implements:

```c
void dpu_force_eth_link_up_subtask(struct dpu_hw *hw);
```

The helper follows the same ownership and locking rules as
`dpu_process_eth_status_subtask()`:

1. Process an AF, or host 1 PF0, and return for functions that do not own ETH
   status handling.
2. Acquire `adapter->eth_status_lock` with IRQ save/restore.
3. Determine the implemented port count from
   `af_res->spec_info.dpu_max_eth_num` for an AF, or `adapter->eth_num` for the
   host-side owner. The current DPU maximum is two ports.
4. Build a `dpu_eth_action_mng` with `DPU_ADD_ETH_2_BC` for each currently
   offline port and `DPU_ETH_ACTION_BUILD` for each already-online port.
5. Reuse `dpu_cfg_eth_2_bc()` for an AF or `dpu_cfg_host_eth_stats()` for the
   host-side owner.
6. Release the lock.

The helper does not call `rd32()` and does not infer link state from a DUT
register. Reusing the existing action path is important: the first execution
updates `adapter->eth_modules_status`, configures the existing VLAN/broadcast
path where applicable, and calls `netif_carrier_on()`. Later executions see
the ports online, select `DPU_ETH_ACTION_BUILD`, and are idempotent; the config
helpers immediately skip those ports and issue no ETH-state MMIO.

The implementation must initialize an action for every processed port.
`action_type == 0` is not a valid no-op value in the current helpers and could
otherwise be interpreted as a delete operation.

## 7. Compatibility and failure behavior

The change is additive and disabled by default. No source path in the normal
hardware mode branches on new synthetic state, so loading the module without
the parameter retains its current register reads and link transitions.

If the existing VLAN/broadcast setup used by the first forced-Link-Up action
fails internally, this feature follows the existing helper behavior and does
not silently substitute a new error policy. The periodic worker remains alive,
but subsequent action selection is determined by the existing online bitmap.
No new retry loop or MMIO polling is introduced.

Because the parameter is read-only, there is no transition from forced state
back to register-derived state within one module lifetime. Module unload uses
the existing teardown paths.

## 8. Files and release boundary

Driver source changes are limited to:

- `main.c`: module parameter and service-task selection.
- `af_mng.h`: forced-Link-Up helper declaration.
- `af_mng.c`: locked, read-free forced-Link-Up helper.

QEMU_VCS bridge, QEMU device, PCIe VIP, and Xilinx adapter sources are not
changed for this feature. QEMU_VCS records the design, build plan, source
archive, bundle metadata, and offline-import integration; it does not vendor
the private driver source directly.

Implementation produces a new 2026-08-10 release derived from, but not
overwriting, `dpu-qid128-pf0only-vnetcache-20260804`. The release contains:

- the modified source directory;
- a reproducible source `.tar.gz`;
- the rebuilt `dpu_snd1.ko`;
- an importable custom-driver bundle; and
- a SHA-256 manifest covering the source archive, module, and bundle artifacts.

## 9. Validation

All kernel-module compilation and VCS simulation validation runs on
`10.11.10.53` through a Bash login shell so its VCS and license environment is
loaded.

### 9.1 Source-contract checks

- `main.c` defines `skip_eth_scan` as a boolean `0444` module parameter with
  default false.
- Task 1 retains mailbox purge and conditionally skips only optical inspection.
- Task 2 retains virtqueue notification and reset handling, then selects the
  real or forced ETH path.
- The forced helper initializes all active action entries, holds the existing
  lock, reuses the existing config helpers, and contains no `rd32()` call.
- The PF0-only PCI ID table, fixed 128-QID definition, and cached
  `dpu_get_vnet_num()` behavior from the baseline remain intact.

### 9.2 Build and module metadata

- Build with the existing project-local temporary directory rather than
  `/tmp`, against the guest's `6.8.0-107-generic` headers.
- `modinfo` reports matching vermagic, the PF0 `20f9:5011` alias, no PF1 alias,
  and the `skip_eth_scan` parameter description/type.
- The new source archive and bundle pass their SHA-256 verification and
  offline import checks from a relocated project directory.

### 9.3 Behavioral regression matrix

With `skip_eth_scan=1`:

- the module loads and both implemented ETH ports reach driver-visible carrier
  Link Up;
- after the one-time state initialization, QEMU/VCS traces contain no periodic
  reads of `BAR0 + 0x0c00024` or `BAR0 + 0x0c0002c` and no follow-on periodic
  ETH module I2C/link-fault scan;
- mailbox readiness, virtqueue notification, reset handling, driver probe, and
  the existing virtio/TX/RX initialization continue;
- repeated service ticks do not repeat the Link-Up configuration action.

With the default load command:

- the original one-second optical and ETH status polling remains present;
- Link Up/Down continues to follow DUT register values.

The feature is accepted only if both modes pass their source/build contracts
and the bypass-mode VCS trace proves that the targeted periodic MMIO has
stopped without suppressing unrelated driver traffic.
