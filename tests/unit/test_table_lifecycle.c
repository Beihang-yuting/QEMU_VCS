#define _POSIX_C_SOURCE 200809L

#include "cosim_table_protocol.h"
#include "table_ctrl_lifecycle.h"

#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define CHECK(condition)                                                       \
    do {                                                                       \
        if (!(condition)) {                                                    \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, \
                    #condition);                                               \
            return -1;                                                         \
        }                                                                      \
    } while (0)

enum {
    COMMAND_WAIT,
    COMMAND_ROUTES,
    COMMAND_DISCONNECT,
    COMMAND_PROTOCOL_FAILURE,
    COMMAND_INTERRUPT,
};

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int command;
    atomic_int worker_entered;
    atomic_int worker_exited;
    atomic_int ready_callback;
    atomic_int interrupt_called;
    atomic_int interrupt_order;
    atomic_int exit_order;
    atomic_int cleanup_called;
    atomic_int cleanup_order;
    atomic_int sequence;
    atomic_int block_ready_callback;
    atomic_int ready_callback_entered;
    atomic_int release_ready_callback;
} fake_service_t;

typedef struct {
    cosim_table_ctrl_lifecycle_t *lifecycle;
    atomic_int entered;
    int result;
} stop_context_t;

/* Model the pre-fix controller callbacks, which returned RPC status directly.
 * Once the production lifecycle helper exists, every assertion below runs
 * against that helper instead of this legacy compatibility path. */
#ifdef COSIM_TABLE_CTRL_LIFECYCLE_HAS_RPC_STATUS
#define complete_rpc_status cosim_table_ctrl_lifecycle_complete_rpc
#else
static cosim_table_status_t complete_rpc_status(
    cosim_table_ctrl_lifecycle_t *lifecycle, cosim_table_status_t status)
{
    (void)lifecycle;
    return status;
}
#endif

static void pause_milliseconds(unsigned int milliseconds)
{
    struct timespec pause;

    pause.tv_sec = milliseconds / 1000u;
    pause.tv_nsec = (long)(milliseconds % 1000u) * 1000000L;
    while (nanosleep(&pause, &pause) != 0 && errno == EINTR)
        ;
}

static int wait_atomic(atomic_int *value, int expected)
{
    unsigned int waited;

    for (waited = 0; waited < 1000; ++waited) {
        if (atomic_load_explicit(value, memory_order_acquire) == expected)
            return 0;
        pause_milliseconds(1);
    }
    return -1;
}

