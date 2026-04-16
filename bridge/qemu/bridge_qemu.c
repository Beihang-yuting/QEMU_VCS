#include "bridge_qemu.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

bridge_ctx_t *bridge_init(const char *shm_name, const char *sock_path) {
    bridge_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    strncpy(ctx->shm_name, shm_name, sizeof(ctx->shm_name) - 1);
    strncpy(ctx->sock_path, sock_path, sizeof(ctx->sock_path) - 1);
    ctx->listen_fd = -1;
    ctx->client_fd = -1;
    ctx->next_tag = 0;

    if (cosim_shm_create(&ctx->shm, shm_name) < 0) {
        free(ctx);
        return NULL;
    }

    ctx->listen_fd = sock_sync_listen(sock_path);
    if (ctx->listen_fd < 0) {
        cosim_shm_destroy(&ctx->shm, shm_name);
        free(ctx);
        return NULL;
    }

    atomic_store(&ctx->shm.ctrl->qemu_ready, 1);

    return ctx;
}

int bridge_connect(bridge_ctx_t *ctx) {
    ctx->client_fd = sock_sync_accept(ctx->listen_fd);
    return (ctx->client_fd >= 0) ? 0 : -1;
}

int bridge_send_tlp(bridge_ctx_t *ctx, tlp_entry_t *req) {
    req->tag = ctx->next_tag++;

    int ret = ring_buf_enqueue(&ctx->shm.req_ring, req);
    if (ret < 0) {
        fprintf(stderr, "bridge_send_tlp: request queue full\n");
        return -1;
    }

    sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = 0 };
    return sock_sync_send(ctx->client_fd, &msg);
}

int bridge_wait_completion(bridge_ctx_t *ctx, uint8_t tag, cpl_entry_t *cpl) {
    sync_msg_t msg;
    int ret = sock_sync_recv(ctx->client_fd, &msg);
    if (ret < 0) return -1;

    if (msg.type != SYNC_MSG_CPL_READY) {
        fprintf(stderr, "bridge_wait_completion: unexpected msg type %d\n", msg.type);
        return -1;
    }

    ret = ring_buf_dequeue(&ctx->shm.cpl_ring, cpl);
    if (ret < 0) {
        fprintf(stderr, "bridge_wait_completion: completion queue empty\n");
        return -1;
    }

    if (cpl->tag != tag) {
        fprintf(stderr, "bridge_wait_completion: tag mismatch (expected %d, got %d)\n",
                tag, cpl->tag);
        return -1;
    }

    return 0;
}

int bridge_send_tlp_and_wait(bridge_ctx_t *ctx, tlp_entry_t *req, cpl_entry_t *cpl) {
    int ret = bridge_send_tlp(ctx, req);
    if (ret < 0) return ret;
    return bridge_wait_completion(ctx, req->tag, cpl);
}

int bridge_send_tlp_fire(bridge_ctx_t *ctx, tlp_entry_t *req) {
    return bridge_send_tlp(ctx, req);
}

void bridge_destroy(bridge_ctx_t *ctx) {
    if (!ctx) return;
    sock_sync_close(ctx->client_fd);
    sock_sync_close(ctx->listen_fd);
    cosim_shm_destroy(&ctx->shm, ctx->shm_name);
    unlink(ctx->sock_path);
    free(ctx);
}
