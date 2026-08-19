#include "qemu/osdep.h"

#include "hw/net/cosim_pcie_rc.h"
#include "hw/net/cosim_table_ctrl.h"
#include "hw/net/cosim_table_ctrl_uapi.h"
#include "hw/net/table_client.h"
#include "hw/net/table_ctrl_core.h"
#include "hw/net/table_ctrl_lifecycle.h"
#include "hw/pci/pci.h"
#include "hw/qdev-properties.h"
#include "qapi/error.h"
#include "qemu/log.h"
#include "qemu/main-loop.h"
#include "qemu/module.h"

#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#define COSIM_TABLE_CTRL_REVISION 1u
#define COSIM_TABLE_HEALTH_INTERVAL_MS 20u
#define COSIM_TABLE_DEFAULT_TIMEOUT_MS 3000u

struct CosimTableCtrl {
    PCIDevice parent_obj;

    MemoryRegion bar0;
    char *listen_addr;
    uint32_t table_port_base;
    uint32_t instance_id;
    uint32_t rc_id;
    uint32_t device_instance;
    uint32_t timeout_ms;
    bool debug;

    uint64_t dma_address;
    uint32_t dma_bytes;
    uint32_t slot_count;
    uint32_t last_error;

    cosim_table_ctrl_core_t core;
    cosim_table_ctrl_lifecycle_t lifecycle;
    cosim_table_transport_t *transport;
    cosim_table_client_t *client;
    pthread_mutex_t state_lock;
    pthread_mutex_t doorbell_lock;
    pthread_cond_t worker_wakeup;
    bool state_lock_initialized;
    bool doorbell_lock_initialized;
    bool worker_wakeup_initialized;
    bool bar_initialized;
    struct CosimTableCtrl *registry_next;
    bool registry_registered;
};

