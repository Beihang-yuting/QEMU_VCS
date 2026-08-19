// SPDX-License-Identifier: GPL-2.0
#include <linux/atomic.h>
#include <linux/completion.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/pci.h>
#include <linux/refcount.h>
#include <linux/slab.h>
#include <linux/spinlock.h>

#include "common.h"
#include "adapter.h"
#include "cosim_table_ctrl.h"
#include "cosim_table_ctrl_uapi.h"

#define DPU_TABLE_SLOT_COUNT 4u
#define DPU_TABLE_SLOT_PAYLOAD_BYTES COSIM_TABLE_FRAME_DATA_BYTES
#define DPU_TABLE_SLOT_BYTES \
	ALIGN(sizeof(cosim_table_slot_hdr_t) + DPU_TABLE_SLOT_PAYLOAD_BYTES, 8u)
#define DPU_TABLE_DMA_BYTES (DPU_TABLE_SLOT_COUNT * DPU_TABLE_SLOT_BYTES)

struct dpu_table_controller {
	struct pci_dev *pdev;
	void __iomem *bar0;
	void *slots;
	dma_addr_t slots_dma;
	int domain;
	u16 rc_id;
	u16 device_instance;
	refcount_t refs;
	struct completion refs_released;
	atomic64_t next_transaction;
	bool removing;
	struct list_head registry_node;
};

static LIST_HEAD(dpu_table_controllers);
static DEFINE_SPINLOCK(dpu_table_registry_lock);

static int dpu_table_registry_add(struct dpu_table_controller *candidate)
{
	struct dpu_table_controller *controller;

	spin_lock(&dpu_table_registry_lock);
	list_for_each_entry(controller, &dpu_table_controllers, registry_node) {
		if (controller->domain == candidate->domain) {
			spin_unlock(&dpu_table_registry_lock);
			return -EEXIST;
		}
	}
	list_add_tail(&candidate->registry_node, &dpu_table_controllers);
	spin_unlock(&dpu_table_registry_lock);
	return 0;
}

static void dpu_table_controller_put(struct dpu_table_controller *controller)
{
	if (refcount_dec_and_test(&controller->refs))
		complete(&controller->refs_released);
}

static struct dpu_table_controller *
dpu_table_controller_get(struct pci_dev *target)
{
	struct dpu_table_controller *controller;
	int domain;

	if (!target || !target->bus)
		return NULL;
	domain = pci_domain_nr(target->bus);
	/*
	 * The controller is on the root bus while PF0 is behind another root
	 * port.  The unique controller in this PCI domain carries the
	 * authoritative RC/device identity used below; ancestry is irrelevant.
	 */
	spin_lock(&dpu_table_registry_lock);
	list_for_each_entry(controller, &dpu_table_controllers, registry_node) {
		if (!controller->removing && controller->domain == domain &&
		    refcount_inc_not_zero(&controller->refs)) {
			spin_unlock(&dpu_table_registry_lock);
			return controller;
		}
	}
	spin_unlock(&dpu_table_registry_lock);
	return NULL;
}

static cosim_u32 *dpu_table_slot_state(cosim_table_slot_hdr_t *slot)
{
	return (cosim_u32 *)slot;
}

static cosim_table_slot_hdr_t *
dpu_table_claim_slot(struct dpu_table_controller *controller, u32 *slot_index)
{
	cosim_u32 busy = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_BUSY);
	cosim_u32 free = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_FREE);
	u32 index;

	for (index = 0; index < DPU_TABLE_SLOT_COUNT; ++index) {
		cosim_table_slot_hdr_t *slot =
			(cosim_table_slot_hdr_t *)((u8 *)controller->slots +
						 index * DPU_TABLE_SLOT_BYTES);

		if (cmpxchg(dpu_table_slot_state(slot), free, busy) == free) {
			*slot_index = index;
			return slot;
		}
	}
	return NULL;
}

static void dpu_table_fill_target(cosim_table_target_t *target,
				  struct dpu_table_controller *controller,
				  struct dpu_adapter *adapter,
				  unsigned int logical_bar, u32 generation)
{
	struct pci_dev *pdev = adapter->pdev;

	memset(target, 0, sizeof(*target));
	cosim_table_target_set_identity(target, controller->rc_id,
					controller->device_instance,
					pci_domain_nr(pdev->bus),
					((u16)pdev->bus->number << 8) |
					pdev->devfn, generation);
	target->target_type = COSIM_TABLE_TARGET_PF;
	target->pf_index = 0;
	target->bar_index = (cosim_u8)logical_bar;
}

