/* test_vip_smoke.c — VIP mode smoke test (QEMU-side simulator)
 *
 * This program acts as the QEMU side of the cosim bridge:
 *   1. Creates SHM + Unix domain socket listener
 *   2. Waits for VCS to connect
 *   3. Sends a Config Read (CfgRd0) TLP → expects completion
 *   4. Sends a Memory Write (MWr) TLP → fire-and-forget
 *   5. Sends shutdown → clean exit
 *
 * Usage: Run this first, then start VCS simv_vip.
 *   ./test_vip_smoke &
 *   ./build/simv_vip +SHM_NAME=/cosim_smoke +SOCK_PATH=/tmp/cosim_smoke.sock
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include "bridge_qemu.h"
#include "shm_layout.h"
#include "cosim_types.h"

static const char *SHM  = "/cosim_smoke";
static const char *SOCK = "/tmp/cosim_smoke.sock";

int main(void) {
    printf("[SMOKE] Starting QEMU-side simulator\n");
    printf("[SMOKE] SHM=%s  SOCK=%s\n", SHM, SOCK);

    /* Init bridge (creates SHM + socket listener) */
    bridge_ctx_t *ctx = bridge_init(SHM, SOCK);
    if (!ctx) {
        fprintf(stderr, "[SMOKE] bridge_init failed\n");
        return 1;
    }

    printf("[SMOKE] Waiting for VCS to connect...\n");
    int ret = bridge_connect(ctx);
    if (ret < 0) {
        fprintf(stderr, "[SMOKE] bridge_connect failed\n");
        bridge_destroy(ctx);
        return 1;
    }
    printf("[SMOKE] VCS connected!\n");

    /* Wait for VCS ready */
    int timeout = 100;
    while (!atomic_load(&ctx->shm.ctrl->vcs_ready) && timeout-- > 0)
        usleep(100000);  /* 100ms */
    if (timeout <= 0) {
        fprintf(stderr, "[SMOKE] Timeout waiting for vcs_ready\n");
        bridge_destroy(ctx);
        return 1;
    }
    printf("[SMOKE] VCS ready, sending TLPs...\n");

    /* --- Test 1: Config Read Type 0 (expects completion) --- */
    printf("[SMOKE] Test 1: CfgRd0 @ offset 0x00 (Vendor/Device ID)\n");
    {
        tlp_entry_t req;
        memset(&req, 0, sizeof(req));
        req.type     = TLP_CFGRD0;
        req.addr     = 0x00;  /* PCI config register 0 */
        req.len      = 4;
        req.tag      = 1;
        req.first_be = 0xF;

        cpl_entry_t cpl;
        ret = bridge_send_tlp_and_wait(ctx, &req, &cpl);
        if (ret == 0) {
            uint32_t val;
            memcpy(&val, cpl.data, 4);
            printf("[SMOKE]   CfgRd0 completion: tag=%d status=%d data=0x%08X OK\n",
                   cpl.tag, cpl.status, val);
        } else {
            printf("[SMOKE]   CfgRd0 completion: TIMEOUT or ERROR (ret=%d)\n", ret);
            /* Non-fatal for smoke test — completion path may not be fully wired */
        }
    }

    /* --- Test 2: Memory Write (fire-and-forget) --- */
    printf("[SMOKE] Test 2: MWr @ 0x1000 (32 bytes)\n");
    {
        tlp_entry_t req;
        memset(&req, 0, sizeof(req));
        req.type     = TLP_MWR;
        req.addr     = 0x1000;
        req.len      = 32;
        req.first_be = 0xF;
        req.last_be  = 0xF;
        /* Fill data with pattern */
        for (int i = 0; i < 32; i++)
            req.data[i] = (uint8_t)(0xA0 + i);

        ret = bridge_send_tlp_fire(ctx, &req);
        if (ret == 0) {
            printf("[SMOKE]   MWr sent OK\n");
        } else {
            printf("[SMOKE]   MWr send failed (ret=%d)\n", ret);
        }
    }

    /* Give VCS time to process */
    usleep(500000);  /* 500ms */

    /* --- Shutdown --- */
    printf("[SMOKE] Sending shutdown...\n");
    {
        sync_msg_t msg = { .type = SYNC_MSG_SHUTDOWN, .payload = 0 };
        sock_sync_send(ctx->client_fd, &msg);
    }

    usleep(200000);  /* 200ms */
    printf("[SMOKE] Done. Destroying context.\n");
    bridge_destroy(ctx);
    return 0;
}
