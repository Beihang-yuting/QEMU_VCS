#ifndef BRIDGE_QEMU_H
#define BRIDGE_QEMU_H

#include "cosim_types.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "trace_log.h"

typedef struct {
    cosim_shm_t shm;
    int         listen_fd;
    int         client_fd;
    char        shm_name[256];
    char        sock_path[256];
    uint8_t     next_tag;
    /* P2: optional transaction trace */
    trace_log_t trace;
    int         trace_enabled;
} bridge_ctx_t;

bridge_ctx_t *bridge_init(const char *shm_name, const char *sock_path);
int bridge_connect(bridge_ctx_t *ctx);
int bridge_send_tlp(bridge_ctx_t *ctx, tlp_entry_t *req);
int bridge_wait_completion(bridge_ctx_t *ctx, uint8_t tag, cpl_entry_t *cpl);
int bridge_send_tlp_and_wait(bridge_ctx_t *ctx, tlp_entry_t *req, cpl_entry_t *cpl);
int bridge_send_tlp_fire(bridge_ctx_t *ctx, tlp_entry_t *req);
void bridge_destroy(bridge_ctx_t *ctx);

/* P2: DMA completion (QEMU→VCS) */
int bridge_complete_dma(bridge_ctx_t *ctx, uint32_t tag, uint32_t status);

/* P2: Mode switch */
int bridge_request_mode_switch(bridge_ctx_t *ctx, cosim_mode_t target_mode);
cosim_mode_t bridge_get_mode(bridge_ctx_t *ctx);

/* P2: Precise mode clock advance (QEMU requests VCS advance N cycles, waits ACK) */
int bridge_advance_clock(bridge_ctx_t *ctx, uint64_t cycles);

/* P2: Optional transaction trace logging */
int  bridge_enable_trace(bridge_ctx_t *ctx, const char *path, trace_fmt_t fmt);
void bridge_disable_trace(bridge_ctx_t *ctx);

#endif