#define TABLE_DEBUG(s, format, ...)                                            \
    do {                                                                       \
        if ((s)->debug) {                                                      \
            qemu_log("cosim-table[%u]: " format, (s)->instance_id,            \
                     ##__VA_ARGS__);                                           \
        }                                                                      \
    } while (0)

/* Minimal BQL-only endpoint registry.  It indexes controller lifetimes and
 * deliberately carries no PF/VF or BAR topology. */
static CosimTableCtrl *g_cosim_table_ctrl_registry;

static CosimTableCtrl *cosim_table_ctrl_registry_find(
    uint16_t rc_id, uint16_t device_instance)
{
    CosimTableCtrl *entry;

    g_assert(bql_locked());
    for (entry = g_cosim_table_ctrl_registry; entry != NULL;
         entry = entry->registry_next) {
        if (entry->rc_id == rc_id &&
            entry->device_instance == device_instance)
            return entry;
    }
    return NULL;
}

static int cosim_table_ctrl_registry_add(CosimTableCtrl *s)
{
    g_assert(bql_locked());
    if (s->registry_registered ||
        cosim_table_ctrl_registry_find((uint16_t)s->rc_id,
                                       (uint16_t)s->device_instance) != NULL)
        return -1;
    s->registry_next = g_cosim_table_ctrl_registry;
    g_cosim_table_ctrl_registry = s;
    s->registry_registered = true;
    return 0;
}

static void cosim_table_ctrl_registry_remove(CosimTableCtrl *s)
{
    CosimTableCtrl **link;

    g_assert(bql_locked());
    if (!s->registry_registered)
        return;
    link = &g_cosim_table_ctrl_registry;
    while (*link != NULL && *link != s)
        link = &(*link)->registry_next;
    if (*link == s)
        *link = s->registry_next;
    s->registry_next = NULL;
    s->registry_registered = false;
}

static ssize_t cosim_table_dma_read(void *opaque, uint64_t address,
                                    void *buffer, size_t bytes)
{
    CosimTableCtrl *s = opaque;

    return pci_dma_read(PCI_DEVICE(s), address, buffer, bytes) == MEMTX_OK
               ? (ssize_t)bytes
               : -1;
}

static ssize_t cosim_table_dma_write(void *opaque, uint64_t address,
                                     const void *buffer, size_t bytes)
{
    CosimTableCtrl *s = opaque;

    return pci_dma_write(PCI_DEVICE(s), address, buffer, bytes) == MEMTX_OK
               ? (ssize_t)bytes
               : -1;
}

static void cosim_table_acquire_barrier(void *opaque)
{
    (void)opaque;
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
}

static void cosim_table_release_barrier(void *opaque)
{
    (void)opaque;
    __atomic_thread_fence(__ATOMIC_RELEASE);
}

static int cosim_table_target_active(void *opaque,
                                     const cosim_table_target_t *target)
{
    CosimTableCtrl *s = opaque;
    cosim_table_target_snapshot_t snapshot;

    return cosim_pcie_rc_get_table_target(s->instance_id, &snapshot) &&
           cosim_table_target_matches(&snapshot, target);
}

static const cosim_table_route_entry_t *cosim_table_match(
    void *opaque, const cosim_table_target_t *target, uint64_t offset,
    uint8_t operation)
{
    CosimTableCtrl *s = opaque;

    return cosim_table_client_match(s->client, target, offset, operation);
}

static cosim_table_status_t cosim_table_write(
    void *opaque, const cosim_table_write_begin_t *request,
    const uint8_t *payload, cosim_table_completion_t *completion,
    int timeout_ms)
{
    CosimTableCtrl *s = opaque;
    cosim_table_status_t status;

    status = cosim_table_client_write(s->client, request, payload, completion,
                                      timeout_ms);
    return cosim_table_ctrl_lifecycle_complete_rpc(&s->lifecycle, status);
}

static cosim_table_status_t cosim_table_read_dword(
    void *opaque, const cosim_table_read_dword_t *request,
    cosim_table_completion_t *completion, int timeout_ms)
{
    CosimTableCtrl *s = opaque;
    cosim_table_status_t status;

    status = cosim_table_client_read_dword(s->client, request, completion,
                                           timeout_ms);
    return cosim_table_ctrl_lifecycle_complete_rpc(&s->lifecycle, status);
}

cosim_table_status_t cosim_table_ctrl_try_read(
    uint16_t rc_id, uint16_t device_instance,
    const cosim_table_target_t *target, uint64_t aligned_bar_offset,
    uint32_t *returned_dword)
{
    cosim_table_target_snapshot_t snapshot;
    cosim_table_completion_t completion;
    cosim_table_read_dword_t request;
    cosim_table_client_t *client;
    CosimTableCtrl *s;
    cosim_table_status_t status;

    g_assert(bql_locked());
    if (target == NULL || returned_dword == NULL ||
        (aligned_bar_offset & UINT64_C(3)) != 0)
        return COSIM_TABLE_ST_PROTOCOL;
    s = cosim_table_ctrl_registry_find(rc_id, device_instance);
    if (s == NULL || !cosim_table_ctrl_lifecycle_is_ready(&s->lifecycle))
        return COSIM_TABLE_ST_NOT_READY;

    /* The doorbell lock owns client lifetime across the blocking RPC.  State
     * is inspected only briefly, preserving doorbell -> state -> transport. */
    (void)pthread_mutex_lock(&s->doorbell_lock);
    if (!cosim_table_ctrl_lifecycle_is_ready(&s->lifecycle)) {
        status = COSIM_TABLE_ST_NOT_READY;
        goto done;
    }
    (void)pthread_mutex_lock(&s->state_lock);
    client = s->client;
    (void)pthread_mutex_unlock(&s->state_lock);
    if (client == NULL) {
        status = COSIM_TABLE_ST_NOT_READY;
        goto done;
    }

    /* Route entries intentionally contain zero placeholders for dynamic
     * domain/BDF/generation.  Validate live identity against Task 9 state
     * independently before asking the route map about static ownership. */
    if (!cosim_pcie_rc_get_table_target(s->instance_id, &snapshot) ||
        !cosim_table_target_matches(&snapshot, target)) {
        status = COSIM_TABLE_ST_TARGET_GONE;
        goto done;
    }
    if (cosim_table_client_match(client, target, aligned_bar_offset,
                                 COSIM_TABLE_OP_READ_DWORD) == NULL) {
        status = cosim_table_client_match(client, target, aligned_bar_offset,
                                          COSIM_TABLE_OP_WRITE) != NULL
                     ? COSIM_TABLE_ST_UNSUPPORTED
                     : COSIM_TABLE_ST_NO_ROUTE;
        goto done;
    }

    memset(&request, 0, sizeof(request));
    request.target = *target;
    request.bar_offset = cosim_table_cpu_to_le64(aligned_bar_offset);
    memset(&completion, 0, sizeof(completion));
    status = cosim_table_client_read_dword(client, &request, &completion,
                                           (int)s->timeout_ms);
    status = cosim_table_ctrl_lifecycle_complete_rpc(&s->lifecycle, status);
    if (status == COSIM_TABLE_ST_SUCCESS)
        *returned_dword = completion.returned_dword;

done:
    (void)pthread_mutex_unlock(&s->doorbell_lock);
    return status;
}

static void cosim_table_ready_changed(void *opaque, int ready)
{
    CosimTableCtrl *s = opaque;

    cosim_table_ctrl_core_set_ready(&s->core, ready);
    TABLE_DEBUG(s, "READY=%d\n", ready != 0);
}

static void cosim_table_worker_interrupt(void *opaque)
{
    CosimTableCtrl *s = opaque;

    (void)pthread_mutex_lock(&s->state_lock);
    if (s->transport != NULL)
        cosim_table_transport_interrupt(s->transport);
    (void)pthread_cond_broadcast(&s->worker_wakeup);
    (void)pthread_mutex_unlock(&s->state_lock);
}

static void cosim_table_health_wait(CosimTableCtrl *s)
{
    struct timespec deadline;
    int64_t nanoseconds;

    if (clock_gettime(CLOCK_REALTIME, &deadline) != 0)
        return;
    nanoseconds = (int64_t)deadline.tv_nsec +
                  (int64_t)COSIM_TABLE_HEALTH_INTERVAL_MS * 1000000;
    deadline.tv_sec += nanoseconds / 1000000000;
    deadline.tv_nsec = nanoseconds % 1000000000;

    (void)pthread_mutex_lock(&s->state_lock);
    if (!cosim_table_ctrl_lifecycle_is_stopping(&s->lifecycle))
        (void)pthread_cond_timedwait(&s->worker_wakeup, &s->state_lock,
                                     &deadline);
    (void)pthread_mutex_unlock(&s->state_lock);
}

static int cosim_table_worker(cosim_table_ctrl_lifecycle_t *lifecycle,
                              void *opaque)
{
    CosimTableCtrl *s = opaque;
    cosim_table_transport_cfg_t cfg;
    cosim_table_transport_t *transport;
    cosim_table_client_t *client;
    int result = -1;

    memset(&cfg, 0, sizeof(cfg));
    cfg.listen_addr = s->listen_addr;
    cfg.table_port_base = s->table_port_base;
    cfg.instance_id = s->instance_id;
    cfg.rc_id = (uint16_t)s->rc_id;
    cfg.is_server = 1;
    cfg.connect_timeout_ms = (int)s->timeout_ms;

    transport = cosim_table_transport_create(&cfg);
    if (transport == NULL) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "cosim-table[%u]: server create failed: %s\n",
                      s->instance_id, strerror(errno));
        return -1;
    }
    client = cosim_table_client_create(transport, (uint16_t)s->rc_id);
    if (client == NULL) {
        cosim_table_transport_close(transport);
        return -1;
    }

    (void)pthread_mutex_lock(&s->state_lock);
    s->transport = transport;
    s->client = client;
    (void)pthread_mutex_unlock(&s->state_lock);
    if (cosim_table_ctrl_lifecycle_is_stopping(lifecycle))
        return 0;

    while (!cosim_table_ctrl_lifecycle_is_stopping(lifecycle)) {
        result = cosim_table_client_wait_routes(client, (int)s->timeout_ms);
        if (result == 0)
            break;
        if (result < 0)
            goto done;
    }
    if (cosim_table_ctrl_lifecycle_is_stopping(lifecycle)) {
        result = 0;
        goto done;
    }

    cosim_table_ctrl_lifecycle_set_ready(lifecycle, 1);
    TABLE_DEBUG(s, "route generation active\n");
    while (!cosim_table_ctrl_lifecycle_is_stopping(lifecycle)) {
        int closed;

        cosim_table_health_wait(s);
        if (cosim_table_ctrl_lifecycle_is_stopping(lifecycle))
            break;
        closed = cosim_table_transport_peer_closed(transport);
        if (closed != 0) {
            TABLE_DEBUG(s, "peer health=%d; clearing READY\n", closed);
            result = closed < 0 ? -1 : 0;
            break;
        }
    }

