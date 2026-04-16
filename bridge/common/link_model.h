#ifndef LINK_MODEL_H
#define LINK_MODEL_H

#include <stdint.h>

typedef struct {
    /* --- configuration --- */
    uint32_t drop_rate_ppm;     /* per-million chance of entering a drop burst */
    uint16_t burst_drop_len;    /* frames to drop once burst triggers (>=1) */
    uint32_t rate_mbps;         /* line rate; 0 = unlimited */
    uint64_t latency_ns;        /* per-frame one-way fixed latency */
    uint32_t fc_window;         /* max in-flight frames; 0 = unlimited */

    /* --- runtime state (do not set directly; use reset) --- */
    uint32_t rng_state;         /* xorshift32 */
    uint16_t burst_remaining;   /* frames left in current drop burst */
    uint64_t token_bucket_ns;   /* next-earliest tx time in ns */
    uint32_t outstanding;       /* currently in-flight; incremented by send,
                                   decremented by recv */
} link_model_t;

/* Initialize / reset with deterministic RNG seed (call before sending). */
void link_model_reset(link_model_t *m, uint32_t seed);

/* Called on each send attempt. Returns non-zero if the frame should be dropped. */
int  link_model_should_drop(link_model_t *m);

/* Returns the earliest time (ns) at which a frame of given size may be
 * transmitted given rate limits and the fixed latency. Also updates the
 * internal token bucket to reflect this frame being queued.
 */
uint64_t link_model_deadline(link_model_t *m, uint32_t frame_bytes, uint64_t now_ns);

/* Flow-control: returns non-zero if the sender may queue another frame
 * (outstanding + 1 <= fc_window). */
int  link_model_fc_can_send(const link_model_t *m);

/* Accounting helpers for the sender/receiver to maintain `outstanding`. */
void link_model_inc_outstanding(link_model_t *m);
void link_model_dec_outstanding(link_model_t *m);

#endif
