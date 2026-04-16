#include "irq_poller.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdio.h>

struct irq_poller {
    pthread_t       tid;
    cosim_shm_t    *shm;
    dma_req_cb_t    dma_cb;
    msi_cb_t        msi_cb;
    void           *user;
    atomic_int      stop;
};

static void *poller_thread(void *arg) {
    irq_poller_t *p = arg;

    while (!atomic_load(&p->stop)) {
        int did_work = 0;

        msi_event_t ev;
        while (ring_buf_dequeue(&p->shm->msi_ring, &ev) == 0) {
            if (p->msi_cb) p->msi_cb(ev.vector, p->user);
            did_work = 1;
        }

        dma_req_t req;
        while (ring_buf_dequeue(&p->shm->dma_req_ring, &req) == 0) {
            if (p->dma_cb) p->dma_cb(&req, p->user);
            did_work = 1;
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

void irq_poller_stop(irq_poller_t *poller) {
    if (!poller) return;
    atomic_store(&poller->stop, 1);
    pthread_join(poller->tid, NULL);
    free(poller);
}
