/* cosim_transport.h — 传输层抽象接口
 *
 * SHM 和 TCP 各实现一套函数指针，上层代码通过此接口操作，
 * 运行时根据 transport_cfg_t.transport 选择实现。
 */
#ifndef COSIM_TRANSPORT_H
#define COSIM_TRANSPORT_H

#include "cosim_types.h"
#include "eth_types.h"
#include <stdint.h>

typedef struct cosim_transport cosim_transport_t;

typedef struct {
    const char *transport;       /* "shm" | "tcp" */
    /* SHM 模式参数 */
    const char *shm_name;       /* e.g. "/cosim0" */
    const char *sock_path;      /* e.g. "/tmp/cosim.sock" */
    /* TCP 模式参数 */
    const char *remote_host;    /* VCS 侧连接目标, e.g. "192.168.1.100" */
    const char *listen_addr;    /* QEMU 侧监听地址, e.g. "0.0.0.0" */
    int         port_base;      /* 端口基数, 默认 9100 */
    int         instance_id;    /* 实例 ID, 默认 0 */
    int         is_server;      /* 1=QEMU(listen), 0=VCS(connect) */
} transport_cfg_t;

struct cosim_transport {
    /* 控制通道 */
    int  (*send_sync)(cosim_transport_t *t, const sync_msg_t *msg);
    int  (*recv_sync)(cosim_transport_t *t, sync_msg_t *msg);
    int  (*recv_sync_timed)(cosim_transport_t *t, sync_msg_t *msg, int timeout_ms);

    /* PCIe 数据通道 */
    int  (*send_tlp)(cosim_transport_t *t, const tlp_entry_t *tlp);
    int  (*recv_tlp)(cosim_transport_t *t, tlp_entry_t *tlp);
    int  (*send_cpl)(cosim_transport_t *t, const cpl_entry_t *cpl);
    int  (*recv_cpl)(cosim_transport_t *t, cpl_entry_t *cpl);

    /* DMA 通道 */
    int  (*send_dma_req)(cosim_transport_t *t, const dma_req_t *req);
    int  (*recv_dma_req)(cosim_transport_t *t, dma_req_t *req);
    int  (*send_dma_cpl)(cosim_transport_t *t, const dma_cpl_t *cpl);
    int  (*recv_dma_cpl)(cosim_transport_t *t, dma_cpl_t *cpl);

    /* DMA 数据搬运 — TCP 模式专用 (SHM 用 dma_buf 直接访问) */
    int  (*send_dma_data)(cosim_transport_t *t, uint32_t tag, uint32_t direction,
                          uint64_t host_addr, const uint8_t *data, uint32_t len);
    int  (*recv_dma_data)(cosim_transport_t *t, uint32_t *tag, uint32_t *direction,
                          uint64_t *host_addr, uint8_t *data, uint32_t *len);

    /* 非阻塞接收 — irq_poller 线程使用 (返回: 0=成功, 1=无数据, -1=错误) */
    int  (*recv_dma_req_nb)(cosim_transport_t *t, dma_req_t *req);
    int  (*recv_msi_nb)(cosim_transport_t *t, msi_event_t *ev);

    /* MSI 通道 */
    int  (*send_msi)(cosim_transport_t *t, const msi_event_t *ev);
    int  (*recv_msi)(cosim_transport_t *t, msi_event_t *ev);

    /* ETH 通道 */
    int  (*send_eth)(cosim_transport_t *t, const eth_frame_t *frame);
    int  (*recv_eth)(cosim_transport_t *t, eth_frame_t *frame, uint64_t timeout_ns);

    /* 状态查询 */
    int  (*peer_ready)(cosim_transport_t *t);
    void (*set_ready)(cosim_transport_t *t);

    /* SHM 兼容 — 暴露底层 SHM 指针供需要直接访问的代码使用
     * TCP 模式下返回 NULL */
    void *(*get_shm_base)(cosim_transport_t *t);
    void *(*get_dma_buf)(cosim_transport_t *t, uint32_t *out_size);

    /* 生命周期 */
    void (*close)(cosim_transport_t *t);

    /* 私有数据 */
    void *priv;
};

/* 工厂函数 — 根据 cfg->transport 创建对应实现 */
cosim_transport_t *transport_create(const transport_cfg_t *cfg);

/* 各实现的创建函数（内部使用） */
cosim_transport_t *transport_shm_create(const transport_cfg_t *cfg);
cosim_transport_t *transport_tcp_create(const transport_cfg_t *cfg);

#endif /* COSIM_TRANSPORT_H */
