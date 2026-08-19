}
#endif

static void dpu_af_fill_qid_map_table(struct dpu_hw *hw, u16 srcid,
				      u64 notify_addr, u8 notify_type, struct dpu_virtio_device *virtio_dev)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];
	struct dpu_vio_notify_tbl qid_map = {0};
	struct cfg_vio_notify_tab_reg queue_cfg;
	unsigned long flags;
	u32 *global_queue_ids;
	u64 key;
	u16 qid_map_entries;
	u16 qid_map_base;
	u16 i;
	u16 j;
	u8 host_id;

	host_id = srcid >> ID_FIELD_HOST_ID_SHIFT;

	spin_lock_irqsave(&af_res->func_res_lock, flags);

	qid_map_base = DPU_QID_MAP_TABLE_ENTRIES(hw);

	key = ((u64)host_id << 61) | (notify_addr & 0x1fffffffffffff80);
	qid_map.type = notify_type;

	for (i = 0; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++) {
		WARN_ON(key ==
			dpu_get_qid_map_key(&(af_res->vio_notify_table[i])));
		if (key < dpu_get_qid_map_key(&(af_res->vio_notify_table[i]))) {
			qid_map_base = i;
			break;
		}
	}

	if (unlikely(qid_map_base == DPU_QID_MAP_TABLE_ENTRIES(hw))) {
		pr_alert(
			"Can not insert key corresponding to notify addr %llx\n",
			notify_addr);
		spin_unlock_irqrestore(&af_res->func_res_lock, flags);
		return;
	}

	switch(notify_type) {
		case VIO_NOTIFY_TYPE_NET:
			qid_map_entries = func_res->num_txrx_queues;
			global_queue_ids = func_res->txrx_queues;
			break;
		case VIO_NOTIFY_TYPE_CTRLQ:
			pr_alert("Error not support CTRLQ\n");
			return;
		case VIO_NOTIFY_TYPE_BLK:
			qid_map_entries = virtio_dev->common.total_queue_num;
			global_queue_ids = virtio_dev->common.global_queue_ids;
			break;
		default:
			pr_alert("Error not support\n");
			return;
	}

	for (i = DPU_QID_MAP_TABLE_ENTRIES(hw) - qid_map_entries; i > qid_map_base; i--)
		memcpy(&af_res->vio_notify_table[i - 1 + qid_map_entries],
			&af_res->vio_notify_table[i - 1],sizeof(struct dpu_vio_notify_tbl));

	for (i = 0; i < qid_map_entries; i++) {
		if ((VIO_NOTIFY_TYPE_NET == notify_type) || (VIO_NOTIFY_TYPE_CTRLQ == notify_type)) {
			qid_map.local_qid_net = 1;
			qid_map.local_qid     = (i & 0x1F);       /* 0x1F = 00011111 */
			qid_map.local_qid_blk = (i & 0x20) >> 5;    /* 0x20 = 00100000 */
		} else if (VIO_NOTIFY_TYPE_BLK == notify_type) {
			qid_map.local_qid_net = (i & 0x1);        /* 0x01 = 00000001 */
			qid_map.local_qid     = (i & 0x3E) >> 1;   /* 0x3E = 00111110 */
			qid_map.local_qid_blk = 0;
		} else
			pr_alert("Error not support\n");
		qid_map.notify_addr_l = (notify_addr & 0xffffff80) >> 7;

		qid_map.host_id = host_id;
		qid_map.notify_addr_h =
			(notify_addr & 0x1fffffff00000000) >> 32;
		qid_map.global_qid = global_queue_ids[i];
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

	if (af_res->vio_notify_tbl_ready)
		queue_cfg.cfg_vio_notify_rdy = 1;

	wr32_and_verify(hw, INTF_PCMPL_CFG_VIO_NOTIFY_TAB_ADDR,
			*(u32 *)&queue_cfg);
	af_res->vio_notify_tbl_select = !af_res->vio_notify_tbl_select;

	spin_unlock_irqrestore(&af_res->func_res_lock, flags);
}

