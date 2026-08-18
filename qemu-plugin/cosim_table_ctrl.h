/* QEMU table sideband control endpoint. */
#ifndef COSIM_TABLE_CTRL_H
#define COSIM_TABLE_CTRL_H

#include "hw/pci/pci_device.h"
#include "qom/object.h"

#define TYPE_COSIM_TABLE_CTRL "cosim-table-ctrl"

OBJECT_DECLARE_SIMPLE_TYPE(CosimTableCtrl, COSIM_TABLE_CTRL)

#endif /* COSIM_TABLE_CTRL_H */
