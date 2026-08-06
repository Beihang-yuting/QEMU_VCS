#ifndef __REG_INTERRUPT_H__
#define __REG_INTERRUPT_H__

#include "reg_display.h"
#include "reg_interface.h"
#include <string.h>

typedef struct {
	uint32_t l1_bit;			/* Level 1 interrupt bit position */
	const char *l2_reg_name;	/* Level 2 register name for display */
	uint32_t l2_reg_addr;	   /* Level 2 register address */
	const char **l2_keys;	   /* Level 2 interrupt key names */
	const void *l3_map;		 /* Pointer to Level 3 mapping table */
} l2_intr_map_t;

/* ----------------------------------------------------------------
 * Level 2 Interrupt Key Definitions
 * ----------------------------------------------------------------
 */

/* INTF module level 2 interrupts */
const char *int_greg_l2_intf_keys[] = {
	"INTF_BBLOCK",		  // Bit 0: BBLOCK interrupt
	"INTF_SBLOCK",		  // Bit 1: SBLOCK interrupt
	"INTF_BREG",			// Bit 2: BREG interrupt
	"INTF_PCOMPLETER",	  // Bit 3: PCOMPLETER interrupt
	"INTF_PREQUESTER",	  // Bit 4: PREQUESTER interrupt
	"INTF_MAILBOX",		 // Bit 5: MAILBOX interrupt
	"INTF_CMDQ",			// Bit 6: CMDQ interrupt
	"INTF_MSGQ",			// Bit 7: MSGQ interrupt
	"INTF_TLPQ",			// Bit 8: TLPQ interrupt
	"INTF_DMAQ",			// Bit 9: DMAQ interrupt
	"INTF_PMERGE",		  // Bit 10: PMERGE interrupt
	NULL
};


/* PP module level 2 interrupts */
const char *int_greg_l2_pp_keys[] = {
	"PP_CBUS",			  // Bit 0: CBUS interrupt
	"PP_PARSER",			// Bit 1: Parser interrupt
	"PP_IPRO",			  // Bit 2: IPRO interrupt
	"PP_PFLOW",			 // Bit 3: PFLOW interrupt
	"PP_IACL",			  // Bit 4: IACL interrupt
	"PP_PMC",			   // Bit 5: PMC interrupt
	"PP_EPRO",			  // Bit 6: EPRO interrupt
	"PP_EACL",			  // Bit 7: EACL interrupt
	"PP_PMIRR",			 // Bit 8: Pmirror interrupt
	"PP_PCAR",			  // Bit 9: Pscheduler interrupt
	"PP_TSE",			   // Bit 10: TSE interrupt
	"PP_PSE",			   // Bit 11: PSE interrupt
	"PP_MSE",			   // Bit 12: MSE interrupt
	"PP_FSE",			   // Bit 13: FSE interrupt
        "PP_IASE",                        // Bit 14: IASE interrupt
	"PP_EASE",			  // Bit 15: EASE interrupt
	"PP_CBUS_S",			// Bit 16: CBUS slave interrupt
	"PP_PRSM",			  // Bit 17: PRSM interrupt
	"PP_PROBE",			 // Bit 18: Probe interrupt
	NULL
};

/* DPTX module level 2 interrupts */
const char *int_greg_l2_dptx_keys[] = {
	"DPTX_INIT_CLIENT",	 // Bit 0: Client initialization interrupt
	"DPTX_INIT_PQM",		// Bit 1: PQM initialization interrupt
	"DPTX_INIT_PSCH",	   // Bit 2: PSCH initialization interrupt
	"DPTX_INIT_PMODIFIER",  // Bit 3: PMODIFIER initialization interrupt
	"DPTX_INIT_PDMUX",	  // Bit 4: PDMUX initialization interrupt
	"DPTX_INIT_SHAPING",	// Bit 5: Shaping initialization interrupt
	"DPTX_INIT_PSTATE",	 // Bit 6: PSTATE initialization interrupt
	NULL
};

/* VIO module level 2 interrupts */
const char *int_greg_l2_vio_keys[] = {
	"VIO_CBUS_CLIENT",	  // Bit 0: CBUS client interrupt
	"VIO_VTX",			  // Bit 1: Vtx interrupt
	"VIO_VRX",			  // Bit 2: Vrx interrupt
	"VIO_VBLK",			 // Bit 3: Vblock interrupt
	"VIO_ARBITER",		  // Bit 4: Arbiter interrupt
	NULL
};

/* DSCH module level 2 interrupts */
const char *int_greg_l2_dsch_keys[] = {
	"DSCH_CBUS_CLST",	   // Bit 0: CBUS cluster interrupt
	"DSCH_CBUS_C2ND0",	  // Bit 1: CBUS second0 interrupt
	"DSCH_CBUS_C3RD0",	  // Bit 2: CBUS third0 interrupt
	"DSCH_CBUS_C4TH3",	  // Bit 3: CBUS fourth3 interrupt
	"DSCH_DBQ_OCC",		 // Bit 4: Doorbell queue occupancy interrupt
	"DSCH_QSCH",			// Bit 5: Queue scheduler interrupt
	"DSCH_SHAP",			// Bit 6: Shaper interrupt
	NULL
};

/* CBUS BBLOCK module level 2 interrupts */
const char *int_greg_l2_bblock_keys[] = {
	"BBLOCK_WAIT_ACK_CLIENT0",  // Bit 0: Wait ack client 0 interrupt
	"BBLOCK_WAIT_ACK_CLIENT1",  // Bit 1: Wait ack client 1 interrupt
	"BBLOCK_WAIT_ACK_CLIENT2",  // Bit 2: Wait ack client 2 interrupt
	"BBLOCK_WAIT_ACK_CLIENT3",  // Bit 3: Wait ack client 3 interrupt
	"BBLOCK_WAIT_ACK_CLIENT4",  // Bit 4: Wait ack client 4 interrupt
	"BBLOCK_WAIT_ACK_CLIENT5",  // Bit 5: Wait ack client 5 interrupt
	"BBLOCK_WAIT_ACK_CLIENT6",  // Bit 6: Wait ack client 6 interrupt
	"BBLOCK_WAIT_ACK_CLIENT7",  // Bit 7: Wait ack client 7 interrupt
	"BBLOCK_WAIT_ACK_CNT0",	 // Bit 8: Wait ack count 0 interrupt
	"BBLOCK_WAIT_ACK_CNT1",	 // Bit 9: Wait ack count 1 interrupt
	"BBLOCK_WAIT_ACK_CNT2",	 // Bit 10: Wait ack count 2 interrupt
	"BBLOCK_WAIT_ACK_CNT3",	 // Bit 11: Wait ack count 3 interrupt
	"BBLOCK_RSV_ACK_CNT0",	  // Bit 12: Reserve ack count 0 interrupt
	"BBLOCK_RSV_ACK_CNT1",	  // Bit 13: Reserve ack count 1 interrupt
	"BBLOCK_RSV_ACK_CNT2",	  // Bit 14: Reserve ack count 2 interrupt
	"BBLOCK_RSV_ACK_CNT3",	  // Bit 15: Reserve ack count 3 interrupt
	"BBLOCK_RSV0",			  // Bit 16: Reserve 0 interrupt
	"BBLOCK_RSV1",			  // Bit 17: Reserve 1 interrupt
	"BBLOCK_RSV2",			  // Bit 18: Reserve 2 interrupt
	"BBLOCK_RSV3",			  // Bit 19: Reserve 3 interrupt
	"BBLOCK_RSV4",			  // Bit 20: Reserve 4 interrupt
	"BBLOCK_RSV5",			  // Bit 21: Reserve 5 interrupt
	"BBLOCK_RSV6",			  // Bit 22: Reserve 6 interrupt
	"BBLOCK_RSV7",			  // Bit 23: Reserve 7 interrupt
	"BBLOCK_RSV8",			  // Bit 24: Reserve 8 interrupt
	"BBLOCK_RSV9",			  // Bit 25: Reserve 9 interrupt
	"BBLOCK_RSV10",			 // Bit 26: Reserve 10 interrupt
	"BBLOCK_RSV11",			 // Bit 27: Reserve 11 interrupt
	"BBLOCK_RSV12",			 // Bit 28: Reserve 12 interrupt
	"BBLOCK_RSV13",			 // Bit 29: Reserve 13 interrupt
	"BBLOCK_CBUS_WAIT_ACK",	 // Bit 30: CBUS wait ack interrupt
	"BBLOCK_CBUS_RSV_ACK",	  // Bit 31: CBUS reserve ack interrupt
	NULL
};

