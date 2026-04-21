/* test_tcp_cross_machine.c — 跨机 TCP 传输层验证
 *
 * 用法:
 *   Server (QEMU 侧): ./test_tcp_cross_machine --server --port 9100
 *   Client (VCS  侧): ./test_tcp_cross_machine --client --host 10.11.10.53 --port 9100
 *
 * 测试内容:
 *   1. TCP 连接 + handshake
 *   2. sync_msg roundtrip (10 次)
 *   3. TLP + CPL roundtrip (10 次)
 *   4. DMA req + cpl roundtrip (5 次)
 *   5. MSI event (5 次)
 *   6. ETH frame (5 次, 各种大小)
 */
#define _GNU_SOURCE
#include "cosim_transport.h"
#include "cosim_types.h"
#include "eth_types.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#define CHECK(cond) do { \
    if (!(cond)) { \
        fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        fflush(stderr); \
        return 1; \
    } \
} while (0)

static uint64_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000;
}

static int run_server(int port) {
    printf("[Server] Starting on 0.0.0.0:%d...\n", port);

    transport_cfg_t cfg = {
        .transport   = "tcp",
        .listen_addr = "0.0.0.0",
        .port_base   = port,
        .instance_id = 0,
        .is_server   = 1,
    };
    cosim_transport_t *t = transport_create(&cfg);
    if (!t) {
        fprintf(stderr, "[Server] transport_create failed\n");
        return 1;
    }
    t->set_ready(t);
    printf("[Server] Client connected!\n\n");

    /* Test 1: sync_msg roundtrip */
    printf("[Server] Test 1: sync_msg roundtrip (10x)...\n");
    for (int i = 0; i < 10; i++) {
        sync_msg_t msg;
        CHECK(t->recv_sync(t, &msg) == 0);
        CHECK(msg.type == SYNC_MSG_TLP_READY);
        CHECK(msg.payload == (uint32_t)i);

        sync_msg_t ack = { .type = SYNC_MSG_CPL_READY, .payload = (uint32_t)(i + 100) };
        CHECK(t->send_sync(t, &ack) == 0);
    }
    printf("[Server] Test 1: PASS\n\n");

    /* Test 2: TLP + CPL roundtrip */
    printf("[Server] Test 2: TLP+CPL roundtrip (10x)...\n");
    for (int i = 0; i < 10; i++) {
        tlp_entry_t tlp;
        CHECK(t->recv_tlp(t, &tlp) == 0);
        CHECK(tlp.type == TLP_MRD);
        CHECK(tlp.tag == (uint8_t)i);

        cpl_entry_t cpl;
        memset(&cpl, 0, sizeof(cpl));
        cpl.type = TLP_CPL;
        cpl.tag = tlp.tag;
        cpl.status = 0;
        cpl.len = 4;
        uint32_t val = 0xBEEF0000 + (uint32_t)i;
        memcpy(cpl.data, &val, 4);
        CHECK(t->send_cpl(t, &cpl) == 0);
    }
    printf("[Server] Test 2: PASS\n\n");

    /* Test 3: DMA roundtrip */
    printf("[Server] Test 3: DMA roundtrip (5x)...\n");
    for (int i = 0; i < 5; i++) {
        dma_req_t req;
        CHECK(t->recv_dma_req(t, &req) == 0);
        CHECK(req.tag == (uint32_t)(2000 + i));

        dma_cpl_t cpl = { .tag = req.tag, .status = 0, .timestamp = now_us() };
        CHECK(t->send_dma_cpl(t, &cpl) == 0);
    }
    printf("[Server] Test 3: PASS\n\n");

    /* Test 4: MSI */
    printf("[Server] Test 4: MSI event (5x)...\n");
    for (int i = 0; i < 5; i++) {
        msi_event_t ev;
        CHECK(t->recv_msi(t, &ev) == 0);
        CHECK(ev.vector == (uint32_t)(i + 1));
    }
    printf("[Server] Test 4: PASS\n\n");

    /* Test 5: ETH frames */
    printf("[Server] Test 5: ETH frame (5x)...\n");
    uint16_t sizes[] = { 64, 512, 1500, 4096, 9000 };
    for (int i = 0; i < 5; i++) {
        eth_frame_t frame;
        memset(&frame, 0, sizeof(frame));
        frame.len = sizes[i];
        frame.seq = (uint32_t)(i + 1);
        for (uint16_t j = 0; j < sizes[i]; j++)
            frame.data[j] = (uint8_t)((j + i) & 0xFF);

        CHECK(t->send_eth(t, &frame) == 0);
        printf("[Server]   Sent ETH frame %d: %u bytes\n", i + 1, sizes[i]);
    }
    printf("[Server] Test 5: PASS\n\n");

    /* done — wait for client ACK */
    sync_msg_t done_msg;
    t->recv_sync_timed(t, &done_msg, 2000);

    t->close(t);
    printf("[Server] === ALL TESTS PASSED ===\n");
    return 0;
}

