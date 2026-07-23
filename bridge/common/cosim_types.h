#ifndef COSIM_TYPES_H
#define COSIM_TYPES_H

#include <stdint.h>
#include "compat_atomic.h"

/* _Static_assert 兼容：
 * - C11+: 原生支持
 * - C99:  不支持，定义为空
 * - C++:  用 static_assert 替代（C++11+），老版本跳过 */
#ifdef __cplusplus
#if __cplusplus >= 201103L
#define _Static_assert(expr, msg)  static_assert(expr, msg)
#else
#define _Static_assert(expr, msg)
#endif
#elif !defined(__STDC_VERSION__) || __STDC_VERSION__ < 201112L
#define _Static_assert(expr, msg)
#endif

#define COSIM_SHM_MAGIC       0xDEADBEEF
#define COSIM_PROTOCOL_VER    1
#define COSIM_TLP_DATA_SIZE   64
#define COSIM_IRQ_SLOTS       8

typedef enum {
    TLP_MWR      = 0,
    TLP_MRD      = 1,
    TLP_CFGWR0   = 2,   /* 原 TLP_CFGWR，改名为 Type 0，值不变 */
    TLP_CFGRD0   = 3,   /* 原 TLP_CFGRD，改名为 Type 0，值不变 */
    TLP_CPL      = 4,
    TLP_CFGWR1   = 5,
    TLP_CFGRD1   = 6,
    TLP_IORD     = 7,
    TLP_IOWR     = 8,
    TLP_CPLD     = 9,
    TLP_MSG      = 10,
    TLP_ATOMIC_FETCHADD = 11,
    TLP_ATOMIC_SWAP     = 12,
    TLP_ATOMIC_CAS      = 13,
    TLP_VENDOR_MSG      = 14,
    TLP_LTR             = 15,
    TLP_MRD_LK          = 16,
    /* ATS Invalidation Request (RC→device). RC/IOMMU tells the device to flush
     * its ATC (Address Translation Cache) for tlp.target_bdf covering tlp.addr;
     * the device responds with a Completion (Invalidation ACK). Sent by QEMU via
     * bridge_send_tlp_and_wait when a per-VF window is torn down. Value 17
     * additive — tlp_entry_t layout/ABI unchanged. */
    TLP_ATS_INVAL       = 17,
} tlp_type_t;

/* 向后兼容别名 */
#define TLP_CFGWR  TLP_CFGWR0
#define TLP_CFGRD  TLP_CFGRD0

typedef enum {
    COSIM_MODE_FAST    = 0,
    COSIM_MODE_PRECISE = 1,
} cosim_mode_t;

typedef enum {
    SYNC_MSG_TLP_READY    = 0,
    SYNC_MSG_CPL_READY    = 1,
    SYNC_MSG_MODE_SWITCH  = 2,
    SYNC_MSG_SHUTDOWN     = 3,
    /* P2 新增 */
    SYNC_MSG_DMA_REQ      = 4,
    SYNC_MSG_DMA_CPL      = 5,
    SYNC_MSG_MSI          = 6,
    SYNC_MSG_CLOCK_STEP   = 7,
    SYNC_MSG_CLOCK_ACK    = 8,
    /* P3: Multi-function / SR-IOV topology */
    SYNC_MSG_QUERY_TOPOLOGY = 0x10,
    SYNC_MSG_TOPOLOGY_RESP  = 0x11,
    SYNC_MSG_VF_EVENT       = 0x12,
    SYNC_MSG_REALIZED       = 0x13,
    SYNC_MSG_VF_CONFIG      = 0x14,
} sync_msg_type_t;

typedef struct {
    sync_msg_type_t type;
    uint32_t        payload;
} sync_msg_t;

typedef struct {
    uint8_t   type;
    uint8_t   _pad_type;      /* alignment padding (was part of old tag) */
    uint16_t  tag;            /* 10-bit tag support (was uint8_t) */
    uint16_t  len;
    uint8_t   msg_code;       /* Message code (TLP_MSG) */
    uint8_t   atomic_op_size; /* AtomicOp operand size: 4 or 8 bytes */
    uint16_t  vendor_id;      /* Vendor Defined Message ID */
    uint16_t  requester_id;   /* PCIe BDF of requester (P3: multi-function) */
    uint16_t  target_bdf;     /* PCIe BDF of target device (P3: routing) */
    uint16_t  _pad_bdf;       /* alignment padding */
    uint64_t  addr;
    uint8_t   data[COSIM_TLP_DATA_SIZE];
    uint64_t  dma_offset;
    uint64_t  timestamp;
    uint8_t   first_be;       /* First DW Byte Enable */
    uint8_t   last_be;        /* Last DW Byte Enable */
    uint8_t   _reserved[6];
} __attribute__((packed)) tlp_entry_t;

