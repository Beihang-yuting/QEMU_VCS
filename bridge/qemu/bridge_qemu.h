#ifndef BRIDGE_QEMU_H
#define BRIDGE_QEMU_H

#include "cosim_types.h"
#include "cosim_topology.h"
#include "shm_layout.h"
#include "sock_sync.h"
#include "trace_log.h"
#include <pthread.h>

typedef struct {
    cosim_shm_t shm;
    int         listen_fd;
    int         client_fd;
    char        shm_name[256];
    char        sock_path[256];
    uint16_t    next_tag;      /* P3: widened from uint8_t for 10-bit tags */
    uint16_t    tag_mask;      /* P3: tag wrap mask (from tag_width_to_mask) */
    /* P2: optional transaction trace */
    trace_log_t trace;
    int         trace_enabled;
    struct cosim_transport *transport;  /* NULL = legacy SHM mode */
    pthread_mutex_t tlp_mutex;         /* protects send_tlp + wait_completion */
    int             debug;             /* runtime debug print toggle */
    /* VF config sync (VCS/DUT authoritative → QEMU applies). Received inline
     * on the ctrl channel during a CfgWr completion wait; dispatched to the
     * device via vf_config_cb if registered, else stashed for polling. */
    vf_config_t     vf_config;         /* last received VF config */
    int             vf_config_pending; /* set when a new vf_config arrived */
    void          (*vf_config_cb)(const vf_config_t *cfg, void *user);
    void           *vf_config_user;
} bridge_ctx_t;

bridge_ctx_t *bridge_init(const char *shm_name, const char *sock_path);
int bridge_connect(bridge_ctx_t *ctx);
int bridge_send_tlp(bridge_ctx_t *ctx, tlp_entry_t *req);
int bridge_wait_completion(bridge_ctx_t *ctx, uint16_t tag, cpl_entry_t *cpl);
int bridge_send_tlp_and_wait(bridge_ctx_t *ctx, tlp_entry_t *req, cpl_entry_t *cpl);
/* Timed variants: bound the ctrl-channel completion wait to timeout_ms.
 * Return 0 on match, -2 on timeout, -1 on error. Fall back to the blocking
 * variant when the transport has no timed recv. */
int bridge_wait_completion_timed(bridge_ctx_t *ctx, uint16_t tag,
                                 cpl_entry_t *cpl, int timeout_ms);
int bridge_send_tlp_and_wait_timed(bridge_ctx_t *ctx, tlp_entry_t *req,
                                   cpl_entry_t *cpl, int timeout_ms);
int bridge_send_tlp_fire(bridge_ctx_t *ctx, tlp_entry_t *req);
/* Bounded drain of VF_CONFIG/VF_EVENT pushed by VCS after a fire-and-forget
 * SR-IOV VF-enable CfgWr; applies the VF layout before the guest probes VFs. */
void bridge_drain_vf_pending(bridge_ctx_t *ctx, int timeout_ms);
void bridge_destroy(bridge_ctx_t *ctx);

/* P2: DMA completion (QEMU→VCS) */
int bridge_complete_dma(bridge_ctx_t *ctx, uint32_t tag, uint32_t status);

/* TCP mode: DMA completion with data (no shared dma_buf over network) */
int bridge_complete_dma_with_data(bridge_ctx_t *ctx, uint32_t tag,
                                  uint32_t status, uint32_t direction,
                                  uint64_t host_addr, const uint8_t *data,
                                  uint32_t len);

/* P2: Mode switch */
int bridge_request_mode_switch(bridge_ctx_t *ctx, cosim_mode_t target_mode);
cosim_mode_t bridge_get_mode(bridge_ctx_t *ctx);

/* P2: Precise mode clock advance (QEMU requests VCS advance N cycles, waits ACK) */
int bridge_advance_clock(bridge_ctx_t *ctx, uint64_t cycles);

/* P2: Optional transaction trace logging */
int  bridge_enable_trace(bridge_ctx_t *ctx, const char *path, trace_fmt_t fmt);
void bridge_disable_trace(bridge_ctx_t *ctx);

/* Transport-aware API (新增，不影响现有代码) */
#include "cosim_transport.h"
bridge_ctx_t *bridge_init_ex(const transport_cfg_t *cfg);
int bridge_connect_ex(bridge_ctx_t *ctx);

/* P3: Topology query — retrieves PF/VF topology from VCS side */
int bridge_query_topology(bridge_ctx_t *ctx, topology_resp_t *topo);

/* P3: Notify VCS of SR-IOV VF enable/disable */
int bridge_send_vf_event(bridge_ctx_t *ctx, const vf_event_t *ev);

/* VF config sync. bridge_send_vf_config: QEMU→VCS push (duplex, when QEMU owns
 * SR-IOV). bridge_set_vf_config_cb: register device callback invoked when a
 * VCS-pushed vf_config is received inline. bridge_poll_vf_config: pull the last
 * received config (returns 1 if pending, clears the flag). */
int  bridge_send_vf_config(bridge_ctx_t *ctx, const vf_config_t *cfg);
void bridge_set_vf_config_cb(bridge_ctx_t *ctx,
                             void (*cb)(const vf_config_t *cfg, void *user),
                             void *user);
int  bridge_poll_vf_config(bridge_ctx_t *ctx, vf_config_t *cfg);

/* P3: BDF-aware TLP send — sets requester_id and target_bdf before sending */
int bridge_send_tlp_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                         uint16_t requester_id, uint16_t target_bdf);
int bridge_send_tlp_and_wait_bdf(bridge_ctx_t *ctx, tlp_entry_t *req,
                                  cpl_entry_t *cpl,
                                  uint16_t requester_id, uint16_t target_bdf);

#endif