static enum dpu_table_submit_result
dpu_table_completion_result(struct dpu_table_controller *controller,
			    cosim_table_slot_hdr_t *slot)
{
	cosim_table_status_t status = (cosim_table_status_t)
		cosim_table_le32_to_cpu(READ_ONCE(slot->result_status));
	enum dpu_table_submit_result result = dpu_table_policy(status);

	if (result == DPU_TABLE_ERROR)
		dev_err(&controller->pdev->dev,
			"table sideband hard error: status=%u failed_index=%u committed=%u\n",
			(unsigned int)status,
			cosim_table_le32_to_cpu(slot->result_failed_index),
			cosim_table_le32_to_cpu(slot->result_committed_count));
	return result;
}

static enum dpu_table_submit_result dpu_table_submit_request(
	struct dpu_hw *hw, unsigned int logical_bar, u64 offset,
	const void *data, u32 bytes, enum dpu_table_write_order order)
{
	struct dpu_table_controller *controller;
	struct dpu_adapter *adapter;
	cosim_table_slot_hdr_t *slot;
	cosim_u32 complete = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_COMPLETE);
	cosim_u32 free = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_FREE);
	cosim_u32 ready = cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_READY);
	u64 transaction;
	u32 generation;
	u32 slot_index;
	int domain;
	enum dpu_table_submit_result result;

	/* Disabled mode must not perform lookup, identity MMIO, or slot access. */
	if (!dpu_table_backdoor_enabled())
		return DPU_TABLE_FRONTDOOR;
	if (!hw || !hw->adapter || !data || !bytes ||
	    bytes > DPU_TABLE_SLOT_PAYLOAD_BYTES || logical_bar > 1 ||
	    (order != DPU_TABLE_LOW_TO_HIGH &&
	     order != DPU_TABLE_HIGH_TO_LOW))
		return DPU_TABLE_FRONTDOOR;

	adapter = (struct dpu_adapter *)hw->adapter;
	if (!adapter->pdev || !adapter->pdev->bus ||
	    adapter->func_type == DPU_FUNC_VF || adapter->pfvf_id != 0)
		return DPU_TABLE_FRONTDOOR;
	domain = pci_domain_nr(adapter->pdev->bus);
	if (domain < 0 || domain > U16_MAX)
		return DPU_TABLE_FRONTDOOR;

	controller = dpu_table_controller_get(adapter->pdev);
	if (!controller)
		return DPU_TABLE_FRONTDOOR;
	if (!readl(controller->bar0 + COSIM_TABLE_REG_READY)) {
		result = DPU_TABLE_FRONTDOOR;
		goto out_put;
	}
	generation = readl(controller->bar0 + COSIM_TABLE_REG_TARGET_GENERATION);
	if (!generation) {
		result = DPU_TABLE_FRONTDOOR;
		goto out_put;
	}

	slot = dpu_table_claim_slot(controller, &slot_index);
	if (!slot) {
		result = DPU_TABLE_FRONTDOOR;
		goto out_put;
	}

	memset((u8 *)slot + sizeof(slot->state), 0,
	       DPU_TABLE_SLOT_BYTES - sizeof(slot->state));
	transaction = atomic64_inc_return(&controller->next_transaction);
	if (!transaction)
		transaction = atomic64_inc_return(&controller->next_transaction);
	slot->header_version =
		cosim_table_cpu_to_le32(COSIM_TABLE_SLOT_HEADER_VERSION);
	slot->transaction_id = cosim_table_cpu_to_le64(transaction);
	dpu_table_fill_target(&slot->target, controller, adapter, logical_bar,
			      generation);
	slot->bar_offset = cosim_table_cpu_to_le64(offset);
	slot->payload_bytes = cosim_table_cpu_to_le32(bytes);
	slot->payload_offset =
		cosim_table_cpu_to_le32(sizeof(cosim_table_slot_hdr_t));
	memcpy((u8 *)slot + sizeof(cosim_table_slot_hdr_t), data, bytes);

	dma_wmb();
	smp_store_release(dpu_table_slot_state(slot), ready);
	writel(slot_index, controller->bar0 + COSIM_TABLE_REG_DOORBELL);
	/* Flush the posted doorbell before consuming the coherent completion. */
	readl(controller->bar0 + COSIM_TABLE_REG_LAST_ERROR);
	if (smp_load_acquire(dpu_table_slot_state(slot)) != complete) {
		dev_err(&controller->pdev->dev,
			"table sideband hard error: no completion failed_index=0 committed=0\n");
		result = DPU_TABLE_ERROR;
	} else {
		dma_rmb();
		result = dpu_table_completion_result(controller, slot);
	}
	dma_wmb();
	smp_store_release(dpu_table_slot_state(slot), free);
