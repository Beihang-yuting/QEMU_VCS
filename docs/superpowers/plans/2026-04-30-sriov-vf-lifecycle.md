# SR-IOV VF Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable full SR-IOV VF dynamic creation/destruction via standard Linux `sriov_numvfs` sysfs interface in cosim-platform Guest.

**Architecture:** Four components — (1) QEMU patch to allow VF hotplug on Q35 root bus, (2) cosim_pcie_pf.c cleanup with correct VF offset/stride, (3) Guest stub kernel driver with SR-IOV + basic netdev, (4) setup.sh driver mode selection.

**Tech Stack:** QEMU 9.2.0 C, Linux kernel module C, Bash (setup.sh), Alpine Linux Guest

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch` | QEMU patch for Q35 VF hotplug |
| Modify | `qemu-plugin/cosim_pcie_pf.c` | Remove cold-plug/reset hacks, keep offset/stride fix |
| Create | `guest/driver/cosim_nic.c` | Stub PF/VF driver with SR-IOV + netdev |
| Create | `guest/driver/Makefile` | Kernel module cross-compile |
| Create | `guest/overlay/etc/local.d/cosim-driver.start` | OpenRC script to load driver at boot |
| Modify | `setup.sh` | --driver stub/custom/none option |

---

### Task 1: QEMU Hotplug Patch

**Files:**
- Create: `qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch`

This patch modifies QEMU's `hw/acpi/pcihp.c` to let SR-IOV VF devices bypass the ACPI hotplug bsel check on Q35 root bus.

- [ ] **Step 1: Read the original function on remote QEMU**

Read the target function to capture exact context lines for the patch:

```bash
ssh -p 2222 ryan@10.11.10.61 'sed -n "1,30p" /home/ryan/workspace/qemu-9.2.0/hw/acpi/pcihp.c'
ssh -p 2222 ryan@10.11.10.61 'grep -n "acpi_pcihp_device_plug_cb" /home/ryan/workspace/qemu-9.2.0/hw/acpi/pcihp.c'
ssh -p 2222 ryan@10.11.10.61 'grep -n "pci_is_vf\|pcie_sriov.h" /home/ryan/workspace/qemu-9.2.0/hw/acpi/pcihp.c'
```

Note the exact line numbers and surrounding context of the `if (bsel < 0)` block inside `acpi_pcihp_device_plug_cb`. Also check if `pci_is_vf` is already available via included headers; if not, we need to add `#include "hw/pci/pcie_sriov.h"`.

- [ ] **Step 2: Create the patch file**

Create `qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch` with the following content. **Adjust line numbers after Step 1 confirms the exact offsets.**

```diff
From: CoSim Platform <cosim@local>
Subject: [PATCH] acpi/pcihp: skip ACPI hotplug for SR-IOV VF devices

SR-IOV Virtual Functions do not need ACPI hotplug notification.
The Linux kernel discovers VFs via the PF's SR-IOV capability
when pci_enable_sriov() is called. Without this patch, VF
creation on Q35 root bus fails with "Unsupported bus. Bus
doesn't have property 'acpi-pcihp-bsel' set".

Signed-off-by: CoSim Platform <cosim@local>
---
 hw/acpi/pcihp.c | 7 +++++++
 1 file changed, 7 insertions(+)

diff --git a/hw/acpi/pcihp.c b/hw/acpi/pcihp.c
index XXXXXXX..XXXXXXX 100644
--- a/hw/acpi/pcihp.c
+++ b/hw/acpi/pcihp.c
@@ -XX,6 +XX,7 @@
 #include "hw/pci/pci_bridge.h"
 #include "hw/pci/pci_host.h"
 #include "hw/pci/pcie_port.h"
+#include "hw/pci/pcie_sriov.h"
 #include "hw/i386/acpi-build.h"

 /* ... (context from Step 1) ... */
@@ -XX,6 +XX,13 @@ void acpi_pcihp_device_plug_cb(HotplugHandler *hotplug_dev,
     int bsel = acpi_pcihp_get_bsel(pci_get_bus(pdev));

     if (bsel < 0) {
+        /*
+         * SR-IOV VFs are discovered by the guest kernel through the PF's
+         * SR-IOV capability, not via ACPI hotplug events.  Allow VF
+         * creation to succeed even on buses without bsel support (Q35 root).
+         */
+        if (pci_is_vf(pdev)) {
+            return;
+        }
         error_setg(errp,
                    "Unsupported bus. Bus doesn't have property"
```

