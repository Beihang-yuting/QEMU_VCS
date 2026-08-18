#ifndef COSIM_TABLE_PROTOCOL_H
#define COSIM_TABLE_PROTOCOL_H

/*
 * Semantic table sideband wire protocol.
 *
 * All multi-byte fields are little-endian on the wire.  The records stay
 * packed so Linux, QEMU, and VCS userspace share one fixed-width ABI.
 */
#ifdef __KERNEL__
#include <asm/byteorder.h>
#include <linux/build_bug.h>
#include <linux/types.h>
typedef u8 cosim_u8;
typedef u16 cosim_u16;
typedef u32 cosim_u32;
typedef u64 cosim_u64;
#define COSIM_STATIC_ASSERT(condition, message) static_assert(condition, message)
#ifndef UINT32_C
#define UINT32_C(value) value##U
#endif
#else
#include <stdint.h>
typedef uint8_t cosim_u8;
typedef uint16_t cosim_u16;
typedef uint32_t cosim_u32;
typedef uint64_t cosim_u64;
#define COSIM_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif

#ifdef __KERNEL__
static inline cosim_u16 cosim_table_cpu_to_le16(cosim_u16 value)
{
    return (__force cosim_u16)cpu_to_le16(value);
}

static inline cosim_u32 cosim_table_cpu_to_le32(cosim_u32 value)
{
    return (__force cosim_u32)cpu_to_le32(value);
}

static inline cosim_u64 cosim_table_cpu_to_le64(cosim_u64 value)
{
    return (__force cosim_u64)cpu_to_le64(value);
}

static inline cosim_u16 cosim_table_le16_to_cpu(cosim_u16 value)
{
    return (cosim_u16)le16_to_cpu((__force __le16)value);
}

static inline cosim_u32 cosim_table_le32_to_cpu(cosim_u32 value)
{
    return (cosim_u32)le32_to_cpu((__force __le32)value);
}

static inline cosim_u64 cosim_table_le64_to_cpu(cosim_u64 value)
{
    return (cosim_u64)le64_to_cpu((__force __le64)value);
}
#else
#if !defined(__BYTE_ORDER__) || !defined(__ORDER_LITTLE_ENDIAN__) || \
    !defined(__ORDER_BIG_ENDIAN__)
#error "cosim table protocol requires compiler byte-order macros"
#elif __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
static inline cosim_u16 cosim_table_cpu_to_le16(cosim_u16 value)
{
    return value;
}

static inline cosim_u32 cosim_table_cpu_to_le32(cosim_u32 value)
{
    return value;
}

static inline cosim_u64 cosim_table_cpu_to_le64(cosim_u64 value)
{
    return value;
}

static inline cosim_u16 cosim_table_le16_to_cpu(cosim_u16 value)
{
    return value;
}

static inline cosim_u32 cosim_table_le32_to_cpu(cosim_u32 value)
{
    return value;
}

static inline cosim_u64 cosim_table_le64_to_cpu(cosim_u64 value)
{
    return value;
}
#elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
static inline cosim_u16 cosim_table_cpu_to_le16(cosim_u16 value)
{
    return (cosim_u16)__builtin_bswap16(value);
}

static inline cosim_u32 cosim_table_cpu_to_le32(cosim_u32 value)
{
    return (cosim_u32)__builtin_bswap32(value);
}

static inline cosim_u64 cosim_table_cpu_to_le64(cosim_u64 value)
{
    return (cosim_u64)__builtin_bswap64(value);
}

static inline cosim_u16 cosim_table_le16_to_cpu(cosim_u16 value)
{
    return (cosim_u16)__builtin_bswap16(value);
}

static inline cosim_u32 cosim_table_le32_to_cpu(cosim_u32 value)
{
    return (cosim_u32)__builtin_bswap32(value);
}

static inline cosim_u64 cosim_table_le64_to_cpu(cosim_u64 value)
{
    return (cosim_u64)__builtin_bswap64(value);
}
#else
#error "cosim table protocol does not support this compiler byte order"
#endif
#endif