/* CBUS SBLOCK module level 2 interrupts */
const char *int_greg_l2_sblock_keys[] = {
	"SBLOCK_WAIT_ACK_CLIENT0",  // Bit 0: Wait ack client 0 interrupt
	"SBLOCK_WAIT_ACK_CLIENT1",  // Bit 1: Wait ack client 1 interrupt
	"SBLOCK_WAIT_ACK_CLIENT2",  // Bit 2: Wait ack client 2 interrupt
	"SBLOCK_WAIT_ACK_CLIENT3",  // Bit 3: Wait ack client 3 interrupt
	"SBLOCK_WAIT_ACK_CLIENT4",  // Bit 4: Wait ack client 4 interrupt
	"SBLOCK_WAIT_ACK_CLIENT5",  // Bit 5: Wait ack client 5 interrupt
	"SBLOCK_WAIT_ACK_CLIENT6",  // Bit 6: Wait ack client 6 interrupt
	"SBLOCK_WAIT_ACK_CLIENT7",  // Bit 7: Wait ack client 7 interrupt
	"SBLOCK_WAIT_ACK_CNT0",	 // Bit 8: Wait ack count 0 interrupt
	"SBLOCK_WAIT_ACK_CNT1",	 // Bit 9: Wait ack count 1 interrupt
	"SBLOCK_WAIT_ACK_CNT2",	 // Bit 10: Wait ack count 2 interrupt
	"SBLOCK_WAIT_ACK_CNT3",	 // Bit 11: Wait ack count 3 interrupt
	"SBLOCK_RSV_ACK_CNT0",	  // Bit 12: Reserve ack count 0 interrupt
	"SBLOCK_RSV_ACK_CNT1",	  // Bit 13: Reserve ack count 1 interrupt
	"SBLOCK_RSV_ACK_CNT2",	  // Bit 14: Reserve ack count 2 interrupt
	"SBLOCK_RSV_ACK_CNT3",	  // Bit 15: Reserve ack count 3 interrupt
	"SBLOCK_RSV0",			  // Bit 16: Reserve 0 interrupt
	"SBLOCK_RSV1",			  // Bit 17: Reserve 1 interrupt
	"SBLOCK_RSV2",			  // Bit 18: Reserve 2 interrupt
	"SBLOCK_RSV3",			  // Bit 19: Reserve 3 interrupt
	"SBLOCK_RSV4",			  // Bit 20: Reserve 4 interrupt
	"SBLOCK_RSV5",			  // Bit 21: Reserve 5 interrupt
	"SBLOCK_RSV6",			  // Bit 22: Reserve 6 interrupt
	"SBLOCK_RSV7",			  // Bit 23: Reserve 7 interrupt
	"SBLOCK_RSV8",			  // Bit 24: Reserve 8 interrupt
	"SBLOCK_RSV9",			  // Bit 25: Reserve 9 interrupt
	"SBLOCK_RSV10",			 // Bit 26: Reserve 10 interrupt
	"SBLOCK_RSV11",			 // Bit 27: Reserve 11 interrupt
	"SBLOCK_RSV12",			 // Bit 28: Reserve 12 interrupt
	"SBLOCK_RSV13",			 // Bit 29: Reserve 13 interrupt
	"SBLOCK_CBUS_WAIT_ACK",	 // Bit 30: CBUS wait ack interrupt
	"SBLOCK_CBUS_RSV_ACK",	  // Bit 31: CBUS reserve ack interrupt
	NULL
};

/* DPRX module level 2 interrupts */
const char *int_greg_l2_dprx_keys[] = {
	"DPRX_CBUS_CLIENT",	 // Bit 0: CBUS client interrupt
	"DPRX_PRMUX",		   // Bit 1: Packet receive multiplexer interrupt
	"DPRX_PSTORE",		  // Bit 2: Packet store interrupt
	"DPRX_PBUFFER",		 // Bit 3: Packet buffer interrupt
	"DPRX_FBM",			 // Bit 4: Free buffer manager interrupt
	"DPRX_DPRE",			// Bit 5: DPRX engine interrupt
	NULL
};

/* ETH module level 2 interrupts */
const char *int_greg_l2_eth_keys[] = {
	"ETH_CBUS_INTR",		// Bit 0: CBUS interrupt
	"ETH_ETH0_MODULE_INTR", // Bit 1: ETH0 module interrupt
	"ETH_ETH1_MODULE_INTR", // Bit 2: ETH1 module interrupt
	NULL
};

/* RDMA module level 2 interrupts */
const char *int_greg_l2_rdma_keys[] = {
	"RDMA_CBUS_FST",		// Bit 0: CBUS FST
	"RDMA_CBUS_SND0",		// Bit 1: CBUS SND0
	"RDMA_CBUS_SND1",		// Bit 2: CBUS SND1
	"RDMA_CBUS_SND2",		// Bit 3: CBUS SND2
	"RDMA_CBUS_SND3",		// Bit 4: CBUS SND3
	"RDMA_CMQE",			// Bit 5: CMQE (Command Queue Engine)
	"RDMA_TPE",			// Bit 6: TPE (Transmit Processing Engine)
	"RDMA_TME",			// Bit 7: TME (Transmit Memory Engine)
	"RDMA_TDE",			// Bit 8: TDE (Transmit Data Engine)
	"RDMA_RPE",			// Bit 9: RPE (Receive Processing Engine)
	"RDMA_RME",			// Bit 10: RME (Receive Memory Engine)
	"RDMA_RDE",			// Bit 11: RDE (Receive Data Engine)
	"RDMA_RCE",			// Bit 12: RCE (Receive Completion Engine)
	"RDMA_CCE",			// Bit 13: CCE (Congestion Control Engine)
	"RDMA_TQE",			// Bit 14: TQE (Transmit Queue Engine)
	"RDMA_DMI",			// Bit 15: DMI (DMA Interface)
	"RDMA_CQC_OCC",			// Bit 16: CQC Occupancy
	"RDMA_MRT_OCC",			// Bit 17: MRT Occupancy
	"RDMA_APC_OCC",			// Bit 18: APC Occupancy
	"RDMA_SRFQC_OCM",		// Bit 19: SRFQC OCM
	"RDMA_PD_OCC",			// Bit 20: PD Occupancy
	"RDMA_SQRQ_OCC",		// Bit 21: SQ/RQ Occupancy
	"RDMA_SGB_OCC",			// Bit 22: SGB Occupancy
	"RDMA_EIRQ_OCC",		// Bit 23: EIRQ Occupancy
	"RDMA_ORQ_OCC",			// Bit 24: ORQ Occupancy
	"RDMA_UAQ_OCC",			// Bit 25: UAQ Occupancy
	"RDMA_PB1_OCC",			// Bit 26: PB1 Occupancy
	"RDMA_STAE",			// Bit 27: STAE (Statistics Engine)
	"RDMA_NTFE",			// Bit 28: NTFE (Notification Engine)
	"RDMA_ICAP_INFO",		// Bit 29: ICAP Info
	"RDMA_RSV",			// Bit 30: Reserved
	NULL
};

/* ----------------------------------------------------------------
 * Level 3 Interrupt Structure and Definitions
 * ----------------------------------------------------------------
 */

/* Level 3 interrupt mapping structure */
typedef struct {
	const char *l2_module;	 /* Level 2 module name */
	uint32_t l3_reg_addr;	  /* Level 3 register address */
	const char **l3_keys;	  /* Level 3 interrupt key names */
} l3_intr_map_t;



/* INTF BREG level 3 interrupts */
const char *int_greg_l3_intf_breg_keys[] = {
	"BREG_FIFO_WOVERFLOW",
	"BREG_FIFO_ROVERFLOW",
	"BREG_FIFO_WERR",
	"BREG_FIFO_RERR",
	"BREG_FIFO_RAM_ERR",
	"BREG_CBUS_BBLOCK_INTERRUPT_PULSE",
	"BREG_CBUS_SBLOCK_INTERRUPT_PULSE",
	NULL
};

/* INTF PCOMPLETER level 3 interrupts */
const char *int_greg_l3_intf_pcompleter_keys[] = {
	"PCOMPLETER_FIFO_WOVERFLOW",
	"PCOMPLETER_FIFO_ROVERFLOW",
	"PCOMPLETER_FIFO_WERR",
	"PCOMPLETER_FIFO_RERR",
	"PCOMPLETER_FIFO_RAM_ERR",
	"PCOMPLETER_TABLE_RAM_ERR",
	"PCOMPLETER_CBUS_FIFO_DROP_INT",
	"PCOMPLETER_TLPQ_FIFO_DROP_INT",
	"PCOMPLETER_NTFY_FIFO_DROP_INT",
	"PCOMPLETER_HOST0_ADPT_FIFO_DROP_INT",
	"PCOMPLETER_HOST1_ADPT_FIFO_DROP_INT",
	"PCOMPLETER_HOST2_ADPT_FIFO_DROP_INT",
	"PCOMPLETER_HOST3_ADPT_FIFO_DROP_INT",
	"PCOMPLETER_HOST4_ADPT_FIFO_DROP_INT",
	"PCOMPLETER_HOST0_RMUX_ERR_DROP_INT",
	"PCOMPLETER_HOST1_RMUX_ERR_DROP_INT",
	"PCOMPLETER_HOST2_RMUX_ERR_DROP_INT",
	"PCOMPLETER_HOST3_RMUX_ERR_DROP_INT",
	"PCOMPLETER_HOST4_RMUX_ERR_DROP_INT",
	NULL
};

