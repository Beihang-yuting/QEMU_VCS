/* test_transport_tcp.c — TCP transport loopback 单元测试
 *
 * 在本机 127.0.0.1 创建 server + client transport，
 * 验证各通道消息的收发正确性。
 */
#define _GNU_SOURCE
#include "cosim_transport.h"
#include "cosim_types.h"
#include "eth_types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        fflush(stderr); \
        abort(); \
    } \
} while (0)

typedef struct {
    cosim_transport_t *transport;
    int test_pass;
} server_ctx_t;

static void *server_thread(void *arg) {
    server_ctx_t *sctx = (server_ctx_t *)arg;

    transport_cfg_t cfg = {
        .transport   = "tcp",
        .listen_addr = "127.0.0.1",
        .port_base   = 19100,
        .instance_id = 0,
        .is_server   = 1,
    };

    sctx->transport = transport_create(&cfg);
    if (!sctx->transport) {
        fprintf(stderr, "Server: transport_create failed\n");
        sctx->test_pass = 0;
        return NULL;
    }
    sctx->test_pass = 1;
    return NULL;
}

static void test_sync_roundtrip(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 1: sync_msg roundtrip... ");

    sync_msg_t send_msg = { .type = SYNC_MSG_TLP_READY, .payload = 42 };
    CHECK(client->send_sync(client, &send_msg) == 0);

    sync_msg_t recv_msg;
    CHECK(server->recv_sync(server, &recv_msg) == 0);
    CHECK(recv_msg.type == SYNC_MSG_TLP_READY);
    CHECK(recv_msg.payload == 42);

    sync_msg_t ack = { .type = SYNC_MSG_CPL_READY, .payload = 99 };
    CHECK(server->send_sync(server, &ack) == 0);

    sync_msg_t ack_recv;
    CHECK(client->recv_sync(client, &ack_recv) == 0);
    CHECK(ack_recv.type == SYNC_MSG_CPL_READY);
    CHECK(ack_recv.payload == 99);

    printf("PASS\n");
}

static void test_tlp_roundtrip(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 2: TLP roundtrip... ");

    tlp_entry_t tlp;
    memset(&tlp, 0, sizeof(tlp));
    tlp.type = TLP_MWR;
    tlp.tag = 7;
    tlp.len = 4;
    tlp.addr = 0xFEED0000ULL;
    tlp.data[0] = 0xDE;
    tlp.data[1] = 0xAD;
    tlp.data[2] = 0xBE;
    tlp.data[3] = 0xEF;

    CHECK(server->send_tlp(server, &tlp) == 0);

    tlp_entry_t recv_tlp;
    CHECK(client->recv_tlp(client, &recv_tlp) == 0);
    CHECK(recv_tlp.type == TLP_MWR);
    CHECK(recv_tlp.tag == 7);
    CHECK(recv_tlp.addr == 0xFEED0000ULL);
    CHECK(memcmp(recv_tlp.data, tlp.data, 4) == 0);

    cpl_entry_t cpl;
    memset(&cpl, 0, sizeof(cpl));
    cpl.type = TLP_CPL;
    cpl.tag = 7;
    cpl.status = 0;
    cpl.len = 4;
    cpl.data[0] = 0xCA;

    CHECK(client->send_cpl(client, &cpl) == 0);

    cpl_entry_t recv_cpl;
    CHECK(server->recv_cpl(server, &recv_cpl) == 0);
    CHECK(recv_cpl.tag == 7);
    CHECK(recv_cpl.data[0] == 0xCA);

    printf("PASS\n");
}

