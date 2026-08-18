#include "qemu/osdep.h"

#include "hw/qdev-core.h"
#include "qemu/module.h"
#include "qom/object.h"

#define TYPE_DIRECT_RESET_PROBE "cosim-direct-reset-probe"
#define TYPE_HELPER_RESET_PROBE "cosim-helper-reset-probe"

typedef struct ResetProbeState {
    DeviceState parent_obj;
    uint32_t generation;
} ResetProbeState;

static void reset_probe_reset(DeviceState *dev)
{
    ResetProbeState *s = (ResetProbeState *)dev;

    ++s->generation;
}

static void direct_reset_probe_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    (void)data;
    dc->legacy_reset = reset_probe_reset;
}

static void helper_reset_probe_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    (void)data;
    device_class_set_legacy_reset(dc, reset_probe_reset);
}

static const TypeInfo direct_reset_probe_info = {
    .name = TYPE_DIRECT_RESET_PROBE,
    .parent = TYPE_DEVICE,
    .instance_size = sizeof(ResetProbeState),
    .class_init = direct_reset_probe_class_init,
};

static const TypeInfo helper_reset_probe_info = {
    .name = TYPE_HELPER_RESET_PROBE,
    .parent = TYPE_DEVICE,
    .instance_size = sizeof(ResetProbeState),
    .class_init = helper_reset_probe_class_init,
};

int main(int argc, char **argv)
{
    ResetProbeState *s;
    const char *type;
    uint32_t before;
    uint32_t after;

    if (argc != 2 || (strcmp(argv[1], "direct") != 0 &&
                      strcmp(argv[1], "helper") != 0)) {
        fprintf(stderr, "usage: %s direct|helper\n", argv[0]);
        return 2;
    }

    module_call_init(MODULE_INIT_QOM);
    type_register_static(&direct_reset_probe_info);
    type_register_static(&helper_reset_probe_info);

    type = strcmp(argv[1], "helper") == 0 ? TYPE_HELPER_RESET_PROBE
                                           : TYPE_DIRECT_RESET_PROBE;
    s = (ResetProbeState *)object_new(type);
    s->generation = 1;
    before = s->generation;
    device_cold_reset(DEVICE(s));
    after = s->generation;

    printf("registration=%s generation_before=%u generation_after=%u\n",
           argv[1], before, after);
    object_unref(OBJECT(s));
    return after == before + 1 ? 0 : 1;
}
