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

static inline bool cosim_cpl_value_decode(uint8_t status,
                                          const uint8_t *payload,
                                          unsigned size,
                                          uint64_t *value)
{
    uint64_t decoded = 0;

    *value = UINT64_MAX;
    if (!cosim_cpl_status_is_success(status) || size > sizeof(decoded)) {
        return false;
    }

    for (unsigned i = 0; i < size; i++) {
        decoded |= (uint64_t)payload[i] << (i * 8);
    }
    *value = decoded;
    return true;
}

#endif /* COSIM_PCIE_REQUEST_H */