#define COSIM_TABLE_MAGIC UINT32_C(0x4c425443)
#define COSIM_TABLE_PROTOCOL_VERSION 1u
#define COSIM_TABLE_CTRL_VENDOR_ID 0x1af4
#define COSIM_TABLE_CTRL_DEVICE_ID 0x10f0
#define COSIM_TABLE_CTRL_BAR_BYTES 0x1000u
#define COSIM_TABLE_HANDLER_NAME_BYTES 64u
#define COSIM_TABLE_FRAME_DATA_BYTES (64u * 1024u)
#define COSIM_TABLE_DEFAULT_PORT_BASE 10100u
/* Cross-endpoint resource ceilings; both route peers must enforce these. */
#define COSIM_TABLE_MAX_ROUTES 65536u
#define COSIM_TABLE_MAX_WRITE_BYTES (64u * 1024u * 1024u)

static inline int cosim_table_route_count_supported(cosim_u64 count)
{
    return count != 0 && count <= COSIM_TABLE_MAX_ROUTES;
}

static inline int cosim_table_write_bytes_supported(cosim_u64 bytes)
{
    return bytes != 0 && bytes <= COSIM_TABLE_MAX_WRITE_BYTES;
}

typedef enum {
    COSIM_TABLE_MSG_HELLO = 1,
    COSIM_TABLE_MSG_CAPABILITY = 2,
    COSIM_TABLE_MSG_ROUTE_BEGIN = 3,
    COSIM_TABLE_MSG_ROUTE_ENTRY = 4,
    COSIM_TABLE_MSG_ROUTE_END = 5,
    COSIM_TABLE_MSG_WRITE_BEGIN = 6,
    COSIM_TABLE_MSG_WRITE_DATA = 7,
    COSIM_TABLE_MSG_WRITE_END = 8,
    COSIM_TABLE_MSG_READ_DWORD = 9,
    COSIM_TABLE_MSG_COMPLETION = 10,
    COSIM_TABLE_MSG_SHUTDOWN = 11,
} cosim_table_msg_type_t;

typedef enum {
    COSIM_TABLE_ST_SUCCESS = 0,
    COSIM_TABLE_ST_NOT_READY = 1,
    COSIM_TABLE_ST_NO_ROUTE = 2,
    COSIM_TABLE_ST_UNSUPPORTED = 3,
    COSIM_TABLE_ST_SLOT_BUSY = 4,
    COSIM_TABLE_ST_EXEC_ERROR = 5,
    COSIM_TABLE_ST_TIMEOUT = 6,
    COSIM_TABLE_ST_UNKNOWN = 7,
    COSIM_TABLE_ST_TARGET_GONE = 8,
    COSIM_TABLE_ST_PROTOCOL = 9,
} cosim_table_status_t;

static inline int
cosim_table_status_may_frontdoor(cosim_table_status_t status)
{
    return status == COSIM_TABLE_ST_NOT_READY ||
           status == COSIM_TABLE_ST_NO_ROUTE ||
           status == COSIM_TABLE_ST_UNSUPPORTED ||
           status == COSIM_TABLE_ST_SLOT_BUSY;
}

enum {
    COSIM_TABLE_TARGET_PF = 0,
    COSIM_TABLE_TARGET_VF = 1,
};

enum {
    COSIM_TABLE_OP_WRITE = 1u << 0,
    COSIM_TABLE_OP_READ_DWORD = 1u << 1,
};

enum {
    COSIM_TABLE_CAP_WRITE = 1u << 0,
    COSIM_TABLE_CAP_READ_DWORD = 1u << 1,
};

typedef struct __attribute__((packed)) {
    cosim_u32 magic;
    cosim_u16 version;
    cosim_u16 type;
    cosim_u32 header_bytes;
    cosim_u32 payload_bytes;
    cosim_u64 transaction_id;
} cosim_table_frame_hdr_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_frame_hdr_t) == 24,
                    "cosim_table_frame_hdr_t must be 24 bytes");

