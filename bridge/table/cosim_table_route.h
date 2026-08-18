#ifndef COSIM_TABLE_ROUTE_H
#define COSIM_TABLE_ROUTE_H

#include <stddef.h>
#include <stdint.h>

#include "cosim_table_protocol.h"

typedef struct {
    cosim_table_route_entry_t *entries;
    size_t count;
    uint64_t generation_hash;
} cosim_table_route_map_t;

int cosim_table_route_load(const char *path, cosim_table_route_map_t *map,
                           char *error, size_t error_bytes);
void cosim_table_route_free(cosim_table_route_map_t *map);
const cosim_table_route_entry_t *cosim_table_route_match(
    const cosim_table_route_map_t *map, const cosim_table_target_t *target,
    uint64_t bar_offset, uint8_t operation);
int cosim_table_route_slice(const cosim_table_route_entry_t *route,
                            uint64_t bar_offset, uint32_t payload_bytes,
                            uint64_t *first_index, uint32_t *entry_count);

#endif /* COSIM_TABLE_ROUTE_H */
