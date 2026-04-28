/* cosim-platform/qemu-plugin/cosim_pcie_vf.h
 * QEMU SR-IOV VF device model for multi-function cosim
 *
 * VF devices are auto-created by QEMU's SR-IOV framework when the
 * guest enables SR-IOV on the parent PF.
 *
 * Place in QEMU source tree: qemu/include/hw/net/cosim_pcie_vf.h
 */
#ifndef COSIM_PCIE_VF_H
#define COSIM_PCIE_VF_H

#include "qemu/osdep.h"
#include "hw/pci/pci.h"
#include "hw/pci/pcie.h"
#include "hw/pci/msix.h"
#include "qom/object.h"

#include "cosim_pcie_pf.h"

#define TYPE_COSIM_PCIE_VF "cosim-pcie-vf"
OBJECT_DECLARE_SIMPLE_TYPE(CosimPCIeVF, COSIM_PCIE_VF)

struct CosimPCIeVF {
    PCIDevice parent_obj;

    /* Back-pointer to parent PF */
    CosimPCIePF *parent_pf;

    /* VF index within parent PF (0-based) */
    uint16_t  vf_index;

    /* BAR regions */
    MemoryRegion      bars[6];
    CosimPFBarContext  bar_ctx[6];
    int               num_bars;

    /* MSI-X */
    uint16_t  msix_vectors;

    bool      debug;
};

#endif /* COSIM_PCIE_VF_H */