/* INTF PREQUESTER level 3 interrupts */
const char *int_greg_l3_intf_prequester_keys[] = {
	"PREQUESTER_FIFO_WOVERFLOW",
	"PREQUESTER_FIFO_ROVERFLOW",
	"PREQUESTER_FIFO_WERR",
	"PREQUESTER_FIFO_RERR",
	"PREQUESTER_FIFO_RAM_ERR",
	"PREQUESTER_TABLE_RAM_ERR",
	"PREQUESTER_HOST0_RC_TAG_RERR",
	"PREQUESTER_HOST1_RC_TAG_RERR",
	"PREQUESTER_HOST2_RC_TAG_RERR",
	"PREQUESTER_HOST3_RC_TAG_RERR",
	"PREQUESTER_HOST4_RC_TAG_RERR",
	NULL
};

/* INTF MAILBOX level 3 interrupts */
const char *int_greg_l3_intf_mailbox_keys[] = {
	"MAILBOX_FIFO_WOVERFLOW",
	"MAILBOX_FIFO_ROVERFLOW",
	"MAILBOX_FIFO_WERR",
	"MAILBOX_FIFO_RERR",
	"MAILBOX_FIFO_RAM_ERR",
	"MAILBOX_TABLE_RAM_ERR",
	"MAILBOX_TXQ_DESC_INTERRUPT",
	"MAILBOX_TXQ_RERR_INTERRUPT",
	"MAILBOX_RXQ_DESC_INTERRUPT",
	"MAILBOX_RXQ_RERR_INTERRUPT",
	NULL
};

/* INTF CMDQ level 3 interrupts */
const char *int_greg_l3_intf_cmdq_keys[] = {
	"CMDQ_FIFO_WOVERFLOW",
	"CMDQ_FIFO_ROVERFLOW",
	"CMDQ_FIFO_WERR",
	"CMDQ_FIFO_RERR",
	"CMDQ_FIFO_RAM_ERR",
	"CMDQ_RSV",
	"CMDQ_DESC_INTERRUPT",
	"CMDQ_RERR_INTERRUPT",
	NULL
};

/* INTF MSGQ level 3 interrupts */
const char *int_greg_l3_intf_msgq_keys[] = {
	"MSGQ_FIFO_WOVERFLOW",
	"MSGQ_FIFO_ROVERFLOW",
	"MSGQ_FIFO_WERR",
	"MSGQ_FIFO_RERR",
	"MSGQ_FIFO_RAM_ERR",
	NULL
};

/* INTF TLPQ level 3 interrupts */
const char *int_greg_l3_intf_tlpq_keys[] = {
	"TLPQ_FIFO_WOVERFLOW",
	"TLPQ_FIFO_ROVERFLOW",
	"TLPQ_FIFO_WERR",
	"TLPQ_FIFO_RERR",
	"TLPQ_FIFO_RAM_ERR",
	"TLPQ_RSV",
	"TLPQ_TXQ_DESC_INTERRUPT",
	"TLPQ_TXQ_RERR_INTERRUPT",
	"TLPQ_RXQ_DESC_INTERRUPT",
	"TLPQ_RXQ_RERR_INTERRUPT",
	NULL
};

/* INTF DMAQ level 3 interrupts */
const char *int_greg_l3_intf_dmaq_keys[] = {
	"DMAQ_FIFO_WOVERFLOW",
	"DMAQ_FIFO_ROVERFLOW",
	"DMAQ_FIFO_WERR",
	"DMAQ_FIFO_RERR",
	"DMAQ_FIFO_RAM_ERR",
	"DMAQ_RSV",
	"DMAQ_DESC_INTERRUPT",
	"DMAQ_DESC_RERR_INTERRUPT",
	"DMAQ_DATA_RERR_INTERRUPT",
	NULL
};

/* INTF PMERGE level 3 interrupts */
const char *int_greg_l3_intf_pmerge_keys[] = {
	"PMERGE_FIFO_WOVERFLOW",
	"PMERGE_FIFO_ROVERFLOW",
	"PMERGE_FIFO_WERR",
	"PMERGE_FIFO_RERR",
	"PMERGE_FIFO_RAM_ERR",
	NULL
};

/* PP IACL level 3 interrupts */
const char *int_greg_l3_pp_iacl_keys[] = {
	"IACL_FIFO_WOVERFLOW",
	"IACL_FIFO_ROVERFLOW",
	"IACL_FIFO_ERRSIDE",
	"IACL_FIFO_WERR",
	"IACL_FIFO_RERR",
	"IACL_PROFILE_CFG_ERR",
	NULL
};

/* PP PFLOW level 3 interrupts */
const char *int_greg_l3_pp_pflow_keys[] = {
	"PFLOW_MAIN_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_CTRL_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_LUT_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_LUT_MAIN_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_LUT_CTRL_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_CAS_LUT_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_FSE_RSLT_FIFO_RAM_ERR_LOCK",
	"PFLOW_PFLOW_IACL_INFO_FIFO_RAM_ERR_LOCK",
	"PFLOW_CAS_FSE_RSLT_FIFO_RAM_ERR_LOCK",
	"PFLOW_RESERVED_9",
	"PFLOW_RESERVED_10",
	"PFLOW_RESERVED_11",
	"PFLOW_RESERVED_12",
	"PFLOW_RESERVED_13",
	"PFLOW_RESERVED_14",
	"PFLOW_RESERVED_15",
	"PFLOW_RESERVED_16",
	"PFLOW_RESERVED_17",
	"PFLOW_RESERVED_18",
	"PFLOW_RESERVED_19",
	"PFLOW_RESERVED_20",
	"PFLOW_RESERVED_21",
	"PFLOW_RESERVED_22",
	"PFLOW_RESERVED_23",
	"PFLOW_RESERVED_24",
	"PFLOW_FNL_ETH_FLOW_KEY_MASK_TBL_RAM_ERR_LOCK",
	"PFLOW_FNL_FLOW_KEY_MASK_TBL_RAM_ERR_LOCK",
	"PFLOW_FIFO_RERR",
	"PFLOW_FIFO_WERR",
	"PFLOW_FIFO_ROVERFLOW",
	"PFLOW_FIFO_WOVERFLOW",
	"PFLOW_RESERVED_31",
	NULL
};

/* PP IPRO level 3 interrupts */
const char *int_greg_l3_pp_ipro_keys[] = {
	"IPRO_FIFO_WOVERFLOW",
	"IPRO_FIFO_ROVERFLOW",
	"IPRO_FIFO_WERR",
	"IPRO_FIFO_RERR",
	"IPRO_PRE_RSLT_MAIN_FIFO_RAM_ERR",
	"IPRO_TSE_LUT_INFO_FIFO_RAM_ERR",
	"IPRO_TSE_SE_INFO_FIFO_RAM_ERR",
	"IPRO_F_IPORT_RSLT_FIFO_RAM_ERR",
	"IPRO_TNL_SE_LUT_INFO_FIFO_RAM_ERR",
	"IPRO_TNL_SE_INFO_FIFO_RAM_ERR",
	"IPRO_TNL_SE_RSLT_FIFO_RAM_ERR",
	"IPRO_TNL_SE_ACTION_FIFO_RAM_ERR",
	"IPRO_TNL_RSLT_LUT_INFO_FIFO_RAM_ERR",
	"IPRO_PORT_SE_LUT_INFO_FIFO_RAM_ERR",
	"IPRO_PORT_SE_INFO_FIFO_RAM_ERR",
	"IPRO_PORT_SE_RSLT_FIFO_RAM_ERR",
	"IPRO_PORT_SE_ACTION_FIFO_RAM_ERR",
	"IPRO_PORT_RSLT_LUT_INFO_FIFO_RAM_ERR",
	"IPRO_MAC_SE_RSLT_FIFO_RAM_ERR",
	"IPRO_MAC_SE_ACTION_FIFO_RAM_ERR",
	"IPRO_MAC_RSLT_LUT_INFO_FIFO_RAM_ERR",
	"IPRO_IPRO_PFLOW_INFO_FIFO_RAM_ERR",
	"IPRO_IPORT_EPRO_INFO_RAM_ERR",
	"IPRO_VP_IPORT_RAM_RAM_ERR",
	"IPRO_ETH_IPORT_RAM_RAM_ERR",
	"IPRO_VP_2ND_IPORT_RAM_RAM_ERR",
	"IPRO_PCM_ACTION_RAM_RAM_ERR",
	"IPRO_FSE_PROFILE_ID_RAM_RAM_ERR",
	"IPRO_PSE_PROFILE_ID_RAM_RAM_ERR",
	"IPRO_SW_CFG_ERR",
	"IPRO_RESERVED",
	NULL
};