out_put:
	dpu_table_controller_put(controller);
	return result;
}

enum dpu_table_submit_result dpu_table_submit(
	struct dpu_hw *hw, unsigned int logical_bar, u64 offset,
	const void *data, u32 bytes, enum dpu_table_write_order order)
{
	return dpu_table_submit_request(hw, logical_bar, offset, data, bytes,
					order);
}

enum dpu_table_submit_result dpu_table_submit_batch(
	struct dpu_hw *hw, unsigned int logical_bar, u64 first_offset,
	const void *entries, u32 entry_bytes, u32 stride_bytes,
	u32 entry_count, enum dpu_table_write_order order)
{
	const u8 *entry_data = entries;
	u32 submitted;

	if (!entry_data || !entry_bytes || !entry_count ||
	    entry_bytes > DPU_TABLE_SLOT_PAYLOAD_BYTES ||
	    stride_bytes < entry_bytes || logical_bar > 1 ||
	    (order != DPU_TABLE_LOW_TO_HIGH &&
	     order != DPU_TABLE_HIGH_TO_LOW) ||
	    (u64)(entry_count - 1) * stride_bytes > U64_MAX - first_offset)
		return DPU_TABLE_FRONTDOOR;

	for (submitted = 0; submitted < entry_count; ++submitted) {
		u32 index = order == DPU_TABLE_HIGH_TO_LOW ?
			entry_count - 1 - submitted : submitted;
		enum dpu_table_submit_result result = dpu_table_submit_request(
			hw, logical_bar, first_offset + (u64)index * stride_bytes,
			entry_data + (size_t)index * entry_bytes, entry_bytes,
			order);

		if (result == DPU_TABLE_SUCCESS)
			continue;
		if (result == DPU_TABLE_FRONTDOOR && submitted) {
			struct dpu_adapter *adapter = hw && hw->adapter ?
				(struct dpu_adapter *)hw->adapter : NULL;

			if (adapter && adapter->pdev)
				dev_err(&adapter->pdev->dev,
					"table sideband batch partially committed: failed_index=%u committed=%u\n",
					index, submitted);
			return DPU_TABLE_ERROR;
		}
		return result;
	}
	return DPU_TABLE_SUCCESS;
}