done:
    return result;
}

static uint32_t cosim_table_live_generation(CosimTableCtrl *s)
{
    cosim_table_target_snapshot_t snapshot;

    if (!cosim_pcie_rc_get_table_target(s->instance_id, &snapshot) ||
        snapshot.rc_id != (uint16_t)s->rc_id ||
        snapshot.device_instance != (uint16_t)s->device_instance)
        return 0;
    return snapshot.generation;
}

static uint64_t cosim_table_bar_read(void *opaque, hwaddr offset,
                                     unsigned size)
{
    CosimTableCtrl *s = opaque;

    if (size != sizeof(uint32_t) || (offset & 3u) != 0)
        return UINT32_MAX;
    switch (offset) {
    case COSIM_TABLE_REG_MAGIC:
        return COSIM_TABLE_MAGIC;
    case COSIM_TABLE_REG_VERSION:
        return COSIM_TABLE_PROTOCOL_VERSION;
    case COSIM_TABLE_REG_CAPS:
        return COSIM_TABLE_CAP_WRITE | COSIM_TABLE_CAP_READ_DWORD;
    case COSIM_TABLE_REG_READY:
        return cosim_table_ctrl_lifecycle_is_ready(&s->lifecycle) ? 1 : 0;
    case COSIM_TABLE_REG_DMA_ADDR_LO:
        return (uint32_t)s->dma_address;
    case COSIM_TABLE_REG_DMA_ADDR_HI:
        return (uint32_t)(s->dma_address >> 32);
    case COSIM_TABLE_REG_DMA_BYTES:
        return s->dma_bytes;
    case COSIM_TABLE_REG_SLOT_COUNT:
        return s->slot_count;
    case COSIM_TABLE_REG_LAST_ERROR:
        return s->last_error;
    case COSIM_TABLE_REG_RC_ID:
        return s->rc_id;
    case COSIM_TABLE_REG_DEVICE_INSTANCE:
        return s->device_instance;
    case COSIM_TABLE_REG_TARGET_GENERATION:
        return cosim_table_live_generation(s);
    default:
        return 0;
    }
}