/* PP PARSER level 3 interrupts */
const char *int_greg_l3_pp_parser_keys[] = {

	"PARSER_RESERVED_25",
	"PARSER_RESERVED_24",
	"PARSER_RESERVED_23",
	"PARSER_RESERVED_22",
	"PARSER_RESERVED_21",
	"PARSER_RESERVED_20",
	"PARSER_RESERVED_19",
	"PARSER_RESERVED_18",
	"PARSER_RESERVED_17",
	"PARSER_RESERVED_16",
	"PARSER_RESERVED_15",
	"PARSER_RESERVED_14",
	"PARSER_RESERVED_13",
	"PARSER_RESERVED_12",
	"PARSER_RESERVED_11",
	"PARSER_RESERVED_10",
	"PARSER_RESERVED_9",
	"PARSER_RESERVED_8",
	"PARSER_RESERVED_7",
	"PARSER_RESERVED_6",
	"PARSER_RESERVED_5",
	"PARSER_RESERVED_4",
	"PARSER_RESERVED_3",
	"PARSER_RESERVED_2",
	"PARSER_RESERVED_1",
	"PARSER_RESERVED_0",
	"PARSER_RAM_ERR",
	"PARSER_FIFO_RERR",
	"PARSER_FIFO_WERR",
	"PARSER_FIFO_ROVERFLOW",
	"PARSER_FIFO_WOVERFLOW",
	"PARSER_EGRESS_FIFO_BLOCKED",
	NULL
};

/* PP PMC level 3 interrupts */
const char *int_greg_l3_pp_pmc_keys[] = {
	"PMC_FIFO_WOVERFLOW",
	"PMC_FIFO_ROVERFLOW",
	"PMC_FIFO_WERR",
	"PMC_FIFO_RERR",
	"PMC_PRE_RSLT_NOCOPY_INFO_FIFO_RAM_ERR",
	"PMC_PRE_RSLT_SEQENCE_FIFO_RAM_ERR",
	"PMC_PPRE_COPY_BC_INFO_FIFO_RAM_ERR",
	"PMC_PPRE_COPY_MC_INFO_FIFO_RAM_ERR",
	"PMC_COPY_RSLT_BC_INFO_FIFO_RAM_ERR",
	"PMC_COPY_RSLT_MC_INFO_FIFO_RAM_ERR",
	"PMC_PMC_EPRO_FIFO_RAM_ERR",
	"PMC_PMC_MC_TBL_RAM_ERR",
	"PMC_PQM_MCPKT_256BYTES_ADD_MINUS_OVERFLOW",
	NULL
};

/* PP EPRO level 3 interrupts */
const char *int_greg_l3_pp_epro_keys[] = {
	"EPRO_FIFO_WOVERFLOW",
	"EPRO_FIFO_ROVERFLOW",
	"EPRO_FIFO_WERR",
	"EPRO_FIFO_RERR",
	"EPRO_FLOW_RSLT_I_FIFO_RAM_ERR",
	"EPRO_FLOW_RSLT_CTRL_FIFO_RAM_ERR",
	"EPRO_FLOW_PORT_I_FIFO_RAM_ERR",
	"EPRO_PORT_RSLT_I_FIFO_RAM_ERR",
	"EPRO_EACL_I_FIFO_RAM_ERR",
	"EPRO_FSE_EPRO_CMDQ_I_FIFO_RAM_ERR",
	"EPRO_IACL_EPRO_CMDQ_I_FIFO_RAM_ERR",
	"EPRO_FNL_FACT_TBL_RAM_ERR",
	"EPRO_FNL_ETH_PORT_TBL_RAM_ERR",
	"EPRO_FNL_VEPORT_TBL_RAM_ERR",
	"EPRO_SOFTWARE_CFG_ERR",
	"EPRO_ETH_LAG_TBL_RAM_ERR",
	NULL
};

/* PP EACL level 3 interrupts */
const char *int_greg_l3_pp_eacl_keys[] = {
	"EACL_FIFO_WOVERFLOW",
	"EACL_FIFO_ROVERFLOW",
	"EACL_ERRSIDE",
	"EACL_FIFO_WERR",
	"EACL_FIFO_RERR",
	"EACL_RAM_ERR",
	"EACL_PROFILE_CFG_ERR",
	"EACL_REASSEMBLE_PACKETS_ERR",
	NULL
};

/* PP PMIRR level 3 interrupts */
const char *int_greg_l3_pp_pmirr_keys[] = {
	"PMIRR_FIFO_WOVERFLOW",
	"PMIRR_FIFO_ROVERFLOW",
	"PMIRR_FIFO_WERR",
	"PMIRR_FIFO_RERR",
	"PMIRR_MIRR_TBL_RAM_ERR",
	"PMIRR_RSS_TBL_RAM_ERR",
	"PMIRR_RSS_PROFILE_RAM_ERR",
	"PMIRR_PTYPE_CAR_TBL_RAM_ERR",
	"PMIRR_PRE_RSLT_I_FIFO_RAM_ERR",
	"PMIRR_PRE_RSLT_CTRL_FIFO_RAM_ERR",
	"PMIRR_PRE_PORT_I_FIFO_RAM_ERR",
	"PMIRR_PORT_RSLT_I_FIFO_RAM_ERR",
	"PMIRR_CAR_I_FIFO_RAM_ERR",
	"PMIRR_SOFTWARE_CFG_ERR",
	"PMIRR_SOFTWARE_CFG_CHKSUM_EN_ERR",
	"PMIRR_SNAT_INFO_TBL_RAM_ERR",
	"PMIRR_DNAT_INFO_TBL_RAM_ERR",
	"PMIRR_LAG_LOGICAL_SWITCH_A/B_MEMBER",
	"PMIRR_LAG_A/B_MEMBER_PORT_INVAILD",
	"PMIRR_LAG_RDMA_USE_LOGICAL_SWITCH_A/B_PORT",
	NULL
};

/* PP PCAR level 3 interrupts */
const char *int_greg_l3_pp_pcar_keys[] = {
	"PCAR_RSV0",
	"PCAR_RSV1",
	"PCAR_RSV2",
	"PCAR_RSV3",
	"PCAR_RAM_ERR",
	NULL
};

/* PP TSE level 3 interrupts */
const char *int_greg_l3_pp_tse_keys[] = {
	"TSE_HASH_TBL_RAM_ERR",
	"TSE_ACT_TBL_RAM_ERR",
	"TSE_RAM_CNT_RAM_ERR",
	NULL
};

/* PP PSE level 3 interrupts */
const char *int_greg_l3_pp_pse_keys[] = {
	"PSE_HASH_TBL_RAM_ERR",
	"PSE_ACT_TBL_RAM_ERR",
	"PSE_RAM_CNT_RAM_ERR",
	NULL
};

/* PP MSE level 3 interrupts */
const char *int_greg_l3_pp_mse_keys[] = {
	"MSE_HASH_TBL_RAM_ERR",
	"MSE_ACT_TBL_RAM_ERR",
	"MSE_RAM_CNT_RAM_ERR",
	"MSE_ACT_AGE_TBL_RAM_ERR",
	NULL
};

/* PP FSE level 3 interrupts */
const char *int_greg_l3_pp_fse_keys[] = {
	"FSE_HASH_TBL_RAM_ERR",
	"FSE_ACT_TBL_RAM_ERR",
	"FSE_RAM_CNT_RAM_ERR",
	"FSE_ACT_AGE_TBL_RAM_ERR",
	"FSE_CMDQ_INFO_FIFO_RAM_ERR",
	"FSE_CMDQ_INFO_FIFO_RERR",
	"FSE_CMDQ_INFO_FIFO_WERR",
	"FSE_CMDQ_INFO_FIFO_ROVERFLOW",
	"FSE_CMDQ_INFO_FIFO_WOVERFLOW",
	"FSE_CMDQ_CONFIG_CMDQ_TYPE_OVER_3",
	NULL
};

/* PP IASE level 3 interrupts */
const char *int_greg_l3_pp_iase_keys[] = {
	"IASE_ACT_TBL_RAM_ERR",
	"IASE_AGE_RAM_ERR",
	"IASE_RSLT_CNT_RAM_ERR",
	"IASE_CMDQ_FIFO_ERR",
	NULL
};

/* PP EASE level 3 interrupts */
const char *int_greg_l3_pp_ease_keys[] = {
	"EASE_ACT_TBL_RAM_ERR",
	"EASE_AGE_RAM_ERR",
	"EASE_RSLT_CNT_RAM_ERR",
	"EASE_CMDQ_FIFO_ERR",
	NULL
};

/* PP PRSM level 3 interrupts */
const char *int_greg_l3_pp_prsm_keys[] = {
	"PRSM_FRAG_OFFSET_ERR",
	"PRSM_AGE_TIMEOUT_ERR",
	"PRSM_LEN_EXCEEDS_ERR",
	"PRSM_RSC_ALC_ERR",
	"PRSM_RSC_RECYCLE_ERR",
	"PRSM_AGE_RECYCLE_ERR",
	"PRSM_FORCE_RSM_MEM_ERR",
	"PRSM_MEM_ID_RSM_RECYCLE_ERR",
	"PRSM_MEM_ID_AGE_RECYCLE_ERR",
	"PRSM_MEM_ID_ALC_ERR",
	"PRSM_MEM_ID_USING_ERR",
	"PRSM_DPORT_CHECK_ERR",
	"PRSM_IP_NET_ERR",
	"PRSM_RESV0",
	"PRSM_RESV1",
	"PRSM_RESV2",
	"PRSM_RESV3",
	"PRSM_RESV4",
	"PRSM_RESV5",
	"PRSM_RESV6",
	"PRSM_RESV7",
	"PRSM_RESV8",
	"PRSM_RESV9",
	"PRSM_RESV10",
	"PRSM_RESV11",
	"PRSM_RESV12",
	"PRSM_RSC_MFIFO_OVERFLOW_VECTOR",
	NULL
};

