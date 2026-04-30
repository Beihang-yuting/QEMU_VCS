/* cosim-platform/qemu-plugin/cosim_pcie_vf.c
 * QEMU SR-IOV VF device model — auto-created by SR-IOV framework
 *
 * Place in QEMU source tree: qemu/hw/net/cosim_pcie_vf.c
 * Header: qemu/include/hw/net/cosim_pcie_vf.h
 * Build: modify qemu/hw/net/meson.build
 *
 * VF devices are instantiated automatically when the guest writes to the
 * SR-IOV NumVFs register on the parent PF. Each VF shares the PF's bridge
 * connection and MMIO ops — it simply has its own BARs and MSI-X table.
 */
#include "hw/net/cosim_pcie_vf.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qemu/main-loop.h"
#include "hw/qdev-properties.h"
#include "qapi/error.h"

/* Bridge API — linked dynamically (same as PF) */
#include "bridge_qemu.h"
#include "cosim_transport.h"
#include "hw/pci/pcie_sriov.h"
#include "hw/pci/pcie.h"


#define VF_DPRINTF(s, fmt, ...) do { \
    if ((s)->debug) fprintf(stderr, "cosim-vf%d: " fmt, \
                            (s)->vf_index, ##__VA_ARGS__); \
} while (0)

/* ========== VF config space forwarding ========== */

static uint32_t cosim_vf_config_read(PCIDevice *pci_dev, uint32_t address,
                                      int len)
{
    CosimPCIeVF *s = COSIM_PCIE_VF(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)g_cosim_shared.bridge_ctx;

    if (!ctx) {
        return pci_default_read_config(pci_dev, address, len);
    }

    /* VF BDF: compute from PCI bus position */
    uint16_t vf_bdf = pci_get_bdf(pci_dev);

    uint32_t dword_addr  = address & ~3u;
    uint32_t byte_offset = address & 3u;

    tlp_entry_t req = {0};
    req.type = TLP_CFGRD;
    req.addr = dword_addr;
    req.len  = 4;
    req.requester_id = 0;       /* RC BDF */
    req.target_bdf   = vf_bdf;

    cpl_entry_t cpl = {0};
    int ret = bridge_send_tlp_and_wait_bdf(ctx, &req, &cpl, 0, vf_bdf);
    if (ret < 0) {
        return pci_default_read_config(pci_dev, address, len);
    }

    uint32_t dword = 0;
    for (int i = 0; i < 4 && i < COSIM_TLP_DATA_SIZE; i++) {
        dword |= ((uint32_t)cpl.data[i]) << (i * 8);
    }

    uint32_t val = dword >> (byte_offset * 8);
    if (len < 4) {
        val &= (1u << (len * 8)) - 1;
    }

    VF_DPRINTF(s, "cfg_read addr=0x%02x len=%d -> 0x%x (bdf=0x%04x)\n",
               address, len, val, vf_bdf);
    return val;
}

static void cosim_vf_config_write(PCIDevice *pci_dev, uint32_t address,
                                   uint32_t data, int len)
{
    CosimPCIeVF *s = COSIM_PCIE_VF(pci_dev);
    bridge_ctx_t *ctx = (bridge_ctx_t *)g_cosim_shared.bridge_ctx;

    pci_default_write_config(pci_dev, address, data, len);

    if (!ctx) return;

    uint16_t vf_bdf = pci_get_bdf(pci_dev);

    tlp_entry_t req = {0};
    req.type = TLP_CFGWR;
    req.addr = address;
    req.len  = len;
    req.requester_id = 0;
    req.target_bdf   = vf_bdf;
    for (int i = 0; i < len && i < COSIM_TLP_DATA_SIZE; i++) {
        req.data[i] = (data >> (i * 8)) & 0xFF;
    }

    bridge_send_tlp_fire(ctx, &req);

    VF_DPRINTF(s, "CfgWr addr=0x%02x len=%d data=0x%x (bdf=0x%04x)\n",
               address, len, data, vf_bdf);
}

/* ========== VF lifecycle ========== */

