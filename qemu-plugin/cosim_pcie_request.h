#ifndef COSIM_PCIE_REQUEST_H
#define COSIM_PCIE_REQUEST_H

#include <stdint.h>

#include "cosim_types.h"

static inline uint16_t cosim_pcie_bdf(uint8_t bus, uint8_t devfn)
{
    return ((uint16_t)bus << 8) | devfn;
}

static inline void cosim_route_host_to_device(tlp_entry_t *req,
                                               uint16_t target)
{
    req->requester_id = 0;
    req->target_bdf = target;
}

#endif /* COSIM_PCIE_REQUEST_H */