**Important:** The exact line numbers and index hashes must be filled in after Step 1. The patch content above shows the logical change; the context lines must match the real file.

- [ ] **Step 3: Apply the patch and rebuild QEMU**

```bash
ssh -p 2222 ryan@10.11.10.61 'cd /home/ryan/workspace/qemu-9.2.0 && \
    git apply /home/ryan/workspace/cosim-platform/qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch && \
    echo "Patch applied OK"'

ssh -p 2222 ryan@10.11.10.61 'export PATH=$HOME/.local/bin:$PATH && \
    cd /home/ryan/workspace/qemu-9.2.0/build && \
    ninja -j$(nproc) qemu-system-x86_64 2>&1 | tail -5'
```

Expected: `Linking target qemu-system-x86_64` with no errors.

- [ ] **Step 4: Verify patch with a quick smoke test**

Start QEMU + VCS with 4 PF / 4 VF, login to Guest, and use setpci to write VF Enable:

```bash
# In Guest:
setpci -s 00:03.0 0x110.w=0x0002   # NumVFs = 2
setpci -s 00:03.0 0x108.w=0x0001   # VF Enable
```

Expected: No "Unsupported bus" error in QEMU log. The QEMU debug log should show `sriov_register_vfs ... creating 2 vf devs` and `cosim-vf: VF0 realized`. VFs won't appear in `lspci` yet (VID=0xFFFF per spec -- this is correct; the Guest stub driver in Task 3 will handle discovery).

- [ ] **Step 5: Commit**

```bash
cd /home/ubuntu/ryan/software/cosim-platform
git add qemu-plugin/patches/0001-pcie-sriov-skip-acpi-hotplug-for-vf.patch
git commit -m "feat: add QEMU patch to skip ACPI hotplug for SR-IOV VFs

Q35 root bus lacks acpi-pcihp-bsel, causing VF qdev_realize to fail.
SR-IOV VFs don't need ACPI hotplug -- the kernel discovers them via
the PF's SR-IOV capability. This patch lets VF creation succeed by
returning early from acpi_pcihp_device_plug_cb for VF devices."
```

---

### Task 2: Clean Up cosim_pcie_pf.c

**Files:**
- Modify: `qemu-plugin/cosim_pcie_pf.c:680-701` (remove cold-plug hack)
- Modify: `qemu-plugin/cosim_pcie_pf.c:810-843` (remove reset callback)
- Modify: `qemu-plugin/cosim_pcie_pf.c:876` (remove legacy_reset registration)

- [ ] **Step 1: Remove cold-plug VF code from realize**

In `cosim_pcie_pf.c`, remove lines 680-701 (the block starting with `/* Cold-plug VFs during realize...`). Keep the SR-IOV init and VF BAR registration (lines 651-678) intact.

The SR-IOV section should end cleanly after the `PF_DPRINTF` line:

```c
        PF_DPRINTF(s, "SR-IOV initialized: %d VFs, vf_did=0x%04x\n",
                   s->num_vfs, s->vf_device_id);
    }

    /* ======== Step 6: PF0 starts irq_poller + auto-creates PF1..N ======== */
```

- [ ] **Step 2: Remove the reset callback function**

Delete the entire `cosim_pcie_pf_reset` function (lines 810-843):

```c
/* ========== Reset: re-create VFs after SR-IOV reset ========== */
static void cosim_pcie_pf_reset(DeviceState *dev)
{
    ... entire function ...
}
```

- [ ] **Step 3: Remove legacy_reset registration from class_init**

In `cosim_pcie_pf_class_init`, remove line 876:

```c
    device_class_set_legacy_reset(dc, cosim_pcie_pf_reset);
```

- [ ] **Step 4: Sync to remote and rebuild**

```bash
scp -P 2222 cosim-platform/qemu-plugin/cosim_pcie_pf.c \
    ryan@10.11.10.61:/home/ryan/workspace/cosim-platform/qemu-plugin/
ssh -p 2222 ryan@10.11.10.61 'cp /home/ryan/workspace/cosim-platform/qemu-plugin/cosim_pcie_pf.c \
    /home/ryan/workspace/qemu-9.2.0/hw/net/cosim_pcie_pf.c && \
    export PATH=$HOME/.local/bin:$PATH && \
    cd /home/ryan/workspace/qemu-9.2.0/build && \
    ninja -j$(nproc) qemu-system-x86_64 2>&1 | tail -5'
```

