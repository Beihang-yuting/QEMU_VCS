/* Fixed active-function excerpt from the 2026-08-10 QID128 release. */
static void dpu_af_fill_qid_map_table(struct dpu_hw *hw, u16 srcid,
				      u64 notify_addr, u8 notify_type, struct dpu_virtio_device *virtio_dev)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_vio_notify_tbl qid_map = {0};
	struct cfg_vio_notify_tab_reg queue_cfg;
	unsigned long flags;
	u16 qid_map_entries;
	u16 qid_map_base;
	u16 i;
	u16 j;
	u8 host_id;

	host_id = srcid >> ID_FIELD_HOST_ID_SHIFT;

	spin_lock_irqsave(&af_res->func_res_lock, flags);
	for (i = 0; i < qid_map_entries; i++) {
		qid_map.global_qid = i;
		memcpy(&af_res->vio_notify_table[qid_map_base + i], &qid_map, sizeof(struct dpu_vio_notify_tbl));
	}

	for (i = 0; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++) {
		j = 0;

		do {
			wr32_for_high_order(hw,
				      VIO_NOTIFY_TBL_E_ADDR(
					      af_res->vio_notify_tbl_select, i),
				      (u32 *)(af_res->vio_notify_table + i),
				      sizeof(qid_map));
			wmb();
			udelay(5);
			rd32_for_each(hw,
				      VIO_NOTIFY_TBL_E_ADDR(
					      af_res->vio_notify_tbl_select, i),
				      (u32 *)&qid_map, sizeof(qid_map));
			if (likely(!memcmp(&qid_map,
					   af_res->vio_notify_table + i,
					   sizeof(qid_map))))
				break;
			j++;
		} while (j < DPU_REG_WRITE_MAX_TRY_TIMES);

		if (j == DPU_REG_WRITE_MAX_TRY_TIMES)
			pr_err("Write to qid map table entry %hhu failed\n", i);
	}

	af_res->vio_notify_tbl_ready += qid_map_entries;
	memset(&queue_cfg, 0, sizeof(queue_cfg));
	queue_cfg.cfg_vio_notify_sel = af_res->vio_notify_tbl_select;
	spin_unlock_irqrestore(&af_res->func_res_lock, flags);
}

static void dpu_af_remove_qid_map_table(struct dpu_hw *hw, u16 srcid,
					u64 notify_addr, u8 notify_type, struct dpu_virtio_device *virtio_dev)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_vio_notify_tbl qid_map;
	struct dpu_vio_notify_tbl invalid_qid_map;
	struct cfg_vio_notify_tab_reg queue_cfg;
	unsigned long flags;
	u16 qid_map_entries;
	u16 qid_map_base;
	u32 i;
	u32 j;
	u8 host_id;

	host_id = srcid >> ID_FIELD_HOST_ID_SHIFT;

	spin_lock_irqsave(&af_res->func_res_lock, flags);
	for (i = qid_map_base; i < DPU_QID_MAP_TABLE_ENTRIES(hw) - qid_map_entries;
	     i++)
		af_res->vio_notify_table[i] =
			af_res->vio_notify_table[i + qid_map_entries];
	for (; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++)
		af_res->vio_notify_table[i] = invalid_qid_map;

	for (i = 0; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++) {
		j = 0;

		do {
			wr32_for_high_order(hw,
				      VIO_NOTIFY_TBL_E_ADDR(
					      af_res->vio_notify_tbl_select, i),
				      (u32 *)(af_res->vio_notify_table + i),
				      sizeof(qid_map));
			wmb();
			udelay(5);
			rd32_for_each(hw,
				      VIO_NOTIFY_TBL_E_ADDR(
					      af_res->vio_notify_tbl_select, i),
				      (u32 *)&qid_map, sizeof(qid_map));
			if (likely(!memcmp(&qid_map,
					   af_res->vio_notify_table + i,
					   sizeof(qid_map))))
				break;
			j++;
		} while (j < DPU_REG_WRITE_MAX_TRY_TIMES);

		if (j == DPU_REG_WRITE_MAX_TRY_TIMES)
			pr_err("Write to qid map table entry %hhu failed when remove entries\n",
			       i);
	}

	af_res->vio_notify_tbl_ready -= qid_map_entries;
	memset(&queue_cfg, 0, sizeof(queue_cfg));
	queue_cfg.cfg_vio_notify_sel = af_res->vio_notify_tbl_select;
	spin_unlock_irqrestore(&af_res->func_res_lock, flags);
}