/* DPTX INIT_PSCH level 3 interrupts */
const char *int_greg_l3_dptx_init_psch_keys[] = {
	"PSCH_FIFO_WOVERFLOW",
	"PSCH_FIFO_ROVERFLOW",
	"PSCH_FIFO_WERR",
	"PSCH_FIFO_RERR",
	"PSCH_FIFO_ERRSIDE_ERR",
	"PSCH_FIFO_RAM_ERR",
	"PSCH_RAM_ERR",
	NULL
};

/* DPTX INIT_PMODIFIER level 3 interrupts */
const char *int_greg_l3_dptx_init_pmodifier_keys[] = {
	"PMODIFIER_FIFO_WOVERFLOW",
	"PMODIFIER_FIFO_ROVERFLOW",
	"PMODIFIER_FIFO_WERR",
	"PMODIFIER_FIFO_RERR",
	"PMODIFIER_FIFO_ERRSIDE_ERR",
	"PMODIFIER_FIFO_RAM_ERR",
	"PMODIFIER_RAM_ERR",
	"PMODIFIER_PACKET_SHORT_ERR",
	NULL
};

/* DPTX INIT_PDMUX level 3 interrupts */
const char *int_greg_l3_dptx_init_pdmux_keys[] = {
	"PDMUX_FIFO_WOVERFLOW",
	"PDMUX_FIFO_ROVERFLOW",
	"PDMUX_FIFO_WERR",
	"PDMUX_FIFO_RERR",
	"PDMUX_FIFO_ERRSIDE_ERR",
	"PDMUX_FIFO_RAM_ERR",
	NULL
};

/* DPTX INIT_SHAPING level 3 interrupts */
const char *int_greg_l3_dptx_init_shaping_keys[] = {
	"SHAPING_FIFO_WOVERFLOW",
	"SHAPING_FIFO_ROVERFLOW",
	"SHAPING_FIFO_WERR",
	"SHAPING_FIFO_RERR",
	"SHAPING_FIFO_RAM_ERR",
	"SHAPING_RAM_ERR",
	NULL
};

/* DPTX INIT_PSTATE level 3 interrupts */
const char *int_greg_l3_dptx_init_pstate_keys[] = {
	"PSTATE_FIFO_WOVERFLOW",
	"PSTATE_FIFO_ROVERFLOW",
	"PSTATE_FIFO_WERR",
	"PSTATE_FIFO_RERR",
	"PSTATE_FIFO_ERRSIDE_ERR",
	"PSTATE_FIFO_RAM_ERR",
	NULL
};

/* DPTX INIT_PQM level 3 interrupts */
const char *int_greg_l3_dptx_init_pqm_keys[] = {
	"PQM_FIFO_WOVERFLOW",
	"PQM_FIFO_ROVERFLOW",
	"PQM_FIFO_WERR",
	"PQM_FIFO_RERR",
	"PQM_FIFO_ERRSIDE_ERR",
	"PQM_FIFO_RAM_ERR",
	"PQM_RAM_ERR",
	"PQM_ADM_MODULE_ERR",
	"PQM_MFIFO_OVERFLOW_VECTOR",
	"PQM_MFIFO_ROVERFLOW_VECTOR",
	"PQM_MFIFO_WOVERFLOW_VECTOR",
	"PQM_FIFO_BUF_ERR_REG",
	"PQM_INQUE_CFG_DFG_REG0",
	"PQM_INQUE_CFG_DFG_REG1",

	NULL
};

/* DPTX INIT_CUBS level 3 interrupts */
const char *int_greg_l3_dptx_init_client_keys[] = {
	"CBUS_WAIT_ACK_CLIENT0",
	"CBUS_WAIT_ACK_CLIENT1",
	"CBUS_WAIT_ACK_CLIENT2",
	"CBUS_RSV0",
	"CBUS_RSV1",
	"CBUS_RSV2",
	"CBUS_RSV3",
	"CBUS_RSV4",
	"CBUS_WAIT_ACK_CNT0",
	"CBUS_WAIT_ACK_CNT1",
	"CBUS_WAIT_ACK_CNT2",
	"CBUS_WAIT_ACK_CNT3",
	"CBUS_RSV_ACK_CNT0",
	"CBUS_RSV_ACK_CNT1",
	"CBUS_RSV_ACK_CNT2",
	"CBUS_RSV_ACK_CNT3",
	"CBUS_RSV5",
	"CBUS_RSV6",
	"CBUS_RSV7",
	"CBUS_RSV8",
	"CBUS_RSV9",
	"CBUS_RSV10",
	"CBUS_RSV11",
	"CBUS_RSV12",
	"CBUS_RSV13",
	"CBUS_RSV14",
	"CBUS_RSV15",
	"CBUS_RSV16",
	"CBUS_RSV17",
	"CBUS_RSV18",
	"CBUS_WAIT_ACK_INTERRUPT",
	"CBUS_RSV_ACK_INTERRUPT",
	NULL
};

/* VIO VTX level 3 interrupts */
const char *int_greg_l3_vio_vtx_keys[] = {
	"VTX_DESC_ERROR",
	"VTX_PKT_DIFF_ERROR",
	"VTX_FIFO_WOVERFLOW",
	"VTX_FIFO_ROVERFLOW",
	"VTX_FIFO_ERRSIDE_ERR",
	"VTX_FIFO_WERR",
	"VTX_FIFO_RERR",
	"VTX_FIFO_RAM_ERR",
	"VTX_Q_REP_SCH_ERR",
	"VTX_Q_REV_DB_ERR",
	"VTX_LSO_RC_ERR",
	"VTX_PACKET_ERR",
	"VTX_RING_AFULL",
	"VTX_Q_DEPTH_ERR",
	"VTX_REP_SCH_ERR",
	"VTX_DESC_LEN_ERR",
	"VTX_DESC_CHAIN_ERR",
	"VTX_PKT_LEN_ERR",
	"VTX_PKT_FWD_ERR",
	"VTX_PACKED_PKT_ERR",
	"VTX_PKTAN_PKTLEN_ERR",
	"VTX_MSS_HEADLEN_ERR",
	"VTX_SELFMODE_LSO_EXTENDTYPE_ERR",
	"VTX_MORE8DESC_NOEOP_SEGDIS_ERR",
	"VTX_LARGEMTU_SEGDIS_ERR",
	"VTX_PKT_ALLDESCLESSMSS_ERR",
	"VTX_VIRTIO_GSO_SIZE_ERR",
	"VTX_VIRTIO_HEADLEN_ERR",
	"VTX_VIRTIO_LSO_FLAG_ERR",
	"VTX_IP_SEG_ERR",
	"VTX_WRAP_ERR",
	"VTX_DATA_TO_PRMUX_ERR",
	NULL
};

/* VIO VRX level 3 interrupts */
const char *int_greg_l3_vio_vrx_keys[] = {
	"VRX_FIFO_WOVERFLOW",
	"VRX_FIFO_ROVERFLOW",
	"VRX_FIFO_WERR_INTERRUPT",
	"VRX_FIFO_RERR_INTERRUPT",
	"VRX_FIFO_ERRSIDE_ERR_INTERRUPT",
	"VRX_FIFO_RAM_ERR_INTERRUPT",
	"VRX_RAM_ERR_INTERRUPT",
	"VRX_DESC_RAM_ADDR_ERR_INTERRUPT",
	"VRX_DESC_RAM_ADDR_CLASH_INTERRUPT",
	"VRX_ZIDY_DSC_UNVLD_ERR_INTERRUPT",
	"VRX_RD_DIF_ERR_INTERRUPT",
	"VRX_PKT_HEAD_SPLIT_INTERRUPT",
	"VRX_PKT_DSC_NUM_INTERRUPT",
	"VRX_MFIFO_ID_ERR_INTERRUPT",
	"VRX_RSM_QUE_ERR_INTERRUPT",
	"VRX_PNTR_WRAPPER_ERR_INTERRUPT",
	"VRX_RSV",
	"VRX_MFIFO_WOVERFLOW_VECTOR",
	"VRX_MFIFO_ROVERFLOW_VECTOR",
	"VRX_MFIFO_OVERFLOW_VECTOR",
	"VRX_FIFO_BUF_ERR_REG",
	NULL
};

/* VIO VBLK level 3 interrupts */
const char *int_greg_l3_vio_vblk_keys[] = {
	"VBLK_AQ_INTR",
	"VBLK_DQ_INTR",
	"VBLK_DESC_RD_ARBITER_ERR",
	"VBLK_DATA_RD_ARBITER_ERR",
	"VBLK_DESC_WR_ARBITER_ERR",
	"VBLK_DATA_WR_ARBITER_ERR",
	NULL
};