static int run_client(const char *host, int port) {
    printf("[Client] Connecting to %s:%d...\n", host, port);

    transport_cfg_t cfg = {
        .transport   = "tcp",
        .remote_host = host,
        .port_base   = port,
        .instance_id = 0,
        .is_server   = 0,
    };
    cosim_transport_t *t = transport_create(&cfg);
    if (!t) {
        fprintf(stderr, "[Client] transport_create failed\n");
        return 1;
    }
    t->set_ready(t);
    printf("[Client] Connected!\n\n");

    /* Test 1: sync_msg roundtrip */
    printf("[Client] Test 1: sync_msg roundtrip (10x)...\n");
    uint64_t lat_sum = 0;
    for (int i = 0; i < 10; i++) {
        uint64_t t0 = now_us();
        sync_msg_t msg = { .type = SYNC_MSG_TLP_READY, .payload = (uint32_t)i };
        CHECK(t->send_sync(t, &msg) == 0);

        sync_msg_t ack;
        CHECK(t->recv_sync(t, &ack) == 0);
        uint64_t lat = now_us() - t0;
        lat_sum += lat;
        CHECK(ack.type == SYNC_MSG_CPL_READY);
        CHECK(ack.payload == (uint32_t)(i + 100));
        printf("[Client]   sync roundtrip %d: %lu us\n", i + 1, (unsigned long)lat);
    }
    printf("[Client] Test 1: PASS (avg %lu us)\n\n", (unsigned long)(lat_sum / 10));

    /* Test 2: TLP + CPL roundtrip */
    printf("[Client] Test 2: TLP+CPL roundtrip (10x)...\n");
    lat_sum = 0;
    for (int i = 0; i < 10; i++) {
        uint64_t t0 = now_us();
        tlp_entry_t tlp;
        memset(&tlp, 0, sizeof(tlp));
        tlp.type = TLP_MRD;
        tlp.tag = (uint8_t)i;
        tlp.len = 4;
        tlp.addr = (uint64_t)(0x1000 + i * 4);
        CHECK(t->send_tlp(t, &tlp) == 0);

        cpl_entry_t cpl;
        CHECK(t->recv_cpl(t, &cpl) == 0);
        uint64_t lat = now_us() - t0;
        lat_sum += lat;
        CHECK(cpl.tag == (uint8_t)i);
        uint32_t val;
        memcpy(&val, cpl.data, 4);
        CHECK(val == 0xBEEF0000 + (uint32_t)i);
        printf("[Client]   TLP roundtrip %d: %lu us\n", i + 1, (unsigned long)lat);
    }
    printf("[Client] Test 2: PASS (avg %lu us)\n\n", (unsigned long)(lat_sum / 10));

    /* Test 3: DMA roundtrip */
    printf("[Client] Test 3: DMA roundtrip (5x)...\n");
    lat_sum = 0;
    for (int i = 0; i < 5; i++) {
        uint64_t t0 = now_us();
        dma_req_t req = {
            .tag = (uint32_t)(2000 + i),
            .direction = DMA_DIR_READ,
            .host_addr = 0x80000000ULL + (uint64_t)(i * 0x1000),
            .len = 64,
            .dma_offset = 0,
            .timestamp = now_us(),
        };
        CHECK(t->send_dma_req(t, &req) == 0);

        dma_cpl_t cpl;
        CHECK(t->recv_dma_cpl(t, &cpl) == 0);
        uint64_t lat = now_us() - t0;
        lat_sum += lat;
        CHECK(cpl.tag == (uint32_t)(2000 + i));
        CHECK(cpl.status == 0);
        printf("[Client]   DMA roundtrip %d: %lu us\n", i + 1, (unsigned long)lat);
    }
    printf("[Client] Test 3: PASS (avg %lu us)\n\n", (unsigned long)(lat_sum / 5));

    /* Test 4: MSI */
    printf("[Client] Test 4: MSI event (5x)...\n");
    for (int i = 0; i < 5; i++) {
        msi_event_t ev = { .vector = (uint32_t)(i + 1), .timestamp = now_us() };
        CHECK(t->send_msi(t, &ev) == 0);
    }
    printf("[Client] Test 4: PASS\n\n");

    /* Test 5: ETH frames */
    printf("[Client] Test 5: ETH frame (5x)...\n");
    uint16_t sizes[] = { 64, 512, 1500, 4096, 9000 };
    for (int i = 0; i < 5; i++) {
        eth_frame_t frame;
        CHECK(t->recv_eth(t, &frame, 5000000000ULL) == 0);
        CHECK(frame.len == sizes[i]);
        CHECK(frame.seq == (uint32_t)(i + 1));
        for (uint16_t j = 0; j < sizes[i]; j++) {
            CHECK(frame.data[j] == (uint8_t)((j + i) & 0xFF));
        }
        printf("[Client]   Recv ETH frame %d: %u bytes OK\n", i + 1, sizes[i]);
    }
    printf("[Client] Test 5: PASS\n\n");

    /* notify server we're done */
    sync_msg_t done = { .type = SYNC_MSG_TLP_READY, .payload = 0xFFFF };
    t->send_sync(t, &done);

    t->close(t);
    printf("[Client] === ALL TESTS PASSED ===\n");
    return 0;
}

int main(int argc, char *argv[]) {
    int is_server = 0, is_client = 0;
    const char *host = "127.0.0.1";
    int port = 9100;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--server") == 0) is_server = 1;
        else if (strcmp(argv[i], "--client") == 0) is_client = 1;
        else if (strcmp(argv[i], "--host") == 0 && i + 1 < argc) host = argv[++i];
        else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) port = atoi(argv[++i]);
    }

    if (!is_server && !is_client) {
        fprintf(stderr, "Usage:\n");
        fprintf(stderr, "  %s --server [--port PORT]\n", argv[0]);
        fprintf(stderr, "  %s --client --host HOST [--port PORT]\n", argv[0]);
        return 1;
    }

    printf("=== TCP Cross-Machine Transport Test ===\n");
    printf("Mode: %s, Port: %d\n\n", is_server ? "SERVER" : "CLIENT", port);

    if (is_server) return run_server(port);
    else return run_client(host, port);
}