static void cosim_pcie_vf_realize(PCIDevice *pci_dev, Error **errp)
{
    CosimPCIeVF *s = COSIM_PCIE_VF(pci_dev);
    s->num_bars = 0;

    /* Find parent PF via SR-IOV framework */
    PCIDevice *pf_dev = pcie_sriov_get_pf(pci_dev);
    if (!pf_dev) {
        error_setg(errp, "cosim-vf: cannot find parent PF");
        return;
    }
    s->parent_pf = COSIM_PCIE_PF(pf_dev);

    CosimPCIePF *pf = s->parent_pf;
    s->debug = pf->debug;

    /* Get VF index from SR-IOV framework */
    s->vf_index = pcie_sriov_vf_number(pci_dev);

    /* Get VF MSI-X count from parent PF's topology */
    s->msix_vectors = pf->vf_msix_vectors;

    /* Register VF BARs — use shared MMIO ops from PF */
    for (int i = 0; i < 6; i += 2) {
        uint64_t sz = pf->vf_bar_sizes[i];
        if (sz == 0) continue;

        char name[32];
        snprintf(name, sizeof(name), "cosim-vf%d-bar%d", s->vf_index, i);

        s->bar_ctx[i].dev       = s;
        s->bar_ctx[i].bar_index = i;
        s->bar_ctx[i].is_vf     = 1;

        memory_region_init_io(&s->bars[i], OBJECT(s), &cosim_pf_mmio_ops,
                              &s->bar_ctx[i], name, sz);
        /* VFs must use pcie_sriov_vf_register_bar (not pci_register_bar) */
        pcie_sriov_vf_register_bar(pci_dev, i, &s->bars[i]);
        s->num_bars++;

        VF_DPRINTF(s, "BAR%d registered, size=0x%lx\n", i, (unsigned long)sz);
    }

    /* Enable bus mastering */
    pci_set_word(pci_dev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);

    /* MSI-X init for VF — only if BAR0 exists and is large enough */
    if (s->msix_vectors > 0 && s->num_bars > 0) {
        uint32_t table_size = s->msix_vectors * PCI_MSIX_ENTRY_SIZE;
        uint32_t pba_offset = QEMU_ALIGN_UP(table_size, 0x1000);
        uint64_t bar0_size = pf->vf_bar_sizes[0];
        int bar_nr = 0;

        if (bar0_size >= pba_offset + 8) {
            Error *msix_err = NULL;
            int ret = msix_init(pci_dev, s->msix_vectors,
                                &s->bars[bar_nr], bar_nr, 0,
                                &s->bars[bar_nr], bar_nr, pba_offset,
                                0, &msix_err);
            if (ret < 0) {
                VF_DPRINTF(s, "msix_init failed: %s\n",
                           msix_err ? error_get_pretty(msix_err) : "?");
                error_free(msix_err);
            } else {
                VF_DPRINTF(s, "MSI-X initialized: %d vectors\n",
                           s->msix_vectors);
            }
        } else {
            VF_DPRINTF(s, "VF BAR0 too small for MSI-X (need 0x%x, have 0x%lx)"
                       ", skipping\n", pba_offset + 8, (unsigned long)bar0_size);
        }
    }

    /* PCIe Endpoint Capability for VF */
    if (pcie_endpoint_cap_init(pci_dev, 0xa0) < 0) {
        qemu_log("cosim-vf: VF%d pcie_endpoint_cap_init failed\n",
                 s->vf_index);
    }

    qemu_log("cosim-vf: VF%d realized (parent PF%d, vf_bdf=0x%04x, msix=%d)\n",
             s->vf_index, pf->pf_index, pci_get_bdf(pci_dev), s->msix_vectors);
}

static void cosim_pcie_vf_exit(PCIDevice *pci_dev)
{
    CosimPCIeVF *s = COSIM_PCIE_VF(pci_dev);

    if (s->num_bars > 0) {
        msix_uninit(pci_dev, &s->bars[0], &s->bars[0]);
    }
    pcie_cap_exit(pci_dev);

    qemu_log("cosim-vf: VF%d exited\n", s->vf_index);
}

/* ========== Type registration ========== */

static void cosim_pcie_vf_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    k->realize      = cosim_pcie_vf_realize;
    k->exit         = cosim_pcie_vf_exit;
    k->config_read  = cosim_vf_config_read;
    k->config_write = cosim_vf_config_write;

    /* VF IDs — device_id comes from SR-IOV cap, vendor matches PF */
    k->vendor_id = 0x1AF4;
    k->device_id = 0x1041;   /* overridden by SR-IOV framework */
    k->revision  = 0x01;
    k->class_id  = PCI_CLASS_NETWORK_ETHERNET;

    set_bit(DEVICE_CATEGORY_NETWORK, dc->categories);
    dc->desc = "CoSim PCIe VF Device (SR-IOV Virtual Function)";
}

static const TypeInfo cosim_pcie_vf_info = {
    .name          = TYPE_COSIM_PCIE_VF,
    .parent        = TYPE_PCI_DEVICE,
    .instance_size = sizeof(CosimPCIeVF),
    .class_init    = cosim_pcie_vf_class_init,
    .interfaces    = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

static void cosim_vf_register_types(void)
{
    type_register_static(&cosim_pcie_vf_info);
}

type_init(cosim_vf_register_types)