/* DSCH QSCH level 3 interrupts */
const char *int_greg_l3_dsch_qsch_keys[] = {
	"QSCH_FIFO_WOVERFLOW",
	"QSCH_FIFO_ROVERFLOW",
	"QSCH_FIFO_WERR",
	"QSCH_FIFO_RERR",
	"QSCH_FIFO_RAM_ERR",
	"QSCH_RAM_ERR",
	"QSCH_LIST_FATAL_ERR",
	"QSCH_KB_KEY_REQ_ERR",
	"QSCH_CFG_HF_MAP_ERR",
	"QSCH_DSCH_RW_DMA_RERR",
	"QSCH_DMA_OP_ERR",
	"QSCH_RDMA_DB_LOSS",
	NULL
};

/* DSCH DBQ_OCC level 3 interrupts */
const char *int_greg_l3_dsch_dbq_occ_keys[] = {
	"DBQ_OCC_FIFO_WOVERFLOW",
	"DBQ_OCC_FIFO_ROVERFLOW",
	"DBQ_OCC_FIFO_WERR",
	"DBQ_OCC_FIFO_RERR",
	"DBQ_OCC_FIFO_ERRSIDE_ERR",
	"DBQ_OCC_FIFO_RAM_ERR",
	"DBQ_OCC_RAM_ERR",
	"DBQ_OCC_CLIENT0_ERR",
	"DBQ_OCC_CTRL_FINISH_ERR_STATUS",
	"DBQ_OCC_MANAGER_ERR_DEBUG",
	"DBQ_OCC_MBUS_RD_ERR_STATUS",
	"DBQ_OCC_MBUS_WR_ERR_STATUS",
	"DBQ_OCC_DMA_ERR_STATUS",
	"DBQ_OCC_MBUS_STATUS_REG",
	"DBQ_OCC_MBUS_R_ERR",
	"DBQ_OCC_MBUS_W_ERR",
	"DBQ_OCC_MBUS_1_R_ERR",
	NULL
};

/* DSCH DSHAP level 3 interrupts */
const char *int_greg_l3_dsch_dshap_keys[] = {
	"DSHAP_FIFO_WOVERFLOW",
	"DSHAP_FIFO_ROVERFLOW",
	"DSHAP_FIFO_WERR",
	"DSHAP_FIFO_RERR",
	"DSHAP_FIFO_RAM_ERR",
	"DSHAP_RAM_ERR",
	NULL
};

/* DSCH SSHAP level 3 interrupts */
const char *int_greg_l3_dsch_sshap_keys[] = {
	"SSHAP_FIFO_WOVERFLOW",
	"SSHAP_FIFO_ROVERFLOW",
	"SSHAP_FIFO_WERR",
	"SSHAP_FIFO_RERR",
	"SSHAP_FIFO_RAM_ERR",
	"SSHAP_RAM_ERR",
	NULL
};

/* DSCH NSHAP level 3 interrupts */
const char *int_greg_l3_dsch_nshap_keys[] = {
	"NSHAP_FIFO_WOVERFLOW",
	"NSHAP_FIFO_ROVERFLOW",
	"NSHAP_FIFO_WERR",
	"NSHAP_FIFO_RERR",
	"NSHAP_FIFO_RAM_ERR",
	"NSHAP_RAM_ERR",
	NULL
};

/* DSCH GSHAP level 3 interrupts */
const char *int_greg_l3_dsch_gshap_keys[] = {
	"GSHAP_FIFO_WOVERFLOW",
	"GSHAP_FIFO_ROVERFLOW",
	"GSHAP_FIFO_WERR",
	"GSHAP_FIFO_RERR",
	"GSHAP_FIFO_RAM_ERR",
	"GSHAP_RAM_ERR",
	NULL
};

/* DPRX PRMUX level 3 interrupts */
const char *int_greg_l3_dprx_prmux_keys[] = {
	"PRMUX_ETH0_INFO_RAM_ERR",
	"PRMUX_ETH1_INFO_RAM_ERR",
	"PRMUX_ETH2_INFO_RAM_ERR",
	"PRMUX_ETH3_INFO_RAM_ERR",
	"PRMUX_ETH4_INFO_RAM_ERR",
	"PRMUX_ETH5_INFO_RAM_ERR",
	"PRMUX_ETH6_INFO_RAM_ERR",
	"PRMUX_ETH7_INFO_RAM_ERR",
	"PRMUX_ETH0_DATA_RAM_ERR",
	"PRMUX_ETH1_DATA_RAM_ERR",
	"PRMUX_ETH2_DATA_RAM_ERR",
	"PRMUX_ETH3_DATA_RAM_ERR",
	"PRMUX_ETH4_DATA_RAM_ERR",
	"PRMUX_ETH5_DATA_RAM_ERR",
	"PRMUX_ETH6_DATA_RAM_ERR",
	"PRMUX_ETH7_DATA_RAM_ERR",
	"PRMUX_CPU0_INFO_RAM_ERR",
	"PRMUX_CPU1_INFO_RAM_ERR",
	"PRMUX_CPU0_DATA_RAM_ERR",
	"PRMUX_CPU1_DATA_RAM_ERR",
	"PRMUX_O_INFO_RAM_ERR",
	"PRMUX_O_DATA_RAM_ERR",
	"PRMUX_RSV0",
	"PRMUX_RSV1",
	"PRMUX_PRMUX_FIFO_RERR",
	"PRMUX_PRMUX_FIFO_WERR",
	"PRMUX_PRMUX_FIFO_ROVERFLOW",
	"PRMUX_PRMUX_FIFO_WOVERFLOW",
	"PRMUX_PRMUX_EOP_ERR",
	"PRMUX_RSV2",
	"PRMUX_RSV3",
	"PRMUX_DETECT",
	NULL
};

/* DPRX PSTORE level 3 interrupts */
const char *int_greg_l3_dprx_pstore_keys[] = {
	"PSTORE_EOP_CHECK_ERR",
	NULL
};

/* DPRX PBUFFER level 3 interrupts */
const char *int_greg_l3_dprx_pbuffer_keys[] = {
	"PBUFFER_MBUS_R_ERR0",
	"PBUFFER_MBUS_R_ERR1",
	"PBUFFER_MBUS_W_ERR0",
	"PBUFFER_MBUS_W_ERR1",
	"PBUFFER_MBUS_W_ERR2",
	NULL
};

/* DPRX FBM level 3 interrupts */
const char *int_greg_l3_dprx_fbm_keys[] = {
	"FBM_CHAIN_RAM_ERROR",
	"FBM_RLS_MC_WEIGHT_ERROR",
	"FBM_RLS_UC_WEIGHT_ERROR",
	"FBM_PTR_FIFO_NFULL_ERROR",
	"FBM_BITMAP_RAM_RDATA_ERROR",
	"FBM_PTR_RAM_ERROR",
	"FBM_BITMAP_RAM_ERR",
	"FBM_WEIGHT_RAM_ERR",
	"FBM_RLS_RAM_ERR",
	"FBM_RLS_CHAIN_TAIL_INVAILD_ERR",
	"FBM_RLS_CHAIN_ERR",
	"FBM_RLS_HIGH_RAM_ERR",
	"FBM_RESV0",
	"FBM_RESV1",
	"FBM_RESV2",
	"FBM_RESV3",
	"FBM_PSTORE_ALLOC_GET_ERR",
	"FBM_RESV4",
	"FBM_RESV5",
	"FBM_RESV6",
	"FBM_PQM_RLS_PUT_ERR",
	"FBM_RESV7",
	"FBM_RESV8",
	"FBM_RESV9",
	"FBM_RESV10",
	"FBM_RESV11",
	"FBM_RESV12",
	"FBM_RESV13",
	"FBM_RESV14",
	"FBM_RESV15",
	"FBM_PTR_WARNING_POSEDGE",
	"FBM_FIFO_OVERFLOW",
};

/* DPRX DPRE level 3 interrupts */
const char *int_greg_l3_dprx_dpre_keys[] = {
	"DPRE_FIFO_WOVERFLOW",
	"DPRE_FIFO_ROVERFLOW",
	"DPRE_FIFO_WERR",
	"DPRE_FIFO_RERR",
	"DPRE_FIFO_ERRSIDE_ERR",
	"DPRE_FIFO_RAM_ERR",
	"DPRE_CHECK_ERR",
	NULL
};

/* ETH ETH0_MODULE level 3 interrupts */
const char *int_greg_l3_eth_eth_module_keys[] = {
	"ETH0_LINK_UP_INTR",
	"ETH0_LINK_DOWN_INTR",
	"ETH1_LINK_UP_INTR",
	"ETH1_LINK_DOWN_INTR",
	NULL
};


/* ----------------------------------------------------------------
 * Level 3 Interrupt Mapping Tables
 * ----------------------------------------------------------------
 */