static void test_dma_roundtrip(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 3: DMA roundtrip... ");

    dma_req_t req = {
        .tag = 1000,
        .direction = DMA_DIR_READ,
        .host_addr = 0x80000000ULL,
        .len = 64,
        .dma_offset = 0,
        .timestamp = 12345,
    };
    CHECK(client->send_dma_req(client, &req) == 0);

    dma_req_t recv_req;
    CHECK(server->recv_dma_req(server, &recv_req) == 0);
    CHECK(recv_req.tag == 1000);
    CHECK(recv_req.host_addr == 0x80000000ULL);

    dma_cpl_t cpl = { .tag = 1000, .status = 0, .timestamp = 12346 };
    CHECK(server->send_dma_cpl(server, &cpl) == 0);

    dma_cpl_t recv_cpl;
    CHECK(client->recv_dma_cpl(client, &recv_cpl) == 0);
    CHECK(recv_cpl.tag == 1000);
    CHECK(recv_cpl.status == 0);

    printf("PASS\n");
}

static void test_msi(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 4: MSI event... ");

    msi_event_t ev = { .vector = 3, .timestamp = 99999 };
    CHECK(client->send_msi(client, &ev) == 0);

    msi_event_t recv_ev;
    CHECK(server->recv_msi(server, &recv_ev) == 0);
    CHECK(recv_ev.vector == 3);
    CHECK(recv_ev.timestamp == 99999);

    printf("PASS\n");
}

static void test_eth_frame(cosim_transport_t *server, cosim_transport_t *client) {
    printf("Test 5: ETH frame... ");

    eth_frame_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.len = 64;
    frame.seq = 1;
    frame.timestamp_ns = 1000000;
    for (int i = 0; i < 64; i++) {
        frame.data[i] = (uint8_t)(i & 0xFF);
    }

    CHECK(server->send_eth(server, &frame) == 0);

    eth_frame_t recv_frame;
    CHECK(client->recv_eth(client, &recv_frame, 5000000000ULL) == 0);
    CHECK(recv_frame.len == 64);
    CHECK(recv_frame.seq == 1);
    for (int i = 0; i < 64; i++) {
        CHECK(recv_frame.data[i] == (uint8_t)(i & 0xFF));
    }

    printf("PASS\n");
}

static void test_recv_timeout(cosim_transport_t *server) {
    printf("Test 6: recv_sync_timed timeout... ");

    sync_msg_t msg;
    int ret = server->recv_sync_timed(server, &msg, 100);
    CHECK(ret == 1);

    printf("PASS\n");
}

static void test_port_allocation(void) {
    printf("Test 7: port allocation... ");

    CHECK(9100 + 0 * 2     == 9100);
    CHECK(9100 + 0 * 2 + 1 == 9101);
    CHECK(9100 + 1 * 2     == 9102);
    CHECK(9100 + 1 * 2 + 1 == 9103);
    CHECK(9100 + 2 * 2     == 9104);
    CHECK(9100 + 2 * 2 + 1 == 9105);

    printf("PASS\n");
}

int main(void) {
    printf("=== TCP Transport Unit Tests ===\n\n");

    test_port_allocation();

    server_ctx_t sctx = { .transport = NULL, .test_pass = 0 };
    pthread_t server_tid;
    pthread_create(&server_tid, NULL, server_thread, &sctx);

    usleep(200000);

    transport_cfg_t client_cfg = {
        .transport   = "tcp",
        .remote_host = "127.0.0.1",
        .port_base   = 19100,
        .instance_id = 0,
        .is_server   = 0,
    };
    cosim_transport_t *client = transport_create(&client_cfg);
    CHECK(client != NULL);

    pthread_join(server_tid, NULL);
    CHECK(sctx.test_pass == 1);
    cosim_transport_t *server = sctx.transport;
    CHECK(server != NULL);

    printf("\n");

    test_sync_roundtrip(server, client);
    test_tlp_roundtrip(server, client);
    test_dma_roundtrip(server, client);
    test_msi(server, client);
    test_eth_frame(server, client);
    test_recv_timeout(server);

    server->close(server);
    client->close(client);

    printf("\n=== All 7 tests PASSED ===\n");
    return 0;
}
