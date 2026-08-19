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