/* INTF Level 3 */
static const l3_intr_map_t intf_l3_map[] = {
    {"INTF_BBLOCK",     INTF_BLOCK_BREG_cbus_bblock_status_reg,     NULL},
    {"INTF_SBLOCK",     INTF_BLOCK_BREG_cbus_sblock_status_reg,     NULL},
    {"INTF_BREG",       INTF_BLOCK_BREG_status_reg,       int_greg_l3_intf_breg_keys},
    {"INTF_PCOMPLETER", INTF_PCOMPLETER_int_status_reg, int_greg_l3_intf_pcompleter_keys},
    {"INTF_PREQUESTER", INTF_PREQUESTER_init_status_reg, int_greg_l3_intf_prequester_keys},
    {"INTF_MAILBOX",    INTF_MAILBOX_int_status_reg,    int_greg_l3_intf_mailbox_keys},
    {"INTF_CMDQ",       INTF_CMDQ_init_status_reg,       int_greg_l3_intf_cmdq_keys},
    {"INTF_MSGQ",       INTF_MSGQ_int_status_reg,       int_greg_l3_intf_msgq_keys},
    {"INTF_TLPQ",       INTF_TLPQ_int_status_reg,       int_greg_l3_intf_tlpq_keys},
    {"INTF_DMAQ",       INTF_DMAQ_int_status_reg,       int_greg_l3_intf_dmaq_keys},
    {"INTF_PMERGE",     INTF_PMERGE_int_status_reg,     int_greg_l3_intf_pmerge_keys},
    {NULL, 0, NULL}
};

/* PP Level 3 */
static const l3_intr_map_t pp_l3_map[] = {
    {"PP_CBUS",    0, NULL},
    {"PP_PARSER",  PP_PARSER_INT_STATUS, int_greg_l3_pp_parser_keys},
    {"PP_IPRO",    PP_IPRO_INT_STATUS,   int_greg_l3_pp_ipro_keys},
    {"PP_PFLOW",   PP_PFLOW_INT_STATUS,  int_greg_l3_pp_pflow_keys},
    {"PP_IACL",    PP_IACL_INT_STATUS,   int_greg_l3_pp_iacl_keys},
    {"PP_PMC",     PP_PMC_INT_STATUS,    int_greg_l3_pp_pmc_keys},
    {"PP_EPRO",    PP_EPRO_INT_STATUS,   int_greg_l3_pp_epro_keys},
    {"PP_EACL",    PP_EACL_INT_STATUS,   int_greg_l3_pp_eacl_keys},
    {"PP_PMIRR",   PP_PMIRR_INT_STATUS,  int_greg_l3_pp_pmirr_keys},
    {"PP_PCAR",    PP_PCAR_INT_STATUS,   int_greg_l3_pp_pcar_keys},
    {"PP_TSE",     PP_TSE_INT_STATUS,    int_greg_l3_pp_tse_keys},
    {"PP_PSE",     PP_PSE_INT_STATUS,    int_greg_l3_pp_pse_keys},
    {"PP_MSE",     PP_MSE_INT_STATUS,    int_greg_l3_pp_mse_keys},
    {"PP_FSE",     PP_FSE_INT_STATUS,    int_greg_l3_pp_fse_keys},
    {"PP_IASE",    PP_IASE_INT_STATUS,   int_greg_l3_pp_iase_keys},
    {"PP_EASE",    PP_EASE_INT_STATUS,   int_greg_l3_pp_ease_keys},
    {"PP_CBUS_S",  0, NULL},
    {"PP_PRSM",    PP_PRSM_INT_STATUS,   int_greg_l3_pp_prsm_keys},
    {"PP_PROBE",   0,  NULL},
    {NULL, 0, NULL}
};

/* DPTX Level 3  */
static const l3_intr_map_t dptx_l3_map[] = {
    {"DPTX_INIT_CLIENT",    DPTX_INIT_CLIENT_BASE,  int_greg_l3_dptx_init_client_keys},
    {"DPTX_INIT_PQM",       PQM_INT_STATUS_REG,     int_greg_l3_dptx_init_pqm_keys},
    {"DPTX_INIT_PSCH",      PSCH_INT_STATUS_REG,    int_greg_l3_dptx_init_psch_keys},
    {"DPTX_INIT_PMODIFIER", PMODIFIER_INT_STATUS_REG, int_greg_l3_dptx_init_pmodifier_keys},
    {"DPTX_INIT_PDMUX",     PDMUX_INT_STATUS_REG,   int_greg_l3_dptx_init_pdmux_keys},
    {"DPTX_INIT_SHAPING",   DPTX_PSCH_SHAPING_BASE, int_greg_l3_dptx_init_shaping_keys},
    {"DPTX_INIT_PSTATE",    DPTX_PSTAT_BASE,  int_greg_l3_dptx_init_pstate_keys},
    {NULL, 0, NULL}
};

/* VIO Level 3 */
static const l3_intr_map_t vio_l3_map[] = {
    {"VIO_CBUS_CLIENT", 0, NULL},
    {"VIO_VTX",         VTX_INTP_STATUS,         int_greg_l3_vio_vtx_keys},
    {"VIO_VRX",         VRX_INT_STATUS,         int_greg_l3_vio_vrx_keys},
    {"VIO_VBLK",        VIO_VBLK_BASE,        int_greg_l3_vio_vblk_keys},
    {"VIO_ARBITER",     0,     NULL},
    {NULL, 0, NULL}
};

/* DSCH Level 3 */
static const l3_intr_map_t dsch_l3_map[] = {
    {"DSCH_CBUS_CLST",  0, NULL},
    {"DSCH_CBUS_C2ND0", 0, NULL},
    {"DSCH_CBUS_C3RD0", 0, NULL},
    {"DSCH_CBUS_C4TH3", 0, NULL},
    {"DSCH_DBQ_OCC",    DSCH_OCC_DBQ_INT_STATUS,    int_greg_l3_dsch_dbq_occ_keys},
    {"DSCH_QSCH",       DSCH_QSCH_INT_STATUS,       int_greg_l3_dsch_qsch_keys},
    {"DSCH_SHAP",       DSCH_SHAPING_2_INT_STATUS,  int_greg_l3_dsch_dshap_keys},
    {NULL, 0, NULL}
};

/* BBLOCK Level 3*/
static const l3_intr_map_t bblock_l3_map[] = {
    {"BBLOCK_WAIT_ACK_CLIENT0", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT1", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT2", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT3", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT4", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT5", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT6", 0, NULL},
    {"BBLOCK_WAIT_ACK_CLIENT7", 0, NULL},
    {"BBLOCK_WAIT_ACK_CNT0",    0,    NULL},
    {"BBLOCK_WAIT_ACK_CNT1",    0,    NULL},
    {"BBLOCK_WAIT_ACK_CNT2",    0,    NULL},
    {"BBLOCK_WAIT_ACK_CNT3",    0,    NULL},
    {"BBLOCK_RSV_ACK_CNT0",     0,     NULL},
    {"BBLOCK_RSV_ACK_CNT1",     0,     NULL},
    {"BBLOCK_RSV_ACK_CNT2",     0,     NULL},
    {"BBLOCK_RSV_ACK_CNT3",     0,     NULL},
    {"BBLOCK_RSV0",             0,             NULL},
    {"BBLOCK_RSV1",             0,             NULL},
    {"BBLOCK_RSV2",             0,             NULL},
    {"BBLOCK_RSV3",             0,             NULL},
    {"BBLOCK_RSV4",             0,             NULL},
    {"BBLOCK_RSV5",             0,             NULL},
    {"BBLOCK_RSV6",             0,             NULL},
    {"BBLOCK_RSV7",             0,             NULL},
    {"BBLOCK_RSV8",             0,             NULL},
    {"BBLOCK_RSV9",             0,             NULL},
    {"BBLOCK_RSV10",            0,            NULL},
    {"BBLOCK_RSV11",            0,            NULL},
    {"BBLOCK_RSV12",            0,            NULL},
    {"BBLOCK_RSV13",            0,            NULL},
    {"BBLOCK_CBUS_WAIT_ACK",    0,    NULL},
    {"BBLOCK_CBUS_RSV_ACK",     0,     NULL},
    {NULL, 0, NULL}
};

/* SBLOCK Level 3 */
static const l3_intr_map_t sblock_l3_map[] = {
    {"SBLOCK_WAIT_ACK_CLIENT0", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT1", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT2", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT3", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT4", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT5", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT6", 0, NULL},
    {"SBLOCK_WAIT_ACK_CLIENT7", 0, NULL},
    {"SBLOCK_WAIT_ACK_CNT0",    0,    NULL},
    {"SBLOCK_WAIT_ACK_CNT1",    0,    NULL},
    {"SBLOCK_WAIT_ACK_CNT2",    0,    NULL},
    {"SBLOCK_WAIT_ACK_CNT3",    0,    NULL},
    {"SBLOCK_RSV_ACK_CNT0",     0,     NULL},
    {"SBLOCK_RSV_ACK_CNT1",     0,     NULL},
    {"SBLOCK_RSV_ACK_CNT2",     0,     NULL},
    {"SBLOCK_RSV_ACK_CNT3",     0,     NULL},
    {"SBLOCK_RSV0",             0,             NULL},
    {"SBLOCK_RSV1",             0,             NULL},
    {"SBLOCK_RSV2",             0,             NULL},
    {"SBLOCK_RSV3",             0,             NULL},
    {"SBLOCK_RSV4",             0,             NULL},
    {"SBLOCK_RSV5",             0,             NULL},
    {"SBLOCK_RSV6",             0,             NULL},
    {"SBLOCK_RSV7",             0,             NULL},
    {"SBLOCK_RSV8",             0,             NULL},
    {"SBLOCK_RSV9",             0,             NULL},
    {"SBLOCK_RSV10",            0,            NULL},
    {"SBLOCK_RSV11",            0,            NULL},
    {"SBLOCK_RSV12",            0,            NULL},
    {"SBLOCK_RSV13",            0,            NULL},
    {"SBLOCK_CBUS_WAIT_ACK",    0,    NULL},
    {"SBLOCK_CBUS_RSV_ACK",     0,     NULL},
    {NULL, 0, NULL}
};