static void dpu_af_remove_qid_map_table(struct dpu_hw *hw, u16 srcid,
					u64 notify_addr, u8 notify_type, struct dpu_virtio_device *virtio_dev)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];
	struct dpu_vio_notify_tbl qid_map;
	struct dpu_vio_notify_tbl invalid_qid_map;
	struct cfg_vio_notify_tab_reg queue_cfg;
	unsigned long flags;
	u64 key;
	u16 qid_map_entries;
	u16 qid_map_base;
	u32 i;
	u32 j;
	u8 host_id;

	host_id = srcid >> ID_FIELD_HOST_ID_SHIFT;

	spin_lock_irqsave(&af_res->func_res_lock, flags);

	qid_map_base = DPU_QID_MAP_TABLE_ENTRIES(hw);
	key = ((u64)host_id << 61) | (notify_addr & 0x1fffffffffffff80);

	for (i = 0; i < DPU_QID_MAP_TABLE_ENTRIES(hw); i++) {
		if (key ==
			dpu_get_qid_map_key(&(af_res->vio_notify_table[i]))) {
			qid_map_base = i;
			break;
		}
	}

	if (unlikely(qid_map_base == DPU_QID_MAP_TABLE_ENTRIES(hw))) {
		pr_alert("Can not find key corresponding to notify addr %llx\n",
			 notify_addr);
		spin_unlock_irqrestore(&af_res->func_res_lock, flags);
		return;
	}

	switch(notify_type) {
		case VIO_NOTIFY_TYPE_NET:
			qid_map_entries = func_res->num_txrx_queues;
			break;
		case VIO_NOTIFY_TYPE_CTRLQ:
			pr_alert("Error not support CTRLQ\n");
			return;
		case VIO_NOTIFY_TYPE_BLK:
			qid_map_entries = virtio_dev->common.total_queue_num;
			break;
		default:
			spin_unlock_irqrestore(&af_res->func_res_lock, flags);
			pr_alert("Error not support\n");
			return;
	}

	memset(&invalid_qid_map, 0xff, sizeof(invalid_qid_map));

	invalid_qid_map.type = VIO_NOTIFY_TYPE_RSV;
	invalid_qid_map.rsv = 0;
	invalid_qid_map.rsv2 = 0;
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

	if (af_res->vio_notify_tbl_ready)
		queue_cfg.cfg_vio_notify_rdy = 1;

	wr32_and_verify(hw, INTF_PCMPL_CFG_VIO_NOTIFY_TAB_ADDR,
			*(u32 *)&queue_cfg);
	af_res->vio_notify_tbl_select = !af_res->vio_notify_tbl_select;

	spin_unlock_irqrestore(&af_res->func_res_lock, flags);
}

static void dpu_configure_eth_port_table_p2(struct dpu_hw *hw, u16 srcid)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res;
	struct ipro_eth_iport_table_entry ipro_eth_iport = {0};
	struct ipro_vport_iport_table_entry ipro_vport_iport = {0};
	u8 hostid;
	u16 pfvf_id;

	if (!is_af(hw))
		return;

	if (!(dpu_get_fabric_mode() & BIT(DPU_ETH_PORT_ST)))
		return;

	if (srcid < PORT_ST_MIN_SRC || srcid > PORT_ST_MAX_SRC)
		return;

	hostid = (srcid & ID_FIELD_HOST_ID_MASK) >> ID_FIELD_HOST_ID_SHIFT;
	pfvf_id = srcid & ID_FIELD_PFVF_ID_MASK;

	func_res = af_res->res_record[SRCID_2_INDEX(srcid)];

	rd32_for_each(hw,
		PP_IPRO_VPORT_IPORT_TBL_E_ADDR(func_res->global_func_id),
			  &ipro_vport_iport, sizeof(ipro_vport_iport));

	ipro_vport_iport.port_straight = 1;

	wr32_for_each(hw,
		PP_IPRO_VPORT_IPORT_TBL_E_ADDR(func_res->global_func_id),
			  &ipro_vport_iport, sizeof(ipro_vport_iport));

	rd32_for_each(hw, PP_IPRO_ETH_IPORT_TBL_E_ADDR(pfvf_id - 1),
			  &ipro_eth_iport, sizeof(ipro_eth_iport));

	ipro_eth_iport.port_straight = 1;

	/* set eth0/1 to selective host pf1/2, for hardware test case */
	ipro_eth_iport.dport_type = hostid + PT_HOST0;
	ipro_eth_iport.rss_lag_en = 1;
	ipro_eth_iport.dport_id_l = func_res->global_func_id & 0x1f;
	ipro_eth_iport.dport_id_h = (func_res->global_func_id & 0x3E0) >> 5;
	ipro_eth_iport.dport_info = func_res->txrx_queues[0];

	if (dpu_af_get_lag_status(hw, 0)) {
		ipro_eth_iport.in_lag_en = 1;
		ipro_eth_iport.in_lag_id = 0;
	}
	wr32_for_each(hw, PP_IPRO_ETH_IPORT_TBL_E_ADDR(pfvf_id - 1),
			  &ipro_eth_iport, sizeof(ipro_eth_iport));
}

static void dpu_clear_eth_port_table_p2(struct dpu_hw *hw, u16 srcid)
{
	struct ipro_eth_iport_table_entry ipro_eth_iport = { 0 };
	u16 pfvf_id;

	if (!is_af(hw))
		return;

	if ((srcid < PORT_ST_MIN_SRC || srcid > PORT_ST_MAX_SRC)
		|| !(dpu_get_fabric_mode() & BIT(DPU_ETH_PORT_ST)))
		return;

	pfvf_id = srcid & ID_FIELD_PFVF_ID_MASK;

	wr32_for_each(hw, PP_IPRO_ETH_IPORT_TBL_E_ADDR(pfvf_id - 1),
		      &ipro_eth_iport, sizeof(ipro_eth_iport));
}