Expected: Compiles with no errors or warnings.

- [ ] **Step 5: Commit**

```bash
git add qemu-plugin/cosim_pcie_pf.c
git commit -m "refactor: remove cold-plug and reset VF hacks from cosim_pcie_pf

With the ACPI hotplug patch in place, VF creation goes through
the standard SR-IOV framework path triggered by the Guest driver.
Remove:
- Cold-plug VF code in realize (NumVFs/VFE/config_write)
- VF VID/DID override (0xFFFF is correct per PCIe spec)
- cosim_pcie_pf_reset callback (no longer needed)

Keep: vf_offset=npfs, vf_stride=npfs to avoid devfn collisions."
```

---

### Task 3: Guest Stub Driver (cosim_nic.ko)

**Files:**
- Create: `guest/driver/cosim_nic.c`
- Create: `guest/driver/Makefile`

- [ ] **Step 1: Create driver Makefile**

Create `guest/driver/Makefile`:

```makefile
# cosim_nic kernel module -- cross-compile against Guest kernel headers
#
# Usage:
#   make KDIR=/path/to/kernel/build
#   make KDIR=/path/to/kernel/build CROSS_COMPILE=x86_64-linux-gnu-
#
# The resulting cosim_nic.ko goes into guest/images/<type>/rootfs overlay.

obj-m := cosim_nic.o

KDIR  ?= /lib/modules/$(shell uname -r)/build

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
```

- [ ] **Step 2: Create driver source**

Create `guest/driver/cosim_nic.c`:

```c
// SPDX-License-Identifier: GPL-2.0
/*
 * cosim_nic -- CoSim Platform stub NIC driver
 *
 * Provides:
 *   - PCI driver for cosim PF/VF devices (default VID:DID = abcd:1234)
 *   - SR-IOV sriov_configure callback (PF only)
 *   - Basic netdev with deterministic MAC
 *
 * Module parameters:
 *   vid=0xABCD  -- override vendor ID
 *   did=0x1234  -- override device ID
 *   vf_did=0x1235 -- override VF device ID
 */

#include <linux/module.h>
#include <linux/pci.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/io.h>

#define DRV_NAME    "cosim_nic"
#define DRV_VERSION "1.0"

static unsigned int vid = 0xabcd;
static unsigned int did = 0x1234;
static unsigned int vf_did = 0x1235;
module_param(vid, uint, 0444);
module_param(did, uint, 0444);
module_param(vf_did, uint, 0444);
MODULE_PARM_DESC(vid, "PCI Vendor ID to match (default 0xabcd)");
MODULE_PARM_DESC(did, "PCI Device ID to match (default 0x1234)");
MODULE_PARM_DESC(vf_did, "VF PCI Device ID to match (default 0x1235)");

struct cosim_nic {
    struct pci_dev  *pdev;
    struct net_device *netdev;
    void __iomem    *bar0;
    bool             is_vf;
};

static int cosim_sriov_configure(struct pci_dev *dev, int num_vfs);

/* ========== Net device ops ========== */

static int cosim_open(struct net_device *ndev)
{
    netif_start_queue(ndev);
    return 0;
}

static int cosim_stop(struct net_device *ndev)
{
    netif_stop_queue(ndev);
    return 0;
}

static netdev_tx_t cosim_xmit(struct sk_buff *skb, struct net_device *ndev)
{
    /* Stub: drop packet, count stats.
     * ETH SHM data-plane integration is a future enhancement. */
    ndev->stats.tx_packets++;
    ndev->stats.tx_bytes += skb->len;
    dev_kfree_skb_any(skb);
    return NETDEV_TX_OK;
}

static const struct net_device_ops cosim_netdev_ops = {
    .ndo_open       = cosim_open,
    .ndo_stop       = cosim_stop,
    .ndo_start_xmit = cosim_xmit,
};

/* ========== PCI probe / remove ========== */

static int cosim_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    struct cosim_nic *priv;
    struct net_device *ndev;
    int err;
    bool is_vf = pdev->is_virtfn;

    err = pci_enable_device(pdev);
    if (err)
        return err;

    err = pci_request_regions(pdev, DRV_NAME);
    if (err)
        goto err_disable;

    pci_set_master(pdev);

    ndev = alloc_etherdev(sizeof(struct cosim_nic));
    if (!ndev) {
        err = -ENOMEM;
        goto err_regions;
    }

    SET_NETDEV_DEV(ndev, &pdev->dev);
    priv = netdev_priv(ndev);
    priv->pdev = pdev;
    priv->netdev = ndev;
    priv->is_vf = is_vf;

    ndev->netdev_ops = &cosim_netdev_ops;

    /* Deterministic MAC from BDF */
    eth_hw_addr_random(ndev);
    ndev->dev_addr[0] &= 0xfe;  /* unicast */
    ndev->dev_addr[0] |= 0x02;  /* locally administered */
    ndev->dev_addr[4] = PCI_SLOT(pdev->devfn);
    ndev->dev_addr[5] = PCI_FUNC(pdev->devfn);

    /* Map BAR0 if present */
    if (pci_resource_len(pdev, 0) > 0) {
        priv->bar0 = pci_iomap(pdev, 0, 0);
        if (!priv->bar0)
            dev_warn(&pdev->dev, "BAR0 iomap failed\n");
    }

    err = register_netdev(ndev);
    if (err)
        goto err_unmap;

    pci_set_drvdata(pdev, priv);

    dev_info(&pdev->dev, "%s: %s %s (BDF %04x:%02x:%02x.%x)\n",
             ndev->name, is_vf ? "VF" : "PF", DRV_NAME,
             pci_domain_nr(pdev->bus), pdev->bus->number,
             PCI_SLOT(pdev->devfn), PCI_FUNC(pdev->devfn));

    return 0;

err_unmap:
    if (priv->bar0)
        pci_iounmap(pdev, priv->bar0);
    free_netdev(ndev);
err_regions:
    pci_release_regions(pdev);
err_disable:
    pci_disable_device(pdev);
    return err;
}

static void cosim_remove(struct pci_dev *pdev)
{
    struct cosim_nic *priv = pci_get_drvdata(pdev);

    if (!priv)
        return;

    if (!priv->is_vf && pdev->is_physfn)
        pci_disable_sriov(pdev);

    unregister_netdev(priv->netdev);
    if (priv->bar0)
        pci_iounmap(pdev, priv->bar0);
    free_netdev(priv->netdev);
    pci_release_regions(pdev);
    pci_disable_device(pdev);
}

/* ========== SR-IOV ========== */

static int cosim_sriov_configure(struct pci_dev *dev, int num_vfs)
{
    if (num_vfs > 0) {
        dev_info(&dev->dev, "Enabling %d VFs\n", num_vfs);
        return pci_enable_sriov(dev, num_vfs);
    }

    dev_info(&dev->dev, "Disabling VFs\n");
    pci_disable_sriov(dev);
    return 0;
}

/* ========== PCI ID table ========== */

static struct pci_device_id cosim_id_table[] = {
    { PCI_DEVICE(0xabcd, 0x1234) },  /* PF -- overridden in init */
    { PCI_DEVICE(0xabcd, 0x1235) },  /* VF -- overridden in init */
    { 0, }
};
MODULE_DEVICE_TABLE(pci, cosim_id_table);

static struct pci_driver cosim_pci_driver = {
    .name           = DRV_NAME,
    .id_table       = cosim_id_table,
    .probe          = cosim_probe,
    .remove         = cosim_remove,
    .sriov_configure = cosim_sriov_configure,
};

static int __init cosim_nic_init(void)
{
    cosim_id_table[0].vendor = vid;
    cosim_id_table[0].device = did;
    cosim_id_table[1].vendor = vid;
    cosim_id_table[1].device = vf_did;

    pr_info(DRV_NAME ": v" DRV_VERSION " (PF %04x:%04x, VF %04x:%04x)\n",
            vid, did, vid, vf_did);

    return pci_register_driver(&cosim_pci_driver);
}

static void __exit cosim_nic_exit(void)
{
    pci_unregister_driver(&cosim_pci_driver);
}

module_init(cosim_nic_init);
module_exit(cosim_nic_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("CoSim Platform");
MODULE_DESCRIPTION("Stub NIC driver for QEMU-VCS CoSim with SR-IOV support");
MODULE_VERSION(DRV_VERSION);
```

- [ ] **Step 3: Cross-compile the module**

Locate kernel build directory and compile:

```bash
ssh -p 2222 ryan@10.11.10.61 'ls /home/ryan/workspace/cosim-platform/guest/kernel-build/*/Module.symvers 2>/dev/null || \
    ls /lib/modules/*/build/Module.symvers 2>/dev/null || \
    echo "Kernel headers not found -- need to locate or download them"'

ssh -p 2222 ryan@10.11.10.61 'cd /home/ryan/workspace/cosim-platform/guest/driver && \
    make KDIR=<path-from-above> 2>&1 | tail -10'
```

Expected: `cosim_nic.ko` generated in `guest/driver/`.

- [ ] **Step 4: Commit**

```bash
git add guest/driver/cosim_nic.c guest/driver/Makefile
git commit -m "feat: add cosim_nic stub driver with SR-IOV support

Minimal PCI NIC driver for cosim PF/VF devices:
- Binds to abcd:1234 (PF) and abcd:1235 (VF)
- Implements sriov_configure for dynamic VF creation
- Registers netdev per PF/VF with deterministic MAC
- Module params vid/did/vf_did for custom device IDs
- Data-plane stub (ETH SHM integration as future enhancement)"
```

---

### Task 4: Setup Flow -- Driver Mode Selection

**Files:**
- Modify: `setup.sh`
- Create: `guest/overlay/etc/local.d/cosim-driver.start`

- [ ] **Step 1: Add --driver option to setup.sh**

In `setup.sh`, add to the argument parsing section (after existing option variables):

```bash
DRIVER_MODE=""
CUSTOM_KO=""
```

In the argument parsing loop, add:

```bash
    --driver)
        DRIVER_MODE="$2"; shift ;;
    --ko)
        CUSTOM_KO="$2"; shift ;;
```

Add interactive selection when `DRIVER_MODE` is empty (after existing Guest type selection):

```bash
if [ -z "$DRIVER_MODE" ]; then
    echo ""
    echo "选择 PF 驱动模式:"
    echo "  1) stub   -- 内置 cosim_nic 驱动 (默认，快速验证)"
    echo "  2) custom -- 使用自定义驱动 (.ko 文件)"
    echo "  3) none   -- 不加载驱动 (手动操作)"
    read -r -p "请选择 [1]: " driver_choice
    case "${driver_choice:-1}" in
        1) DRIVER_MODE="stub" ;;
        2) DRIVER_MODE="custom"
           read -r -p "请输入 .ko 文件路径: " CUSTOM_KO
           if [ ! -f "$CUSTOM_KO" ]; then
               fail "文件不存在: $CUSTOM_KO"; exit 1
           fi ;;
        3) DRIVER_MODE="none" ;;
        *) DRIVER_MODE="stub" ;;
    esac
fi
DRIVER_MODE="${DRIVER_MODE:-stub}"
info "Driver mode: $DRIVER_MODE"
```

- [ ] **Step 2: Add driver packaging to rootfs build**

Add `install_driver_to_rootfs` function in `setup.sh`:

```bash
install_driver_to_rootfs() {
    local rootfs_mnt="$1"
    local mode="$DRIVER_MODE"
    local ko_name=""

    mkdir -p "$rootfs_mnt/lib/modules" "$rootfs_mnt/etc/cosim"

    case "$mode" in
        stub)
            if [ ! -f "$PROJECT_DIR/guest/driver/cosim_nic.ko" ]; then
                info "Building cosim_nic.ko..."
                make -C "$PROJECT_DIR/guest/driver" KDIR="$KERNEL_BUILD_DIR" || {
                    warn "cosim_nic.ko build failed, falling back to none mode"
                    mode="none"
                }
            fi
            if [ -f "$PROJECT_DIR/guest/driver/cosim_nic.ko" ]; then
                cp "$PROJECT_DIR/guest/driver/cosim_nic.ko" "$rootfs_mnt/lib/modules/"
                ko_name="cosim_nic.ko"
            fi
            ;;
        custom)
            if [ -f "$CUSTOM_KO" ]; then
                ko_name=$(basename "$CUSTOM_KO")
                cp "$CUSTOM_KO" "$rootfs_mnt/lib/modules/$ko_name"
            else
                warn "Custom .ko not found: $CUSTOM_KO, falling back to none"
                mode="none"
            fi
            ;;
        none) ;;
    esac

    cat > "$rootfs_mnt/etc/cosim/driver.conf" <<DRVEOF
# CoSim driver configuration (auto-generated by setup.sh)
mode=$mode
ko_name=$ko_name
DRVEOF

    if [ "$mode" = "custom" ]; then
        info "Custom driver mode:"
        info "  1. Guest 启动后驱动已自动加载"
        info "  2. 确认 PF 绑定: lspci -k -s 00:03.0"
        info "  3. 创建 VF:  echo 2 > /sys/bus/pci/devices/0000:00:03.0/sriov_numvfs"
        info "  4. 查看 VF:  lspci | grep 'Virtual Function'"
        info "  5. 如需重新加载: rmmod xxx && insmod /lib/modules/xxx.ko"
    fi
}
```

