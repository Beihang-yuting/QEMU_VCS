/* eth_receiver.c - ETH SHM peer (Role B) that receives and verifies frames
 * from VCS side (Role A).
 *
 * Usage: eth_receiver <shm_name> [timeout_sec] [expected_frames]
 *   shm_name:        POSIX SHM name (e.g., /cosim_eth0)
 *   timeout_sec:     max wait time (default 30)
 *   expected_frames: number of frames to expect (default 4, 0=unlimited)
 *
 * Attaches to existing SHM as Role B, polls for frames, verifies pattern,
 * prints summary and exits.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "eth_port.h"

static int verify_pattern(const uint8_t *data, int len)
{
    int errors = 0;
    for (int i = 0; i < len; i++) {
        if (data[i] != (uint8_t)(i & 0xFF)) {
            if (errors < 5)
                printf("    MISMATCH byte[%d]: got 0x%02x, expect 0x%02x\n",
                       i, data[i], (uint8_t)(i & 0xFF));
            errors++;
        }
    }
    return errors;
}

int main(int argc, char *argv[])
{
    const char *shm_name = (argc >= 2) ? argv[1] : "/cosim_eth0";
    int timeout_sec = (argc >= 3) ? atoi(argv[2]) : 30;
    int expected = (argc >= 4) ? atoi(argv[3]) : 4;

    printf("ETH Receiver: shm=%s timeout=%ds expected=%d\n",
           shm_name, timeout_sec, expected);

    eth_port_t port = {0};

    /* Wait for SHM to be created by VCS (Role A) */
    int wait_count = 0;
    while (eth_port_open(&port, shm_name, ETH_ROLE_B, 0) != 0) {
        if (wait_count++ > timeout_sec * 10) {
            fprintf(stderr, "ERROR: Timed out waiting for SHM '%s'\n", shm_name);
            return 1;
        }
        usleep(100000);  /* 100ms */
    }
    printf("  Attached to SHM as Role B\n");

    /* Mark ourselves ready */
    eth_shm_mark_ready(&port.shm, ETH_ROLE_B);

    int rx_count = 0;
    int pass_count = 0;
    int total_bytes = 0;
    time_t start = time(NULL);

    while (1) {
        eth_frame_t frame;
        int rc = eth_port_recv(&port, &frame, 0);

        if (rc == 0) {
            rx_count++;
            total_bytes += frame.len;
            printf("\n  [Frame %d] seq=%u len=%u\n",
                   rx_count, frame.seq, frame.len);

            /* Print first 8 bytes hex */
            printf("    Data: ");
            for (int i = 0; i < 8 && i < frame.len; i++)
                printf("%02x ", frame.data[i]);
            if (frame.len > 8) printf("...");
            printf("\n");

            /* Verify pattern */
            int errs = verify_pattern(frame.data, frame.len);
            if (errs == 0) {
                printf("    Pattern: PASS (%d bytes)\n", frame.len);
                pass_count++;
            } else {
                printf("    Pattern: FAIL (%d mismatches)\n", errs);
            }

            eth_port_tx_complete(&port);

            /* Got all expected frames? */
            if (expected > 0 && rx_count >= expected)
                break;
        } else {
            /* Check timeout */
            if (difftime(time(NULL), start) > timeout_sec) {
                printf("\n  TIMEOUT after %ds\n", timeout_sec);
                break;
            }
            usleep(10000);  /* 10ms poll interval */
        }
    }

    printf("\n========================================\n");
    printf("ETH Receiver Summary:\n");
    printf("  Frames received: %d\n", rx_count);
    printf("  Pattern passed:  %d\n", pass_count);
    printf("  Total bytes:     %d\n", total_bytes);
    if (expected > 0) {
        printf("  Expected:        %d\n", expected);
        printf("  Result:          %s\n",
               (rx_count == expected && pass_count == expected) ? "ALL PASS" : "FAIL");
    }
    printf("========================================\n");

    eth_port_close(&port);
    return (pass_count == rx_count && rx_count == expected) ? 0 : 1;
}
