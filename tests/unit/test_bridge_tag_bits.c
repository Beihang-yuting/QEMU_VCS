#include "bridge_qemu.h"

#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\\n", __FILE__, __LINE__, #condition); \
        abort(); \
    } \
} while (0)

int main(void) {
    bridge_ctx_t ctx = {0};

    ctx.next_tag = 0x03ff;
    ctx.tag_mask = 0x03ff;

    CHECK(bridge_set_tag_bit(&ctx, 8) == 0);
    CHECK(ctx.tag_mask == 0x00ff);
    CHECK(ctx.next_tag == 0x00ff);

    CHECK(bridge_set_tag_bit(&ctx, 10) == 0);
    CHECK(ctx.tag_mask == 0x03ff);
    CHECK(ctx.next_tag == 0x00ff);

    CHECK(bridge_set_tag_bit(&ctx, 9) < 0);
    CHECK(ctx.tag_mask == 0x03ff);
    CHECK(ctx.next_tag == 0x00ff);

    puts("PASS: bridge tag-bit API");
    return 0;
}
