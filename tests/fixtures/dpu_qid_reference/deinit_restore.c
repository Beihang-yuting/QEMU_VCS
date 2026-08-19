
static void af_rmmod_clear_notify_addr(struct dpu_hw *hw, u16 srcid)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];

	if(unlikely(!func_res)) {
		pr_err(
			"vport srcid [%x] deinit restore clear notify addr with null func_res",
			 srcid);
		return;
	}

	if (!(func_res->vio_notifiy_addr & 1))
		dpu_af_clear_qid_map(hw, srcid, func_res->vio_notifiy_addr);
}

static void af_rmmod_mailbox_disable_iqr(struct dpu_hw *hw, u16 srcid)
{
	struct dpu_af_res_info *af_res = hw->af_res;
	struct dpu_func_res *func_res =
		af_res->res_record[SRCID_2_INDEX(srcid)];
	int i;

	if(unlikely(!func_res)) {
		pr_err(
			"vport srcid [%x] deinit restore mailbox disable irq with null func_res",
			 srcid);
