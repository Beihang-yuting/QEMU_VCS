#ifndef COSIM_TABLE_CTRL_LIFECYCLE_H
#define COSIM_TABLE_CTRL_LIFECYCLE_H

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

typedef struct cosim_table_ctrl_lifecycle cosim_table_ctrl_lifecycle_t;

typedef struct {
    int (*worker)(cosim_table_ctrl_lifecycle_t *lifecycle, void *opaque);
    void (*interrupt)(void *opaque);
    void (*ready_changed)(void *opaque, int ready);
    void (*cleanup)(void *opaque);
} cosim_table_ctrl_lifecycle_ops_t;

struct cosim_table_ctrl_lifecycle {
    cosim_table_ctrl_lifecycle_ops_t ops;
    void *opaque;
    pthread_t worker_thread;
    pthread_mutex_t ready_lock;
    atomic_int ready;
    atomic_int stopping;
    atomic_int running;
    int ready_lock_initialized;
    int initialized;
    int started;
};

static inline void cosim_table_ctrl_lifecycle_set_ready(
    cosim_table_ctrl_lifecycle_t *lifecycle, int ready)
{
    int published;

    if (lifecycle == NULL || !lifecycle->initialized)
        return;
    if (pthread_mutex_lock(&lifecycle->ready_lock) != 0)
        return;
    published = ready != 0 &&
        !atomic_load_explicit(&lifecycle->stopping, memory_order_acquire);
    atomic_store_explicit(&lifecycle->ready, published, memory_order_release);
    lifecycle->ops.ready_changed(lifecycle->opaque, published);
    (void)pthread_mutex_unlock(&lifecycle->ready_lock);
}

static inline int cosim_table_ctrl_lifecycle_is_ready(
    const cosim_table_ctrl_lifecycle_t *lifecycle)
{
    return lifecycle != NULL && lifecycle->initialized &&
        atomic_load_explicit(&lifecycle->ready, memory_order_acquire);
}

static inline int cosim_table_ctrl_lifecycle_is_stopping(
    const cosim_table_ctrl_lifecycle_t *lifecycle)
{
    return lifecycle == NULL || !lifecycle->initialized ||
        atomic_load_explicit(&lifecycle->stopping, memory_order_acquire);
}

static inline void *cosim_table_ctrl_lifecycle_thread(void *opaque)
{
    cosim_table_ctrl_lifecycle_t *lifecycle = opaque;

    (void)lifecycle->ops.worker(lifecycle, lifecycle->opaque);
    cosim_table_ctrl_lifecycle_set_ready(lifecycle, 0);
    atomic_store_explicit(&lifecycle->running, 0, memory_order_release);
    return NULL;
}

static inline int cosim_table_ctrl_lifecycle_init(
    cosim_table_ctrl_lifecycle_t *lifecycle,
    const cosim_table_ctrl_lifecycle_ops_t *ops, void *opaque)
{
    int result;

    if (lifecycle == NULL || ops == NULL || ops->worker == NULL ||
        ops->interrupt == NULL || ops->ready_changed == NULL ||
        ops->cleanup == NULL)
        return -1;
    memset(lifecycle, 0, sizeof(*lifecycle));
    result = pthread_mutex_init(&lifecycle->ready_lock, NULL);
    if (result != 0)
        return -1;
    lifecycle->ready_lock_initialized = 1;
    lifecycle->ops = *ops;
    lifecycle->opaque = opaque;
    atomic_init(&lifecycle->ready, 0);
    atomic_init(&lifecycle->stopping, 0);
    atomic_init(&lifecycle->running, 0);
    lifecycle->initialized = 1;
    return 0;
}

static inline int cosim_table_ctrl_lifecycle_start(
    cosim_table_ctrl_lifecycle_t *lifecycle)
{
    int result;

    if (lifecycle == NULL || !lifecycle->initialized || lifecycle->started)
        return -1;
    atomic_store_explicit(&lifecycle->stopping, 0, memory_order_release);
    atomic_store_explicit(&lifecycle->ready, 0, memory_order_release);
    atomic_store_explicit(&lifecycle->running, 1, memory_order_release);
    result = pthread_create(&lifecycle->worker_thread, NULL,
                            cosim_table_ctrl_lifecycle_thread, lifecycle);
    if (result != 0) {
        atomic_store_explicit(&lifecycle->running, 0, memory_order_release);
        return -1;
    }
    lifecycle->started = 1;
    return 0;
}

static inline int cosim_table_ctrl_lifecycle_stop(
    cosim_table_ctrl_lifecycle_t *lifecycle)
{
    int result;

    if (lifecycle == NULL || !lifecycle->initialized)
        return -1;
    if (!lifecycle->started)
        return 0;
    result = pthread_mutex_lock(&lifecycle->ready_lock);
    if (result != 0)
        return -1;
    atomic_store_explicit(&lifecycle->stopping, 1, memory_order_release);
    atomic_store_explicit(&lifecycle->ready, 0, memory_order_release);
    lifecycle->ops.ready_changed(lifecycle->opaque, 0);
    (void)pthread_mutex_unlock(&lifecycle->ready_lock);
    lifecycle->ops.interrupt(lifecycle->opaque);
    result = pthread_join(lifecycle->worker_thread, NULL);
    if (result != 0)
        return -1;
    lifecycle->started = 0;
    atomic_store_explicit(&lifecycle->running, 0, memory_order_release);
    lifecycle->ops.cleanup(lifecycle->opaque);
    return 0;
}

static inline void cosim_table_ctrl_lifecycle_destroy(
    cosim_table_ctrl_lifecycle_t *lifecycle)
{
    if (lifecycle == NULL || !lifecycle->initialized)
        return;
    (void)cosim_table_ctrl_lifecycle_stop(lifecycle);
    lifecycle->initialized = 0;
    if (lifecycle->ready_lock_initialized) {
        (void)pthread_mutex_destroy(&lifecycle->ready_lock);
        lifecycle->ready_lock_initialized = 0;
    }
    memset(&lifecycle->ops, 0, sizeof(lifecycle->ops));
    lifecycle->opaque = NULL;
}

#endif /* COSIM_TABLE_CTRL_LIFECYCLE_H */