static void af_config_unknown_traffic_destin(struct dpu_hw *hw, u16 srcid)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];
	struct ipro_vport_iport_table_entry ipro_vport_iport = {0};

	rd32_for_each(hw, PP_IPRO_VPORT_IPORT_TBL_E_ADDR(func_res->global_func_id),
		&ipro_vport_iport, sizeof(ipro_vport_iport));

	ipro_vport_iport.port_straight = 0;
	ipro_vport_iport.rss_lag_en = 1;
	ipro_vport_iport.dport_type = PT_ETH;
	ipro_vport_iport.dport_id_l = 0;
	ipro_vport_iport.dprot_id_h = 0;

	wr32_for_each(hw, PP_IPRO_VPORT_IPORT_TBL_E_ADDR(func_res->global_func_id),
		&ipro_vport_iport, sizeof(ipro_vport_iport));

}

int dpu_af_configure_qid_map(struct dpu_hw *hw, u16 srcid, u8 num_queues,
			     u64 notify_addr)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];
	unsigned long flags;
	u16 queue_index;
	u32 *txrx_queues;
	u8 notify_type = VIO_NOTIFY_TYPE_NET;
	u8 i;
	int err;

	WARN_ON(!func_res || func_res->num_txrx_queues);

	txrx_queues = kcalloc(num_queues, sizeof(txrx_queues[0]), GFP_ATOMIC);
	if (!txrx_queues)
		return -ENOMEM;
	func_res->num_txrx_queues = num_queues;
	func_res->txrx_queues = txrx_queues;
	func_res->vio_notifiy_addr = notify_addr;

	spin_lock_irqsave(&af_res->func_res_lock, flags);

	for (i = 0; i < num_queues; i++) {
		queue_index = find_first_zero_bit(af_res->txrx_queue_bitmap,
						  DPU_MAX_TXRX_QUEUE);
		if (queue_index == DPU_MAX_TXRX_QUEUE) {
			pr_err("There is no available txrx queues left\n");
			err = -EAGAIN;
			goto get_txrx_queue_err;
		}
		txrx_queues[i] = queue_index;
		set_bit(queue_index, af_res->txrx_queue_bitmap);
	}

	spin_unlock_irqrestore(&af_res->func_res_lock, flags);

	dpu_af_fill_qid_map_table(hw, srcid, notify_addr, notify_type, NULL);

	/* TODO: Move queue schedule and packet processing
	 *       related code to different places to improve
	 *       code readability.
	 */
	dpu_add_vnet_2_qsch(hw, srcid);

	for (i = 0; i < num_queues; i++)
		dpu_add_queue_2_qsch(hw, srcid, i, 0);

	dpu_configure_eth_port_table_p2(hw, srcid);

	if (legacy_mode_enable())
		af_config_unknown_traffic_destin(hw, srcid);

	return 0;

get_txrx_queue_err:
	while (i--) {
		queue_index = txrx_queues[i];
		clear_bit(queue_index, af_res->txrx_queue_bitmap);
	}
	spin_unlock_irqrestore(&af_res->func_res_lock, flags);

	kfree(txrx_queues);
	func_res->num_txrx_queues = 0;
	func_res->txrx_queues = NULL;

	return err;
}

void dpu_af_clear_qid_map(struct dpu_hw *hw, u16 srcid, u64 notify_addr)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];
	unsigned long flags;
	u8 queue_index;
	u8 num_queues;
	u32 *txrx_queues;
	u8 notify_type = VIO_NOTIFY_TYPE_NET;
	u8 i;

	WARN_ON(!func_res || !func_res->num_txrx_queues);
	num_queues = func_res->num_txrx_queues;

	dpu_af_remove_qid_map_table(hw, srcid, notify_addr, notify_type, NULL);
	func_res->vio_notifiy_addr |= 1;

	for (i = 0; i < num_queues; i++)
		dpu_del_queue_2_qsch(hw, srcid, i, 0);

	dpu_del_vnet_2_qsch(hw, srcid);

	dpu_clear_eth_port_table_p2(hw, srcid);

	dpu_delete_l3mc_port(hw, srcid);

	num_queues = func_res->num_txrx_queues;
	txrx_queues = func_res->txrx_queues;
	spin_lock_irqsave(&af_res->func_res_lock, flags);
	for (i = 0; i < num_queues; i++) {
		queue_index = txrx_queues[i];
		clear_bit(queue_index, af_res->txrx_queue_bitmap);
	}
	spin_unlock_irqrestore(&af_res->func_res_lock, flags);

	kfree(txrx_queues);
	func_res->txrx_queues = NULL;
	func_res->num_txrx_queues = 0;
}

void dpu_af_clear_eth_netdev_mac_addr(struct dpu_hw *hw, u16 port_index)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_macvlan_node *search;
	u8 *mac_addr = af_res->eth_netdev_cfg[port_index].mac_addr;

	search = dpu_macvlan_search_table(mac_addr, 0);