static double monotonic_seconds(void)
{
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
        return -1.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static void fake_ready_changed(void *opaque, int ready)
{
    fake_service_t *fake = opaque;

    if (ready && atomic_load_explicit(&fake->block_ready_callback,
                                      memory_order_acquire)) {
        atomic_store_explicit(&fake->ready_callback_entered, 1,
                              memory_order_release);
        while (!atomic_load_explicit(&fake->release_ready_callback,
                                     memory_order_acquire))
            pause_milliseconds(1);
    }
    atomic_store_explicit(&fake->ready_callback, ready != 0,
                          memory_order_release);
}

static void *stop_main(void *opaque)
{
    stop_context_t *context = opaque;

    atomic_store_explicit(&context->entered, 1, memory_order_release);
    context->result =
        cosim_table_ctrl_lifecycle_stop(context->lifecycle);
    return NULL;
}

static int set_command(fake_service_t *fake, int command)
{
    if (pthread_mutex_lock(&fake->lock) != 0)
        return -1;
    fake->command = command;
    if (pthread_cond_broadcast(&fake->changed) != 0) {
        (void)pthread_mutex_unlock(&fake->lock);
        return -1;
    }
    return pthread_mutex_unlock(&fake->lock) == 0 ? 0 : -1;
}

static int wait_for_command(fake_service_t *fake, int first, int second)
{
    int command;

    if (pthread_mutex_lock(&fake->lock) != 0)
        return COMMAND_INTERRUPT;
    while (fake->command != first && fake->command != second &&
           fake->command != COMMAND_INTERRUPT) {
        if (pthread_cond_wait(&fake->changed, &fake->lock) != 0) {
            (void)pthread_mutex_unlock(&fake->lock);
            return COMMAND_INTERRUPT;
        }
    }
    command = fake->command;
    (void)pthread_mutex_unlock(&fake->lock);
    return command;
}

static int fake_worker(cosim_table_ctrl_lifecycle_t *lifecycle, void *opaque)
{
    fake_service_t *fake = opaque;
    int command;

    atomic_store_explicit(&fake->worker_entered, 1, memory_order_release);
    command = wait_for_command(fake, COMMAND_ROUTES, COMMAND_ROUTES);
    if (command == COMMAND_INTERRUPT)
        goto exited;
    cosim_table_ctrl_lifecycle_set_ready(lifecycle, 1);
    command = wait_for_command(fake, COMMAND_DISCONNECT,
                               COMMAND_PROTOCOL_FAILURE);

exited:
    atomic_store_explicit(
        &fake->exit_order,
        atomic_fetch_add_explicit(&fake->sequence, 1, memory_order_acq_rel) + 1,
        memory_order_release);
    atomic_store_explicit(&fake->worker_exited, 1, memory_order_release);
    return command == COMMAND_PROTOCOL_FAILURE ? -1 : 0;
}

static void fake_interrupt(void *opaque)
{
    fake_service_t *fake = opaque;

    atomic_store_explicit(&fake->interrupt_called, 1, memory_order_release);
    atomic_store_explicit(
        &fake->interrupt_order,
        atomic_fetch_add_explicit(&fake->sequence, 1, memory_order_acq_rel) + 1,
        memory_order_release);
    (void)set_command(fake, COMMAND_INTERRUPT);
}

static void fake_cleanup(void *opaque)
{
    fake_service_t *fake = opaque;

    atomic_store_explicit(
        &fake->cleanup_order,
        atomic_fetch_add_explicit(&fake->sequence, 1, memory_order_acq_rel) + 1,
        memory_order_release);
    atomic_store_explicit(&fake->cleanup_called, 1, memory_order_release);
}

static int fake_init(fake_service_t *fake,
                     cosim_table_ctrl_lifecycle_t *lifecycle)
{
    cosim_table_ctrl_lifecycle_ops_t ops;

    memset(fake, 0, sizeof(*fake));
    memset(lifecycle, 0, sizeof(*lifecycle));
    CHECK(pthread_mutex_init(&fake->lock, NULL) == 0);
    CHECK(pthread_cond_init(&fake->changed, NULL) == 0);
    atomic_init(&fake->worker_entered, 0);
    atomic_init(&fake->worker_exited, 0);
    atomic_init(&fake->ready_callback, 0);
    atomic_init(&fake->interrupt_called, 0);
    atomic_init(&fake->interrupt_order, 0);
    atomic_init(&fake->exit_order, 0);
    atomic_init(&fake->cleanup_called, 0);
    atomic_init(&fake->cleanup_order, 0);
    atomic_init(&fake->sequence, 0);
    atomic_init(&fake->block_ready_callback, 0);
    atomic_init(&fake->ready_callback_entered, 0);
    atomic_init(&fake->release_ready_callback, 0);
    memset(&ops, 0, sizeof(ops));
    ops.worker = fake_worker;
    ops.interrupt = fake_interrupt;
    ops.ready_changed = fake_ready_changed;
    ops.cleanup = fake_cleanup;
    CHECK(cosim_table_ctrl_lifecycle_init(lifecycle, &ops, fake) == 0);
    return 0;
}

static int fake_finish(fake_service_t *fake,
                       cosim_table_ctrl_lifecycle_t *lifecycle)
{
    cosim_table_ctrl_lifecycle_destroy(lifecycle);
    CHECK(pthread_cond_destroy(&fake->changed) == 0);
    CHECK(pthread_mutex_destroy(&fake->lock) == 0);
    return 0;
}

static int test_start_is_nonblocking_and_routes_control_ready(void)
{
    cosim_table_ctrl_lifecycle_t lifecycle;
    fake_service_t fake;
    double started;
    double returned;

    CHECK(fake_init(&fake, &lifecycle) == 0);
    started = monotonic_seconds();
    CHECK(started >= 0.0);
    CHECK(cosim_table_ctrl_lifecycle_start(&lifecycle) == 0);
    returned = monotonic_seconds();
    CHECK(returned >= started);
    CHECK(returned - started < 0.1);
    CHECK(!cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
    CHECK(wait_atomic(&fake.worker_entered, 1) == 0);
    CHECK(!atomic_load_explicit(&fake.ready_callback, memory_order_acquire));

    CHECK(set_command(&fake, COMMAND_ROUTES) == 0);
    CHECK(wait_atomic(&fake.ready_callback, 1) == 0);
    CHECK(cosim_table_ctrl_lifecycle_is_ready(&lifecycle));

    CHECK(set_command(&fake, COMMAND_DISCONNECT) == 0);
    CHECK(wait_atomic(&fake.worker_exited, 1) == 0);
    CHECK(wait_atomic(&fake.ready_callback, 0) == 0);
    CHECK(!cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
    CHECK(cosim_table_ctrl_lifecycle_stop(&lifecycle) == 0);
    CHECK(fake_finish(&fake, &lifecycle) == 0);
    return 0;
}

static int test_protocol_failure_clears_ready(void)
{
    cosim_table_ctrl_lifecycle_t lifecycle;
    fake_service_t fake;

    CHECK(fake_init(&fake, &lifecycle) == 0);
    CHECK(cosim_table_ctrl_lifecycle_start(&lifecycle) == 0);
    CHECK(wait_atomic(&fake.worker_entered, 1) == 0);
    CHECK(set_command(&fake, COMMAND_ROUTES) == 0);
    CHECK(wait_atomic(&fake.ready_callback, 1) == 0);
    CHECK(set_command(&fake, COMMAND_PROTOCOL_FAILURE) == 0);
    CHECK(wait_atomic(&fake.worker_exited, 1) == 0);
    CHECK(wait_atomic(&fake.ready_callback, 0) == 0);
    CHECK(!cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
    CHECK(cosim_table_ctrl_lifecycle_stop(&lifecycle) == 0);
    CHECK(fake_finish(&fake, &lifecycle) == 0);
    return 0;
}

static int test_stop_interrupts_before_joining_blocked_accept(void)
{
    cosim_table_ctrl_lifecycle_t lifecycle;
    fake_service_t fake;
    double started;
    double returned;

    CHECK(fake_init(&fake, &lifecycle) == 0);
    CHECK(cosim_table_ctrl_lifecycle_start(&lifecycle) == 0);
    CHECK(wait_atomic(&fake.worker_entered, 1) == 0);
    started = monotonic_seconds();
    CHECK(cosim_table_ctrl_lifecycle_stop(&lifecycle) == 0);
    returned = monotonic_seconds();
    CHECK(returned - started < 1.0);
    CHECK(atomic_load_explicit(&fake.interrupt_called, memory_order_acquire));
    CHECK(atomic_load_explicit(&fake.worker_exited, memory_order_acquire));
    CHECK(atomic_load_explicit(&fake.interrupt_order, memory_order_acquire) > 0);
    CHECK(atomic_load_explicit(&fake.exit_order, memory_order_acquire) >
          atomic_load_explicit(&fake.interrupt_order, memory_order_acquire));
    CHECK(atomic_load_explicit(&fake.cleanup_called, memory_order_acquire));
    CHECK(atomic_load_explicit(&fake.cleanup_order, memory_order_acquire) >
          atomic_load_explicit(&fake.exit_order, memory_order_acquire));
    CHECK(!cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
    CHECK(cosim_table_ctrl_lifecycle_stop(&lifecycle) == 0);
    CHECK(fake_finish(&fake, &lifecycle) == 0);
    return 0;
}

static int test_stop_serializes_ready_clear_before_interrupt(void)
{
    cosim_table_ctrl_lifecycle_t lifecycle;
    fake_service_t fake;
    stop_context_t context;
    pthread_t stop_thread;

    CHECK(fake_init(&fake, &lifecycle) == 0);
    atomic_store_explicit(&fake.block_ready_callback, 1,
                          memory_order_release);
    CHECK(cosim_table_ctrl_lifecycle_start(&lifecycle) == 0);
    CHECK(wait_atomic(&fake.worker_entered, 1) == 0);
    CHECK(set_command(&fake, COMMAND_ROUTES) == 0);
    CHECK(wait_atomic(&fake.ready_callback_entered, 1) == 0);

    memset(&context, 0, sizeof(context));
    context.lifecycle = &lifecycle;
    atomic_init(&context.entered, 0);
    CHECK(pthread_create(&stop_thread, NULL, stop_main, &context) == 0);
    CHECK(wait_atomic(&context.entered, 1) == 0);
    pause_milliseconds(50);
    CHECK(!atomic_load_explicit(&fake.interrupt_called,
                                memory_order_acquire));

    atomic_store_explicit(&fake.release_ready_callback, 1,
                          memory_order_release);
    CHECK(pthread_join(stop_thread, NULL) == 0);
    CHECK(context.result == 0);
    CHECK(!atomic_load_explicit(&fake.ready_callback, memory_order_acquire));
    CHECK(!cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
    CHECK(fake_finish(&fake, &lifecycle) == 0);
    return 0;
}

static int run_rpc_status_case(cosim_table_status_t status, int terminal)
{
    cosim_table_ctrl_lifecycle_t lifecycle;
    fake_service_t fake;

    CHECK(fake_init(&fake, &lifecycle) == 0);
    CHECK(cosim_table_ctrl_lifecycle_start(&lifecycle) == 0);
    CHECK(wait_atomic(&fake.worker_entered, 1) == 0);
    CHECK(set_command(&fake, COMMAND_ROUTES) == 0);
    CHECK(wait_atomic(&fake.ready_callback, 1) == 0);
    CHECK(cosim_table_ctrl_lifecycle_is_ready(&lifecycle));

    CHECK(complete_rpc_status(&lifecycle, status) == status);
    if (terminal) {
        CHECK(!cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
        CHECK(!atomic_load_explicit(&fake.ready_callback,
                                    memory_order_acquire));
        CHECK(atomic_load_explicit(&fake.interrupt_called,
                                   memory_order_acquire));
        CHECK(wait_atomic(&fake.worker_exited, 1) == 0);
    } else {
        CHECK(cosim_table_ctrl_lifecycle_is_ready(&lifecycle));
        CHECK(atomic_load_explicit(&fake.ready_callback,
                                   memory_order_acquire));
        CHECK(!atomic_load_explicit(&fake.interrupt_called,
                                    memory_order_acquire));
        CHECK(set_command(&fake, COMMAND_DISCONNECT) == 0);
        CHECK(wait_atomic(&fake.worker_exited, 1) == 0);
    }
    CHECK(cosim_table_ctrl_lifecycle_stop(&lifecycle) == 0);
    CHECK(fake_finish(&fake, &lifecycle) == 0);
    return 0;
}

static int test_rpc_terminal_status_clears_ready_and_interrupts(void)
{
    static const cosim_table_status_t terminal_statuses[] = {
        COSIM_TABLE_ST_PROTOCOL,
        COSIM_TABLE_ST_TIMEOUT,
        COSIM_TABLE_ST_TARGET_GONE,
    };
    static const cosim_table_status_t nonterminal_statuses[] = {
        COSIM_TABLE_ST_SUCCESS,
        COSIM_TABLE_ST_NOT_READY,
        COSIM_TABLE_ST_NO_ROUTE,
        COSIM_TABLE_ST_UNSUPPORTED,
        COSIM_TABLE_ST_SLOT_BUSY,
        COSIM_TABLE_ST_EXEC_ERROR,
        COSIM_TABLE_ST_UNKNOWN,
    };
    size_t i;

    for (i = 0; i < sizeof(terminal_statuses) /
                        sizeof(terminal_statuses[0]); i++)
        CHECK(run_rpc_status_case(terminal_statuses[i], 1) == 0);
    for (i = 0; i < sizeof(nonterminal_statuses) /
                        sizeof(nonterminal_statuses[0]); i++)
        CHECK(run_rpc_status_case(nonterminal_statuses[i], 0) == 0);
    return 0;
}

int main(void)
{
    CHECK(test_start_is_nonblocking_and_routes_control_ready() == 0);
    CHECK(test_protocol_failure_clears_ready() == 0);
    CHECK(test_stop_interrupts_before_joining_blocked_accept() == 0);
    CHECK(test_stop_serializes_ready_clear_before_interrupt() == 0);
    CHECK(test_rpc_terminal_status_clears_ready_and_interrupts() == 0);
    puts("PASS: asynchronous table control lifecycle");
    return 0;
}
