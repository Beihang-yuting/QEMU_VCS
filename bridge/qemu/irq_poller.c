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

        /* Process DMA requests FIRST (before MSI) to avoid deadlock:
         * MSI callback needs BQL (for pci_set_irq), but the main thread
         * may hold BQL while waiting for VCS completion. If we block on
         * BQL here, pending DMA requests behind us never get processed,
         * and VCS (waiting for DMA_CPL) can never send the completion
         * the main thread needs -> deadlock.
         * DMA callback does NOT need BQL (uses cpu_physical_memory_*). */
        dma_req_t req;
        if (p->transport) {
            int rc;
            while ((rc = p->transport->recv_dma_req_nb(p->transport, &req)) == 0) {
                if (p->dma_cb) p->dma_cb(&req, p->user);
                did_work = 1;
            }
        } else {
            while (ring_buf_dequeue(&p->shm->dma_req_ring, &req) == 0) {
                if (p->dma_cb) p->dma_cb(&req, p->user);
                did_work = 1;
            }
        }

        msi_event_t ev;
        if (p->transport) {
            int rc;
            while ((rc = p->transport->recv_msi_nb(p->transport, &ev)) == 0) {
                if (p->msi_cb) p->msi_cb(ev.vector, p->user);
                did_work = 1;
            }
        } else {
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
