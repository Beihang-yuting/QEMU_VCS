static void dpu_clear_notify_addr(struct dpu_hw *hw)
{
	struct dpu_adapter *adapter;
	struct pci_dev *pdev;
	u64 real_addr;
	u64 notify_addr;
	u16 srcid;
	int err = 0;

	adapter = hw->adapter;
	pdev = adapter->pdev;
	if (!is_vf(hw))
		real_addr = dpu_read_real_bar_base_addr(pdev);
	else
		err = dpu_mailbox_req_get_vf_bar_base_addr(hw, &real_addr);

	if (err) {
		pr_err("Failed to get VF BAR base address when clear notify address\n");
		return;
	}

	if (is_af(hw)) {
		srcid = ((u16)adapter->host_id << ID_FIELD_HOST_ID_SHIFT) |
			adapter->pfvf_id;
		notify_addr = real_addr + VIO_NOTIFY_BASE;

		dpu_af_clear_qid_map(hw, srcid, notify_addr);
	} else {
		notify_addr = real_addr;
		dpu_mailbox_req_clear_qid_map(hw, notify_addr);
	}
}

static int dpu_get_vsi_id(struct dpu_hw *hw)
{
	int err;