/* DPRX Level 3 */
static const l3_intr_map_t dprx_l3_map[] = {
    {"DPRX_CBUS_CLIENT", 0, NULL},
    {"DPRX_PRMUX",       PRMUX_PRO_INT_STATUS_REG,       int_greg_l3_dprx_prmux_keys},
    {"DPRX_PSTORE",      PSTORE_PRO_INT,      int_greg_l3_dprx_pstore_keys},
    {"DPRX_PBUFFER",     PBUFFER_PRO_INT_STATUS_REG,     int_greg_l3_dprx_pbuffer_keys},
    {"DPRX_FBM",         FBM_PRO_INT_STATUS_REG,         int_greg_l3_dprx_fbm_keys},
    {"DPRX_DPRE",        DPRX_DPRE_BASE,        int_greg_l3_dprx_dpre_keys},
    {NULL, 0, NULL}
};

/* ETH Level 3  */
static const l3_intr_map_t eth_l3_map[] = {
    {"ETH_CBUS_INTR",        0,       NULL},
    {"ETH_ETH0_MODULE_INTR", DPU_L1_BLK_ETH0_INT_STATUS_REG, int_greg_l3_eth_eth_module_keys},
    {"ETH_ETH1_MODULE_INTR", DPU_L1_BLK_ETH0_INT_STATUS_REG, int_greg_l3_eth_eth_module_keys},
    {NULL, 0, NULL}
};

/* ----------------------------------------------------------------
 * Level 2 Interrupt Mappings
 * ----------------------------------------------------------------
 */

 static const l2_intr_map_t l2_intr_map[] = {
	/* INTF level 2 interrupts */
	{0,  "INTF",   INTF_BLOCK_BREG_init_reg,   int_greg_l2_intf_keys, intf_l3_map},

	/* RDMA level 2 interrupts */
	{1,  "RDMA",   RDMA_INT_REG,   int_greg_l2_rdma_keys, NULL},

	/* PP level 2 interrupts */
	{2,  "PP",	 PP_INIT_REG,	 int_greg_l2_pp_keys, pp_l3_map},

	/* DPTX level 2 interrupts */
	{3,  "DPTX",   DPTX_INT_STATUS,   int_greg_l2_dptx_keys, dptx_l3_map},

	/* VIO level 2 interrupts */
	{4,  "VIO",	VIO_INT_STATUS,	int_greg_l2_vio_keys, vio_l3_map},

	/* DSCH level 2 interrupts */
	{5,  "DSCH",   DSCH_INT_STATUS,   int_greg_l2_dsch_keys, dsch_l3_map},

	/* CBUS level 2 interrupts*/
	{8,  "CBUS",   INT_GREG_L2_CBUS_STATUS, NULL, NULL},

	/* DPRX level 2 interrupts */
	{10, "DPRX",   DPRX_INT_STATUS,   int_greg_l2_dprx_keys, dprx_l3_map},

	/* ETH level 2 interrupts */
	{11, "ETH_S0",	DPU_L1_BLK_ETH0_int_reg,	int_greg_l2_eth_keys, eth_l3_map},

	{12, "ETH_S1",	DPU_L1_BLK_ETH0_int_reg,	int_greg_l2_eth_keys, eth_l3_map},

	/* End marker */
	{0, NULL, 0, NULL, NULL}
};

void check_l3_interrupts(const char *l2_module_name, const char *l2_submodule,
						const void *l3_map_ptr)
{
	const l3_intr_map_t *l3_map = NULL;

	if (strcmp(l2_module_name, "INTF") == 0)
		l3_map = (const l3_intr_map_t *)intf_l3_map;
	else if (strcmp(l2_module_name, "PP") == 0)
		l3_map = pp_l3_map;
	else if (strcmp(l2_module_name, "DPTX") == 0)
		l3_map = dptx_l3_map;
	else if (strcmp(l2_module_name, "VIO") == 0)
		l3_map = vio_l3_map;
	else if (strcmp(l2_module_name, "DSCH") == 0)
		l3_map = dsch_l3_map;
	else if (strcmp(l2_module_name, "BBLOCK") == 0)
		l3_map = bblock_l3_map;
	else if (strcmp(l2_module_name, "SBLOCK") == 0)
		l3_map = sblock_l3_map;
	else if (strcmp(l2_module_name, "DPRX") == 0)
		l3_map = dprx_l3_map;
	else if (strcmp(l2_module_name, "ETH") == 0)
		l3_map = eth_l3_map;

	if (l3_map == NULL)
		return;

	const l3_intr_map_t *l3_entry = l3_map;
	while (l3_entry->l2_module != NULL) {
		if (strcmp(l3_entry->l2_module, l2_submodule) == 0)
			break;
		l3_entry++;
	}

	if (l3_entry->l2_module == NULL || l3_entry->l3_reg_addr == 0 || l3_entry->l3_keys == NULL) {
		return;
	}


	uint32_t l3_status = read_reg(l3_entry->l3_reg_addr, 0, 31);

	if (l3_status != 0) {
		int first_l3 = 1;

		for (int i = 0; l3_entry->l3_keys[i] != NULL; i++) {
			if ((l3_status & (1U << i)) != 0) {
				if (first_l3) {
					printf("│		└─ Level 3 \033[1;34m(L3 Status: 0x%08X)\033[0m:\n", l3_status);
					first_l3 = 0;
				}
				printf("│		   └─ %s:\033[;;31m[1]\033[0m \033[1;33m(L3 bit %d)\033[0m\n", l3_entry->l3_keys[i], i);
			}
		}
	}
}

void check_l2_interrupts(const char *l2_module_name, uint32_t l2_status,
						const char **l2_keys, const void *l3_map)
{
	if (l2_keys != NULL) {
		for (int i = 0; l2_keys[i] != NULL; i++) {
			if ((l2_status & (1U << i)) != 0) {
				printf("│	 ├─ %s:\033[;;31m[1]\033[0m \033[1;33m(L2 bit %d)\033[0m\n", l2_keys[i], i);
				check_l3_interrupts(l2_module_name, l2_keys[i], l3_map);
			}
		}
	}
}

void check_greg_l3_tree(uint32_t l1_status)
{
	int has_any_int = 0;
	const l2_intr_map_t *map = l2_intr_map;

	printf("\033[1;36m------------------------------------------------------------------------\033[0m\n");
	printf("L1 Status: \033[1;35m0x%08X\033[0m\n\n", l1_status);
	printf("\033[1;36m------------------------------------------------------------------------\033[0m\n");

	while (map->l2_reg_name != NULL) {
		if (l1_status & (1U << map->l1_bit)) {
			has_any_int = 1;

			printf("├─ %s:\033[;;31m[1]\033[0m \033[1;33m(L1 bit %d)\033[0m\n", int_greg_keys[map->l1_bit], map->l1_bit);

			if (map->l1_bit == 8) {
				uint32_t l2_status = read_reg(INT_GREG_L2_CBUS_STATUS, 0, 31);
				if (l2_status != 0) {
					printf("│  └─ BBLOCK:\033[;;31m[1]\033[0m \033[1;34m(L2 Status: 0x%08X)\033[0m\n", l2_status);
					check_l2_interrupts("BBLOCK", l2_status, int_greg_l2_bblock_keys, bblock_l3_map);

					printf("\033[1;36m------------------------------------------------------------------------\033[0m\n");

					printf("│  └─ SBLOCK:\033[;;31m[1]\033[0m \033[1;34m(L2 Status: 0x%08X)\033[0m\n", l2_status);
					check_l2_interrupts("SBLOCK", l2_status, int_greg_l2_sblock_keys, sblock_l3_map);
				}
			} else if (map->l2_reg_addr != 0) {
				uint32_t l2_status = read_reg(map->l2_reg_addr, 0, 31);
				if (l2_status != 0) {
					printf("│  └─ %s:\033[;;31m[1]\033[0m \033[1;34m(L2 Status: 0x%08X)\033[0m\n", map->l2_reg_name, l2_status);
					check_l2_interrupts(map->l2_reg_name, l2_status, map->l2_keys, map->l3_map);
				}
			}
			printf("\033[1;36m------------------------------------------------------------------------\033[0m\n");
		}
		map++;
	}

	if (!has_any_int) {
		printf("\033[1;32mNo Level 1 interrupts\033[0m\n");
		printf("\033[1;36m------------------------------------------------------------------------\033[0m\n");
	}
}

#endif /* __REG_INTERRUPT_H__ */
