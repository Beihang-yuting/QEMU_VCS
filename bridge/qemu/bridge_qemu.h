#ifndef BRIDGE_QEMU_H
#define BRIDGE_QEMU_H

#include "cosim_types.h"
#include "shm_layout.h"
#include "sock_sync.h"

typedef struct {
    cosim_shm_t shm;
    int         listen_fd;
    int         client_fd;
    char        shm_name[256];
    char        sock_path[256];
    uint8_t     next_tag;
} bridge_ctx_t;

bridge_ctx_t *bridge_init(const char *shm_name, const char *sock_path);
int bridge_connect(bridge_ctx_t *ctx);
int bridge_send_tlp(bridge_ctx_t *ctx, tlp_entry_t *req);
int bridge_wait_completion(bridge_ctx_t *ctx, uint8_t tag, cpl_entry_t *cpl);
int bridge_send_tlp_and_wait(bridge_ctx_t *ctx, tlp_entry_t *req, cpl_entry_t *cpl);
int bridge_send_tlp_fire(bridge_ctx_t *ctx, tlp_entry_t *req);
void bridge_destroy(bridge_ctx_t *ctx);

#endif
