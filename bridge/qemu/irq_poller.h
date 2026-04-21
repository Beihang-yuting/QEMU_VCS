#ifndef IRQ_POLLER_H
#define IRQ_POLLER_H

#include "shm_layout.h"
#include "cosim_types.h"

/* Forward declaration for transport-aware API */
struct cosim_transport;
typedef struct cosim_transport cosim_transport_t;

typedef void (*dma_req_cb_t)(const dma_req_t *req, void *user);
typedef void (*msi_cb_t)(uint32_t vector, void *user);

typedef struct irq_poller irq_poller_t;

irq_poller_t *irq_poller_start(cosim_shm_t *shm,
                                 dma_req_cb_t dma_cb,
                                 msi_cb_t msi_cb,
                                 void *user);

irq_poller_t *irq_poller_start_ex(cosim_transport_t *transport,
                                    dma_req_cb_t dma_cb,
                                    msi_cb_t msi_cb,
                                    void *user);

void irq_poller_stop(irq_poller_t *poller);

#endif
