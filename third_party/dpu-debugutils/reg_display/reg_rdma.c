#include "reg_interface.h"
#include "reg_rdma.h"

extern device_t *dev;

void show_rdma_stat_vport(device_t *dev) {
	uint64_t d64 = 0;

	print_color(MAGENTA, "-----------------VPORT---------------");
	// vport 总共要读取128(行) * 4(每行) = 512个64位的寄存器(共4KB)，分1次读取(每次最多读取4KB)：等同于每次间接读取只能读16(组) * 32(每组32) 个 64位寄存器
	write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x10000); /* 0x10000 = 0001 0000 0000 0000 0000, low 16bit hw set to 0 */
	for (int port_group_idx = 0; port_group_idx < (MAX_STAE_VPORT_GROUP_NUM); port_group_idx++)
	{
		for (enum int_rdma_vport group_reg_idx = VPORT_TX_REQ_WSLD_NML_PKT_CNT; group_reg_idx <= VPORT_RX_REQ_UD_MC_BYTE_CNT; group_reg_idx++)
		{
			d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + port_group_idx * RDMA_STAT_PORT_PER_GROUP_BYTE + group_reg_idx * RDMA_STAT_PER_REG_BYTE, 0, 63); /* 每次读取32个寄存器, 每个寄存器8B */
			d64 = (d64 >> 32) | (d64 << 32);
			if (d64)
			{
				printf("vport %2d %s:\033[;;35m[%.16lX]\033[0m\n", port_group_idx, rdma_vport_keys[group_reg_idx], d64);
			}
		}
	}
}

void show_rdma_stat_opcode_tx(device_t *dev) {
	uint64_t d64 = 0;

	print_color(MAGENTA, "-----------------OPCODE TX---------------");
	// opcode tx 总共要读取4K * 4 个64位的寄存器(128KB)，分2次读取：每次间接读取只能读128(group) * 64 个(1 group) 64位寄存器(64KB)
	for (int time_idx = 0; time_idx < 2; time_idx++) /* Loop 2 time */
	{
		write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x20000 + time_idx * 0x10000); /* 0x20000: opcode offset */
		for (int group_idx = 0; group_idx < RDMA_STAT_OPCODE_ONCE_READ_MAX_GROUP_NUM; group_idx++) /* Loop 128 group */
		{
			for (enum int_rdma_opcode_tx opcode_idx = TX_SEND_DATA_FIRST; opcode_idx <= TX_DB_RSQ_RTO; opcode_idx++) /* Loop 64 opcode */
			{
				d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + group_idx * RDMA_STAT_OPCODE_PER_GROUP_BYTE + opcode_idx * RDMA_STAT_PER_REG_BYTE, 0, 63);
				d64 = (d64 >> 32) | (d64 << 32);
				if (d64)
				{
					printf("stat tx %2d %s:\033[;;35m[%.16lX]\033[0m\n",
						time_idx * RDMA_STAT_OPCODE_ONCE_READ_MAX_GROUP_NUM + group_idx, rdma_opcode_tx_keys[opcode_idx], d64);
				}
			}
		}
	}
}

void show_rdma_stat_opcode_rx(device_t *dev) {
	uint64_t d64 = 0;

	print_color(MAGENTA, "-----------------OPCODE RX---------------");
	// opcode tx 总共要读取4K * 4 个64位的寄存器，分2次读取：每次间接读取只能读128 * 64 个 64位寄存器
	for (int i = 0; i < 2; i++)
	{
		write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x40000 + i * 0x10000);
		for (int j = 0; j < RDMA_STAT_OPCODE_ONCE_READ_MAX_GROUP_NUM; j++)
		{
			for (enum int_rdma_opcode_rx k = RX_SEND_DATA_FIRST; k <= RX_DB_F; k++)
			{
				d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + j * 0x200 + k * 8, 0, 63);
				d64 = (d64 >> 32) | (d64 << 32);
				if (d64)
				{
					printf("stat rx %2d %s:\033[;;35m[%.16lX]\033[0m\n", i * RDMA_STAT_OPCODE_ONCE_READ_MAX_GROUP_NUM + j, rdma_opcode_rx_keys[k], d64);
				}
			}
		}
	}
}

void show_rdma_stat_ecode(device_t *dev) {
	uint64_t d64 = 0;

	print_color(MAGENTA, "-----------------ECODE---------------");
	// ecode 总共要读取16K * 4 个64位的寄存器，分8次读取：每次间接读取只能读32 * 256 个 64位寄存器
	for (int i = 0; i < (MAX_STAE_GROUP / MAX_STAE_ONCE_NUM); i++)
	{
		write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x80000 + i * 0x10000);
		for (int j = 0; j < MAX_STAE_ONCE_NUM; j++)
		{
			for (enum int_rdma_ecode k = EC_TPE_REQ_NML; k < MAX_ECODE; k++)
			{
				d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + j * 0x800 + k * 8, 0, 63);
				d64 = (d64 >> 32) | (d64 << 32);
				if (d64)
				{
					printf("ecode %2d %s(0x%x):\033[;;35m[%.16lX]\033[0m\n", i * 32 + j, rdma_ecode_keys[k], k, d64);
				}
			}
		}
	}
}