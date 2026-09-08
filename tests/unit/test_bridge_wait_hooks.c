#include "bridge_qemu.h"
#include "cosim_transport.h"

#include "test_check.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int send_tlp_rc;
    int send_sync_rc;
    int recv_sync_rc;
    int recv_timed_rc;
    int recv_cpl_rc;
    int match_tag;
    int sync_type;
    uint16_t last_tag;
} fake_state_t;

typedef struct {
    int begin_count;
    int end_count;
    int depth;
    int max_depth;
} hook_state_t;

static int fake_send_tlp(cosim_transport_t *t, const tlp_entry_t *req)
{
    fake_state_t *s = t->priv;
    s->last_tag = req->tag;
    return s->send_tlp_rc;
}

static int fake_send_sync(cosim_transport_t *t, const sync_msg_t *msg)
{
    (void)msg;
    return ((fake_state_t *)t->priv)->send_sync_rc;
}

static int fake_recv_sync(cosim_transport_t *t, sync_msg_t *msg)
{
    fake_state_t *s = t->priv;
    if (s->recv_sync_rc == 0) {
        msg->type = s->sync_type;
        msg->payload = 0;
    }
    return s->recv_sync_rc;
}

static int fake_recv_sync_timed(cosim_transport_t *t, sync_msg_t *msg,
                                int timeout_ms)
{
    fake_state_t *s = t->priv;
    (void)timeout_ms;
    if (s->recv_timed_rc == 0) {
        msg->type = s->sync_type;
        msg->payload = 0;
    }
    return s->recv_timed_rc;
}

static int fake_recv_cpl(cosim_transport_t *t, cpl_entry_t *cpl)
{
    fake_state_t *s = t->priv;
    if (s->recv_cpl_rc == 0) {
        memset(cpl, 0, sizeof(*cpl));
        cpl->type = TLP_CPL;
        cpl->tag = s->match_tag ? s->last_tag
                                : (uint16_t)(s->last_tag ^ 1u);
    }
    return s->recv_cpl_rc;
}

static void hook_begin(void *opaque)
{
    hook_state_t *s = opaque;
    s->begin_count++;
    s->depth++;
    if (s->depth > s->max_depth) {
        s->max_depth = s->depth;
    }
}

static void hook_end(void *opaque)
{
    hook_state_t *s = opaque;
    CHECK(s->depth > 0);
    s->end_count++;
    s->depth--;
}

static void init_ctx(bridge_ctx_t *ctx, cosim_transport_t *transport,
                     fake_state_t *fake, hook_state_t *hooks)
{
    memset(ctx, 0, sizeof(*ctx));
    memset(transport, 0, sizeof(*transport));
    memset(hooks, 0, sizeof(*hooks));
    fake->send_tlp_rc = 0;
    fake->send_sync_rc = 0;
    fake->recv_sync_rc = 0;
    fake->recv_timed_rc = 0;
    fake->recv_cpl_rc = 0;
    fake->match_tag = 1;
    fake->sync_type = SYNC_MSG_CPL_READY;
    transport->send_tlp = fake_send_tlp;
    transport->send_sync = fake_send_sync;
    transport->recv_sync = fake_recv_sync;
    transport->recv_sync_timed = fake_recv_sync_timed;
    transport->recv_cpl = fake_recv_cpl;
    transport->priv = fake;
    ctx->transport = transport;
    ctx->tag_mask = 0xff;
    pthread_mutex_init(&ctx->tlp_mutex, NULL);
    bridge_set_wait_hooks(ctx, hook_begin, hook_end, hooks);
}

static void assert_balanced(const hook_state_t *s, int expected)
{
    CHECK(s->begin_count == expected);
    CHECK(s->end_count == expected);
    CHECK(s->depth == 0);
    CHECK(s->max_depth == 1);
}

static void test_success_and_failures(void)
{
    bridge_ctx_t ctx;
    cosim_transport_t transport;
    fake_state_t fake = {0};
    hook_state_t hooks;
    tlp_entry_t req = { .type = TLP_MRD, .len = 4 };
    cpl_entry_t cpl;

    init_ctx(&ctx, &transport, &fake, &hooks);
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == 0);
    assert_balanced(&hooks, 1);

    fake.send_tlp_rc = -1;
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 2);

    fake.send_tlp_rc = 0;
    fake.send_sync_rc = -1;
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 3);

    fake.send_sync_rc = 0;
    fake.recv_sync_rc = -1;
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 4);

    fake.recv_sync_rc = 0;
    fake.sync_type = SYNC_MSG_DMA_CPL;
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 5);

    fake.sync_type = SYNC_MSG_CPL_READY;
    fake.recv_cpl_rc = -1;
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 6);

    fake.recv_cpl_rc = 0;
    fake.recv_timed_rc = 1;
    CHECK(bridge_send_tlp_and_wait_timed(&ctx, &req, &cpl, 10) == -2);
    assert_balanced(&hooks, 7);

    fake.recv_timed_rc = 0;
    CHECK(bridge_send_tlp_fire(&ctx, &req) == 0);
    assert_balanced(&hooks, 8);

    fake.recv_timed_rc = 1;
    bridge_drain_vf_pending(&ctx, 10);
    assert_balanced(&hooks, 9);

    pthread_mutex_destroy(&ctx.tlp_mutex);
}

static void test_stale_completion_guard_restores_hook(void)
{
    bridge_ctx_t ctx;
    cosim_transport_t transport;
    fake_state_t fake = {0};
    hook_state_t hooks;
    tlp_entry_t req = { .type = TLP_MRD, .len = 4 };
    cpl_entry_t cpl;

    init_ctx(&ctx, &transport, &fake, &hooks);
    fake.match_tag = 0;
    CHECK(bridge_send_tlp_and_wait(&ctx, &req, &cpl) == -1);
    assert_balanced(&hooks, 1);
    pthread_mutex_destroy(&ctx.tlp_mutex);
}

int main(void)
{
    test_success_and_failures();
    test_stale_completion_guard_restores_hook();
    puts("bridge wait-hook tests: PASS");
    return 0;
}
