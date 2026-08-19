/* QEMU table sideband control endpoint. */
#ifndef COSIM_TABLE_CTRL_H
#define COSIM_TABLE_CTRL_H

#include "hw/net/cosim_table_ctrl_uapi.h"
#include "hw/pci/pci_device.h"
#include "qom/object.h"

#define TYPE_COSIM_TABLE_CTRL "cosim-table-ctrl"

OBJECT_DECLARE_SIMPLE_TYPE(CosimTableCtrl, COSIM_TABLE_CTRL)

/* BQL-only lookup and read against a realized controller endpoint. */
cosim_table_status_t cosim_table_ctrl_try_read(
    uint16_t rc_id, uint16_t device_instance,
    const cosim_table_target_t *target, uint64_t aligned_bar_offset,
    uint32_t *returned_dword);

#endif /* COSIM_TABLE_CTRL_H */