static void cosim_table_ring_doorbell(CosimTableCtrl *s, uint64_t value)
{
    cosim_table_status_t status;
    uint64_t slot_address;
    uint32_t slot_bytes;

    if (value > UINT32_MAX || s->slot_count == 0 ||
        value >= s->slot_count || s->dma_address == 0 ||
        (s->dma_address & UINT64_C(7)) != 0 || s->dma_bytes == 0 ||
        s->dma_bytes % s->slot_count != 0) {
        s->last_error = COSIM_TABLE_ST_PROTOCOL;
        return;
    }
    slot_bytes = s->dma_bytes / s->slot_count;
    if (slot_bytes < sizeof(cosim_table_slot_hdr_t) ||
        value > (UINT64_MAX - s->dma_address) / slot_bytes) {
        s->last_error = COSIM_TABLE_ST_PROTOCOL;
        return;
    }
    slot_address = s->dma_address + value * slot_bytes;

    (void)pthread_mutex_lock(&s->doorbell_lock);
    status = cosim_table_ctrl_process_slot(&s->core, slot_address, slot_bytes,
                                           (int)s->timeout_ms);
    s->last_error = status;
    (void)pthread_mutex_unlock(&s->doorbell_lock);
    TABLE_DEBUG(s, "doorbell=%" PRIu64 " status=%u\n", value,
                (unsigned int)status);
}

static void cosim_table_bar_write(void *opaque, hwaddr offset, uint64_t value,
                                  unsigned size)
{
    CosimTableCtrl *s = opaque;

    if (size != sizeof(uint32_t) || (offset & 3u) != 0)
        return;
    switch (offset) {
    case COSIM_TABLE_REG_DMA_ADDR_LO:
        s->dma_address = (s->dma_address & UINT64_C(0xffffffff00000000)) |
                         (uint32_t)value;
        break;
    case COSIM_TABLE_REG_DMA_ADDR_HI:
        s->dma_address = (s->dma_address & UINT64_C(0xffffffff)) |
                         ((uint64_t)(uint32_t)value << 32);
        break;
    case COSIM_TABLE_REG_DMA_BYTES:
        s->dma_bytes = (uint32_t)value;
        break;
    case COSIM_TABLE_REG_SLOT_COUNT:
        s->slot_count = (uint32_t)value;
        break;
    case COSIM_TABLE_REG_DOORBELL:
        cosim_table_ring_doorbell(s, value);
        break;
    default:
        break;
    }
}

static const MemoryRegionOps cosim_table_bar_ops = {
    .read = cosim_table_bar_read,
    .write = cosim_table_bar_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
        .unaligned = false,
    },
    .impl = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void cosim_table_ctrl_reset(DeviceState *dev)
{
    CosimTableCtrl *s = COSIM_TABLE_CTRL(dev);

    s->dma_address = 0;
    s->dma_bytes = 0;
    s->slot_count = 0;
    s->last_error = COSIM_TABLE_ST_SUCCESS;
    (void)cosim_pcie_rc_bump_table_target_generation(s->instance_id);
}

