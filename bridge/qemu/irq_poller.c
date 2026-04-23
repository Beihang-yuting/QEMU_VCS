#include "irq_poller.h"
#include "cosim_transport.h"
#include <pthread.h>
#include "compat_atomic.h"
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>

struct irq_poller {
    pthread_t            tid;
    cosim_shm_t         *shm;
    cosim_transport_t   *transport;
    dma_req_cb_t         dma_cb;
    msi_cb_t             msi_cb;
    void                *user;
    atomic_int           stop;
};

static void *poller_thread(void *arg) {
    irq_poller_t *p = arg;

    while (!atomic_load(&p->stop)) {
        int did_work = 0;

        if (p->transport) {
            /* TCP 模式：统一消息分发循环。
             *
             * aux channel 上混合了 DMA_REQ, MSI, ETH_FRAME, DMA_DATA 等消息。
             * recv_dma_req_nb 和 recv_msi_nb 已改为 MSG_PEEK 先看类型，
             * 不匹配时返回 1（无数据）不消费 buffer。
             *
             * 但如果队头是 ETH_FRAME 等 poller 不关心的类型，
             * DMA_REQ 和 MSI 都返回 1，循环空转。
             * 需要主动跳过不关心的消息类型。
             */
            for (int rounds = 0; rounds < 64; rounds++) {
                dma_req_t req;
                msi_event_t ev;
                int rc;

                /* 尝试 DMA_REQ */
                rc = p->transport->recv_dma_req_nb(p->transport, &req);
                if (rc == 0) {
                    if (p->dma_cb) p->dma_cb(&req, p->user);
                    did_work = 1;
                    continue;
                }

                /* 尝试 MSI */
                rc = p->transport->recv_msi_nb(p->transport, &ev);
                if (rc == 0) {
                    if (p->msi_cb) p->msi_cb(ev.vector, p->user);
                    did_work = 1;
                    continue;
                }

                /* 两者都不匹配：可能是 ETH_FRAME 或其他消息堵在队头。
                 * 用 get_shm_base 获取 transport priv 无法直接拿 fd，
                 * 但 recv_dma_req_nb 返回 1 意味着 peek 看到了非 DMA_REQ，
                 * recv_msi_nb 返回 1 意味着 peek 看到了非 MSI。
                 * 如果两者都返回 1 且有数据，说明队头是未知类型，需跳过。
                 * 利用 recv_dma_req_nb 的行为：返回 1 时如果有数据说明类型不匹配。 */

                /* 无数据（poll 返回 0），退出循环 */
                break;
            }
        } else {
            /* SHM 模式：原始逻辑，分别从 ring buffer 读取 */
            dma_req_t req;
            while (ring_buf_dequeue(&p->shm->dma_req_ring, &req) == 0) {
                if (p->dma_cb) p->dma_cb(&req, p->user);
                did_work = 1;
            }

            msi_event_t ev;
            while (ring_buf_dequeue(&p->shm->msi_ring, &ev) == 0) {
                if (p->msi_cb) p->msi_cb(ev.vector, p->user);
                did_work = 1;
            }
        }

        if (!did_work) usleep(100);
    }

    return NULL;
}

irq_poller_t *irq_poller_start(cosim_shm_t *shm,
                                 dma_req_cb_t dma_cb,
                                 msi_cb_t msi_cb,
                                 void *user) {
    irq_poller_t *p = calloc(1, sizeof(*p));
    if (!p) return NULL;

    p->shm = shm;
    p->dma_cb = dma_cb;
    p->msi_cb = msi_cb;
    p->user = user;
    atomic_store(&p->stop, 0);

    if (pthread_create(&p->tid, NULL, poller_thread, p) != 0) {
        perror("pthread_create");
        free(p);
        return NULL;
    }

    return p;
}

irq_poller_t *irq_poller_start_ex(cosim_transport_t *transport,
                                    dma_req_cb_t dma_cb,
                                    msi_cb_t msi_cb,
                                    void *user) {
    irq_poller_t *p = calloc(1, sizeof(*p));
    if (!p) return NULL;

    p->transport = transport;
    p->dma_cb = dma_cb;
    p->msi_cb = msi_cb;
    p->user = user;
    atomic_store(&p->stop, 0);

    if (pthread_create(&p->tid, NULL, poller_thread, p) != 0) {
        perror("pthread_create");
        free(p);
        return NULL;
    }

    return p;
}

void irq_poller_stop(irq_poller_t *poller) {
    if (!poller) return;
    atomic_store(&poller->stop, 1);
    pthread_join(poller->tid, NULL);
    free(poller);
}
