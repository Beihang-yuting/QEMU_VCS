#include "test_check.h"
#include <stdint.h>
#include <stdio.h>

#include "cosim_mmio_be.h"

static void expect_layout(unsigned offset, unsigned size,
                          uint8_t first_be, uint8_t last_be,
                          uint32_t wire_len)
{
    cosim_mmio_be_layout_t layout;
    uint64_t value = UINT64_C(0x8877665544332211);

    CHECK(cosim_mmio_be_layout_build(offset, size, value, &layout) == 0);
    CHECK(layout.first_be == first_be);
    CHECK(layout.last_be == last_be);
    CHECK(layout.wire_len == wire_len);
    for (unsigned i = 0; i < size; i++) {
        CHECK(layout.data[offset + i] == (uint8_t)(value >> (8 * i)));
    }
}

int main(void)
{
    /* Every architectural MMIO size at each DWORD offset.  The cross-DWORD
     * cases prove last_be and the aligned payload length rather than merely
     * the first DWORD mask. */
    static const struct {
        unsigned size;
        uint8_t first_be[4];
        uint8_t last_be[4];
        uint32_t wire_len[4];
    } cases[] = {
        { 1, { 0x1, 0x2, 0x4, 0x8 }, { 0, 0, 0, 0 }, { 4, 4, 4, 4 } },
        { 2, { 0x3, 0x6, 0xc, 0x8 }, { 0, 0, 0, 0x1 }, { 4, 4, 4, 8 } },
        { 4, { 0xf, 0xe, 0xc, 0x8 }, { 0, 0x1, 0x3, 0x7 }, { 4, 8, 8, 8 } },
        { 8, { 0xf, 0xe, 0xc, 0x8 }, { 0xf, 0x1, 0x3, 0x7 }, { 8, 12, 12, 12 } },
    };

    for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        for (unsigned offset = 0; offset < 4; offset++) {
            expect_layout(offset, cases[c].size,
                          cases[c].first_be[offset],
                          cases[c].last_be[offset],
                          cases[c].wire_len[offset]);
        }
    }

    puts("PASS: cosim MMIO byte-enable layout");
    return 0;
}