static void cosim_table_ctrl_release_runtime(void *opaque)
{
    CosimTableCtrl *s = opaque;
    cosim_table_client_t *client;
    cosim_table_transport_t *transport;

    if (!s->doorbell_lock_initialized || !s->state_lock_initialized)
        return;
    (void)pthread_mutex_lock(&s->doorbell_lock);
    (void)pthread_mutex_lock(&s->state_lock);
    client = s->client;
    transport = s->transport;
    s->client = NULL;
    s->transport = NULL;
    (void)pthread_mutex_unlock(&s->state_lock);
    cosim_table_client_destroy(client);
    cosim_table_transport_close(transport);
    (void)pthread_mutex_unlock(&s->doorbell_lock);
}

static void cosim_table_ctrl_realize(PCIDevice *pdev, Error **errp)
{
    CosimTableCtrl *s = COSIM_TABLE_CTRL(pdev);
    cosim_table_ctrl_ops_t core_ops;
    cosim_table_ctrl_lifecycle_ops_t lifecycle_ops;
    uint64_t port;
    int result;

    port = (uint64_t)s->table_port_base + s->instance_id;
    if (s->table_port_base == 0 || port > UINT16_MAX ||
        s->rc_id > UINT16_MAX || s->device_instance > UINT16_MAX ||
        s->rc_id != s->instance_id || s->device_instance != 0 ||
        s->timeout_ms == 0 || s->timeout_ms > INT_MAX) {
        error_setg(errp, "cosim-table: invalid endpoint properties");
        return;
    }

    result = pthread_mutex_init(&s->state_lock, NULL);
    if (result != 0) {
        error_setg_errno(errp, result, "cosim-table: state mutex init");
        return;
    }
    s->state_lock_initialized = true;
    result = pthread_mutex_init(&s->doorbell_lock, NULL);
    if (result != 0) {
        error_setg_errno(errp, result, "cosim-table: doorbell mutex init");
        goto fail;
    }
    s->doorbell_lock_initialized = true;
    result = pthread_cond_init(&s->worker_wakeup, NULL);
    if (result != 0) {
        error_setg_errno(errp, result, "cosim-table: worker condition init");
        goto fail;
    }
    s->worker_wakeup_initialized = true;

    memset(&core_ops, 0, sizeof(core_ops));
    core_ops.dma_read = cosim_table_dma_read;
    core_ops.dma_write = cosim_table_dma_write;
    core_ops.acquire_barrier = cosim_table_acquire_barrier;
    core_ops.release_barrier = cosim_table_release_barrier;
    core_ops.target_active = cosim_table_target_active;
    core_ops.match = cosim_table_match;
    core_ops.write = cosim_table_write;
    core_ops.read_dword = cosim_table_read_dword;
    if (cosim_table_ctrl_core_init(&s->core, &core_ops, s,
                                   COSIM_TABLE_MAX_WRITE_BYTES) != 0) {
        error_setg(errp, "cosim-table: controller core init failed");
        goto fail;
    }

    memset(&lifecycle_ops, 0, sizeof(lifecycle_ops));
    lifecycle_ops.worker = cosim_table_worker;
    lifecycle_ops.interrupt = cosim_table_worker_interrupt;
    lifecycle_ops.ready_changed = cosim_table_ready_changed;
    lifecycle_ops.cleanup = cosim_table_ctrl_release_runtime;
    if (cosim_table_ctrl_lifecycle_init(&s->lifecycle, &lifecycle_ops, s) !=
        0) {
        error_setg(errp, "cosim-table: lifecycle init failed");
        goto fail;
    }

    memory_region_init_io(&s->bar0, OBJECT(pdev), &cosim_table_bar_ops, s,
                          "cosim-table-ctrl-bar0",
                          COSIM_TABLE_CTRL_BAR_BYTES);
    s->bar_initialized = true;
    pci_register_bar(pdev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->bar0);
    pci_set_word(pdev->config + PCI_COMMAND,
                 PCI_COMMAND_MEMORY | PCI_COMMAND_MASTER);
    memory_region_set_enabled(&pdev->bus_master_enable_region, true);

    if (cosim_table_ctrl_lifecycle_start(&s->lifecycle) != 0) {
        error_setg(errp, "cosim-table: worker start failed");
        goto fail;
    }
    if (cosim_table_ctrl_registry_add(s) != 0) {
        error_setg(errp,
                   "cosim-table: duplicate controller for rc_id=%u "
                   "device_instance=%u",
                   s->rc_id, s->device_instance);
        goto fail;
    }
    TABLE_DEBUG(s, "listening at %s:%u\n",
                s->listen_addr != NULL ? s->listen_addr : "0.0.0.0",
                (unsigned int)port);
    return;

fail:
    cosim_table_ctrl_registry_remove(s);
    cosim_table_ctrl_lifecycle_destroy(&s->lifecycle);
    cosim_table_ctrl_release_runtime(s);
    /* bar0 is an embedded child of the QOM device and is finalized with it. */
    s->bar_initialized = false;
    if (s->worker_wakeup_initialized) {
        (void)pthread_cond_destroy(&s->worker_wakeup);
        s->worker_wakeup_initialized = false;
    }
    if (s->doorbell_lock_initialized) {
        (void)pthread_mutex_destroy(&s->doorbell_lock);
        s->doorbell_lock_initialized = false;
    }
    if (s->state_lock_initialized) {
        (void)pthread_mutex_destroy(&s->state_lock);
        s->state_lock_initialized = false;
    }
}

