void dpu_af_register_vf_bar_info(struct dpu_hw *hw, u16 srcid, u64 vf_bar_start,
				 u64 vf_bar_len);
int dpu_af_configure_qid_map(struct dpu_hw *hw, u16 srcid, u8 num_queues,
				u64 notify_addr);
void dpu_af_disable_promisc(struct dpu_hw *hw);
void dpu_af_enable_promisc(struct dpu_hw *hw);
void dpu_af_clear_qid_map(struct dpu_hw *hw, u16 srcid, u64 notify_addr);


void dpu_af_configure_eth_netdev_rss_group_table(struct dpu_hw *hw, u16 port_index);
void dpu_af_clear_mac_addr(struct dpu_hw *hw, u16 srcid, u8 free_pf_mac);
void dpu_af_clear_eth_netdev_mac_addr(struct dpu_hw *hw, u16 port_index);
