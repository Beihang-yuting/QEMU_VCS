/* transport_tcp.h — TCP 传输层内部定义
 *
 * 消息协议: 8 字节头 (msg_type 4B + payload_len 4B) + payload
 * 双连接: 控制通道 (sync_msg) + 数据通道 (tlp/cpl/dma/msi/eth)
 */
#ifndef TRANSPORT_TCP_H
#define TRANSPORT_TCP_H

#include <stdint.h>

#define TCP_HANDSHAKE_MAGIC   0x434F5349u  /* "COSI" */
#define TCP_HANDSHAKE_VERSION 1u
#define TCP_DEFAULT_PORT_BASE 9100
#define TCP_RECV_BUF_SIZE     (256 * 1024)
#define TCP_SEND_BUF_SIZE     (256 * 1024)

/* 消息类型 */
typedef enum {
    TCP_MSG_HANDSHAKE    = 0x00,
    TCP_MSG_SYNC         = 0x01,
    TCP_MSG_TLP          = 0x02,
    TCP_MSG_CPL          = 0x03,
    TCP_MSG_DMA_REQ      = 0x04,
    TCP_MSG_DMA_CPL      = 0x05,
    TCP_MSG_MSI          = 0x06,
    TCP_MSG_ETH_FRAME    = 0x07,
    TCP_MSG_DMA_DATA     = 0x08,  /* DMA 数据搬运 */
} tcp_msg_type_t;

/* 消息头 */
typedef struct {
    uint32_t msg_type;
    uint32_t payload_len;
} __attribute__((packed)) tcp_msg_hdr_t;

/* 握手消息 */
typedef struct {
    uint32_t magic;
    uint32_t version;
} __attribute__((packed)) tcp_handshake_t;

/* DMA 数据传输消息 — TCP 模式没有共享内存，
 * DMA 数据需要通过网络搬运 */
typedef struct {
    uint32_t tag;
    uint32_t direction;   /* DMA_DIR_READ=0, DMA_DIR_WRITE=1 */
    uint64_t host_addr;
    uint32_t len;
    uint32_t _pad;
    /* 后跟 len 字节 DMA 数据 */
} __attribute__((packed)) tcp_dma_data_hdr_t;

#endif /* TRANSPORT_TCP_H */
