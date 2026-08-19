	dpu_mailbox_send_ack_msg(hw, mailbox, srcid, err, req_msg_type);
}

void dpu_mailbox_req_clear_qid_map(struct dpu_hw *hw, u64 notify_addr)
{
	struct dpu_mailbox_clear_qid_map_arg arg;
	struct dpu_mailbox_info *mailbox = &hw->mailbox;
	struct dpu_adapter *adapter = hw->adapter;
	int i;
	u16 destid;

	if (adapter->ecpu_host_id < DPU_MAX_HOST) {
		destid = (u16)adapter->ecpu_host_id << ID_FIELD_HOST_ID_SHIFT;
	} else {
		destid = 0xFFFF;
	}

	mutex_lock(&mailbox->send_normal_msg_lock);

	mailbox->ack_req_msg_type = DPU_MAILBOX_CLEAR_QID_MAP;
	/* ensure request message related variables are completely written */
	wmb();

	arg.notify_addr = notify_addr;

	dpu_mailbox_send_msg(hw, mailbox, destid, DPU_MAILBOX_CLEAR_QID_MAP,
			     &arg, sizeof(arg));

	i = 0;
	while (!mailbox->acked) {
		cpu_relax();
		i++;
		if (i >= get_mailbox_max_retry_count(MSG_TYPE_NETWORK) - 5)
			dpu_mailbox_poll_once_rxq(hw);

		if (i == get_mailbox_max_retry_count(MSG_TYPE_NETWORK)) {
			pr_warn("Wait clear qid map ack message timeout\n");
			mailbox_timeout_counter++;
			mutex_unlock(&mailbox->send_normal_msg_lock);
			return;
		}
		usleep_range(100, 200);
	}
	mailbox_timeout_counter = 0;
	mailbox->acked = 0;
	mailbox->ack_req_msg_type = 0;
	mutex_unlock(&mailbox->send_normal_msg_lock);
}

static void dpu_mailbox_resp_clear_qid_map(struct dpu_hw *hw, void *data,
					   u32 data_len)
{
	struct dpu_mailbox_info *mailbox;
	struct dpu_mailbox_tx_desc *tx_desc;
	struct dpu_mailbox_clear_qid_map_arg *arg;
	u16 arg_len;
	u16 srcid;
	u64 notify_addr;
	unsigned int req_msg_type;

	tx_desc = data;

	arg_len = (u16)sizeof(struct dpu_mailbox_clear_qid_map_arg);
	if (arg_len > DPU_MAILBOX_TX_DESC_EMBEDDED_DATA_LEN) {
		if (tx_desc->buf_len != arg_len) {
			pr_err("Clear qid map mailbox message has wrong argument size\n");
			return;
		}
		arg = (struct dpu_mailbox_clear_qid_map_arg *)(tx_desc + 1);
	} else {
		if (tx_desc->data_len != arg_len) {
			pr_err("Clear qid map mailbox message has wrong argument size\n");
			return;
		}
		arg = (struct dpu_mailbox_clear_qid_map_arg *)tx_desc->data;
	}

	srcid = tx_desc->srcid;
	notify_addr = arg->notify_addr;
	dpu_af_clear_qid_map(hw, srcid, notify_addr);

	mailbox = &hw->mailbox;
	req_msg_type = tx_desc->msg_type;
	dpu_mailbox_send_ack_msg(hw, mailbox, srcid, 0, req_msg_type);
}

void dpu_mailbox_req_disable_promisc(struct dpu_hw *hw, u8 eth_port_id)
{
	struct dpu_mailbox_cfg_promisc_arg arg;
	struct dpu_mailbox_info *mailbox = &hw->mailbox;
	struct dpu_adapter *adapter = hw->adapter;
	int i;
	u16 destid;

	if (!mutex_trylock(&mailbox->send_normal_msg_lock)) {
