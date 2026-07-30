#ifndef COSIM_MMIO_BE_H
#define COSIM_MMIO_BE_H

#include <stdint.h>
#include <string.h>

/* Describe the DWORD-aligned PCIe request that represents one QEMU MMIO
 * access (QEMU currently supplies 1/2/4/8-byte little-endian accesses).
 * `data` is the full aligned TLP payload, so disabled lanes are explicit zero
 * padding and never inherit bytes from the host access. */
typedef struct {
    uint8_t  first_be;
    uint8_t  last_be;
    uint32_t wire_len;
    uint8_t  data[12];
} cosim_mmio_be_layout_t;

static inline int cosim_mmio_be_layout_build(unsigned byte_offset,
                                             unsigned access_size,
                                             uint64_t value,
                                             cosim_mmio_be_layout_t *out)
{
    unsigned first_count;
    unsigned last_count;

    if (!out || byte_offset > 3 || access_size == 0 || access_size > 8)
        return -1;

    memset(out, 0, sizeof(*out));
    first_count = access_size < (4 - byte_offset)
                ? access_size : (4 - byte_offset);
    out->first_be = (uint8_t)(((1u << first_count) - 1u) << byte_offset);
    out->wire_len = (byte_offset + access_size + 3u) & ~3u;
    if (out->wire_len > 4) {
        last_count = (byte_offset + access_size) & 3u;
        out->last_be = (uint8_t)(last_count ? ((1u << last_count) - 1u) : 0xfu);
    }
    for (unsigned i = 0; i < access_size; i++)
        out->data[byte_offset + i] = (uint8_t)(value >> (8u * i));
    return 0;
}

#endif /* COSIM_MMIO_BE_H */