_Static_assert(sizeof(tlp_entry_t) == 112, "tlp_entry_t must be 112 bytes");

typedef struct {
    uint8_t   type;
    uint8_t   status;
    uint16_t  tag;            /* 10-bit tag support (was uint8_t) */
    uint16_t  requester_id;   /* PCIe BDF of original requester (P3) */
    uint16_t  completer_id;   /* PCIe BDF of completer (P3) */
    uint32_t  len;
    uint8_t   data[COSIM_TLP_DATA_SIZE];
    uint64_t  timestamp;
} __attribute__((packed)) cpl_entry_t;

_Static_assert(sizeof(cpl_entry_t) == 84, "cpl_entry_t must be 84 bytes");

/* ========== DMA 请求（VCS 发起，QEMU 处理） ========== */
typedef enum {
    DMA_DIR_READ  = 0,
    DMA_DIR_WRITE = 1,
    /* Inbound AtomicOp (DUT/EP requester → Host completer). Operand(s) ride in
     * DMA_DATA (like a write): FetchAdd/Swap = 1 operand (op_size B), CAS =
     * compare‖swap (2*op_size B). dma_req_t.len carries op_size (4 or 8). The
     * host RMW returns the ORIGINAL value via DMA_DATA+DMA_CPL (like a read).
     * Values 2..4 are additive — struct layout/ABI unchanged. */
    DMA_DIR_ATOMIC_FETCHADD = 2,
    DMA_DIR_ATOMIC_SWAP     = 3,
    DMA_DIR_ATOMIC_CAS      = 4,
    /* ATS/PRI (device-side address translation). Requester = DUT/EP.
     *  ATS_TRANSLATE: device asks the RC/IOMMU to translate an untranslated
     *    address (host_addr = IOVA). RC replies via DMA_DATA+DMA_CPL: data = 8B
     *    translated PA, cpl.status = 0 granted / non-0 no-translation (denied).
     *    Models a PCIe ATS Translation Request/Completion round-trip.
     *  ATS_PAGE_REQ (PRI): device requests the host make a page present;
     *    cpl.status = 0 granted / non-0 denied (models a Page Request / PRG
     *    Response). Values 5..6 additive — struct layout/ABI unchanged. */
    DMA_DIR_ATS_TRANSLATE   = 5,
    DMA_DIR_ATS_PAGE_REQ    = 6,
} dma_direction_t;

#define DMA_DIR_IS_ATOMIC(d) \
    ((d) >= DMA_DIR_ATOMIC_FETCHADD && (d) <= DMA_DIR_ATOMIC_CAS)

/* AT=Translated flag OR'd into dma_req_t.direction: the host_addr is already
 * IOMMU-translated (PCIe AT=10). The RC trusts it and bypasses the per-VF IOMMU
 * window (the translation was pre-authorized via DMA_DIR_ATS_TRANSLATE). The
 * low bits still carry DMA_DIR_READ/WRITE. High bit avoids colliding with the
 * additive opcode values above. */
#define DMA_AT_TRANSLATED   0x80000000u
#define DMA_DIR_BASE(d)     ((d) & ~DMA_AT_TRANSLATED)
#define DMA_DIR_IS_TRANSLATED(d) (((d) & DMA_AT_TRANSLATED) != 0)

typedef struct {
    uint16_t requester_id;    /* PCIe BDF of DMA initiator (P3: multi-function) */
    uint16_t _pad_rid;
    uint32_t tag;
    uint32_t direction;
    uint64_t host_addr;
    uint32_t len;
    uint32_t dma_offset;
    uint32_t timestamp;       /* narrowed from uint64_t to fit requester_id */
} __attribute__((packed)) dma_req_t;

_Static_assert(sizeof(dma_req_t) == 32, "dma_req_t must be 32 bytes");

typedef struct {
    uint32_t tag;
    uint32_t status;
    uint64_t timestamp;
} __attribute__((packed)) dma_cpl_t;

_Static_assert(sizeof(dma_cpl_t) == 16, "dma_cpl_t must be 16 bytes");

/* ========== MSI 事件 ========== */
typedef struct {
    uint16_t requester_id;    /* PCIe BDF of MSI source (P3: multi-function) */
    uint16_t vector;          /* MSI-X vector index (narrowed from uint32_t) */
    uint32_t _pad0;
    uint64_t timestamp;
} __attribute__((packed)) msi_event_t;

_Static_assert(sizeof(msi_event_t) == 16, "msi_event_t must be 16 bytes");

/* ========== 时钟同步（精确模式） ========== */
typedef struct {
    uint64_t cycles;
    uint64_t sim_time_ns;
} __attribute__((packed)) clock_sync_t;

_Static_assert(sizeof(clock_sync_t) == 16, "clock_sync_t must be 16 bytes");

#endif /* COSIM_TYPES_H */