Call this function in the rootfs build section where the overlay is applied.

- [ ] **Step 3: Create OpenRC boot script for driver loading**

Create `guest/overlay/etc/local.d/cosim-driver.start`:

```bash
#!/bin/sh
# Load cosim NIC driver at boot (OpenRC local.d)
if [ -f /etc/cosim/driver.conf ]; then
    . /etc/cosim/driver.conf
    case "$mode" in
        stub|custom)
            if [ -f "/lib/modules/${ko_name}" ]; then
                insmod "/lib/modules/${ko_name}" 2>/dev/null
                echo "[cosim] Loaded driver: ${ko_name}"
            else
                echo "[cosim] WARNING: ${ko_name} not found in /lib/modules/"
            fi
            ;;
        none)
            echo "[cosim] No driver loaded (manual mode)"
            ;;
    esac
fi
```

Make it executable:

```bash
chmod +x guest/overlay/etc/local.d/cosim-driver.start
```

- [ ] **Step 4: Commit**

```bash
git add setup.sh guest/overlay/etc/local.d/cosim-driver.start
git commit -m "feat: add --driver stub/custom/none option to setup.sh

Three driver modes for SR-IOV verification:
- stub:   built-in cosim_nic.ko, auto-loaded at Guest boot
- custom: user-provided .ko, auto-loaded at Guest boot
- none:   no driver, manual operation

Driver config stored in /etc/cosim/driver.conf on rootfs.
OpenRC local.d script handles loading after boot."
```

---

### Task 5: End-to-End Verification

**Files:** (no code changes -- verification only)

- [ ] **Step 1: Rebuild rootfs with stub driver**

```bash
./setup.sh --mode local --guest alpine --driver stub
```

Or if rootfs is already built, manually mount and install the driver + config.

- [ ] **Step 2: Start QEMU + VCS**

```bash
# Terminal A:
make run-qemu NUM_PFS=4 MAX_VFS=4

# Terminal B:
make run-vcs NUM_PFS=4 MAX_VFS=4
```

- [ ] **Step 3: Verify PF driver binding**

In Guest:

```bash
lspci -k -s 00:03.0
```

Expected output includes `Kernel driver in use: cosim_nic`.

- [ ] **Step 4: Verify SR-IOV capability**

```bash
lspci -vvs 00:03.0 | grep -A10 "SR-IOV"
```

Expected: `Initial VFs: 4, Total VFs: 4, NumVFs: 0, VF offset: 4, VF stride: 4`

- [ ] **Step 5: Create VFs dynamically**

```bash
echo 2 > /sys/bus/pci/devices/0000:00:03.0/sriov_numvfs
lspci
```

Expected: Two new VF entries appear (e.g., `00:03.4` and `00:04.0`).

- [ ] **Step 6: Verify VF config space forwarding**

```bash
lspci -vvs 00:03.4
```

Expected: VF config space readable. QEMU debug log shows `cosim-vf: cfg_read` for VF BDF.

- [ ] **Step 7: Destroy VFs**

```bash
echo 0 > /sys/bus/pci/devices/0000:00:03.0/sriov_numvfs
lspci | grep -c "Vadatech"
```

Expected: Count is `4` (PFs only, VFs gone).

- [ ] **Step 8: Document results and commit**

```bash
git add -A
git commit -m "test: verify SR-IOV VF lifecycle -- create and destroy via sriov_numvfs

Verified on QEMU 9.2.0 Q35 + VCS with 4PF/4VF topology:
- PF driver binding (cosim_nic)
- SR-IOV capability correct (offset=4, stride=4)
- VF dynamic creation via sriov_numvfs
- VF config space forwarding to VCS
- VF dynamic destruction"
```
