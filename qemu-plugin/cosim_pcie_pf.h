/* cosim-platform/qemu-plugin/cosim_pcie_pf.h
 * QEMU SR-IOV PF device model for multi-function cosim
 *
 * Note: Uses "hw/pci/pci_device.h" not "hw/pci/pci_device.h" for QEMU 7.2 compat.
 * Place in QEMU source tree: qemu/include/hw/net/cosim_pcie_pf.h
 */
#ifndef COSIM_PCIE_PF_H
#define COSIM_PCIE_PF_H

#include "qemu/osdep.h"
#include "hw/pci/pci_device.h"
#include "hw/pci/pcie.h"
#include "hw/pci/msix.h"
#include "qom/object.h"

#include "hw/net/cosim_topology.h"

#define TYPE_COSIM_PCIE_PF "cosim-pcie-pf"
OBJECT_DECLARE_SIMPLE_TYPE(CosimPCIePF, COSIM_PCIE_PF)

#define TYPE_COSIM_PCIE_VF "cosim-pcie-vf"

/* SR-IOV capability offset in config space */
#define COSIM_SRIOV_CAP_OFFSET  0x100
#define COSIM_MAX_PF_DEVICES    8

/* MSI-X BH queue entry size */
#define COSIM_MSIX_QUEUE_SIZE   256

/* Per-BAR MMIO callback context */
typedef struct CosimPFBarContext {
    void *dev;          /* CosimPCIePF* or CosimPCIeVF* */
    int   bar_index;
    int   is_vf;        /* 0 = PF, 1 = VF */
} CosimPFBarContext;

struct CosimPCIePF {
    PCIDevice parent_obj;

    /* Identity */
    uint8_t   pf_index;

    /* BAR regions */
    MemoryRegion      bars[6];
    CosimPFBarContext  bar_ctx[6];
    uint64_t          bar_sizes[6];
    int               num_bars;

    /* MSI-X */
    uint16_t  msix_vectors;

    /* SR-IOV parameters (from topology) */
    uint16_t  num_vfs;
    uint16_t  vf_device_id;
    uint64_t  vf_bar_sizes[6];
    uint16_t  vf_msix_vectors;

    /* Bridge connection parameters (-device properties) */
    char     *transport;
    char     *remote_host;
    uint32_t  port_base;
    uint32_t  instance_id;
    char     *shm_name;
    char     *sock_path;

    /* Runtime state */
    void     *bridge_ctx;       /* bridge_ctx_t* opaque */
    void     *irq_poller;       /* irq_poller_t* opaque */

    /* Tag management */
    uint16_t  tag_mask;

    /* Topology (shared across all PFs) */
    topology_resp_t *topo;

    /* MSI-X BH queue: irq_poller enqueues, QEMU main-loop BH dequeues */
    void     *msix_bh;          /* QEMUBH* opaque */
    uint32_t  msix_queue_rid[COSIM_MSIX_QUEUE_SIZE];    /* requester_id */
    uint16_t  msix_queue_vec[COSIM_MSIX_QUEUE_SIZE];    /* vector */
    volatile int msix_queue_head;   /* main-loop BH reads */
    volatile int msix_queue_tail;   /* irq_poller thread writes */

    bool      debug;
};

/* ========== Shared state across PF instances ========== */

typedef struct CosimSharedState {
    void            *bridge_ctx;        /* bridge_ctx_t* */
    void            *irq_poller;        /* irq_poller_t* */
    topology_resp_t  topo;
    CosimPCIePF     *pf_devices[COSIM_MAX_PF_DEVICES];
    int              num_pfs;
    bool             initialized;
} CosimSharedState;

extern CosimSharedState g_cosim_shared;

/* Shared MMIO ops (used by both PF and VF) */
extern const MemoryRegionOps cosim_pf_mmio_ops;

/* BDF helper: find PF index in shared state by BDF */
int cosim_find_pf_by_bdf(uint16_t bdf);

#endif /* COSIM_PCIE_PF_H */
