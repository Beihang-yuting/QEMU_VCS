#ifndef ETH_TYPES_H
#define ETH_TYPES_H

#include <stdint.h>

/* Maximum Ethernet frame payload, including jumbo (9K + overhead) */
#define ETH_FRAME_MAX_DATA     9216u
/* Number of slots per direction in ETH SHM (A->B and B->A) */
#define ETH_FRAME_RING_DEPTH   64u

/* Frame flags */
#define ETH_FRAME_FLAG_DROP    0x01u   /* marked by link model, must not be delivered */
#define ETH_FRAME_FLAG_BROAD   0x02u   /* broadcast */

/* Node role on an ETH link */
typedef enum {
    ETH_ROLE_A = 0,
    ETH_ROLE_B = 1,
} eth_role_t;

typedef struct {
    uint16_t len;                         /* actual payload length in bytes */
    uint16_t flags;                       /* ETH_FRAME_FLAG_* */
    uint32_t seq;                         /* monotonically increasing sequence */
    uint64_t timestamp_ns;                /* sender-side sim time */
    uint8_t  data[ETH_FRAME_MAX_DATA];    /* frame bytes */
} eth_frame_t;

_Static_assert(sizeof(eth_frame_t) <= 9232,
               "eth_frame_t layout exceeded 9232 bytes");

#endif