typedef struct __attribute__((packed)) {
    cosim_u16 rc_id;
    cosim_u16 device_instance;
    cosim_u16 pci_domain;
    cosim_u16 target_bdf;
    cosim_u8 target_type;
    cosim_u8 pf_index;
    cosim_u16 vf_index;
    cosim_u8 bar_index;
    cosim_u8 reserved0[3];
    cosim_u32 generation;
    cosim_u32 reserved1;
} cosim_table_target_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_target_t) == 24,
                    "cosim_table_target_t must be 24 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 protocol_version;
    cosim_u32 max_frame_data_bytes;
    cosim_u32 capabilities;
    cosim_u32 reserved;
} cosim_table_hello_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_hello_t) == 16,
                    "cosim_table_hello_t must be 16 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 capabilities;
    cosim_u32 max_routes;
    cosim_u32 max_write_bytes;
    cosim_u32 reserved;
} cosim_table_capability_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_capability_t) == 16,
                    "cosim_table_capability_t must be 16 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 generation;
    cosim_u32 entry_count;
} cosim_table_route_begin_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_route_begin_t) == 8,
                    "cosim_table_route_begin_t must be 8 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 route_id;
    cosim_table_target_t target;
    cosim_u32 operation_mask;
    cosim_u64 start_offset;
    cosim_u64 end_offset;
    cosim_u32 entry_bytes;
    cosim_u32 stride_bytes;
    cosim_u32 index_base;
    cosim_u32 reserved;
    cosim_u8 handler_name[COSIM_TABLE_HANDLER_NAME_BYTES];
} cosim_table_route_entry_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_route_entry_t) == 128,
                    "cosim_table_route_entry_t must be 128 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 generation;
    cosim_u32 reserved;
} cosim_table_route_end_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_route_end_t) == 8,
                    "cosim_table_route_end_t must be 8 bytes");

typedef struct __attribute__((packed)) {
    cosim_table_target_t target;
    cosim_u32 route_id;
    cosim_u32 entry_index;
    cosim_u64 bar_offset;
    cosim_u32 payload_bytes;
    cosim_u32 flags;
} cosim_table_write_begin_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_write_begin_t) == 48,
                    "cosim_table_write_begin_t must be 48 bytes");

typedef struct __attribute__((packed)) {
    cosim_u64 data_offset;
    cosim_u32 data_bytes;
    cosim_u32 reserved;
} cosim_table_write_data_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_write_data_t) == 16,
                    "cosim_table_write_data_t must be 16 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 payload_bytes;
    cosim_u32 reserved;
} cosim_table_write_end_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_write_end_t) == 8,
                    "cosim_table_write_end_t must be 8 bytes");

typedef struct __attribute__((packed)) {
    cosim_table_target_t target;
    cosim_u64 bar_offset;
    cosim_u32 route_id;
    cosim_u32 reserved;
} cosim_table_read_dword_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_read_dword_t) == 40,
                    "cosim_table_read_dword_t must be 40 bytes");

typedef struct __attribute__((packed)) {
    cosim_u32 status;
    cosim_u32 failed_index;
    cosim_u32 committed_count;
    cosim_u32 handler_error;
    cosim_u32 returned_dword;
    cosim_u32 reserved[3];
} cosim_table_completion_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_completion_t) == 32,
                    "cosim_table_completion_t must be 32 bytes");

typedef struct __attribute__((packed)) {
    cosim_table_frame_hdr_t header;
    cosim_u8 data[COSIM_TABLE_FRAME_DATA_BYTES];
} cosim_table_frame_t;

COSIM_STATIC_ASSERT(sizeof(cosim_table_frame_t) ==
                        sizeof(cosim_table_frame_hdr_t) +
                            COSIM_TABLE_FRAME_DATA_BYTES,
                    "cosim_table_frame_t ABI size mismatch");

#endif /* COSIM_TABLE_PROTOCOL_H */