static int dpu_table_ctrl_probe(struct pci_dev *pdev,
				const struct pci_device_id *id)
{
	struct dpu_table_controller *controller;
	u32 device_instance;
	u32 rc_id;
	int err;

	(void)id;
	err = pci_enable_device(pdev);
	if (err)
		return err;
	err = pci_request_region(pdev, 0, "dpu-table-sideband");
	if (err)
		goto err_disable;
	if (pci_resource_len(pdev, 0) < COSIM_TABLE_CTRL_BAR_BYTES) {
		err = -ENODEV;
		goto err_release;
	}

	controller = kzalloc(sizeof(*controller), GFP_KERNEL);
	if (!controller) {
		err = -ENOMEM;
		goto err_release;
	}
	controller->bar0 = pci_iomap(pdev, 0, 0);
	if (!controller->bar0) {
		err = -ENOMEM;
		goto err_free;
	}
	if (readl(controller->bar0 + COSIM_TABLE_REG_MAGIC) !=
		    COSIM_TABLE_MAGIC ||
	    readl(controller->bar0 + COSIM_TABLE_REG_VERSION) !=
		    COSIM_TABLE_PROTOCOL_VERSION ||
	    !(readl(controller->bar0 + COSIM_TABLE_REG_CAPS) &
	      COSIM_TABLE_CAP_WRITE)) {
		err = -ENODEV;
		goto err_unmap;
	}
	rc_id = readl(controller->bar0 + COSIM_TABLE_REG_RC_ID);
	device_instance =
		readl(controller->bar0 + COSIM_TABLE_REG_DEVICE_INSTANCE);
	if (rc_id > U16_MAX || device_instance > U16_MAX) {
		err = -ERANGE;
		goto err_unmap;
	}

	err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (err)
		err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (err)
		goto err_unmap;
	pci_set_master(pdev);

	controller->slots = dma_alloc_coherent(&pdev->dev, DPU_TABLE_DMA_BYTES,
					       &controller->slots_dma,
					       GFP_KERNEL);
	if (!controller->slots) {
		err = -ENOMEM;
		goto err_clear_master;
	}
	memset(controller->slots, 0, DPU_TABLE_DMA_BYTES);
	controller->pdev = pdev;
	controller->domain = pci_domain_nr(pdev->bus);
	controller->rc_id = (u16)rc_id;
	controller->device_instance = (u16)device_instance;
	refcount_set(&controller->refs, 1);
	init_completion(&controller->refs_released);
	atomic64_set(&controller->next_transaction, 0);
	INIT_LIST_HEAD(&controller->registry_node);

	err = dpu_table_registry_add(controller);
	if (err)
		goto err_dma;
	writel(lower_32_bits(controller->slots_dma),
	       controller->bar0 + COSIM_TABLE_REG_DMA_ADDR_LO);
	writel(upper_32_bits(controller->slots_dma),
	       controller->bar0 + COSIM_TABLE_REG_DMA_ADDR_HI);
	writel(DPU_TABLE_DMA_BYTES,
	       controller->bar0 + COSIM_TABLE_REG_DMA_BYTES);
	writel(DPU_TABLE_SLOT_COUNT,
	       controller->bar0 + COSIM_TABLE_REG_SLOT_COUNT);
	pci_set_drvdata(pdev, controller);
	return 0;

err_dma:
	dma_free_coherent(&pdev->dev, DPU_TABLE_DMA_BYTES, controller->slots,
			  controller->slots_dma);
err_clear_master:
	pci_clear_master(pdev);
err_unmap:
	pci_iounmap(pdev, controller->bar0);
err_free:
	kfree(controller);
err_release:
	pci_release_region(pdev, 0);
err_disable:
	pci_disable_device(pdev);
	return err;
}

static void dpu_table_ctrl_remove(struct pci_dev *pdev)
{
	struct dpu_table_controller *controller = pci_get_drvdata(pdev);

	if (!controller)
		return;
	spin_lock(&dpu_table_registry_lock);
	controller->removing = true;
	list_del_init(&controller->registry_node);
	spin_unlock(&dpu_table_registry_lock);
	dpu_table_controller_put(controller);
	wait_for_completion(&controller->refs_released);

	writel(0, controller->bar0 + COSIM_TABLE_REG_SLOT_COUNT);
	writel(0, controller->bar0 + COSIM_TABLE_REG_DMA_BYTES);
	writel(0, controller->bar0 + COSIM_TABLE_REG_DMA_ADDR_HI);
	writel(0, controller->bar0 + COSIM_TABLE_REG_DMA_ADDR_LO);
	dma_free_coherent(&pdev->dev, DPU_TABLE_DMA_BYTES, controller->slots,
			  controller->slots_dma);
	pci_iounmap(pdev, controller->bar0);
	pci_clear_master(pdev);
	pci_release_region(pdev, 0);
	pci_disable_device(pdev);
	kfree(controller);
}

static const struct pci_device_id dpu_table_ctrl_ids[] = {
	{ PCI_DEVICE(COSIM_TABLE_CTRL_VENDOR_ID, COSIM_TABLE_CTRL_DEVICE_ID) },
	{ 0, }
};
MODULE_DEVICE_TABLE(pci, dpu_table_ctrl_ids);

static struct pci_driver dpu_table_ctrl_driver = {
	.name = "dpu-table-sideband",
	.id_table = dpu_table_ctrl_ids,
	.probe = dpu_table_ctrl_probe,
	.remove = dpu_table_ctrl_remove,
};

int dpu_table_ctrl_register(void)
{
	return pci_register_driver(&dpu_table_ctrl_driver);
}

void dpu_table_ctrl_unregister(void)
{
	pci_unregister_driver(&dpu_table_ctrl_driver);
}
