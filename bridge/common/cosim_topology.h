/* cosim_topology.h — Multi-function / SR-IOV topology definitions
 *
 * Shared between QEMU and VCS sides for PF/VF topology discovery
 * and VF enable/disable event notification.
 */
#ifndef COSIM_TOPOLOGY_H
#define COSIM_TOPOLOGY_H

#include <stdint.h>

/* _Static_assert compat (same as cosim_types.h) */
#ifdef __cplusplus
#if __cplusplus >= 201103L
#define _Static_assert(expr, msg)  static_assert(expr, msg)
#else
#define _Static_assert(expr, msg)
#endif
#elif !defined(__STDC_VERSION__) || __STDC_VERSION__ < 201112L
#define _Static_assert(expr, msg)
#endif

/* ========== Constants ========== */

#define COSIM_MAX_PFS       8
#define COSIM_MAX_BARS      6

/* PCIe tag width constants (Capability bit encodings) */
#define TAG_WIDTH_5BIT      0   /* 32 tags (legacy) */
#define TAG_WIDTH_8BIT      1   /* 256 tags (extended) */
#define TAG_WIDTH_10BIT     2   /* 1024 tags (PCIe 4.0+) */

/* ========== Topology structures ========== */

typedef struct {
    uint8_t  num_pfs;         /* Number of physical functions (1..MAX_PFS) */
    uint8_t  tag_width;       /* TAG_WIDTH_5BIT / 8BIT / 10BIT */
    uint8_t  pad[2];
} __attribute__((packed)) topology_header_t;

_Static_assert(sizeof(topology_header_t) == 4, "topology_header_t must be 4 bytes");

typedef struct {
    uint16_t bdf;             /* Bus:Device:Function (PCIe BDF encoding) */
    uint16_t num_vfs;         /* Number of VFs enabled for this PF */
    uint16_t vf_device_id;    /* VF Device ID (from SR-IOV cap) */
    uint16_t vendor_id;       /* PCI Vendor ID */
    uint16_t device_id;       /* PCI Device ID */
    uint16_t msix_vectors;    /* PF MSI-X table size */
    uint16_t vf_msix_vectors; /* Per-VF MSI-X table size */
    uint16_t pad;
    uint64_t pf_bar_size[COSIM_MAX_BARS];  /* PF BAR sizes in bytes */
    uint64_t vf_bar_size[COSIM_MAX_BARS];  /* Per-VF BAR sizes (from SR-IOV cap) */
} __attribute__((packed)) pf_topology_t;

_Static_assert(sizeof(pf_topology_t) == 112, "pf_topology_t must be 112 bytes");

typedef struct {
    topology_header_t header;
    pf_topology_t     pfs[COSIM_MAX_PFS];
} __attribute__((packed)) topology_resp_t;

_Static_assert(sizeof(topology_resp_t) == 4 + 112 * COSIM_MAX_PFS,
               "topology_resp_t size mismatch");

/* ========== VF event (enable / disable) ========== */

#define VF_EVENT_ENABLE     0
#define VF_EVENT_DISABLE    1

typedef struct {
    uint8_t  event_type;      /* VF_EVENT_ENABLE or VF_EVENT_DISABLE */
    uint8_t  pf_index;        /* Index into topology_resp_t.pfs[] */
    uint16_t num_vfs;         /* Number of VFs being enabled/disabled */
} __attribute__((packed)) vf_event_t;

_Static_assert(sizeof(vf_event_t) == 4, "vf_event_t must be 4 bytes");

/* ========== Inline helpers ========== */

static inline uint16_t tag_width_to_mask(uint8_t width) {
    switch (width) {
        case TAG_WIDTH_5BIT:  return 0x001Fu;  /* 31 */
        case TAG_WIDTH_8BIT:  return 0x00FFu;  /* 255 */
        case TAG_WIDTH_10BIT: return 0x03FFu;  /* 1023 */
        default:              return 0x001Fu;   /* fallback to 5-bit */
    }
}

#endif /* COSIM_TOPOLOGY_H */
