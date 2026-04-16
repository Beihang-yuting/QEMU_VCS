#include "link_model.h"
#include <string.h>

/* xorshift32 — cheap deterministic RNG, good enough for drop decisions. */
static uint32_t xs32(uint32_t *s)
{
    uint32_t x = *s ? *s : 0xDEADBEEFu;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

void link_model_reset(link_model_t *m, uint32_t seed)
{
    /* Preserve configuration, reset runtime state. */
    m->rng_state       = seed ? seed : 1u;
    m->burst_remaining = 0;
    m->token_bucket_ns = 0;
    m->outstanding     = 0;
}

int link_model_should_drop(link_model_t *m)
{
    /* If currently inside a drop burst, continue dropping. */
    if (m->burst_remaining > 0) {
        m->burst_remaining--;
        return 1;
    }
    if (m->drop_rate_ppm == 0) return 0;

    /* Compare xorshift output against ppm probability. */
    uint32_t r = xs32(&m->rng_state) % 1000000u;
    if (r < m->drop_rate_ppm) {
        uint16_t burst = m->burst_drop_len == 0 ? 1 : m->burst_drop_len;
        /* The current frame is dropped now; burst_remaining applies to following frames. */
        m->burst_remaining = (uint16_t)(burst - 1);
        return 1;
    }
    return 0;
}

uint64_t link_model_deadline(link_model_t *m, uint32_t frame_bytes, uint64_t now_ns)
{
    uint64_t serialize_ns = 0;
    if (m->rate_mbps > 0) {
        /* bytes * 8 / Mbps → ns = bytes * 8000 / Mbps */
        serialize_ns = (uint64_t)frame_bytes * 8000ull / (uint64_t)m->rate_mbps;
    }
    uint64_t earliest = (now_ns > m->token_bucket_ns) ? now_ns : m->token_bucket_ns;
    m->token_bucket_ns = earliest + serialize_ns;
    return earliest + serialize_ns + m->latency_ns;
}

int link_model_fc_can_send(const link_model_t *m)
{
    if (m->fc_window == 0) return 1;
    return m->outstanding < m->fc_window;
}

void link_model_inc_outstanding(link_model_t *m)
{
    m->outstanding++;
}

void link_model_dec_outstanding(link_model_t *m)
{
    if (m->outstanding > 0) m->outstanding--;
}