static void cosim_table_ctrl_exit(PCIDevice *pdev)
{
    CosimTableCtrl *s = COSIM_TABLE_CTRL(pdev);

    cosim_table_ctrl_registry_remove(s);
    (void)cosim_table_ctrl_lifecycle_stop(&s->lifecycle);
    cosim_table_ctrl_lifecycle_destroy(&s->lifecycle);
    /* bar0 is an embedded child of the QOM device and is finalized with it. */
    s->bar_initialized = false;
    if (s->worker_wakeup_initialized) {
        (void)pthread_cond_destroy(&s->worker_wakeup);
        s->worker_wakeup_initialized = false;
    }
    if (s->doorbell_lock_initialized) {
        (void)pthread_mutex_destroy(&s->doorbell_lock);
        s->doorbell_lock_initialized = false;
    }
    if (s->state_lock_initialized) {
        (void)pthread_mutex_destroy(&s->state_lock);
        s->state_lock_initialized = false;
    }
}

static Property cosim_table_ctrl_properties[] = {
    DEFINE_PROP_STRING("listen_addr", CosimTableCtrl, listen_addr),
    DEFINE_PROP_UINT32("table_port_base", CosimTableCtrl, table_port_base,
                       COSIM_TABLE_DEFAULT_PORT_BASE),
    DEFINE_PROP_UINT32("instance_id", CosimTableCtrl, instance_id, 0),
    DEFINE_PROP_UINT32("rc_id", CosimTableCtrl, rc_id, 0),
    DEFINE_PROP_UINT32("device_instance", CosimTableCtrl, device_instance, 0),
    DEFINE_PROP_UINT32("timeout_ms", CosimTableCtrl, timeout_ms,
                       COSIM_TABLE_DEFAULT_TIMEOUT_MS),
    DEFINE_PROP_BOOL("debug", CosimTableCtrl, debug, false),
    DEFINE_PROP_END_OF_LIST(),
};

static void cosim_table_ctrl_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    PCIDeviceClass *k = PCI_DEVICE_CLASS(klass);

    (void)data;
    k->realize = cosim_table_ctrl_realize;
    k->exit = cosim_table_ctrl_exit;
    k->vendor_id = COSIM_TABLE_CTRL_VENDOR_ID;
    k->device_id = COSIM_TABLE_CTRL_DEVICE_ID;
    k->revision = COSIM_TABLE_CTRL_REVISION;
    k->class_id = PCI_CLASS_OTHERS;
    device_class_set_legacy_reset(dc, cosim_table_ctrl_reset);
    device_class_set_props(dc, cosim_table_ctrl_properties);
    dc->desc = "CoSim table sideband control endpoint";
}

static const TypeInfo cosim_table_ctrl_info = {
    .name = TYPE_COSIM_TABLE_CTRL,
    .parent = TYPE_PCI_DEVICE,
    .instance_size = sizeof(CosimTableCtrl),
    .class_init = cosim_table_ctrl_class_init,
    .interfaces = (InterfaceInfo[]) {
        { INTERFACE_PCIE_DEVICE },
        { }
    },
};

static void cosim_table_ctrl_register_types(void)
{
    type_register_static(&cosim_table_ctrl_info);
}

type_init(cosim_table_ctrl_register_types)
