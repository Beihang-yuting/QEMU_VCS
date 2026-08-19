int dpu_mailbox_request_irq(struct dpu_adapter *adapter);
void dpu_mailbox_enable_irq(struct dpu_adapter *adapter);
void dpu_purge_mailbox_event(struct dpu_adapter *adapter);
int dpu_mailbox_req_get_vsi_id(struct dpu_hw *hw);
int dpu_mailbox_req_cfg_qid_map(struct dpu_hw *hw, u8 num_queues,
				u64 notify_addr);
void dpu_mailbox_req_clear_qid_map(struct dpu_hw *hw, u64 notify_addr);
void dpu_af_disable_mailbox_irq(struct dpu_hw *hw, u16 srcid,
				       u16 vector_id);
void dpu_mailbox_req_disable_promisc(struct dpu_hw *hw, u8 eth_port_id);
int dpu_mailbox_req_register_vf_bar_info(struct dpu_hw *hw, u64 vf_bar_start,
