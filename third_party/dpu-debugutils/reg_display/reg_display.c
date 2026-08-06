#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <unistd.h>
#include <byteswap.h>
#include <endian.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>
#include <getopt.h>

#include "reg_display.h"

/* Color output control: 0 = no color, 1 = color enabled */
int g_color_enabled = 1;

/*
 * When color is disabled, filter ANSI escape sequences from stdout.
 * This handles hardcoded escape codes in printf() calls throughout the code.
 * Uses fopencookie (GNU extension) to wrap stdout with a filtering stream.
 */
static FILE *g_real_stdout;

static ssize_t nocolor_write(void *cookie, const char *buf, size_t size)
{
	size_t i = 0;
	while (i < size) {
		if (buf[i] == '\033') {
			/* Skip ESC [ ... m sequences */
			i++;
			if (i < size && buf[i] == '[') {
				i++;
				while (i < size && buf[i] != 'm')
					i++;
				if (i < size)
					i++; /* skip 'm' */
			}
		} else {
			fputc(buf[i], g_real_stdout);
			i++;
		}
	}
	return size;
}

static int nocolor_close(void *cookie)
{
	fflush(g_real_stdout);
	return 0;
}

static void setup_nocolor_stdout(void)
{
	cookie_io_functions_t funcs = {
		.write = nocolor_write,
		.close = nocolor_close,
	};
	g_real_stdout = stdout;
	stdout = fopencookie(NULL, "w", funcs);
	setvbuf(stdout, NULL, _IOLBF, 0);
}
#include "git_version.h"
#include "reg_interface.h"
#include "reg_rdma.h"
#include "reg_intr.h"

static device_t g_device;
static device_t *g_dev = NULL;

#define TRAVERSE_MODE_NONE     0
#define TRAVERSE_MODE_ALL      1
#define TRAVERSE_MODE_ETH      2
#define TRAVERSE_MODE_VTX      3
#define TRAVERSE_MODE_VRX      4
#define TRAVERSE_MODE_DPTX     5
#define TRAVERSE_MODE_DPRX     6
#define TRAVERSE_MODE_PP       7
#define TRAVERSE_MODE_PTYPE    8
#define TRAVERSE_MODE_RDMA     9
#define TRAVERSE_MODE_VPORT    10
#define TRAVERSE_MODE_INTF     11

static int traverse_mode = TRAVERSE_MODE_NONE;
static int traverse_flag = 0;
static int traverse_count = 1;
static int traverse_duration = 0;

static volatile int time_expired = 0;

static void timer_handler(int signum)
{
	time_expired = 1;
}



int vtx_s = 0;		  // 新增：vtx起始值
int vtx_e = MAX_RING; // 新增：vtx结束值

int pstat_type = 0;	// pstat flow table sel
int pstat_index = 0;	// pstat flow table index
int pstat_flag = 0;
char pstat_type_str[32] = {0};
const char* PSTAT_VALID_TYPES[] = {
	"ptype", "flow0", "flow1", "iacl", "eacl",
	"sportdis", "sportnodis", "dportdis", "dportnodis"
};

char table_name[32] = {0};
int table_value = 0;

int vrx_num = MAX_RING;
int display_mode = 0;
int clear_flag = 0;
/* ----------------------------------------------------------------
 * Raw pointer read/write access
 * ----------------------------------------------------------------
 */
#define DPU_BAR0_REMAINING_OFFSET	 0x4000


/* ----------------------------------------------------------------
 * Address translation function for BAR0 16K offset mapping
 * ----------------------------------------------------------------
 */
static unsigned char *
get_fwqe_addr(unsigned int addr)
{
	if (g_dev == NULL) {
		printf("Error: Device not initialized\n");
		return NULL;
	}

	/* For BAR0 with 16K offset mapping */
	if (g_dev->bar == 0) {
		/* Check if address is in the accessible range (>= 0x4000) */
		if (addr < DPU_BAR0_REMAINING_OFFSET) {
			printf("Error: Address 0x%x is in the first 16K of BAR0 and is not accessible\n", addr);
			printf("       BAR0 is mapped from 0x%x, accessible range: 0x%x - 0x%x\n",
				   DPU_BAR0_REMAINING_OFFSET,
				   DPU_BAR0_REMAINING_OFFSET,
				   DPU_BAR0_REMAINING_OFFSET + g_dev->size - 1);
			return NULL;
		}

		/* Check if address is within mapped region */
		unsigned int offset_addr = addr - DPU_BAR0_REMAINING_OFFSET;
		if (offset_addr >= g_dev->size) {
			printf("Error: Address 0x%x is beyond mapped region (max: 0x%x)\n",
				   addr, DPU_BAR0_REMAINING_OFFSET + g_dev->size - 1);
			return NULL;
		}

		/* Return pointer to mapped memory */
		return g_dev->addr + offset_addr;
	}

	/* For other BARs: simple address addition */
	if (addr >= g_dev->size) {
		printf("Error: Address 0x%x is beyond BAR size (0x%x)\n", addr, g_dev->size);
		return NULL;
	}

	return g_dev->addr + addr;
}


/* Usage */
static void show_usage()
{
	printf("\nUsage: reg_display -s <device> [options]\n"
		   "	-h                  Help (this message)\n"
		   "	-s <device>         Slot/device (as per lspci)\n"
		   "	-b <BAR>            Base address region (BAR) to access, eg. 0 for BAR0\n"
		   "	-m <block name>     default show all block\n"
		   "	                      block: pp, dptx, dprx, vtx, vrx, eth, intf, ptype, rdma, rdmadebug, rdmaqsch, vport\n"
		   "	                      register traversal: traverse:vtx:5 (5 times) or traverse:vtx:100s (100 seconds)\n"
		   "	-t <vtx_ring_num>   vtx ring num\n"
		   "	-r <vrx_ring_num>   vrx ring num\n"
		   "	-c                  clear cnt\n"
		   "	-p <flow,index>     query flow count, eg. flow1,1024 for fse index 1024\n"
		   "	--color <when>      colorize output: 'always', 'never', or 'auto' (default)\n"
		   "	                      auto: color when stdout is a terminal, plain when piped/redirected\n\n");
}
void print_register(const char *name, uint64_t value)
{
	if (value)
	{
		printf("%s:%s[%.8lX]%s\n", name, CYAN, value, RESET);
	}
}

static unsigned int
read_le32(unsigned int addr)
{
	unsigned char *reg_addr = get_fwqe_addr(addr);
	if (reg_addr == NULL) {
		return 0;
	}

	unsigned int data = *(volatile unsigned int *)reg_addr;
	if (__BYTE_ORDER != __LITTLE_ENDIAN)
	{
		data = bswap_32(data);
	}
	return data;
}

/* 连续读取regnum 个32位的数据，并按照每行4个寄存器值的方式打印出来*/
void read_multi_line_ram_register_values(unsigned int addr, unsigned int regcnt, unsigned int avglinenum)
{
	unsigned int d32;
	int non_zero_count; // 用于记录每行中非零值的数量
	unsigned char *reg_addr;

	if (get_fwqe_addr(addr) == NULL) {
		return;
	}

	for (unsigned int i = 0; i < regcnt; i += avglinenum * 4)
	{						// 每次循环处理avglinenum个寄存器（每个寄存器4字节）
		non_zero_count = 0; // 初始化每行的非零值数量为0
		// 检查是否有非零值
		for (int j = 0; j < avglinenum; j++)
		{
			reg_addr = get_fwqe_addr(addr + i + j * 4);
			if (reg_addr == NULL) {
				non_zero_count = -1;
				break;
			}

			d32 = *(volatile unsigned int *)reg_addr;
			if (__BYTE_ORDER != __LITTLE_ENDIAN)
			{
				d32 = bswap_32(d32);
			}

			if (d32 != 0)
			{
				non_zero_count++;
				break; // 只要发现一个非零值，就不再继续检查
			}
		}
		// 如果有非零值，则打印整行
		if (non_zero_count > 0)
		{
			printf("%.8X: ", addr + i);
			for (int j = 0; j < avglinenum; j++)
			{
				reg_addr = get_fwqe_addr(addr + i + j * 4);
				if (reg_addr != NULL) {
					d32 = *(volatile unsigned int *)reg_addr;
					if (__BYTE_ORDER != __LITTLE_ENDIAN)
					{
						d32 = bswap_32(d32);
					}
					printf("%.8X ", d32);
				}
			}
			printf("\n");
		} else if (non_zero_count == -1) {
			break;
		}
	}
}

void
write_le32(unsigned int addr, unsigned int data)
{
	unsigned char *reg_addr = get_fwqe_addr(addr);
	if (reg_addr == NULL) {
		return;
	}
	if (__BYTE_ORDER != __LITTLE_ENDIAN)
	{
		data = bswap_32(data);
	}
	*(volatile unsigned int *)reg_addr = data;
	msync((void *)reg_addr, 4, MS_SYNC | MS_INVALIDATE);
}

/**
 * Read register
 *
 * \param[in] addr            reg addr
 * \param[in] start           start offset(bit)
 * \param[in] end             end offset(bit)
 *
 * \return                     reg value(uint64_t d64)
 */
uint64_t
read_reg(int addr, int start, int end)
{
	int width = end - start + 1;
	int start_offset, end_offset;
	int first_bit = 0;
	int last_bit = 0;
	uint64_t mask = 0;
	int len = 0;
	int temp = 0;
	uint32_t d32 = 0;
	uint64_t d64 = 0;
	uint64_t a = 0;

	if (start < 0)
	{
		printf("Error: invalid start position");
		return -1;
	}

	if (g_dev == NULL) {
		printf("Error: Device not initialized\n");
		return -1;
	}

	if (get_fwqe_addr( addr) == NULL) {
		return -1;
	}

	/* Length in bytes */
	len = end % 8 == 0 ? end / 8 : end / 8 + 1;


	if (width <= 0 || width > MAX_WIDTH)
	{
		printf("Error: invalid width (should between 1 - %d\n", MAX_WIDTH);
		return -1;
	}

	/*32bits*/
	start_offset = start / 32;
	end_offset = end / 32;
	first_bit = start % 32;
	last_bit = end % 32;
	/* Length in 4 bytes */
	len = end_offset - start_offset;

	/*read once*/
	if (start_offset == end_offset)
	{
		mask = ((1ULL << width) - 1) << first_bit;
		d64 = read_le32(addr + start_offset * 4);
		d64 = (d64 & mask) >> first_bit;
	}
	else
	{
		for (int i = 0; i <= len; i++)
		{
			if (get_fwqe_addr( addr + (start_offset + i) * 4) == NULL) {
				printf("Error: Invalid address 0x%x for register read\n",
					   addr + (start_offset + i) * 4);
				return -1;
			}

			d32 = read_le32(addr + (start_offset + i) * 4);
			if (!i)
			{
				/*first sec*/
				mask = UINT32_MAX << first_bit;
				d32 &= mask;
				temp = 32 - first_bit;
				d64 = d32 >> first_bit;
			}
			else
			{
				if (i == len)
				{
					/*last sec*/
					mask = (1ULL << last_bit) - 1;
					d32 &= mask;
				}
				a = (uint64_t)d32 << temp;
				d64 |= a;
				temp += 32;
			}
		}
	}

	return d64;
}

static void traverse_registers(const char *module_name, uint32_t base_addr,
			uint32_t start_offset, uint32_t end_offset,
			uint32_t step)
{
	printf("\n=== Traversing %s Registers ===\n", module_name);
	printf("Address range: 0x%04X - 0x%04X\n", start_offset, end_offset);

	for (uint32_t offset = start_offset; offset <= end_offset; offset += step) {
		read_reg(base_addr + offset, 0, 31);


		if ((offset - start_offset) % 0x1000 == 0 && offset > start_offset) {
			printf(".");
			fflush(stdout);
		}
	}
}

static int set_display_mode(char *s)
{
	if (strncmp(s, "traverse:", 9) == 0) {
		traverse_flag = 1;
		char module_str[64];
		char *module = NULL;
		char *param = NULL;

		strncpy(module_str, s + 9, sizeof(module_str) - 1);
		module_str[sizeof(module_str) - 1] = '\0';

		module = strtok(module_str, ":");
		if (module) {
			param = strtok(NULL, ":");
		}

		if (strcmp(module, "vtx") == 0) traverse_mode = TRAVERSE_MODE_VTX;
		else if (strcmp(module, "vrx") == 0) traverse_mode = TRAVERSE_MODE_VRX;
		else if (strcmp(module, "pp") == 0) traverse_mode = TRAVERSE_MODE_PP;
		else if (strcmp(module, "eth") == 0) traverse_mode = TRAVERSE_MODE_ETH;
		else if (strcmp(module, "intf") == 0) traverse_mode = TRAVERSE_MODE_INTF;
		else {
			fprintf(stderr, "Error: Unknown module '%s' for traverse\n", module);
			fprintf(stderr, "Supported modules: vtx, vrx, pp, eth, intf\n");
			return -1;
		}

		traverse_count = 0;
		traverse_duration = 0;

		if (param) {
			char *extra_param = strtok(NULL, ":");
			if (extra_param) {
				fprintf(stderr, "Error: Only one parameter allowed (either count or duration)\n");
				fprintf(stderr, "Usage: traverse:module[:count] or traverse:module[:duration]\n");
				fprintf(stderr, "Example: traverse:vtx:5 (5 times) or traverse:vtx:100s (100 seconds)\n");
				return -1;
			}

			char *suffix = strstr(param, "s");
			if (suffix && suffix == param + strlen(param) - 1) {
				char time_str[32];
				strncpy(time_str, param, strlen(param) - 1);
				time_str[strlen(param) - 1] = '\0';
				traverse_duration = atoi(time_str);
				if (traverse_duration <= 0) {
					fprintf(stderr, "Error: traverse duration must be positive, got %d\n", traverse_duration);
					return -1;
				}
			} else {
				traverse_count = atoi(param);
				if (traverse_count <= 0) {
					fprintf(stderr, "Error: traverse count must be positive, got %d\n", traverse_count);
					return -1;
				}
			}
		} else
			traverse_count = 1;

		printf("[TEST MODE] Will traverse %s module registers", module);
		if (traverse_count > 0)
			printf(", %d times", traverse_count);
		if (traverse_duration > 0)
			printf(", for %d seconds", traverse_duration);
		printf("\n");

		return 0;
	}

	if (strcmp(s, "pp") == 0)
		display_mode |= MODE_PP;
	else if (strcmp(s, "dprx") == 0)
		display_mode |= MODE_DPRX;
	else if (strcmp(s, "dptx") == 0)
		display_mode |= MODE_DPTX;
	else if (strcmp(s, "vrx") == 0)
		display_mode |= MODE_VRX;
	else if (strcmp(s, "vtx") == 0)
		display_mode |= MODE_VTX;
	else if (strcmp(s, "eth") == 0)
		display_mode |= MODE_ETH;
	else if (strcmp(s, "ptype") == 0)
		display_mode |= MODE_PTYPE;
	else if (strcmp(s, "rdma") == 0)
		display_mode |= MODE_RDMA;
	else if (strcmp(s, "intf") == 0)
		display_mode |= MODE_INTF;
	else if (strcmp(s, "rdmadebug") == 0)
		display_mode |= MODE_RDMAD;
	else if (strcmp(s, "vport") == 0)
		display_mode |= MODE_VPORT;
	else if (strcmp(s, "rdmabg") == 0)
		display_mode |= MODE_RDMABG;
	else if (strcmp(s, "rdmaqsch") == 0)
		display_mode |= MODE_RDMAQSCH;
	else if (strcmp(s, "ethv2") == 0)
		display_mode |= (MODE_ETH | MODE_ETHV2);
	else if (strcmp(s, "pcie") == 0)
		display_mode |= MODE_PCIE;
	else if (strcmp(s, "psw") == 0)
		display_mode |= MODE_PSW;
	else
	{
		printf("no block named %s\n", s);
		return -1;
	}

	return 0;
}

static void traverse_vtx_registers(void)
{

	traverse_registers("VTX", VIO_VTX_BASE, 0x0000, 0x90000, 4);
}


static void traverse_vrx_registers(void)
{
	traverse_registers("VRX", VIO_VRX_BASE, 0x0000, 0x1c000, 4);
}

static void traverse_pp_registers(void)
{
	traverse_registers("PP", PP_BREG_BASE, 0x0000, 0x1e4000, 4);
}

static void traverse_eth_registers(void)
{
	traverse_registers("ETH_S0", DPU_L1_BLK_ETH0_BASE, 0x0000, 0x40000, 4);
}

static void traverse_intf_registers(void)
{
	traverse_registers("INTF_PCOMPLETER", INTF_PCOMPLETER_BASE, 0x0000, 0x60000, 4);
	traverse_registers("INTF_PREQUESTER", INTF_PREQUESTER_BASE, 0x0000, 0x60000, 4);
	traverse_registers("INTF_MAILBOX", INTF_MAILBOX_BASE, 0x0000, 0x50000, 4);
	traverse_registers("INTF_CMDQ", INTF_CMDQ_BASE, 0x0000, 0x3000, 4);
	traverse_registers("INTF_MSGQ", INTF_MSGQ_BASE, 0x0000, 0x3000, 4);
	traverse_registers("INTF_TLPQ", INTF_TLPQ_BASE, 0x0000, 0x3000, 4);
	traverse_registers("INTF_DMAQ", INTF_DMAQ_BASE, 0x0000, 0x3000, 4);
	traverse_registers("INTF_PMERGE", INTF_PMERGE_BASE, 0x0000, 0x3000, 4);
}

static void perform_single_traversal(int iteration)
{
	if (traverse_count > 1 || traverse_duration > 0) {
		printf("\n========== Traversal iteration %d ==========\n", iteration);
	}

	switch (traverse_mode) {
		case TRAVERSE_MODE_VTX:
			traverse_vtx_registers();
			break;
		case TRAVERSE_MODE_VRX:
			traverse_vrx_registers();
			break;
		case TRAVERSE_MODE_PP:
			traverse_pp_registers();
			break;
		case TRAVERSE_MODE_ETH:
			traverse_eth_registers();
			break;
		case TRAVERSE_MODE_INTF:
			traverse_intf_registers();
			break;
		default:
			printf("Unknown traverse mode: %d\n", traverse_mode);
			break;
	}
}

static void perform_module_traversal(void)
{
	if (!traverse_flag)
		return;

	printf("\n");
	printf("========================================\n");
	printf("   MODULE REGISTER TRAVERSAL MODE\n");
	printf("========================================\n");

	if (traverse_count > 1)
		printf("Traversal count: %d times\n", traverse_count);
	if (traverse_duration > 0)
		printf("Traversal duration: %d seconds\n", traverse_duration);
	printf("\n");

	if (traverse_duration > 0) {
		struct sigaction sa;
		struct itimerval timer;

		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = timer_handler;
		sigaction(SIGALRM, &sa, NULL);

		timer.it_value.tv_sec = traverse_duration;
		timer.it_value.tv_usec = 0;
		timer.it_interval.tv_sec = 0;
		timer.it_interval.tv_usec = 0;
		setitimer(ITIMER_REAL, &timer, NULL);

		printf("Traversal will run for %d seconds\n", traverse_duration);
	}

	struct timespec start_time, end_time, iteration_start, iteration_end;
	int iteration = 0;
	int max_iterations = (traverse_count > 0) ? traverse_count : 999999;

	clock_gettime(CLOCK_MONOTONIC, &start_time);

	while (iteration < max_iterations && !time_expired) {
		iteration++;

		clock_gettime(CLOCK_MONOTONIC, &iteration_start);
		perform_single_traversal(iteration);
		clock_gettime(CLOCK_MONOTONIC, &iteration_end);

		double iter_elapsed = (iteration_end.tv_sec - iteration_start.tv_sec) +
		                      (iteration_end.tv_nsec - iteration_start.tv_nsec) / 1e9;

		printf("\nIteration %d completed in %.3f seconds\n", iteration, iter_elapsed);
	}

	clock_gettime(CLOCK_MONOTONIC, &end_time);
	printf("\n========================================\n");
	printf("   TRAVERSAL COMPLETE\n");
	printf("========================================\n");

	if (traverse_duration > 0) {
		struct itimerval timer = {{0, 0}, {0, 0}};
		setitimer(ITIMER_REAL, &timer, NULL);
		time_expired = 0;
	}
}

void display_vport_eport_table(int table_value)
{
	uint64_t d64 = 0;
	if (table_value < 0 || table_value > 1023)
	{
		fprintf(stderr, "[vport_eport] value out of range (0-1023)\n");
		return;
	}

	printf("vport_eport_table_index: %3d\n", table_value);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 0, 0);
	printf("valid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 1, 2);
	printf("vlan_pop_cnt:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 3, 4);
	printf("vlan_push_cnt:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 5, 5);
	printf("ivlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 6, 6);
	printf("ovlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 7, 7);
	printf("dscp_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 8, 8);
	printf("tos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 9, 10);
	printf("push_ivlan_tpid_type:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 11, 12);
	printf("push_ovlan_tpid_type:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 13, 15);
	printf("mirror_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 16, 31);
	printf("push_ivlan:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 32, 47);
	printf("push_ovlan:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 48, 48);
	printf("mirror_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 49, 59);
	printf("car_info:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 60, 60);
	printf("smac_check_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 61, 108);
	printf("smac_check:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 109, 109);
	printf("eacl_profile_id_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 110, 113);
	printf("eacl_profile_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 114, 114);
	printf("vlan_offload_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 115, 115);
	printf("default_vlan_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_VPORT_EPORT_TABLE + EPRO_VPORT_EPORT_TABLE_SIZE * table_value, 116, 127);
	printf("default_vlan_id:\033[;;34m[%1ld]\033[0m ", d64);
	printf("\n\n");
}

void display_eth_eport_table(int table_value)
{
	uint64_t d64 = 0;

	if (table_value < 0 || table_value > 63)
	{
		fprintf(stderr, "[eth_eport] value out of range (0-63)\n");
		return;
	}

	printf("eth_eport_table_index: %3d\n", table_value);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 0, 0);
	printf("valid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 1, 2);
	printf("vlan_pop_cnt:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 3, 4);
	printf("vlan_push_cnt:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 5, 5);
	printf("ivlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 6, 6);
	printf("ovlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 7, 7);
	printf("dscp_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 8, 8);
	printf("tos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 9, 10);
	printf("push_ivlan_tpid_type:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 11, 12);
	printf("push_ovlan_tpid_type:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 13, 13);
	printf("mirror_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 14, 16);
	printf("mirror_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 17, 28);
	printf("default_vlan_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 29, 29);
	printf("default_vlan_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 30, 31);
	printf("rsv:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 32, 47);
	printf("push_ivlan:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(EPRO_ETH_EPORT_TABLE + EPRO_ETH_EPORT_TABLE_SIZE * table_value, 48, 63);
	printf("push_ovlan:\033[;;34m[%1ld]\033[0m ", d64);
	printf("\n\n");
}

void display_epro_flow_act_table(int table_value)
{
	uint64_t d64 = 0;

	if (table_value < 0 || table_value > 16363)
	{
		fprintf(stderr, "[eth_eport] value out of range (0-16363)\n");
		return;
	}

	uint64_t tbls_page_addr = table_value / 64;
	uint64_t tbls_page_index = table_value % 64;

	write_le32( EPRO_TBLS_PAGE_ADDR_REG, tbls_page_addr);
	printf("epro_flow_act_index: %3d\n", table_value);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 0, 1);
	printf("fwd:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 2, 2);
	printf("to_rdma:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 3, 5);
	printf("dport:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 6, 15);
	printf("dport_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 16, 26);
	printf("dport_info:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 27, 27);
	printf("mirror_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 28, 30);
	printf("mirror_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 31, 41);
	printf("car_info_dst_qpn:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 42, 43);
	printf("vlan_push_cnt:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 44, 45);
	printf("vlan_pop_cnt:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 46, 46);
	printf("dscp_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 47, 47);
	printf("tos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 48, 63);
	printf("push_ivlan:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 64, 79);
	printf("push_ovlan:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 80, 80);
	printf("dscp_nat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 81, 81);
	printf("sip_nat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 82, 82);
	printf("smac_chg_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 83, 83);
	printf("sport_nat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 84, 84);
	printf("dip_nat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 85, 85);
	printf("dmac_chg_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 86, 86);
	printf("dport_nat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 87, 87);
	printf("ttl_nat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 88, 95);
	printf("ttl_nat:\033[;;34m[%1ld]\033[0m ", d64);

	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 96, 143);
	printf("mac_chg:\033[;;34m[%1ld]\033[0m ", d64);

	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 144, 207);
	printf("ip_nat_1:\033[;;34m[%1ld]\033[0m ", d64);

	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 208, 271);
	printf("ip_nat_2:\033[;;34m[%1ld]\033[0m ", d64);

	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 272, 287);
	printf("dport_nat:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 288, 303);
	printf("sport_nat:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 304, 309);
	printf("dscp_nat:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 310, 310);
	printf("ttl_dec:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 311, 311);
	printf("flow_cos_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 312, 314);
	printf("flow_cos:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 315, 315);
	printf("ivlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 316, 316);
	printf("ovlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 317, 317);
	printf("dport_disable:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 318, 318);
	printf("rss_lag:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 319, 319);
	printf("mpls_exp_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 320, 333);
	printf("flow_stat_idx:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 334, 334);
	printf("flow_stat_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 335, 335);
	printf("l3_chksum_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 336, 336);
	printf("l4_chksum_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 337, 338);
	printf("push_ivlan_tpid_type:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 339, 340);
	printf("push_ovlan_tpid_type:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 341, 341);
	printf("l2_tnl_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 342, 342);
	printf("l3_tnl_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 343, 343);
	printf("rsv:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 344, 351);
	printf("l2_tnl_idx:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 352, 362);
	printf("l3_tnl_idx:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 363, 367);
	printf("rsv1:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 368, 375);
	printf("tnl_encap_idx:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 376, 376);
	printf("tnl_encap_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 377, 377);
	printf("tnl_dscp_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 378, 378);
	printf("tnl_tos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 379, 379);
	printf("tnl_vlan_cos_remark_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 380, 381);
	printf("dst_qpn:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 382, 382);
	printf("ecn_copy_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 383, 383);
	printf("eacl_profile_id_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(PP_EPRO_BASE + 0x40 * tbls_page_index + 0x8000, 384, 387);
	printf("eacl_profile_id:\033[;;34m[%1ld]\033[0m ", d64);
	printf("\n\n");
}

void display_vport_iport_table(int table_value)
{
	uint64_t d64 = 0;

	if (table_value < 0 || table_value > 1023)
	{
		fprintf(stderr, "[eth_eport] value out of range (0-1023)\n");
		return;
	}

	printf("vport_iport_table_index: %3d\n", table_value);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 0, 0);
	printf("valid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 1, 1);
	printf("vlan_cnt_check_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 2, 3);
	printf("vlan_cnt_check:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 4, 4);
	printf("vlan_id_check_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 5, 5);
	printf("default_vlan_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 6, 17);
	printf("default_vlan_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 18, 20);
	printf("default_vlan_pri:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 21, 21);
	printf("cos_map_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 22, 24);
	printf("cos_map_mode:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 25, 25);
	printf("port_straight:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 26, 26);
	printf("mirror:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 27, 29);
	printf("mirror_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 30, 32);
	printf("dport:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 33, 42);
	printf("dport_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 43, 53);
	printf("dport_info:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 54, 54);
	printf("rss_lag:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 55, 66);
	printf("vsd:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 67, 67);
	printf("pv_lut_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 68, 68);
	printf("tse_lut_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 69, 72);
	printf("rsv1:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 73, 73);
	printf("default_flowid_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 74, 87);
	printf("default_flowid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 88, 88);
	printf("smac_check_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 89, 136);
	printf("smac_check:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 137, 137);
	printf("iacl_profile_id_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_IPORT_TABLE + IPRO_VPORT_IPORT_TABLE_SIZE * table_value, 138, 141);
	printf("iacl_profile_id:\033[;;34m[%1ld]\033[0m ", d64);
	printf("\n\n");
}

void display_vport_2nd_iport_table(int table_value)
{
	uint64_t d64 = 0;

	if (table_value < 0 || table_value > 1023)
	{
		fprintf(stderr, "[eth_eport] value out of range (0-1023)\n");
		return;
	}

	printf("vport__2nd_iport_table_index: %3d\n", table_value);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 0, 0);
	printf("valid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 1, 1);
	printf("cos_map_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 2, 4);
	printf("cos_map_mode:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 5, 5);
	printf("mirror:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 6, 8);
	printf("mirror_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 9, 11);
	printf("dport:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 12, 21);
	printf("dport_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 22, 32);
	printf("dport_info:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 33, 33);
	printf("port_straight:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 34, 34);
	printf("rss_lag:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 35, 46);
	printf("vsd:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 47, 47);
	printf("default_vlan_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 48, 59);
	printf("default_vlan_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 60, 62);
	printf("default_vlan_pri:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 63, 63);
	printf("rsv1:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 64, 64);
	printf("default_flowid_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 65, 78);
	printf("default_flowid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 79, 79);
	printf("iacl_profile_id_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 80, 83);
	printf("iacl_profile_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 84, 84);
	printf("sub_sport_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 85, 87);
	printf("eth_sub_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_VPORT_2ND_IPORT_TABLE + IPRO_VPORT_2ND_IPORT_TABLE_SIZE * table_value, 88, 127);
	printf("rsv0:\033[;;34m[%1ld]\033[0m ", d64);
	printf("\n\n");
}

void display_eth_iport_table(int table_value)
{
	uint64_t d64 = 0;

	if (table_value < 0 || table_value > 7)
	{
		fprintf(stderr, "[eth_eport] value out of range (0-7)\n");
		return;
	}

	printf("eth_iport_table_index: %3d\n", table_value);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 0, 0);
	printf("valid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 1, 1);
	printf("vlan_cnt_check_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 2, 3);
	printf("vlan_cnt_check:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 4, 4);
	printf("vlan_id_check_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 5, 5);
	printf("default_vlan_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 6, 17);
	printf("default_vlan_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 18, 20);
	printf("default_vlan_pri:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 21, 21);
	printf("cos_map_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 22, 23);
	printf("cos_map_mode:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 24, 24);
	printf("port_straight:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 25, 25);
	printf("mirror:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 26, 28);
	printf("mirror_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 29, 31);
	printf("dport:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 32, 41);
	printf("dport_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 42, 52);
	printf("dport_info:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 53, 53);
	printf("rss_lag:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 54, 54);
	printf("in_lag:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 55, 56);
	printf("in_lag_id:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 57, 68);
	printf("vsd:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 69, 69);
	printf("pv_lut_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 70, 70);
	printf("tse_lut_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 71, 72);
	printf("rsv1:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 73, 73);
	printf("default_flowid_en:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 74, 87);
	printf("default_flowid:\033[;;34m[%1ld]\033[0m ", d64);
	d64 = read_reg(IPRO_ETH_IPORT_TABLE + IPRO_ETH_IPORT_TABLE_SIZE * table_value, 88, 127);
	printf("rsv0:\033[;;34m[%1ld]\033[0m ", d64);
	printf("\n\n");
}

int clear_cnt()
{
	write_le32( CLR_CNT_REG, 1);
	write_le32( RDMA_RAM_CLR_EN_REG, 1);
	write_le32( CLR_PTYPE_CNT_REG, 1);
	return 0;
}


void check_greg()
{
	uint32_t d32 = 0;
	int has_l1_int = 0;

	print_color(YELLOW, "**************** Checking GREG ****************");

	d32 = read_reg(INT_GREG, 0, 31);
	for (int i = 0; int_greg_keys[i] != NULL; i++) {
		if ((d32 & (1U << i)) != 0) {
			printf("int_greg %s:\033[;;31m[1]\033[0m\n", int_greg_keys[i]);
			has_l1_int = 1;
		}
	}

	if (!has_l1_int) {
		return;
	}

	printf("\n");

	check_greg_l3_tree(d32);
}




/* display interface register */
void intf_display()
{
	// uint64_t d64 = 0;

	print_color(YELLOW, "**************** INTF ****************");

	print_color(GREEN, "----------------- BREG ---------------");
	print_register_64bit(INTF_BLOCK_BREG_init_done_reg);
	print_register_64bit(INTF_BLOCK_BREG_init_reg);
	print_register_64bit(INTF_BLOCK_BREG_cbus_sblock_status_reg);
	print_register_64bit(INTF_BLOCK_BREG_cbus_bblock_status_reg);
	print_register_64bit(INTF_BLOCK_BREG_status_reg);

	print_color(GREEN, "----------------- PREQUESTER ---------------");
	print_register_64bit(INTF_PREQUESTER_init_status_reg);
	print_register_64bit(INTF_PREQUESTER_init_done_reg);
	print_register_64bit(INTF_PREQUESTER_int_status_reg_history);
	print_register_64bit(INTF_PREQUESTER_cfg_mode_sel);
	print_register_64bit(INTF_PREQUESTER_fifo_0_nempty);
	print_register_64bit(INTF_PREQUESTER_fifo_0_nafull);
	print_register_64bit(INTF_PREQUESTER_fifo_0_nfull);
	print_register_64bit(INTF_PREQUESTER_fifo_0_naempty);
	print_register_64bit(INTF_PREQUESTER_fifo_1_nempty);
	print_register_64bit(INTF_PREQUESTER_fifo_1_nafull);
	print_register_64bit(INTF_PREQUESTER_fifo_1_nfull);
	print_register_64bit(INTF_PREQUESTER_fifo_1_naempty);
	print_register_64bit(INTF_PREQUESTER_fifo_2_nempty);
	print_register_64bit(INTF_PREQUESTER_fifo_2_nafull);
	print_register_64bit(INTF_PREQUESTER_fifo_2_nfull);
	print_register_64bit(INTF_PREQUESTER_fifo_2_naempty);
	print_register_64bit(INTF_PREQUESTER_table_ram_err);
	print_register_64bit(INTF_PREQUESTER_table_ram_err_lock);
	print_register_64bit(INTF_PREQUESTER_fifo_ram_err);
	print_register_64bit(INTF_PREQUESTER_table_ram_parity_err);
	print_register_64bit(INTF_PREQUESTER_fifo_0_ram_err);
	print_register_64bit(INTF_PREQUESTER_fifo_0_ram_err_lock);
	print_register_64bit(INTF_PREQUESTER_fifo_0_ram_parity_err);
	print_register_64bit(INTF_PREQUESTER_fifo_1_ram_err);
	print_register_64bit(INTF_PREQUESTER_fifo_1_ram_err_lock);
	print_register_64bit(INTF_PREQUESTER_fifo_1_ram_parity_err);
	print_register_64bit(INTF_PREQUESTER_fifo_2_ram_err);
	print_register_64bit(INTF_PREQUESTER_fifo_2_ram_err_lock);
	print_register_64bit(INTF_PREQUESTER_fifo_2_ram_parity_err);
	print_register_64bit(INTF_PREQUESTER_spl_dma_info_fifo_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_req_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_data_fifo_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_cpl_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_pending_fifo_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_sop_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_eop_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_req_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_dma_timeout_cnt);
	print_register_64bit(INTF_PREQUESTER_dma_msix_req_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_nlink_err_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_nvld_err_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_arb_err_cnt);
	print_register_64bit(INTF_PREQUESTER_spl_unable_err_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_max_delay_times);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_avr_delay_times);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_rq_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_aged_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_null_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_rx_err_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_rx_complete_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_rx_finish_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_adpt_rls_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_aged_tag_lock);
	print_register_64bit(INTF_PREQUESTER_h0_rx_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h0_rq_credit_cnt);
	print_register_64bit(INTF_PREQUESTER_h1_adpt_max_delay_times);
	print_register_64bit(INTF_PREQUESTER_h1_adpt_avr_delay_times);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_rq_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_aged_total_cnt);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_null_total_cnt);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_rx_err_cnt);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_rx_complete_cnt);
	print_register_64bit(INTF_PREQUESTER_hl_adpt_rx_finish_cnt);
	print_register_64bit(INTF_PREQUESTER_h1_adpt_rls_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h1_aged_tag_lock);
	print_register_64bit(INTF_PREQUESTER_h1_rx_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h1_rq_credit_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_max_delay_times);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_avr_delay_times);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_rq_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_aged_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_null_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_rx_err_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_adpt_rls_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_aged_tag_lock);
	print_register_64bit(INTF_PREQUESTER_h2_rx_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h2_rq_credit_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_max_delay_times);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_avr_delay_times);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_rx_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_aged_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_null_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_rx_err_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_rx_complete_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_rx_finish_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_adpt_rls_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_aged_tag_lock);
	print_register_64bit(INTF_PREQUESTER_h3_rx_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h3_rq_credit_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_max_delay_times);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_avr_delay_times);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_rq_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_aged_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_err_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_null_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_rx_err_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_rx_complete_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_rx_finish_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_adpt_rls_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_aged_tag_lock);
	print_register_64bit(INTF_PREQUESTER_h4_rx_total_cnt);
	print_register_64bit(INTF_PREQUESTER_h4_rq_credit_cnt);

	print_color(GREEN, "----------------- PCOMPLETER ---------------");
	print_register_64bit(INTF_PCOMPLETER_int_status_reg);
	print_register_64bit(INTF_PCOMPLETER_init_done_reg);
	print_register_64bit(INTF_PCOMPLETER_int_status_reg_history);
	print_register_64bit(INTF_PCOMPLETER_fifo_0_nempty);
	print_register_64bit(INTF_PCOMPLETER_fifo_0_nafull);
	print_register_64bit(INTF_PCOMPLETER_fifo_0_nfull);
	print_register_64bit(INTF_PCOMPLETER_fifo_0_naempty);
	print_register_64bit(INTF_PCOMPLETER_fifo_1_nempty);
	print_register_64bit(INTF_PCOMPLETER_fifo_1_nafull);
	print_register_64bit(INTF_PCOMPLETER_fifo_1_nfull);
	print_register_64bit(INTF_PCOMPLETER_fifo_1_naempty);
	print_register_64bit(INTF_PCOMPLETER_fifo_2_nempty);
	print_register_64bit(INTF_PCOMPLETER_fifo_2_nafull);
	print_register_64bit(INTF_PCOMPLETER_fifo_2_nfull);
	print_register_64bit(INTF_PCOMPLETER_fifo_2_naempty);
	print_register_64bit(INTF_PCOMPLETER_table_ram_err);
	print_register_64bit(INTF_PCOMPLETER_table_ram_err_lock);
	print_register_64bit(INTF_PCOMPLETER_fifo_ram_err);
	print_register_64bit(INTF_PCOMPLETER_table_ram_parity_err);
	print_register_64bit(INTF_PCOMPLETER_dmux_cbus_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_dmux_ntfy_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_dmux_tlpq_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_h0_adpt_cq_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_h1_adpt_cq_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_h2_adpt_cq_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_h3_adpt_cq_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_h4_adpt_cq_drop_cnt);
	print_register_64bit(INTF_PCOMPLETER_vrx_notify_cnt);
	print_register_64bit(INTF_PCOMPLETER_vtx_notify_cnt);
	print_register_64bit(INTF_PCOMPLETER_rdma_notify_cnt);
	print_register_64bit(INTF_PCOMPLETER_mailbox_notify_cnt);
	print_register_64bit(INTF_PCOMPLETER_blk_notify_cnt);

	print_color(GREEN, "----------------- MAILBOX ---------------");
	print_register_64bit(INTF_MAILBOX_int_status_reg);
	print_register_64bit(INTF_MAILBOX_init_done_reg);
	print_register_64bit(INTF_MAILBOX_int_status_reg_history);
	print_register_64bit(INTF_MAILBOX_af_host_id);
	print_register_64bit(INTF_MAILBOX_max_func_value);
	print_register_64bit(INTF_MAILBOX_fifo_0_nempty);
	print_register_64bit(INTF_MAILBOX_fifo_0_nafull);
	print_register_64bit(INTF_MAILBOX_fifo_0_nfull);
	print_register_64bit(INTF_MAILBOX_fifo_0_naempty);
	print_register_64bit(INTF_MAILBOX_fifo_1_nempty);
	print_register_64bit(INTF_MAILBOX_fifo_1_nafull);
	print_register_64bit(INTF_MAILBOX_fifo_1_nfull);
	print_register_64bit(INTF_MAILBOX_fifo_1_naempty);
	print_register_64bit(INTF_MAILBOX_table_ram_err);
	print_register_64bit(INTF_MAILBOX_table_ram_err_lock);
	print_register_64bit(INTF_MAILBOX_fifo_ram_err);
	print_register_64bit(INTF_MAILBOX_table_ram_parity_err);
	print_register_64bit(INTF_MAILBOX_rxq_dma_wr_cnt);
	print_register_64bit(INTF_MAILBOX_rxq_dma_rd_cnt);
	print_register_64bit(INTF_MAILBOX_rxq_notify_cnt);
	print_register_64bit(INTF_MAILBOX_txq_notify_ent);
	print_register_64bit(INTF_MAILBOX_txq_dma_wr_cnt);
	print_register_64bit(INTF_MAILBOX_txq_dma_rd_cnt);

	print_color(GREEN, "----------------- CMDQ ---------------");
	print_register_64bit(INTF_CMDQ_init_status_reg);
	print_register_64bit(INTF_CMDQ_init_done_reg);
	print_register_64bit(INTF_CMDQ_int_status_reg_history);
	print_register_64bit(INTF_CMDQ_fifo_0_nempty);
	print_register_64bit(INTF_CMDQ_fifo_0_nafull);
	print_register_64bit(INTF_CMDQ_fifo_0_nfull);
	print_register_64bit(INTF_CMDQ_fifo_0_naempty);
	print_register_64bit(INTF_CMDQ_fifo_1_nempty);
	print_register_64bit(INTF_CMDQ_fifo_1_nafull);
	print_register_64bit(INTF_CMDQ_fifo_1_nfull);
	print_register_64bit(INTF_CMDQ_fifo_1_naempty);
	print_register_64bit(INTF_CMDQ_table_ram_err);
	print_register_64bit(INTF_CMDQ_table_ram_err_lock);
	print_register_64bit(INTF_CMDQ_fifo_ram_err);
	print_register_64bit(INTF_CMDQ_table_ram_parity_err);
	print_register_64bit(INTF_CMDQ_ease_tx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_iase_tx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_fse_tx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_pstat_tx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_tx2rx_info_fifo_cnt);
	print_register_64bit(INTF_CMDQ_dma_desc_rd_cnt);
	print_register_64bit(INTF_CMDQ_dma_data_rd_cnt);
	print_register_64bit(INTF_CMDQ_ease_rx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_iase_rx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_fse_rx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_pstat_rx_data_eoc_cnt);
	print_register_64bit(INTF_CMDQ_dma_desc_wr_cnt);
	print_register_64bit(INTF_CMDQ_dma_data_wr_cnt);

	print_color(GREEN, "----------------- MSGQ ---------------");
	print_register_64bit(INTF_MSGQ_int_status_reg);
	print_register_64bit(INTF_MSGQ_init_done_reg);
	print_register_64bit(INTF_MSGQ_int_status_reg_history);
	print_register_64bit(INTF_MSGQ_fifo_0_nempty);
	print_register_64bit(INTF_MSGQ_fifo_0_nafull);
	print_register_64bit(INTF_MSGQ_fifo_0_nfull);
	print_register_64bit(INTF_MSGQ_fifo_0_naempty);
	print_register_64bit(INTF_MSGQ_fifo_1_nempty);
	print_register_64bit(INTF_MSGQ_fifo_1_nafull);
	print_register_64bit(INTF_MSGQ_fifo_1_nfull);
	print_register_64bit(INTF_MSGQ_fifo_1_naempty);
	print_register_64bit(INTF_MSGQ_table_ram_err);
	print_register_64bit(INTF_MSGQ_table_ram_err_lock);
	print_register_64bit(INTF_MSGQ_fifo_ram_err);
	print_register_64bit(INTF_MSGQ_table_ram_parity_err);
	print_register_64bit(INTF_MSGQ_tstamp_msg_eoc_cnt);
	print_register_64bit(INTF_MSGQ_fse_msg_eoc_cnt);
	print_register_64bit(INTF_MSGQ_mse_msg_eoc_cnt);
	print_register_64bit(INTF_MSGQ_ntfy_msg_eoc_cnt);
	print_register_64bit(INTF_MSGQ_iacl_msg_eoc_cnt);
	print_register_64bit(INTF_MSGQ_eacl_msg_eoc_cnt);
	print_register_64bit(INTF_MSGQ_dma_wr_cnt);
	print_register_64bit(INTF_MSGQ_tstamp_wr_cnt);
	print_register_64bit(INTF_MSGQ_vdpa_wr_cnt);
	print_register_64bit(INTF_MSGQ_msgq_dma_wr_cnt);
	print_register_64bit(INTF_MSGQ_ctrlq_wr_cnt);

	print_color(GREEN, "----------------- TLPQ ---------------");
	print_register_64bit(INTF_TLPQ_int_status_reg);
	print_register_64bit(INTF_TLPQ_init_done_reg);
	print_register_64bit(INTF_TLPQ_int_status_reg_history);
	print_register_64bit(INTF_TLPQ_fifo_0_nempty);
	print_register_64bit(INTF_TLPQ_fifo_0_nafull);
	print_register_64bit(INTF_TLPQ_fifo_0_nfull);
	print_register_64bit(INTF_TLPQ_fifo_0_naempty);
	print_register_64bit(INTF_TLPQ_fifo_1_nempty);
	print_register_64bit(INTF_TLPQ_fifo_1_nafull);
	print_register_64bit(INTF_TLPQ_fifo_1_nfull);
	print_register_64bit(INTF_TLPQ_fifo_1_naempty);
	print_register_64bit(INTF_TLPQ_table_ram_err);
	print_register_64bit(INTF_TLPQ_table_ram_err_lock);
	print_register_64bit(INTF_TLPQ_fifo_ram_err);
	print_register_64bit(INTF_TLPQ_table_ram_parity_err);
	print_register_64bit(INTF_TLPQ_txq_eop_cnt);
	print_register_64bit(INTF_TLPQ_txq_sop_cnt);
	print_register_64bit(INTF_TLPQ_rxq_eop_cnt);
	print_register_64bit(INTF_TLPQ_rxq_sop_cnt);

	print_color(GREEN, "----------------- DMAQ ---------------");
	print_register_64bit(INTF_DMAQ_int_status_reg);
	print_register_64bit(INTF_DMAQ_init_done_reg);
	print_register_64bit(INTF_DMAQ_int_status_reg_history);
	print_register_64bit(INTF_DMAQ_fifo_0_nempty);
	print_register_64bit(INTF_DMAQ_fifo_0_nafull);
	print_register_64bit(INTF_DMAQ_fifo_0_nfull);
	print_register_64bit(INTF_DMAQ_fifo_0_naempty);
	print_register_64bit(INTF_DMAQ_fifo_1_nempty);
	print_register_64bit(INTF_DMAQ_fifo_1_nafull);
	print_register_64bit(INTF_DMAQ_fifo_1_nfull);
	print_register_64bit(INTF_DMAQ_fifo_1_naempty);
	print_register_64bit(INTF_DMAQ_table_ram_err);
	print_register_64bit(INTF_DMAQ_table_ram_err_lock);
	print_register_64bit(INTF_DMAQ_fifo_ram_err);
	print_register_64bit(INTF_DMAQ_table_ram_parity_err);
	print_register_64bit(INTF_DMAQ_desc_fifo_cnt);
	print_register_64bit(INTF_DMAQ_desc_info_fifo_cnt);
	print_register_64bit(INTF_DMAQ_dma_rd_cnt);
	print_register_64bit(INTF_DMAQ_data_fifo_cnt);
	print_register_64bit(INTF_DMAQ_data_info_fifo_cnt);
	print_register_64bit(INTF_DMAQ_dma_rd_data_cnt);
	print_register_64bit(INTF_DMAQ_debug_rpro_fsm_info);
	print_register_64bit(INTF_DMAQ_dma_wr_data_cnt);
	print_register_64bit(INTF_DMAQ_dma_wr_desc_cnt);
	print_register_64bit(INTF_DMAQ_debug_wpro_fsm_info);

	print_color(GREEN, "----------------- PMERGE ---------------");
	print_register_64bit(INTF_PMERGE_int_status_reg);
	print_register_64bit(INTF_PMERGE_init_done_reg);
	print_register_64bit(INTF_PMERGE_int_status_reg_history);
	print_register_64bit(INTF_PMERGE_fifo_0_nempty);
	print_register_64bit(INTF_PMERGE_fifo_0_nafull);
	print_register_64bit(INTF_PMERGE_fifo_0_nfull);
	print_register_64bit(INTF_PMERGE_fifo_0_naempty);
	print_register_64bit(INTF_PMERGE_fifo_1_nempty);
	print_register_64bit(INTF_PMERGE_fifo_1_nafull);
	print_register_64bit(INTF_PMERGE_fifo_1_nfull);
	print_register_64bit(INTF_PMERGE_fifo_1_naempty);
	print_register_64bit(INTF_PMERGE_table_ram_err);
	print_register_64bit(INTF_PMERGE_table_ram_err_lock);
	print_register_64bit(INTF_PMERGE_fifo_ram_err);
	print_register_64bit(INTF_PMERGE_table_ram_parity_err);
	print_register_64bit(INTF_PMERGE_xali_sop_cnt);
	print_register_64bit(INTF_PMERGE_xali_eop_cnt);
	print_register_64bit(INTF_PMERGE_trgt_sop_cnt);
	print_register_64bit(INTF_PMERGE_trgt_eop_cnt);

	print_color(GREEN, "----------------- PADPT ---------------");
	print_register_64bit(DPU_L1_BLK_PADPT_int_status_reg);
	print_register_64bit(DPU_L1_BLK_PADPT_int_status_reg_history);
	print_register_64bit(DPU_L1_BLK_PADPT_cfg_h4_3_2_1_0_is_switch);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_0_nempty);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_0_nafull);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_0_nfull);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_0_naempty);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_1_nempty);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_1_nafull);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_1_nfull);
	print_register_64bit(DPU_L1_BLK_PADPT_fifo_1_naempty);
}

void ethv2_display()
{
	print_color(YELLOW, "**************** ETH V2 (extended registers) ****************");

	print_color(GREEN, "----------------- ETH0 V2 ---------------");
	print_register_64bit(DPU_L1_BLK_ETH0_v2_int_status_reg);
	print_register_64bit(DPU_L1_BLK_ETH0_v2_fifo_0_nempty);
	print_register_64bit(DPU_L1_BLK_ETH0_v2_fifo_0_nafull);
	print_register_64bit(DPU_L1_BLK_ETH0_v2_fifo_0_nfull);
	print_register_64bit(DPU_L1_BLK_ETH0_v2_fifo_0_naempty);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pause_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pause_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p0_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p0_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p1_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p1_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p2_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p2_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p3_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p3_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p4_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p4_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p5_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p5_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p6_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p6_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p7_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_tx_pfc_p7_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pause_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pause_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p0_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p0_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p1_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p1_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p2_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p2_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p3_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p3_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p4_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p4_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p5_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p5_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p6_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p6_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p7_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_stat_rx_pfc_p7_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_debug_tx_mon_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_debug_rx_mon_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_debug_tx_sop_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_debug_tx_eop_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_debug_rx_sop_cnt);
	print_register_64bit(DPU_L1_BLK_ETH0_debug_rx_eop_cnt);

	print_color(GREEN, "----------------- ETH1 V2 ---------------");
	print_register_64bit(DPU_L1_BLK_ETH1_v2_int_status_reg);
	print_register_64bit(DPU_L1_BLK_ETH1_v2_fifo_0_nempty);
	print_register_64bit(DPU_L1_BLK_ETH1_v2_fifo_0_nafull);
	print_register_64bit(DPU_L1_BLK_ETH1_v2_fifo_0_nfull);
	print_register_64bit(DPU_L1_BLK_ETH1_v2_fifo_0_naempty);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pause_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pause_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p0_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p0_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p1_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p1_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p2_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p2_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p3_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p3_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p4_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p4_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p5_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p5_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p6_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p6_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p7_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_tx_pfc_p7_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pause_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pause_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p0_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p0_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p1_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p1_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p2_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p2_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p3_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p3_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p4_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p4_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p5_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p5_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p6_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p6_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p7_l_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_stat_rx_pfc_p7_h_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_debug_tx_mon_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_debug_rx_mon_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_debug_tx_sop_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_debug_tx_eop_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_debug_rx_sop_cnt);
	print_register_64bit(DPU_L1_BLK_ETH1_debug_rx_eop_cnt);
}

void pcie_display()
{
	print_color(YELLOW, "**************** PCIE ****************");

	print_color(GREEN, "----------------- PCIE_BREG ---------------");
	print_register_64bit(PCIE_BREG_init_done);
	print_register_64bit(PCIE_BREG_init_reg);
	print_register_64bit(PCIE_BREG_init_mask);
	print_register_64bit(PCIE_BREG_int_pcie);
	print_register_64bit(PCIE_BREG_int_pcie_mask);
	print_register_64bit(PCIE_BREG_work_mode);
	print_register_64bit(PCIE_BREG_start_mode);
	print_register_64bit(PCIE_BREG_upstream_mode);
	print_register_64bit(PCIE_BREG_dm_mode);
	print_register_64bit(PCIE_BREG_power_up);
	print_register_64bit(PCIE_BREG_phy_rst);
	print_register_64bit(PCIE_BREG_phy_lane_rst);
	print_register_64bit(PCIE_BREG_phy_apb_rst);
	print_register_64bit(PCIE_BREG_access);
	print_register_64bit(PCIE_BREG_phy_fw_mode);
	print_register_64bit(PCIE_BREG_int_reg_history);

	print_color(GREEN, "----------------- PCIE_DM0 ---------------");
	print_register_64bit(PCIE_DM0_link_status);
	print_register_64bit(PCIE_DM0_link_info);
	print_register_64bit(PCIE_DM0_link_ltssm);
	print_register_64bit(PCIE_DM0_link_ltssm_history0);
	print_register_64bit(PCIE_DM0_link_ltssm_history1);
	print_register_64bit(PCIE_DM0_link_ltssm_history2);
	print_register_64bit(PCIE_DM0_link_ltssm_history3);
	print_register_64bit(PCIE_DM0_link_ltssm_history4);
	print_register_64bit(PCIE_DM0_link_ltssm_history5);
	print_register_64bit(PCIE_DM0_link_ltssm_history6);
	print_register_64bit(PCIE_DM0_link_ltssm_history7);
	print_register_64bit(PCIE_DM0_fifo_nempty);
	print_register_64bit(PCIE_DM0_fifo_naempty);
	print_register_64bit(PCIE_DM0_fifo_nfull);
	print_register_64bit(PCIE_DM0_fifo_nafull);
	print_register_64bit(PCIE_DM0_fifo_nafull_history);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_tx_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_info_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_tx_info_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_data_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_tx_data_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_sop_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_tx_sop_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_eop_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_tx_eop_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_parity_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_ecrc_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_rxbuffer_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_invalid_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_op_nomatch_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_malformed_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_trgt_rx_drop_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_parity_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_err_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_info_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_tx_info_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_data_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_tx_data_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_1data_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_tx_1data_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_sop_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_tx_sop_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_rx_eop_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_tx_eop_cnt);
	print_register_64bit(PCIE_DM0_adapt_xali_drop_cnt);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_vld_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_tx_vld_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_nvld_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_tx_nvld_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_nrdy_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_tx_nrdy_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_waitp_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_waitnp_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_waitcpl_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_tlp_rd_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_rx_tlp_wr_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_tx_tlp_rd_tms);
	print_register_64bit(PCIE_DM0_adapt_ntv_tx_tlp_wr_tms);

	print_color(GREEN, "----------------- PCIE_DM1 ---------------");
	print_register_64bit(PCIE_DM1_link_status);
	print_register_64bit(PCIE_DM1_link_info);
	print_register_64bit(PCIE_DM1_link_ltssm);
	print_register_64bit(PCIE_DM1_link_ltssm_history0);
	print_register_64bit(PCIE_DM1_link_ltssm_history1);
	print_register_64bit(PCIE_DM1_link_ltssm_history2);
	print_register_64bit(PCIE_DM1_link_ltssm_history3);
	print_register_64bit(PCIE_DM1_link_ltssm_history4);
	print_register_64bit(PCIE_DM1_link_ltssm_history5);
	print_register_64bit(PCIE_DM1_link_ltssm_history6);
	print_register_64bit(PCIE_DM1_link_ltssm_history7);
	print_register_64bit(PCIE_DM1_fifo_nempty);
	print_register_64bit(PCIE_DM1_fifo_naempty);
	print_register_64bit(PCIE_DM1_fifo_nfull);
	print_register_64bit(PCIE_DM1_fifo_nafull);
	print_register_64bit(PCIE_DM1_fifo_nafull_history);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_tx_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_info_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_tx_info_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_data_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_tx_data_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_sop_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_tx_sop_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_eop_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_tx_eop_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_parity_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_ecrc_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_rxbuffer_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_invalid_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_op_nomatch_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_malformed_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_trgt_rx_drop_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_parity_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_err_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_info_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_tx_info_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_data_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_tx_data_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_1data_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_tx_1data_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_sop_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_tx_sop_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_rx_eop_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_tx_eop_cnt);
	print_register_64bit(PCIE_DM1_adapt_xali_drop_cnt);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_vld_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_tx_vld_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_nvld_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_tx_nvld_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_nrdy_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_tx_nrdy_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_waitp_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_waitnp_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_waitcpl_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_tlp_rd_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_rx_tlp_wr_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_tx_tlp_rd_tms);
	print_register_64bit(PCIE_DM1_adapt_ntv_tx_tlp_wr_tms);
}

void psw_display()
{
	print_color(YELLOW, "**************** PSW (PCIe Switch) ****************");

	print_color(GREEN, "----------------- PSW_BREG ---------------");
	print_register_64bit(PSW_BREG_client_init_done);
	print_register_64bit(PSW_BREG_client_int_reg);
	print_register_64bit(PSW_BREG_client_int_mask_reg);
	print_register_64bit(PSW_BREG_client_status_reg);
	print_register_64bit(PSW_BREG_cfg_psw_mode);

	print_color(GREEN, "----------------- PSW_IPROUSP ---------------");
	print_register_64bit(PSW_IPROUSP_int_status_reg);
	print_register_64bit(PSW_IPROUSP_int_mask_reg);
	print_register_64bit(PSW_IPROUSP_init_done);
	print_register_64bit(PSW_IPROUSP_int_status_reg_his);
	print_register_64bit(PSW_IPROUSP_dsp0_info_fifo_cnt);
	print_register_64bit(PSW_IPROUSP_dsp1_info_fifo_cnt);
	print_register_64bit(PSW_IPROUSP_dsp0_data_fifo_cnt);
	print_register_64bit(PSW_IPROUSP_dsp1_data_fifo_cnt);
	print_register_64bit(PSW_IPROUSP_dsp0_data_sop_cnt);
	print_register_64bit(PSW_IPROUSP_dsp1_data_sop_cnt);
	print_register_64bit(PSW_IPROUSP_dsp0_data_eop_cnt);
	print_register_64bit(PSW_IPROUSP_dsp1_data_eop_cnt);
	print_register_64bit(PSW_IPROUSP_usp_info_fifo_cnt);
	print_register_64bit(PSW_IPROUSP_usp_data_fifo_cnt);
	print_register_64bit(PSW_IPROUSP_usp_data_sop_cnt);
	print_register_64bit(PSW_IPROUSP_usp_data_eop_cnt);
	print_register_64bit(PSW_IPROUSP_tot_tlp_num_cnt);

	print_color(GREEN, "----------------- PSW_IPRODSP0 ---------------");
	print_register_64bit(PSW_IPRODSP0_int_status_reg);
	print_register_64bit(PSW_IPRODSP0_int_mask_reg);
	print_register_64bit(PSW_IPRODSP0_init_done);
	print_register_64bit(PSW_IPRODSP0_int_status_reg_his);
	print_register_64bit(PSW_IPRODSP0_dsp0_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp1_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp0_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp1_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp0_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp1_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp0_data_eop_cnt);
	print_register_64bit(PSW_IPRODSP0_dsp1_data_eop_cnt);
	print_register_64bit(PSW_IPRODSP0_trgt_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_trgt_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_trgt_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP0_trgt_data_eop_cnt);
	print_register_64bit(PSW_IPRODSP0_usp_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_usp_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP0_usp_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP0_usp_data_eop_cnt);

	print_color(GREEN, "----------------- PSW_IPRODSP1 ---------------");
	print_register_64bit(PSW_IPRODSP1_int_status_reg);
	print_register_64bit(PSW_IPRODSP1_int_mask_reg);
	print_register_64bit(PSW_IPRODSP1_init_done);
	print_register_64bit(PSW_IPRODSP1_int_status_reg_his);
	print_register_64bit(PSW_IPRODSP1_dsp0_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp1_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp0_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp1_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp0_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp1_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp0_data_eop_cnt);
	print_register_64bit(PSW_IPRODSP1_dsp1_data_eop_cnt);
	print_register_64bit(PSW_IPRODSP1_trgt_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_trgt_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_trgt_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP1_trgt_data_eop_cnt);
	print_register_64bit(PSW_IPRODSP1_usp_info_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_usp_data_fifo_cnt);
	print_register_64bit(PSW_IPRODSP1_usp_data_sop_cnt);
	print_register_64bit(PSW_IPRODSP1_usp_data_eop_cnt);

	print_color(GREEN, "----------------- PSW_MUXUSP ---------------");
	print_register_64bit(PSW_MUXUSP_int_status_reg);
	print_register_64bit(PSW_MUXUSP_int_mask_reg);
	print_register_64bit(PSW_MUXUSP_init_done);
	print_register_64bit(PSW_MUXUSP_init_status_reg_his);
	print_register_64bit(PSW_MUXUSP_cfg_fc_cplh);
	print_register_64bit(PSW_MUXUSP_cfg_fc_cpld);
	print_register_64bit(PSW_MUXUSP_cfg_fc_ph);
	print_register_64bit(PSW_MUXUSP_cfg_fc_pd);
	print_register_64bit(PSW_MUXUSP_cfg_fc_nph);
	print_register_64bit(PSW_MUXUSP_cfg_fc_npd);
	print_register_64bit(PSW_MUXUSP_sel_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_sel_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_usp_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_dsp0_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_dsp1_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_usp_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_dsp0_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_dsp1_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_usp_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_dsp0_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_dsp1_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXUSP_usp_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_dsp0_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_dsp1_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXUSP_pcie_link);

	print_color(GREEN, "----------------- PSW_MUXDSP0 ---------------");
	print_register_64bit(PSW_MUXDSP0_int_status_reg);
	print_register_64bit(PSW_MUXDSP0_int_mask_reg);
	print_register_64bit(PSW_MUXDSP0_init_done);
	print_register_64bit(PSW_MUXDSP0_init_status_reg_his);
	print_register_64bit(PSW_MUXDSP0_sel_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_sel_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_usp_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp0_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp1_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_usp_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp0_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp1_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_usp_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp0_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp1_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP0_usp_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp0_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_dsp1_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP0_pcie_link);

	print_color(GREEN, "----------------- PSW_MUXDSP1 ---------------");
	print_register_64bit(PSW_MUXDSP1_int_status_reg);
	print_register_64bit(PSW_MUXDSP1_int_mask_reg);
	print_register_64bit(PSW_MUXDSP1_init_done);
	print_register_64bit(PSW_MUXDSP1_init_status_reg_his);
	print_register_64bit(PSW_MUXDSP1_cfg_fc_cplh);
	print_register_64bit(PSW_MUXDSP1_cfg_fc_cpld);
	print_register_64bit(PSW_MUXDSP1_cfg_fc_ph);
	print_register_64bit(PSW_MUXDSP1_cfg_fc_pd);
	print_register_64bit(PSW_MUXDSP1_cfg_fc_nph);
	print_register_64bit(PSW_MUXDSP1_cfg_fc_npd);
	print_register_64bit(PSW_MUXDSP1_sel_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_sel_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_usp_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp0_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp1_info_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_usp_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp0_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp1_info_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_usp_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp0_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp1_data_fifo_wr_cnt);
	print_register_64bit(PSW_MUXDSP1_usp_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp0_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_dsp1_data_fifo_rd_cnt);
	print_register_64bit(PSW_MUXDSP1_pcie_link);

	print_color(GREEN, "----------------- PSW_PSWCFG ---------------");
	print_register_64bit(PSW_PSWCFG_int_status_reg_his);
	print_register_64bit(PSW_PSWCFG_int_status_reg);
	print_register_64bit(PSW_PSWCFG_init_mask);
	print_register_64bit(PSW_PSWCFG_init_done);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_device_id);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_vendor_id);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_bus_num);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_pci_addr);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_prefbase_l);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_prefbase_h);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_preflimit_l);
	print_register_64bit(PSW_PSWCFG_cfg_dsp0_preflimit_h);
	print_register_64bit(PSW_PSWCFG_cfg_space_switch);
	print_register_64bit(PSW_PSWCFG_cfg_usp_bus_num);
	print_register_64bit(PSW_PSWCFG_self_sim_dsp0_ep);
	print_register_64bit(PSW_PSWCFG_usp_bus_num);
	print_register_64bit(PSW_PSWCFG_dsp0_bus_num);
	print_register_64bit(PSW_PSWCFG_dsp1_bus_num);
	print_register_64bit(PSW_PSWCFG_dsp0_mem_addr);
	print_register_64bit(PSW_PSWCFG_dsp1_mem_addr);
	print_register_64bit(PSW_PSWCFG_dsp0_prefbase_l);
	print_register_64bit(PSW_PSWCFG_dsp1_prefbase_l);
	print_register_64bit(PSW_PSWCFG_dsp0_prefbase_h);
	print_register_64bit(PSW_PSWCFG_dsp1_prefbase_h);
	print_register_64bit(PSW_PSWCFG_dsp0_preflimit_l);
	print_register_64bit(PSW_PSWCFG_dsp1_preflimit_l);
	print_register_64bit(PSW_PSWCFG_dsp0_preflimit_h);
	print_register_64bit(PSW_PSWCFG_dsp1_preflimit_h);
	print_register_64bit(PSW_PSWCFG_user_link);
}

void eth_display()
{
	uint64_t d64 = 0;
	print_color(YELLOW, "**************** ETH ****************");

	/* 1. 读取并解析ETH口总数 */
	d64 = read_reg(ETH_SPEC_BASE, 0, 31);
	const uint8_t group0_cnt = (d64 & 0xF);		  // 提取0-3bit[1,4]
	const uint8_t group1_cnt = (d64 >> 16) & 0xF; // 提取16-19bit[4,7]

	const uint8_t total_eth = group0_cnt + group1_cnt;
	printf("Total ETH Ports: \033[;;34m[%d]\033[0m\n", total_eth);

	/* 2. 遍历所有ETH口检查转发模式 */
	for (uint8_t i = 0; i < total_eth; ++i)
	{
		d64 = read_reg(IPRO_ETH_IPORT_TABLE + (ETH_IPORT_TABLE_SIZE * i), 24, 24);
		if (d64)
		{
			printf("ETH\033[;;34m[%d]\033[0mFABRIC_MODE : Bypass Mode\n", i);
		}
		else
		{
			printf("ETH\033[;;34m[%d]\033[0mFABRIC_MODE : MAC Forwarding\n", i);
		}
	}

#if 1
	// printf("\033[;;33m%s\033[0m\n","****************INTF****************");
	for (int i = 0; i < 2; i++) {
		printf("\033[;;33m%s%d%s\033[0m\n","****************ETH", i, "****************");
		// printf("-----------------ETH0---------------\n");
		d64 = read_reg(ETH_LINK_STATUS_REG, i, i);
		if(d64)
			printf("eth%d link up\n", i);
		else
			printf("eth%d link down\n", i);

		if (!i) {
			d64 = read_reg(ETH0_RX_L_CNT, 0, 31);
			printf("ETH0_RX_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_RX_H_CNT, 0, 31);
			printf("ETH0_RX_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_RX_GOOD_I_CNT, 0, 31);
			printf("ETH0_RX_GOOD_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_RX_GOOD_H_CNT, 0, 31);
			printf("ETH0_RX_GOOD_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_RX_FCS_ERR_I_CNT, 0, 31);
			printf("ETH0_rx_fcs_err_L_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_RX_FCS_ERR_H_CNT, 0, 31);
			printf("ETH0_rx_fcs_err_H_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_TX_I_CNT, 0, 31);
			printf("ETH0_TX_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_TX_H_CNT, 0, 31);
			printf("ETH0_TX_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_TX_GOOD_I_CNT, 0, 31);
			printf("ETH0_TX_GOOD_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_TX_GOOD_H_CNT, 0, 31);
			printf("ETH0_TX_GOOD_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_TX_FCS_ERR_I_CNT, 0, 31);
			printf("ETH0_tx_fcs_err_L_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_TX_FCS_ERR_H_CNT, 0, 31);
			printf("ETH0_tx_fcs_err_H_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_STAT_CORE_SPEED, 0, 0);
			printf("ETH0_STAT_CORE_SPEED_REGNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH0_STAT_CORE_SPEED_REG, 0, 0);
		} else {
			d64 = read_reg(ETH1_RX_L_CNT, 0, 31);
			printf("ETH1_RX_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_RX_H_CNT, 0, 31);
			printf("ETH1_RX_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_RX_GOOD_I_CNT, 0, 31);
			printf("ETH1_RX_GOOD_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_RX_GOOD_H_CNT, 0, 31);
			printf("ETH1_RX_GOOD_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_RX_FCS_ERR_I_CNT, 0, 31);
			printf("ETH1_rx_fcs_err_L_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_RX_FCS_ERR_H_CNT, 0, 31);
			printf("ETH1_rx_fcs_err_H_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_TX_I_CNT, 0, 31);
			printf("ETH1_TX_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_TX_H_CNT, 0, 31);
			printf("ETH1_TX_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_TX_GOOD_I_CNT, 0, 31);
			printf("ETH1_TX_GOOD_L_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_TX_GOOD_H_CNT, 0, 31);
			printf("ETH1_TX_GOOD_H_CNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_TX_FCS_ERR_I_CNT, 0, 31);
			printf("ETH1_tx_fcs_err_L_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_TX_FCS_ERR_H_CNT, 0, 31);
			printf("ETH1_tx_fcs_err_H_cnt :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_STAT_CORE_SPEED, 0, 0);
			printf("ETH1_STAT_CORE_SPEED_REGNT :\033[;;34m[%ld]\033[0m\n", d64);
			d64 = read_reg(ETH1_STAT_CORE_SPEED_REG, 0, 0);
		}
		printf("%5score speed:", " ");
		if (!d64)
			printf("25G\n");
		else
			printf("10G\n");
		//if(!mode || mode == 2)
		for(int j = 0; eth_entry_keys[j] != NULL; j++){
			d64 = read_reg(DPU_L1_BLK_ETH0_BASE + i * 0x40000 + eth_reg_offset[j], 0, 63);
			printf("%s:\033[;;34m[%ld]\033[0m\n", eth_entry_keys[j], d64);
		}
	}
#endif
}

void dprx_display()
{
	uint64_t d64 = 0;

	print_color(YELLOW,"****************DPRX****************");
	print_color(GREEN, "-----------------PRMUX---------------");
	d64 = read_reg(PRMUX_PRO_INT_STATUS_REG, 0, 31);
	print_register("PRMUX_PRO_INT_STATUS_REG", d64);
	d64 = read_reg(PRMUX_ETH0_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH0_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH1_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH1_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH2_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH2_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH3_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH3_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH4_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH4_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH5_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH5_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH6_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH6_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ETH7_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_ETH7_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_CPU0_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_CPU0_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_CPU1_WPRO_DEBUG_CNT_REG_VECTOR, 0, 31);
	print_register("PRMUX_CPU1_WPRO_DEBUG_CNT_REG_VECTOR", d64);
	d64 = read_reg(PRMUX_ARBITER_SEL_CNT_REG, 0, 31);
	print_register("PRMUX_ARBITER_SEL_CNT_REG", d64);
	d64 = read_reg(PRMUX_ARBITER_W_CNT_REG, 0, 31);
	print_register("PRMUX_ARBITER_W_CNT_REG", d64);
	d64 = read_reg(PRMUX_ARBITER_R_CNT_REG, 0, 31);
	print_register("PRMUX_ARBITER_R_CNT_REG", d64);

	print_color(GREEN, "-----------------PSTORE---------------");
	d64 = read_reg(PSTORE_PRO_INT, 0, 31);
	print_register("PSTORE_PRO_INT", d64);
	d64 = read_reg(PSTORE_PRO_SOP_CNT_REG, 0, 31);
	print_register("PSTORE_PRO_SOP_CNT_REG", d64);
	d64 = read_reg(PSTORE_PRO_EOP_CNT_REG, 0, 31);
	print_register("PSTORE_PRO_EOP_CNT_REG", d64);
	d64 = read_reg(PSTORE_PRO_ICNT_REG, 0, 31);
	print_register("PSTORE_PRO_ICNT_REG", d64);
	d64 = read_reg(PSTORE_PRO_OCNT_REG, 0, 31);
	print_register("PSTORE_PRO_OCNT_REG", d64);
	d64 = read_reg(PSTORE_PRO_PTR_SUM_REG, 0, 31);
	print_register("PSTORE_PRO_PTR_SUM_REG", d64);
	d64 = read_reg(PSTORE_PRO_LENGTH_SUM_REG, 0, 31);
	print_register("PSTORE_PRO_LENGTH_SUM_REG", d64);
	d64 = read_reg(PSTORE_PRO_PTYPE_CNT0_REG, 0, 31);
	print_register("PSTORE_PRO_PTYPE_CNT0_REG", d64);
	d64 = read_reg(PSTORE_PRO_PTYPE_CNT1_REG, 0, 31);
	print_register("PSTORE_PRO_PTYPE_CNT1_REG", d64);

	print_color(GREEN, "-----------------PBUFFER---------------");
	d64 = read_reg(PBUFFER_PRO_INT_STATUS_REG, 0, 31);
	print_register("PBUFFER_PRO_INT_STATUS_REG", d64);
	print_color(GREEN, "-----------------FBM---------------");
	d64 = read_reg(FBM_PRO_INT_STATUS_REG, 0, 31);
	print_register("FBM_PRO_INT_STATUS_REG", d64);
}

void dptx_display()
{
	uint64_t d64 = 0;

	print_color(YELLOW,"****************DPTX****************");
	print_color(GREEN, "-----------------PQM---------------");
	d64 = read_reg(PQM_INT_STATUS_REG, 0, 31);
	print_register("PQM_INT_STATUS_REG", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG0, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG0", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG1, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG1", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG2, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG2", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG3, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG3", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG4, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG4", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG5, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG5", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG6, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG6", d64);
	d64 = read_reg(PQM_INUQE_CFG_DFX_REG7, 0, 31);
	print_register("PQM_INUQE_CFG_DFX_REG7", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG8, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG8", d64);
	d64 = read_reg(PQM_INQUE_CFG_DFX_REG9, 0, 31);
	print_register("PQM_INQUE_CFG_DFX_REG9", d64);
	d64 = read_reg(PQM_CFG_RAM_ERR_LOCK_REG, 0, 31);
	print_register("PQM_CFG_RAM_ERR_LOCK_REG", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG0, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG0", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG1, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG1", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG2, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG2", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG3, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG3", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG4, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG4", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG5, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG5", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG6, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG6", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG24, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG24", d64);
	d64 = read_reg(PQM_ADMQUE_CFG_DFX_REG25, 0, 31);
	print_register("PQM_ADMQUE_CFG_DFX_REG25", d64);
	d64 = read_reg(PQM_QUE_CNT_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PQM_QUE_CNT_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PQM_QUE_BUFFER_CNT_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PQM_QUE_BUFFER_CNT_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PQM_QUE_BUFFER_CNT_COPY_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PQM_QUE_BUFFER_CNT_COPY_RAM_ERR_DEBUG_REG", d64);

	print_color(GREEN, "-----------------PSCH---------------");
	d64 = read_reg(PSCH_INT_STATUS_REG, 0, 31);
	print_register("PSCH_INT_STATUS_REG", d64);
	d64 = read_reg(PSCH_PRO1_CFG_DFX_REG0, 0, 31);
	print_register("PSCH_PRO1_CFG_DFX_REG0", d64);
	d64 = read_reg(PSCH_PRO1_CFG_DFX_REG1, 0, 31);
	print_register("PSCH_PRO1_CFG_DFX_REG1", d64);
	d64 = read_reg(PSCH_PRO1_CFG_DFX_REG2, 0, 31);
	print_register("PSCH_PRO1_CFG_DFX_REG2", d64);
	d64 = read_reg(PSCH_PRO1_CFG_DFX_REG3, 0, 31);
	print_register("PSCH_PRO1_CFG_DFX_REG3", d64);
	d64 = read_reg(PSCH_PRO1_CFG_DFX_REG4, 0, 31);
	print_register("PSCH_PRO1_CFG_DFX_REG4", d64);
	d64 = read_reg(PSCH_DEADLOCK_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PSCH_DEADLOCK_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PSCH_PRO2_MULTI_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PSCH_PRO2_MULTI_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PSCH_PRO2_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PSCH_PRO2_INFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PSCH_PRO2_BRANCH_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PSCH_PRO2_BRANCH_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_WOVERFLOW, 0, 31);
	print_register("PSCH_PRO2_FIFO_WOVERFLOW", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_ROVERFLOW, 0, 31);
	print_register("PSCH_PRO2_FIFO_ROVERFLOW", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_ERRSIDE, 0, 31);
	print_register("PSCH_PRO2_FIFO_ERRSIDE", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_WERR, 0, 31);
	print_register("PSCH_PRO2_FIFO_WERR", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_RERR, 0, 31);
	print_register("PSCH_PRO2_FIFO_RERR", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_NFULL, 0, 31);
	print_register("PSCH_PRO2_FIFO_NFULL", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_NAFULL, 0, 31);
	print_register("PSCH_PRO2_FIFO_NAFULL", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_NEMPTY, 0, 31);
	print_register("PSCH_PRO2_FIFO_NEMPTY", d64);
	d64 = read_reg(PSCH_PRO2_FIFO_NAEMPTY, 0, 31);
	print_register("PSCH_PRO2_FIFO_NAEMPTY", d64);
	d64 = read_reg(PSCH_PRO2_RAM_ERR_LOCK, 0, 31);
	print_register("PSCH_PRO2_RAM_ERR_LOCK", d64);
	d64 = read_reg(PSCH_PRO2_PKT_LEN_CNT, 0, 31);
	print_register("PSCH_PRO2_PKT_LEN_CNT", d64);
	d64 = read_reg(PSCH_PRO2_PKT_HEAD_PNTR_CNT, 0, 31);
	print_register("PSCH_PRO2_PKT_HEAD_PNTR_CNT", d64);
	d64 = read_reg(PSCH_PRO2_IN_PKT_CNT, 0, 31);
	print_register("PSCH_PRO2_IN_PKT_CNT", d64);
	d64 = read_reg(PSCH_PRO2_OUT_PKT_CNT, 0, 31);
	print_register("PSCH_PRO2_OUT_PKT_CNT", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH0, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH1, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH2, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH3, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH4, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH5, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH6, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_ETH7, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_RDMA, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_RDMA", d64);
	d64 = read_reg(PSCH_DFIFO_WCNT_VECTOR_VIO, 0, 31);
	print_register("PSCH_DFIFO_WCNT_VECTOR_VIO", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH0, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH1, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH2, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH3, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH4, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH5, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH6, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_ETH7, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_RDMA, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_RDMA", d64);
	d64 = read_reg(PSCH_FLY_DATA_CNT_VECTOR_VIO, 0, 31);
	print_register("PSCH_FLY_DATA_CNT_VECTOR_VIO", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH0, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH1, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH2, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH3, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH4, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH5, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH6, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_ETH7, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_RDMA, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_RDMA", d64);
	d64 = read_reg(PSCH_FLY_PKT_CNT_VECTOR_VIO, 0, 31);
	print_register("PSCH_FLY_PKT_CNT_VECTOR_VIO", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH0, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH1, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH2, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH3, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH4, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH5, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH6, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH7, 0, 31);
	print_register("PSCH_TX_TIME_RAM_ERR_DEBUG_REG_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH0, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH1, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH2, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH3, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH4, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH5, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH6, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH7, 0, 31);
	print_register("PSCH_TX_FIFO_RAM_ERR_DEBUG_REG_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH0, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH1, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH2, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH3, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH4, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH5, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH6, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_TX_DEBUG_REG_VECTOR_ETH7, 0, 31);
	print_register("PSCH_TX_DEBUG_REG_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH0, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH1, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH2, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH3, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH4, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH5, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH6, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_RX_DEBUG_REG_VECTOR_ETH7, 0, 31);
	print_register("PSCH_RX_DEBUG_REG_VECTOR_ETH7", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH0, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH0", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH1, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH1", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH2, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH2", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH3, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH3", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH4, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH4", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH5, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH5", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH6, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH6", d64);
	d64 = read_reg(PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH7, 0, 31);
	print_register("PSCH_RX_RAM_ERR_DEBUG_REG_VECTOR_ETH7", d64);

	print_color(GREEN, "-----------------PMODIFIER---------------");
	d64 = read_reg(PMODIFIER_INT_STATUS_REG, 0, 31);
	print_register("PMODIFIER_INT_STATUS_REG", d64);
	d64 = read_reg(PMODIFIER_FIFO_NAFULL, 0, 31);
	print_register("PMODIFIER_FIFO_NAFULL", d64);
	d64 = read_reg(PMODIFIER_FIFO_NFULL, 0, 31);
	print_register("PMODIFIER_FIFO_NFULL", d64);
	d64 = read_reg(PMODIFIER_FIFO_NAEMPTY, 0, 31);
	print_register("PMODIFIER_FIFO_NAEMPTY", d64);
	d64 = read_reg(PMODIFIER_FIFO_NEMPTY, 0, 31);
	print_register("PMODIFIER_FIFO_NEMPTY", d64);
	d64 = read_reg(PMODIFIER_FIFO_WOVERFLOW, 0, 31);
	print_register("PMODIFIER_FIFO_WOVERFLOW", d64);
	d64 = read_reg(PMODIFIER_FIFO_ROVERFLOW, 0, 31);
	print_register("PMODIFIER_FIFO_ROVERFLOW", d64);
	d64 = read_reg(PMODIFIER_FIFO_ERRSIDE, 0, 31);
	print_register("PMODIFIER_FIFO_ERRSIDE", d64);
	d64 = read_reg(PMODIFIER_FIFO_WERR, 0, 31);
	print_register("PMODIFIER_FIFO_WERR", d64);
	d64 = read_reg(PMODIFIER_FIFO_RERR, 0, 31);
	print_register("PMODIFIER_FIFO_RERR", d64);
	d64 = read_reg(PMODIFIER_FIFO_RAM_ERR, 0, 31);
	print_register("PMODIFIER_FIFO_RAM_ERR", d64);
	d64 = read_reg(PMODIFIER_TNL_L2_TABLE_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_TNL_L2_TABLE_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_TNL_L3_TABLE_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_TNL_L3_TABLE_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_TNL_L5_TABLE_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_TNL_L5_TABLE_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_MIR_L2_TABLE_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_MIR_L2_TABLE_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_MIR_L3_TABLE_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_MIR_L3_TABLE_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_MIR_L5_TABLE_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_MIR_L5_TABLE_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_OTNL_CFG_DFX_REG0, 0, 31);
	print_register("PMODIFIER_OTNL_CFG_DFX_REG0", d64);
	d64 = read_reg(PMODIFIER_OTNL_CFG_DFX_REG1, 0, 31);
	print_register("PMODIFIER_OTNL_CFG_DFX_REG1", d64);
	d64 = read_reg(PMODIFIER_OTNL_CFG_DFX_REG2, 0, 31);
	print_register("PMODIFIER_OTNL_CFG_DFX_REG2", d64);
	d64 = read_reg(PMODIFIER_OTNL_I_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_OTNL_I_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_OTNL_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_OTNL_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_OTNL_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_OTNL_INFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_NAT_CFG_DFX_REG0, 0, 31);
	print_register("PMODIFIER_NAT_CFG_DFX_REG0", d64);
	d64 = read_reg(PMODIFIER_NAT_CFG_DFX_REG1, 0, 31);
	print_register("PMODIFIER_NAT_CFG_DFX_REG1", d64);
	d64 = read_reg(PMODIFIER_NAT_CFG_DFX_REG2, 0, 31);
	print_register("PMODIFIER_NAT_CFG_DFX_REG2", d64);
	d64 = read_reg(PMODIFIER_NAT_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_NAT_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_NAT_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_NAT_INFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_ENCAP_CFG_DFX_REG0, 0, 31);
	print_register("PMODIFIER_ENCAP_CFG_DFX_REG0", d64);
	d64 = read_reg(PMODIFIER_ENCAP_CFG_DFX_REG1, 0, 31);
	print_register("PMODIFIER_ENCAP_CFG_DFX_REG1", d64);
	d64 = read_reg(PMODIFIER_ENCAP_CFG_DFX_REG2, 0, 31);
	print_register("PMODIFIER_ENCAP_CFG_DFX_REG2", d64);
	d64 = read_reg(PMODIFIER_ENCAP_TNL_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_ENCAP_TNL_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_ENCAP_TNL_LEN_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_ENCAP_TNL_LEN_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_ENCAP_MIR_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_ENCAP_MIR_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_ENCAP_MIR_LEN_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_ENCAP_MIR_LEN_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_VLAN_CFG_DFX_REG0, 0, 31);
	print_register("PMODIFIER_VLAN_CFG_DFX_REG0", d64);
	d64 = read_reg(PMODIFIER_VLAN_CFG_DFX_REG1, 0, 31);
	print_register("PMODIFIER_VLAN_CFG_DFX_REG1", d64);
	d64 = read_reg(PMODIFIER_VLAN_CFG_DFX_REG2, 0, 31);
	print_register("PMODIFIER_VLAN_CFG_DFX_REG2", d64);
	d64 = read_reg(PMODIFIER_VLAN_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_VLAN_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_VLAN_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_VLAN_INFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_VLAN_TNLIDX_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_VLAN_TNLIDX_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_PACK_CFG_DFX_REG0, 0, 31);
	print_register("PMODIFIER_PACK_CFG_DFX_REG0", d64);
	d64 = read_reg(PMODIFIER_PACK_CFG_DFX_REG1, 0, 31);
	print_register("PMODIFIER_PACK_CFG_DFX_REG1", d64);
	d64 = read_reg(PMODIFIER_PACK_CFG_DFX_REG2, 0, 31);
	print_register("PMODIFIER_PACK_CFG_DFX_REG2", d64);
	d64 = read_reg(PMODIFIER_PACK_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_PACK_DATA_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PMODIFIER_PACK_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PMODIFIER_PACK_INFO_RAM_ERR_DEBUG_REG", d64);

	print_color(GREEN, "-----------------PDMUX---------------");
	d64 = read_reg(PDMUX_INT_STATUS_REG, 0, 31);
	print_register("PDMUX_INT_STATUS_REG", d64);
	d64 = read_reg(PDMUX_PRO_CFG_DFX_REG0, 0, 31);
	print_register("PDMUX_PRO_CFG_DFX_REG0", d64);
	d64 = read_reg(PDMUX_RDMA_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PDMUX_RDMA_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PDMUX_RDMA_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PDMUX_RDMA_DATA_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PDMUX_I_PKT_INFO_CNT0, 0, 31);
	print_register("PDMUX_I_PKT_INFO_CNT0", d64);
	d64 = read_reg(PDMUX_I_PKT_DATA_CNT0, 0, 31);
	print_register("PDMUX_I_PKT_DATA_CNT0", d64);
	d64 = read_reg(PDMUX_I_PKT_INFO_CNT1, 0, 31);
	print_register("PDMUX_I_PKT_INFO_CNT1", d64);
	d64 = read_reg(PDMUX_I_PKT_DATA_CNT1, 0, 31);
	print_register("PDMUX_I_PKT_DATA_CNT1", d64);
	d64 = read_reg(PDMUX_O_RDMA_PKT_INFO_CNT, 0, 31);
	print_register("PDMUX_O_RDMA_PKT_INFO_CNT", d64);
	d64 = read_reg(PDMUX_O_RDMA_PKT_DATA_CNT, 0, 31);
	print_register("PDMUX_O_RDMA_PKT_DATA_CNT", d64);
	d64 = read_reg(PDMUX_O_VIO_PKT_INFO_CNT, 0, 31);
	print_register("PDMUX_O_VIO_PKT_INFO_CNT", d64);
	d64 = read_reg(PDMUX_O_VIO_PKT_DATA_CNT, 0, 31);
	print_register("PDMUX_O_VIO_PKT_DATA_CNT", d64);
	d64 = read_reg(PDMUX_O_ETH0_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH0_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH1_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH1_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH2_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH2_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH3_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH3_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH4_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH4_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH5_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH5_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH6_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH6_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH7_PKT_INFO_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH7_PKT_INFO_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH0_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH0_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH1_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH1_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH2_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH2_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH3_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH3_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH4_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH4_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH5_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH5_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH6_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH6_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_O_ETH7_PKT_DATA_CNT_VECTOR, 0, 31);
	print_register("PDMUX_O_ETH7_PKT_DATA_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH0_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH0_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH1_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH1_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH2_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH2_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH3_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH3_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH4_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH4_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH5_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH5_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH6_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH6_PAUSE_CNT_VECTOR", d64);
	d64 = read_reg(PDMUX_SEND_ETH7_PAUSE_CNT_VECTOR, 0, 31);
	print_register("PDMUX_SEND_ETH7_PAUSE_CNT_VECTOR", d64);

	//	print_color(GREEN,"-----------------SHAPING---------------");
	//	print_color(GREEN,"-----------------PSTAT---------------");
}

void vrx_display()
{
	uint64_t d64 = 0;

	/*vrx*/
	print_color(YELLOW,"****************VRX****************");
	d64 = read_reg(VRX_INT_STATUS, 0, 31);
	print_register("VRX_INT_STATUS", d64);
	d64 = read_reg(VRX_FIFO_NAFULL, 0, 31);
	print_register("VRX_FIFO_NAFULL", d64);
	d64 = read_reg(VRX_FIFO_NFULL, 0, 31);
	print_register("VRX_FIFO_NFULL", d64);
	d64 = read_reg(VRX_FIFO_NAEMPTY, 0, 31);
	print_register("VRX_FIFO_NAEMPTY", d64);
	d64 = read_reg(VRX_FIFO_NEMPTY, 0, 31);
	print_register("VRX_FIFO_NEMPTY", d64);
	d64 = read_reg(VRX_FIFO_WOVERFLOW, 0, 31);
	print_register("VRX_FIFO_WOVERFLOW", d64);
	d64 = read_reg(VRX_FIFO_ROVERFLOW, 0, 31);
	print_register("VRX_FIFO_ROVERFLOW", d64);
	d64 = read_reg(VRX_FIFO_ERRSIDE, 0, 31);
	print_register("VRX_FIFO_ERRSIDE", d64);
	d64 = read_reg(VRX_FIFO_WERR, 0, 31);
	print_register("VRX_FIFO_WERR", d64);
	d64 = read_reg(VRX_FIFO_RERR, 0, 31);
	print_register("VRX_FIFO_RERR", d64);
	d64 = read_reg(VRX_RAM_ERR_LOCK1, 0, 31);
	print_register("VRX_RAM_ERR_LOCK1", d64);
	d64 = read_reg(VRX_RAM_ERR_LOCK2, 0, 31);
	print_register("VRX_RAM_ERR_LOCK2", d64);
	d64 = read_reg(VRX_ADP_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_ADP_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_ADP_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_ADP_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_DOORBELL_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_DOORBELL_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_DOORBELL_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_DOORBELL_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG2, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG2", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG3, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG3", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG4, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG4", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG5, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG5", d64);
	d64 = read_reg(VRX_RDSC_CFG_DEBUG_REG6, 0, 31);
	print_register("VRX_RDSC_CFG_DEBUG_REG6", d64);
	d64 = read_reg(VRX_DDSC_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_DDSC_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_DDSC_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_DDSC_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_UDSC_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_UDSC_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_UDSC_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_UDSC_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG2, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG2", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG3, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG3_DROP", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG4, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG4", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG5, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG5", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG6, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG6", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG7, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG7", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG8, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG8", d64);
	d64 = read_reg(VRX_WPKT_CFG_DEBUG_REG9, 0, 31);
	print_register("VRX_WPKT_CFG_DEBUG_REG9", d64);
	d64 = read_reg(VRX_WRBACK_CFG_DEBUG_REG0, 0, 31);
	print_register("VRX_WRBACK_CFG_DEBUG_REG0", d64);
	d64 = read_reg(VRX_WRBACK_CFG_DEBUG_REG1, 0, 31);
	print_register("VRX_WRBACK_CFG_DEBUG_REG1", d64);
	d64 = read_reg(VRX_WRBACK_CFG_DEBUG_REG2, 0, 31);
	print_register("VRX_WRBACK_CFG_DEBUG_REG2", d64);
	d64 = read_reg(VRX_WRBACK_CFG_DEBUG_REG3, 0, 31);
	print_register("VRX_WRBACK_CFG_DEBUG_REG3", d64);
	d64 = read_reg(VRX_WRBACK_CFG_DEBUG_REG4, 0, 31);
	print_register("VRX_WRBACK_CFG_DEBUG_REG4", d64);
	d64 = read_reg(VRX_WRBACK_CFG_DEBUG_REG5, 0, 31);
	print_register("VRX_WRBACK_CFG_DEBUG_REG5", d64);
}

void vtx_display()
{
	uint64_t d64 = 0;

	print_color(YELLOW, "**************** VTX ****************");
	d64 = read_reg(VTX_INTP_STATUS, 0, 31);
	print_register("VTX_INTP_STATUS", d64);
	d64 = read_reg(VTX_INTP_MASK, 0, 31);
	print_register("VTX_INTP_MASK", d64);
	d64 = read_reg(VTX_RAM_ERR0, 0, 31);
	print_register("VTX_RAM_ERR0", d64);
	d64 = read_reg(VTX_RAM_ERR1, 0, 31);
	print_register("VTX_RAM_ERR1", d64);
	d64 = read_reg(VTX_FIFO_WERR0, 0, 31);
	print_register("VTX_FIFO_WERR0", d64);
	d64 = read_reg(VTX_FIFO_ERRSIDE0, 0, 31);
	print_register("VTX_FIFO_ERRSIDE0", d64);
	d64 = read_reg(VTX_FIFO_ROVERFLOW0, 0, 31);
	print_register("VTX_FIFO_ROVERFLOW0", d64);
	d64 = read_reg(VTX_FIFO_WOVERFLOW0, 0, 31);
	print_register("VTX_FIFO_WOVERFLOW0", d64);
	d64 = read_reg(VTX_FIFO_NAFULL0, 0, 31);
	print_register("VTX_FIFO_NAFULL0", d64);
	d64 = read_reg(VTX_FIFO_NFULL0, 0, 31);
	print_register("VTX_FIFO_NFULL0", d64);
	d64 = read_reg(VTX_FIFO_NAEMPTY0, 0, 31);
	print_register("VTX_FIFO_NAEMPTY0", d64);
	d64 = read_reg(VTX_DB_ERR, 0, 31);
	print_register("VTX_DB_ERR", d64);
	d64 = read_reg(VTX_FIFO_NEMPTY0, 0, 31);
	print_register("VTX_FIFO_NEMPTY0", d64);
	d64 = read_reg(SCH_ERR, 0, 31);
	print_register("SCH_ERR", d64);
	d64 = read_reg(DESC_Q_ERR, 0, 31);
	print_register("DESC_Q_ERR", d64);
	d64 = read_reg(PKT_Q_ERR, 0, 31);
	print_register("PKT_Q_ERR", d64);
	d64 = read_reg(VTX_DESCRDNUM_CFG, 0, 31);
	print_register("VTX_DESCRDNUM_CFG", d64);
	d64 = read_reg(VTX_FLOWCTRL_MASK, 0, 31);
	print_register("VTX_FLOWCTRL_MASK", d64);
	d64 = read_reg(VTX_DESCWR_MERGE_TIMEOUT, 0, 31);
	print_register("VTX_DESCWR_MERGE_TIMEOUT", d64);
	d64 = read_reg(VTX_VLANTAG0_CFG, 0, 31);
	print_register("VTX_VLANTAG0_CFG", d64);
	d64 = read_reg(VTX_VLANTAG1_CFG, 0, 31);
	print_register("VTX_VLANTAG1_CFG", d64);
	d64 = read_reg(VTX_VLANTAG2_CFG, 0, 31);
	print_register("VTX_VLANTAG2_CFG", d64);
	d64 = read_reg(VTX_VLANTAG3_CFG, 0, 31);
	print_register("VTX_VLANTAG3_CFG", d64);
	d64 = read_reg(VTX_CTRL_CFG, 0, 31);
	print_register("VTX_CTRL_CFG", d64);
	d64 = read_reg(VTX_DESCRAM_DEBUG_CFG, 0, 31);
	print_register("VTX_DESCRAM_DEBUG_CFG", d64);
	d64 = read_reg(DEBUG_DSCH_CNT, 0, 31);
	print_register("DEBUG_DSCH_CNT", d64);
	d64 = read_reg(DEBUG_DSCH_REPERR_CNT, 0, 31);
	print_register("DEBUG_DSCH_REPERR_CNT", d64);
	d64 = read_reg(DEBUG_QDEPTH_ERR_CNT, 0, 31);
	print_register("DEBUG_QDEPTH_ERR_CNT", d64);
	d64 = read_reg(DEBUG_DESCDIR_REQ_CNT, 0, 31);
	print_register("DEBUG_DESCDIR_REQ_CNT", d64);
	d64 = read_reg(DEBUG_DESCDIR_EOB_CNT, 0, 31);
	print_register("DEBUG_DESCDIR_EOB_CNT", d64);
	d64 = read_reg(DEBUG_DESCINDIR_DIF_ERR_CNT, 0, 31);
	print_register("DEBUG_DESCINDIR_DIF_ERR_CNT", d64);
	d64 = read_reg(DEBUG_DESCINDIR_VALID_DESC_CNT, 0, 31);
	print_register("DEBUG_DESCINDIR_VALID_DESC_CNT", d64);
	d64 = read_reg(DEBUG_DESCINDIR_INVALID_DESC_CNT, 0, 31);
	print_register("DEBUG_DESCINDIR_INVALID_DESC_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_DESCLEN_ERR_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_DESCLEN_ERR_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_CHAIN_ERR_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_CHAIN_ERR_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_PKTLEN_LARGER256K_ERR_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_PKTLEN_LARGER256K_ERR_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_LSO_DROP_ERR_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_LSO_DROP_ERR_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_PKTPRO_PKT_CNT, 0, 31);
	print_register("DEBUG_PKTAN_PKTPRO_PKT_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_PKTREQ_PKT_CNT, 0, 31);
	print_register("DEBUG_PKTAN_PKTREQ_PKT_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_PKTREQ_DESC_CNT, 0, 31);
	print_register("DEBUG_PKTAN_PKTREQ_DESC_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_LARGERMTU_PKT_CNT, 0, 31);
	print_register("DEBUG_PKTAN_LARGERMTU_PKT_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_LARGER8DESC_INTERSEG_PKT_CNT, 0, 31);
	print_register("DEBUG_PKTAN_LARGER8DESC_INTERSEG_PKT_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_ERRDROP_PKT_CNT, 0, 31);
	print_register("DEBUG_PKTAN_ERRDROP_PKT_CNT", d64);
	d64 = read_reg(DEBUG_PKTDIF_REQ_CNT, 0, 31);
	print_register("DEBUG_PKTDIF_REQ_CNT", d64);
	d64 = read_reg(DEBUG_PKTDIF_EOB_CNT, 0, 31);
	print_register("DEBUG_PKTDIF_EOB_CNT", d64);
	d64 = read_reg(DEBUG_PKTDIF_RERR_CNT, 0, 31);
	print_register("DEBUG_PKTDIF_RERR_CNT", d64);
	d64 = read_reg(DEBUG_PKTPRO_ERRDROP_PKT_CNT, 0, 31);
	print_register("DEBUG_PKTPRO_ERRDROP_PKT_CNT", d64);
	d64 = read_reg(DEBUG_PKTSEG_PRMUX_TXPKT_CNT, 0, 15);
	print_register("DEBUG_PKTSEG_PRMUX_TXPKT_CNT_NUM", d64);
	d64 = read_reg(DEBUG_PKTSEG_PRMUX_TXPKT_CNT, 15, 31);
	print_register("DEBUG_PKTSEG_PRMUX_TXPKT_CNT_BYTE", d64);
	d64 = read_reg(DEBUG_MERGE_PACKED_PKT_CNT, 0, 31);
	print_register("DEBUG_MERGE_PACKED_PKT_CNT", d64);
	d64 = read_reg(DEBUG_DESCWR_REQ_CNT, 0, 31);
	print_register("DEBUG_DESCWR_REQ_CNT", d64);
	d64 = read_reg(DEBUG_DESCWR_EOB_CNT, 0, 31);
	print_register("DEBUG_DESCWR_EOB_CNT", d64);
	d64 = read_reg(DEBUG_DBMUX_VALID_CNT, 0, 31);
	print_register("DEBUG_DBMUX_VALID_CNT", d64);
	d64 = read_reg(DEBUG_DBMUX_INVALID_CNT, 0, 31);
	print_register("DEBUG_DBMUX_INVALID_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_PKTINFO_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_PKTINFO_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_DESC_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_DESC_CNT", d64);
	d64 = read_reg(DEBUG_DESCCHAIN_FWD_ERR_CNT, 0, 31);
	print_register("DEBUG_DESCCHAIN_FWD_ERR_CNT", d64);
	d64 = read_reg(DEBUG_PKTSEG_IP_SEG_DF_ERR_CNT, 0, 31);
	print_register("DEBUG_PKTSEG_IP_SEG_DF_ERR_CNT", d64);
	d64 = read_reg(DEBUG_PKTAN_BURST_NOPKT_CNT, 0, 31);
	print_register("DEBUG_PKTAN_BURST_NOPKT_CNT", d64);
	d64 = read_reg(DEBUG_PRMUX_INFO_NAFULL_CNT, 0, 31);
	print_register("DEBUG_PRMUX_INFO_NAFULL_CNT", d64);
	d64 = read_reg(DEBUG_PRMUX_DATA_NAFULL_CNT, 0, 31);
	print_register("DEBUG_PRMUX_DATA_NAFULL_CNT", d64);
	d64 = read_reg(DEBUG_DPORT_FLOWCTRL_EN_CNT, 0, 31);
	print_register("DEBUG_DPORT_FLOWCTRL_EN_CNT", d64);
	d64 = read_reg(LSO_AVAIL_RC_CNT, 0, 31);
	print_register("LSO_AVAIL_RC_CNT", d64);
	d64 = read_reg(QUEUE_RST_CNT, 0, 31);
	print_register("QUEUE_RST_CNT", d64);

	printf("\nQUEUE_PARA_TABLE\n");
	for (int i = vtx_s; i <= vtx_e; i++)
	{
		printf("vtx%3d:", i);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 0, 63);
		printf("desc_addr:\033[;;34m[%9lX]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 64, 67);
		printf("q_depth:\033[;;34m[%2ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 68, 68);
		printf("queue_en:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 69, 69);
		printf("virtio_mode:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 70, 70);
		printf("interl_seg_en:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 71, 71);
		printf("seg_en:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 72, 72);
		printf("inorder:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 73, 73);
		printf("redraw_en:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 74, 74);
		printf("tail_buf_id_dis:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 75, 75);
		printf("queue_stop:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 76, 78);
		printf("sport:\033[;;34m[%2ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 79, 91);
		printf("dma_msix:\033[;;34m[%2ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 92, 95);
		printf("dma_info:\033[;;34m[%2ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 96, 105);
		printf("sport_id:\033[;;34m[%3ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_PARA_TABLE + QUEUE_PARA_TABLE_SIZE * i, 112, 125);
		printf("mtu:\033[;;34m[%1ld]\033[0m ", d64);
		printf("\n");
	}

	printf("\nQUEUE_CONTEXT_TABLE\n");
	for (int i = vtx_s; i <= vtx_e; i++)
	{
		printf("vtx%3d:", i);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 0, 2);
		printf("descrd_num:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 3, 18);
		printf("tail_buf_id:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 19, 34);
		printf("firstdesc:\033[;;34m[%5ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 35, 50);
		printf("firstdescid:\033[;;34m[%5ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 51, 61);
		printf("lso_id:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 62, 77);
		printf("L1_read:\033[;;34m[%4lX]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 78, 78);
		printf("wrap_counter:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 79, 79);
		printf("last_redraw:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 80, 80);
		printf("lso_flag:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 81, 81);
		printf("descrd_disable:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 82, 82);
		printf("lso_drop:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 83, 83);
		printf("q_err:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 84, 84);
		if (d64)
			printf("protected:\033[;;31m[%ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 85, 100);
		printf("avail_idx:\033[;;34m[%4lX]\033[0m ", d64);
		d64 = read_reg(QUEUE_CONTEXT_TABLE + QUEUE_CONTEXT_TABLE_SIZE * i, 101, 101);
		printf("pkt_diferr:\033[;;34m[%1ld]\033[0m ", d64);
		printf("\n");
	}

	printf("\nQUEUE_STAT_TABLE\n");
	for (int i = vtx_s; i <= vtx_e; i++)
	{
		printf("vtx%3d:", i);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 0, 15);
		printf("fwd_pkt_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 16, 31);
		printf("fwd_desc_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 32, 47);
		printf("drop_pkt_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 48, 63);
		printf("drop_desc_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 64, 79);
		printf("queue_sch_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 80, 95);
		printf("queue_doorbell_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 96, 111);
		printf("pktseg_qtbl_context_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 112, 127);
		printf("pktseg_doorbell_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 128, 143);
		printf("vtx_feedback_doorbell_ivld_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		d64 = read_reg(QUEUE_STAT_TABLE + QUEUE_STAT_TABLE_SIZE * i, 144, 159);
		printf("vtx_feedback_doorbell_cnt:\033[;;34m[%1ld]\033[0m ", d64);
		printf("\n");
	}

	printf("\nCQ_WRBACK_DEBUG_RAM\n");
	for (int i = vtx_s; i <= vtx_e; i++)
	{
		printf("vtx%3d:", i);
		d64 = read_reg(CQ_WRBACK_DEBUG_RAM + CQ_WRBACK_DEBUG_RAM_SIZE * i, 0, 15);
		printf("cq_wdata:\033[;;34m[%1ld]\033[0m ", d64);
		printf("\n");
	}
}

void pstat_display()
{
	int cnt_base_addr = 0;
	int len_base_addr = 0;
	uint64_t cnt_l = 0;
	uint64_t cnt_h = 0;
	uint64_t len_l = 0;
	uint64_t len_h = 0;
	uint64_t len64 = 0;
	uint64_t cnt64 = 0;

	switch (pstat_type)
	{
	case PSTAT_PTYPE:
		cnt_base_addr = PTYPE_CNT_BASE;
		break;
	case PSTAT_FLOW0:
		/* generally flow0 is default frozen and not in use. */
		cnt_base_addr = FLOW0_CNT_BASE;
		len_base_addr = FLOW0_LEN_BASE;
		break;
	case PSTAT_FLOW1:
		cnt_base_addr = FLOW1_CNT_BASE;
		len_base_addr = FLOW1_LEN_BASE;
		break;
	case PSTAT_IACL:
		cnt_base_addr = IACL_CNT_BASE;
		len_base_addr = IACL_LEN_BASE;
		break;
	case PSTAT_EACL:
		cnt_base_addr = EACL_CNT_BASE;
		len_base_addr = EACL_LEN_BASE;
		break;
	case PSTAT_SPORT_DIS:
		cnt_base_addr = SPORT_CNT_DIS_BASE;
		len_base_addr = SPORT_LEN_DIS_BASE;
		break;
	case PSTAT_SPORT_NO_DIS:
		cnt_base_addr = SPORT_CNT_NODIS_BASE;
		len_base_addr = SPORT_LEN_NODIS_BASE;
		break;
	case PSTAT_DPORT_DIS:
		cnt_base_addr = DPORT_CNT_DIS_BASE;
		len_base_addr = DPORT_LEN_DIS_BASE;
		break;
	case PSTAT_DPORT_NO_DIS:
		cnt_base_addr = DPORT_CNT_NODIS_BASE;
		len_base_addr = DPORT_LEN_NODIS_BASE;
		break;
	default:
		return;
	}

	print_color(YELLOW, "**************** pstat_display ****************");
	print_color(YELLOW, "pstat_type=%s, pstat_index=%d", pstat_type_str, pstat_index);

	cnt_base_addr += 4 * pstat_index;
	cnt_l = read_reg(cnt_base_addr, 0, 31);
	cnt_h = read_reg(PSTAT_HIGH_BIT_SEL_NUM, 0, 3);

	if (pstat_type == PSTAT_PTYPE)
		printf("cnt=%lu\n", cnt64);
	else {
		len_base_addr += 4 * pstat_index;
		len_l = read_reg(len_base_addr, 0, 31);
		len_h = read_reg(PSTAT_HIGH_BIT_SEL_LEN, 0, 15);
		len64 = (len_h << 32) | len_l;
		cnt64 = (cnt_h << 32) | cnt_l;

		printf("cnt=%lu len=%lu\n", cnt64, len64);
	}
}

void pp_display()
{
	uint64_t d64 = 0;

	print_color(YELLOW, "**************** PP ****************");
	print_color(GREEN, "-----------------BASE INFO---------------");
	d64 = read_reg(PP_INIT_DONE_REG, 0, 31);
	print_register("PP_INIT_DONE_REG", d64);
	d64 = read_reg(PP_INT_REG, 0, 31);
	print_register("PP_INT_REG", d64);
	d64 = read_reg(PP_INT_MASK_REG, 0, 31);
	print_register("PP_INT_MASK_REG", d64);
	d64 = read_reg(PP_CBUS_STATUS_REG, 0, 31);
	print_register("PP_CBUS_STATUS_REG", d64);

	print_color(GREEN, "-----------------PARSER---------------");
	d64 = read_reg(PARSER_INT_STATUS_REG, 0, 31);
	print_register("PARSER_INT_STATUS_REG", d64);
	d64 = read_reg(PARSER_INT_MASK_REG, 0, 31);
	print_register("PARSER_INT_MASK_REG", d64);
	d64 = read_reg(PARSER_RAM_ERR_REG_0, 0, 31);
	print_register("PARSER_RAM_ERR_REG_0", d64);
	d64 = read_reg(PARSER_RAM_ERR_REG_1, 0, 31);
	print_register("PARSER_RAM_ERR_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_WERR_REG_0, 0, 31);
	print_register("PARSER_FIFO_WERR_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_WERR_REG_1, 0, 31);
	print_register("PARSER_FIFO_WERR_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_RERR_REG_0, 0, 31);
	print_register("PARSER_FIFO_RERR_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_RERR_REG_1, 0, 31);
	print_register("PARSER_FIFO_RERR_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_WOVERFLOW_REG_0, 0, 31);
	print_register("PARSER_FIFO_WOVERFLOW_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_WOVERFLOW_REG_1, 0, 31);
	print_register("PARSER_FIFO_WOVERFLOW_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_ROVERFLOW_REG_0, 0, 31);
	print_register("PARSER_FIFO_ROVERFLOW_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_ROVERFLOW_REG_1, 0, 31);
	print_register("PARSER_FIFO_ROVERFLOW_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_NAFULL_REG_0, 0, 31);
	print_register("PARSER_FIFO_NAFULL_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_NAFULL_REG_1, 0, 31);
	print_register("PARSER_FIFO_NAFULL_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_NFULL_REG_0, 0, 31);
	print_register("PARSER_FIFO_NFULL_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_NFULL_REG_1, 0, 31);
	print_register("PARSER_FIFO_NFULL_REG_1", d64);
	d64 = read_reg(PARSER_FIFO_NAEMPTY_REG_0, 0, 31);
	print_register("PARSER_FIFO_NAEMPTY_REG_0", d64);
	d64 = read_reg(PARSER_FIFO_NAEMPTY_REG_1, 0, 31);
	print_register("PARSER_FIFO_NAEMPTY_REG_1", d64);
	d64 = read_reg(PARSER_PRE_INFO_R_CNT_REG, 0, 31);
	print_register("PARSER_PRE_INFO_R_CNT_REG", d64);
	d64 = read_reg(PARSER_FIFO_NEMPTY_REG_1, 0, 31);
	print_register("PARSER_FIFO_NEMPTY_REG_1", d64);
	d64 = read_reg(PARSER_INIT_DONE_REG, 0, 31);
	print_register("PARSER_INIT_DONE_REG", d64);
	d64 = read_reg(PARSER_PSTORE_INFO_R_CNT, 0, 31);
	print_register("PARSER_PSTORE_INFO_R_CNT", d64);
	d64 = read_reg(PARSER_PSTORE_DATA_R_CNT, 0, 31);
	print_register("PARSER_PSTORE_DATA_R_CNT", d64);
	d64 = read_reg(PARSER_PRE_RSLT_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PRE_RSLT_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_PRE_RSLT_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PRE_RSLT_DATA_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_PRE_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PRE_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_PRE_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PRE_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_PRE_DEBUG0_REG, 0, 31);
	print_register("PARSER_PRE_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_PRE_DEBUG1_REG, 0, 31);
	print_register("PARSER_PRE_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_PRE_DEBUG2_REG, 0, 31);
	print_register("PARSER_PRE_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_PRE_DEBUG3_REG, 0, 31);
	print_register("PARSER_PRE_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_PSTORE_PARSER_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PSTORE_PARSER_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_PSTORE_PARSER_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PSTORE_PARSER_DATA_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_L3_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_L3_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_L3_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_L3_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_L3_DEBUG0_REG, 0, 31);
	print_register("PARSER_L3_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_L3_DEBUG1_REG, 0, 31);
	print_register("PARSER_L3_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_L3_DEBUG2_REG, 0, 31);
	print_register("PARSER_L3_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_L3_DEBUG3_REG, 0, 31);
	print_register("PARSER_L3_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_L4_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_L4_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_L4_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_L4_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_OUTER_KEY_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OUTER_KEY_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_OUTER_PCM_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OUTER_PCM_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_L4_DEBUG0_REG, 0, 31);
	print_register("PARSER_L4_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_L4_DEBUG1_REG, 0, 31);
	print_register("PARSER_L4_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_L4_DEBUG2_REG, 0, 31);
	print_register("PARSER_L4_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_L4_DEBUG3_REG, 0, 31);
	print_register("PARSER_L4_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_OUTER_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OUTER_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TNL_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TNL_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TNL_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TNL_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_ORSLT_DEBUG0_REG, 0, 31);
	print_register("PARSER_ORSLT_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_ORSLT_DEBUG1_REG, 0, 31);
	print_register("PARSER_ORSLT_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_ORSLT_DEBUG2_REG, 0, 31);
	print_register("PARSER_ORSLT_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_ORSLT_DEBUG3_REG, 0, 31);
	print_register("PARSER_ORSLT_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_OPCM_RSLT_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OPCM_RSLT_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_OPCM_DEBUG0_REG, 0, 31);
	print_register("PARSER_OPCM_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_OPCM_KEY_TBL_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OPCM_KEY_TBL_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_OPCM_MSK_TBL_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OPCM_MSK_TBL_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_OPCM_TBL_DEBUG0_REG, 0, 31);
	print_register("PARSER_OPCM_TBL_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_TL2_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TL2_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL2_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TL2_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL2_DEBUG0_REG, 0, 31);
	print_register("PARSER_TL2_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_TL2_DEBUG1_REG, 0, 31);
	print_register("PARSER_TL2_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_TL2_DEBUG2_REG, 0, 31);
	print_register("PARSER_TL2_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_TL2_DEBUG3_REG, 0, 31);
	print_register("PARSER_TL2_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_TL3_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TL3_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL3_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TL3_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL3_DEBUG0_REG, 0, 31);
	print_register("PARSER_TL3_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_TL3_DEBUG1_REG, 0, 31);
	print_register("PARSER_TL3_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_TL3_DEBUG2_REG, 0, 31);
	print_register("PARSER_TL3_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_TL3_DEBUG3_REG, 0, 31);
	print_register("PARSER_TL3_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_TL4_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TL4_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL4_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_TL4_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_INNER_KEY_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_INNER_KEY_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_INNER_PCM_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_INNER_PCM_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL4_DEBUG0_REG, 0, 31);
	print_register("PARSER_TL4_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_TL4_DEBUG1_REG, 0, 31);
	print_register("PARSER_TL4_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_TL4_DEBUG2_REG, 0, 31);
	print_register("PARSER_TL4_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_TL4_DEBUG3_REG, 0, 31);
	print_register("PARSER_TL4_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_INNER_HEAD_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_INNER_HEAD_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_INNER_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_INNER_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_TL5_DEBUG0_REG, 0, 31);
	print_register("PARSER_TL5_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_TL5_DEBUG1_REG, 0, 31);
	print_register("PARSER_TL5_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_TL5_DEBUG2_REG, 0, 31);
	print_register("PARSER_TL5_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_IPCM_RSLT_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_IPCM_RSLT_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IPCM_DEBUG0_REG, 0, 31);
	print_register("PARSER_IPCM_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_IPCM_KEY_TBL_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_IPCM_KEY_TBL_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IPCM_MSK_TBL_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_IPCM_MSK_TBL_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IPCM_TBL_DEBUG0_REG, 0, 31);
	print_register("PARSER_IPCM_TBL_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_FPATH_INFO_TBL_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_FPATH_INFO_TBL_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_FPATH_RSS_TBL_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_FPATH_RSS_TBL_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IPRO_INFO_FIFO_W_CNT, 0, 31);
	print_register("PARSER_IPRO_INFO_FIFO_W_CNT", d64);
	d64 = read_reg(PARSER_IPRO_DATA_FIFO_W_CNT, 0, 31);
	print_register("PARSER_IPRO_DATA_FIFO_W_CNT", d64);
	d64 = read_reg(PARSER_PQM_INFO_FIFO_W_CNT, 0, 31);
	print_register("PARSER_PQM_INFO_FIFO_W_CNT", d64);
	d64 = read_reg(PARSER_HEAD_PNTR_SUM, 0, 31);
	print_register("PARSER_HEAD_PNTR_SUM", d64);
	d64 = read_reg(PARSER_PKT_LENGTH_SUM, 0, 31);
	print_register("PARSER_PKT_LENGTH_SUM", d64);
	d64 = read_reg(PARSER_RSLT_FSM0_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_RSLT_FSM0_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_RSLT_FSM0_IPRE_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_RSLT_FSM0_IPRE_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_OL4_CHKSUM_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_OL4_CHKSUM_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IL4_CHKSUM_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_IL4_CHKSUM_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IPRO_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_IPRO_DATA_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_IPRO_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_IPRO_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_PQM_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PARSER_PQM_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG0_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG0_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG1_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG1_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG2_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG2_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG3_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG3_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG4_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG4_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG5_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG5_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG6_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG6_REG", d64);
	d64 = read_reg(PARSER_RSLT_DEBUG7_REG, 0, 31);
	print_register("PARSER_RSLT_DEBUG7_REG", d64);

	print_color(GREEN, "-----------------IPRO---------------");
	d64 = read_reg(IPRO_INT_MASK_REG, 0, 31);
	print_register("IPRO_INT_MASK_REG", d64);
	d64 = read_reg(IPRO_RD_PARSER_INFO_CNT, 0, 31);
	print_register("IPRO_RD_PARSER_INFO_CNT", d64);
	d64 = read_reg(IPRO_RD_RDMA_PKT_CNT, 0, 31);
	print_register("IPRO_RD_RDMA_PKT_CNT", d64);
	d64 = read_reg(IPRO_WR_EPRO_PFLOW_INFO_CNT, 0, 31);
	print_register("IPRO_WR_EPRO_PFLOW_INFO_CNT", d64);
	d64 = read_reg(IPRO_WR_RDMA_INFO_DATA_CNT, 0, 31);
	print_register("IPRO_WR_RDMA_INFO_DATA_CNT", d64);
	d64 = read_reg(IPRO_FSE_PROFILE_ID_TABLE_DEBUG, 0, 31);
	print_register("IPRO_FSE_PROFILE_ID_TABLE_DEBUG", d64);
	d64 = read_reg(IPRO_LOOKUP_F_IPORT_TBL_CNT, 0, 31);
	print_register("IPRO_LOOKUP_F_IPORT_TBL_CNT", d64);
	d64 = read_reg(IPRO_LOOKUP_TSE_CNT, 0, 31);
	print_register("IPRO_LOOKUP_TSE_CNT", d64);
	d64 = read_reg(IPRO_LOOKUP_PSE_CNT, 0, 31);
	print_register("IPRO_LOOKUP_PSE_CNT", d64);
	d64 = read_reg(IPRO_LOOKUP_2ND_IPORT_TBL_CNT, 0, 31);
	print_register("IPRO_LOOKUP_2ND_IPORT_TBL_CNT", d64);
	d64 = read_reg(IPRO_LOOKUP_MSE_CNT, 0, 31);
	print_register("IPRO_LOOKUP_MSE_CNT", d64);
	d64 = read_reg(IPRO_LOOKUP_PCM_ACTION_CNT, 0, 31);
	print_register("IPRO_LOOKUP_PCM_ACTION_CNT", d64);
	d64 = read_reg(IPRO_RDMA_MSE_TORDMA_CNT, 0, 31);
	print_register("IPRO_RDMA_MSE_TORDMA_CNT", d64);
	d64 = read_reg(IPRO_FIFOS_NAFULL_REG, 0, 31);
	print_register("IPRO_FIFOS_NAFULL_REG", d64);
	d64 = read_reg(IPRO_FIFOS_NEMPTY_REG, 0, 31);
	print_register("IPRO_FIFOS_NEMPTY_REG", d64);
	d64 = read_reg(IPRO_FIFOS_WOVERFLOW_REG, 0, 31);
	print_register("IPRO_FIFOS_WOVERFLOW_REG", d64);
	d64 = read_reg(IPRO_FIFOS_ROVERFLOW_REG, 0, 31);
	print_register("IPRO_FIFOS_ROVERFLOW_REG", d64);
	d64 = read_reg(IPRO_FIFOS_ERRSIDE_REG, 0, 31);
	print_register("IPRO_FIFOS_ERRSIDE_REG", d64);
	d64 = read_reg(IPRO_FIFOS_WERR_REG, 0, 31);
	print_register("IPRO_FIFOS_WERR_REG", d64);
	d64 = read_reg(IPRO_FIFOS_RERR_REG, 0, 31);
	print_register("IPRO_FIFOS_RERR_REG", d64);
	d64 = read_reg(IPRO_FIFOS_RAM_RERR_REG, 0, 31);
	print_register("IPRO_FIFOS_RAM_RERR_REG", d64);
	d64 = read_reg(IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG3, 0, 31);
	print_register("IPRO_PRE_FIFO_RAM_ERR_DEBUG_REG3", d64);
	d64 = read_reg(IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG3, 0, 31);
	print_register("IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG3", d64);
	d64 = read_reg(IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG4, 0, 31);
	print_register("IPRO_TNL_FIFO_RAM_ERR_DEBUG_REG4", d64);
	d64 = read_reg(IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG3, 0, 31);
	print_register("IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG3", d64);
	d64 = read_reg(IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG4, 0, 31);
	print_register("IPRO_PORT_FIFO_RAM_ERR_DEBUG_REG4", d64);
	d64 = read_reg(IPRO_MAC_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("IPRO_MAC_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(IPRO_MAC_FIFO_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("IPRO_MAC_FIFO_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(IPRO_MAC_FIFO_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("IPRO_MAC_FIFO_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(IPRO_RSLT_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("IPRO_RSLT_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(IPRO_RSLT_FIFO_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("IPRO_RSLT_FIFO_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(IPRO_CFG_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("IPRO_CFG_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(IPRO_CFG_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("IPRO_CFG_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(IPRO_CFG_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("IPRO_CFG_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(IPRO_CFG_RAM_ERR_DEBUG_REG3, 0, 31);
	print_register("IPRO_CFG_RAM_ERR_DEBUG_REG3", d64);
	d64 = read_reg(IPRO_CFG_RAM_ERR_DEBUG_REG4, 0, 31);
	print_register("IPRO_CFG_RAM_ERR_DEBUG_REG4", d64);

	print_color(GREEN, "-----------------PFLOW---------------");
	d64 = read_reg(PFLOW_INT_STATUS_REG, 0, 31);
	print_register("PFLOW_INT_STATUS_REG", d64);
	d64 = read_reg(PFLOW_INT_MASK_REG, 0, 31);
	print_register("PFLOW_INT_MASK_REG", d64);

	d64 = read_reg(pflow_pre_info_r_cnt, 0, 31);
	print_register("pflow_pre_info_r_cnt", d64);

	d64 = read_reg(PFLOW_FIFO_NAFULL_REG, 0, 31);
	print_register("PFLOW_FIFO_NAFULL_REG", d64);
	d64 = read_reg(PFLOW_FIFO_NEMPTY_REG, 0, 31);
	print_register("PFLOW_FIFO_NEMPTY_REG", d64);
	d64 = read_reg(PFLOW_FIFO_WOVERFLOW_REG, 0, 31);
	print_register("PFLOW_FIFO_WOVERFLOW_REG", d64);
	d64 = read_reg(PFLOW_FIFO_ROVERFLOW_REG, 0, 31);
	print_register("PFLOW_FIFO_ROVERFLOW_REG", d64);
	d64 = read_reg(PFLOW_FIFO_WERR_REG, 0, 31);
	print_register("PFLOW_FIFO_WERR_REG", d64);
	d64 = read_reg(PFLOW_FIFO_RERR_REG, 0, 31);
	print_register("PFLOW_FIFO_RERR_REG", d64);
	d64 = read_reg(PFLOW_FIFO_RAM_ERR_REG, 0, 31);
	print_register("PFLOW_FIFO_RAM_ERR_REG", d64);
	d64 = read_reg(PFLOW_PRE_DEBUG0_REG, 0, 31);
	print_register("PFLOW_PRE_DEBUG0_REG", d64);
	d64 = read_reg(PFLOW_MAIN_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_MAIN_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_CTRL_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_CTRL_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_CAS_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_CAS_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_LUT_DEBUG0_REG, 0, 31);
	print_register("PFLOW_LUT_DEBUG0_REG", d64);
	d64 = read_reg(PFLOW_CAS_DEBUG1_REG, 0, 31);
	print_register("PFLOW_CAS_DEBUG1_REG", d64);
	d64 = read_reg(PFLOW_CAS_DEBUG0_REG, 0, 31);
	print_register("PFLOW_CAS_DEBUG0_REG", d64);
	d64 = read_reg(PFLOW_LUT_MAIN_INFO_FIFO_RAM_ERR_REG, 0, 31);
	print_register("PFLOW_LUT_MAIN_INFO_FIFO_RAM_ERR_REG", d64);
	d64 = read_reg(PFLOW_FSE_RSLT_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_FSE_RSLT_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_LUT_CTRL_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_LUT_CTRL_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_CAS_LUT_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_CAS_LUT_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_IACL_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_IACL_INFO_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_CAS_FSE_RSLT_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	print_register("PFLOW_CAS_FSE_RSLT_FIFO_RAM_ERR_DEBUG_REG", d64);
	d64 = read_reg(PFLOW_LUT_FSE_MATCH_W_CNT, 0, 31);
	print_register("PFLOW_LUT_FSE_MATCH_W_CNT", d64);
	d64 = read_reg(PFLOW_LUT_DEFAULT_FLOW_ID_VAILD_CNT, 0, 31);
	print_register("PFLOW_LUT_DEFAULT_FLOW_ID_VAILD_CNT", d64);
	d64 = read_reg(PFLOW_CAS_FSE_MATCH_W_CNT, 0, 31);
	print_register("PFLOW_CAS_FSE_MATCH_W_CNT", d64);
	d64 = read_reg(PFLOW_CAS_DEFAULT_FLOW_ID_VAILD_CNT, 0, 31);
	print_register("PFLOW_CAS_DEFAULT_FLOW_ID_VAILD_CNT", d64);
	d64 = read_reg(PFLOW_CAS_FSE_NOMATCH_FWD3_CNT, 0, 31);
	print_register("PFLOW_CAS_FSE_NOMATCH_FWD3_CNT", d64);
	d64 = read_reg(PFLOW_CAPTURE_PKTLENGTH_CNT, 0, 31);
	print_register("PFLOW_CAPTURE_PKTLENGTH_CNT", d64);

	print_color(GREEN, "-----------------IACL---------------");
	d64 = read_reg(IACL_INT_STATUS_REG, 0, 31);
	print_register("IACL_INT_STATUS_REG", d64);
	d64 = read_reg(IACL_INT_MASK_REG, 0, 31);
	print_register("IACL_INT_MASK_REG", d64);
	d64 = read_reg(IACL_CTRL_REG, 0, 31);
	print_register("IACL_CTRL_REG", d64);
	d64 = read_reg(IACL_CAPTURE_INFO_REG, 0, 31);
	print_register("IACL_CAPTURE_INFO_REG", d64);
	d64 = read_reg(IACL_SPORT_PROFILE_TABLE, 0, 31);
	print_register("IACL_SPORT_PROFILE_TABLE", d64);
	d64 = read_reg(IACL_FIFO_RERR0, 0, 31);
	print_register("IACL_FIFO_RERR0", d64);
	d64 = read_reg(IACL_FIFO_WERR0, 0, 31);
	print_register("IACL_FIFO_WERR0", d64);
	d64 = read_reg(IACL_FIFO_ERRSIDE0, 0, 31);
	print_register("IACL_FIFO_ERRSIDE0", d64);
	d64 = read_reg(IACL_FIFO_ROVERFLOW0, 0, 31);
	print_register("IACL_FIFO_ROVERFLOW0", d64);
	d64 = read_reg(IACL_FIFO_WOVERFLOW0, 0, 31);
	print_register("IACL_FIFO_WOVERFLOW0", d64);
	d64 = read_reg(IACL_FIFO_NAFULL0, 0, 31);
	print_register("IACL_FIFO_NAFULL0", d64);
	d64 = read_reg(IACL_FIFO_NFULL0, 0, 31);
	print_register("IACL_FIFO_NFULL0", d64);
	d64 = read_reg(IACL_FIFO_NAEMPTY0, 0, 31);
	print_register("IACL_FIFO_NAEMPTY0", d64);
	d64 = read_reg(IACL_FIFO_NEMPTY0, 0, 31);
	print_register("IACL_FIFO_NEMPTY0", d64);
	d64 = read_reg(DEBUG_IACL_PRE_PROCESS_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_PRE_PROCESS_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_LUT_PROCESS_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_LUT_PROCESS_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_LUT_LUT_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_LUT_LUT_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_LUT_LUT_FAIL_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_LUT_LUT_FAIL_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_CAS_PROCESS_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_CAS_PROCESS_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_CAS_LUT_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_CAS_LUT_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_CAS_LUT_FAIL_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_CAS_LUT_FAIL_PKT_CNT", d64);
	d64 = read_reg(DEBUG_IACL_CAS_MATCH_BUT_CASCADE_PKT_CNT, 0, 31);
	print_register("DEBUG_IACL_CAS_MATCH_BUT_CASCADE_PKT_CNT", d64);
	d64 = read_reg(IACL_PRE_DEBUG_STATUS_REG, 0, 31);
	print_register("IACL_PRE_DEBUG_STATUS_REG", d64);
	d64 = read_reg(IACL_LUT_DEBUG_STATUS_REG, 0, 31);
	print_register("IACL_LUT_DEBUG_STATUS_REG", d64);
	d64 = read_reg(IACL_CAS_DEBUG_STATUS_REG, 0, 31);
	print_register("IACL_CAS_DEBUG_STATUS_REG", d64);
	d64 = read_reg(IACL_LUT1_IASE_PRE_READ_CNT, 0, 31);
	print_register("IACL_LUT1_IASE_PRE_READ_CNT", d64);
	d64 = read_reg(IACL_LUT2_IASE_PRE_READ_CNT, 0, 31);
	print_register("IACL_LUT2_IASE_PRE_READ_CNT", d64);
	d64 = read_reg(IACL_LUT3_IASE_PRE_READ_CNT, 0, 31);
	print_register("IACL_LUT3_IASE_PRE_READ_CNT", d64);
	d64 = read_reg(IACL_LUT4_IASE_PRE_READ_CNT, 0, 31);
	print_register("IACL_LUT4_IASE_PRE_READ_CNT", d64);
	print_color(GREEN, "------------IACL_PROFILE_KEY_TABLE1-------------");
	read_multi_line_ram_register_values(IACL_PROFILE_KEY_TABLE1, 16 * 16, 16);
	print_color(GREEN, "------------IACL_PROFILE_KEY_TABLE2-------------");
	read_multi_line_ram_register_values(IACL_PROFILE_KEY_TABLE2, 16 * 16, 16);
	print_color(GREEN, "------------IACL_SPORT_PROFILE_TABLE-------------");
	read_multi_line_ram_register_values(IACL_SPORT_PROFILE_TABLE, 128, 4);

	print_color(GREEN, "-----------------PMC---------------");
	d64 = read_reg(PP_PMC_INT_STATUS, 0, 31);
	print_register("PMC_INT_STATUS_REG", d64);
	d64 = read_reg(PMC_RD_IACL_INFO_CNT, 0, 31);
	print_register("PMC_RD_IACL_INFO_CNT", d64);
	d64 = read_reg(PMC_COPY_PATH_BACK_PRESS_CNT, 0, 31);
	print_register("PMC_COPY_PATH_BACK_PRESS_CNT", d64);
	d64 = read_reg(PMC_MC_PATH_COPY_CNT, 0, 31);
	print_register("PMC_MC_PATH_COPY_CNT", d64);
	d64 = read_reg(PMC_BC_PATH_COPY_CNT, 0, 31);
	print_register("PMC_BC_PATH_COPY_CNT", d64);
	d64 = read_reg(PMC_EPOR_INFO_CNT, 0, 31);
	print_register("PMC_EPOR_INFO_CNT", d64);
	d64 = read_reg(PMC_INVALID_MC_TBL_LEAF_CNT, 0, 31);
	print_register("PMC_INVALID_MC_TBL_LEAF_CNT", d64);
	d64 = read_reg(PMC_WEIGHT_DEBUG, 0, 31);
	print_register("PMC_WEIGHT_DEBUG", d64);
	d64 = read_reg(PMC_FIFOS_NAFULL_REG, 0, 31);
	print_register("PMC_FIFOS_NAFULL_REG", d64);
	d64 = read_reg(PMC_FIFOS_NEMPTY_REG, 0, 31);
	print_register("PMC_FIFOS_NEMPTY_REG", d64);
	d64 = read_reg(PMC_FIFOS_WOVERFLOW_REG, 0, 31);
	print_register("PMC_FIFOS_WOVERFLOW_REG", d64);
	d64 = read_reg(PMC_FIFOS_ROVERFLOW_REG, 0, 31);
	print_register("PMC_FIFOS_ROVERFLOW_REG", d64);
	d64 = read_reg(PMC_FIFOS_ERRSIDE_REG, 0, 31);
	print_register("PMC_FIFOS_ERRSIDE_REG", d64);
	d64 = read_reg(PMC_FIFOS_WERR_REG, 0, 31);
	print_register("PMC_FIFOS_WERR_REG", d64);
	d64 = read_reg(PMC_FIFOS_RERR_REG, 0, 31);
	print_register("PMC_FIFOS_RERR_REG", d64);
	d64 = read_reg(PMC_FIFOS_RAM_ERR_REG, 0, 31);
	print_register("PMC_FIFOS_RAM_ERR_REG", d64);

	print_color(GREEN, "--------PMC_DEBUG_INVALID_LEAF_INFO---------");
	read_multi_line_ram_register_values(PMC_DEBUG_INVALID_LEAF_INFO, 2, 2);

	print_color(GREEN, "-----------------EPRO---------------");
	d64 = read_reg(EPRO_INT_REG, 0, 31);
	print_register("EPRO_INT_REG", d64);
	d64 = read_reg(EPRO_INT_MASK_REG, 0, 31);
	print_register("EPRO_INT_MASK_REG", d64);
	d64 = read_reg(EPRO_CTRL_REG, 0, 31);
	print_register("EPRO_CTRL_REG", d64);
	d64 = read_reg(EPRO_RDMA_CTRL_REG, 0, 31);
	print_register("EPRO_RDMA_CTRL_REG", d64);
	d64 = read_reg(EPRO_TBLS_PAGE_ADDR_REG, 0, 31);
	print_register("EPRO_TBLS_PAGE_ADDR_REG", d64);
	d64 = read_reg(EPRO_FLOW_0DEBUG_REG, 0, 31);
	print_register("EPRO_FLOW_0DEBUG_REG", d64);
	d64 = read_reg(EPRO_FLOW_1DEBUG_REG, 0, 31);
	print_register("EPRO_FLOW_1DEBUG_REG", d64);
	d64 = read_reg(EPRO_FLOW_2DEBUG_REG, 0, 31);
	print_register("EPRO_FLOW_2DEBUG_REG", d64);
	d64 = read_reg(EPRO_FLOW_3DEBUG_REG, 0, 31);
	print_register("EPRO_FLOW_3DEBUG_REG", d64);
	d64 = read_reg(EPRO_PORT_0DEBUG_REG, 0, 31);
	print_register("EPRO_PORT_0DEBUG_REG", d64);
	d64 = read_reg(EPRO_PORT_1DEBUG_REG, 0, 31);
	print_register("EPRO_PORT_1DEBUG_REG", d64);
	d64 = read_reg(EPRO_PORT_2DEBUG_REG, 0, 31);
	print_register("EPRO_PORT_2DEBUG_REG", d64);
	d64 = read_reg(EPRO_PORT_3DEBUG_REG, 0, 31);
	print_register("EPRO_PORT_3DEBUG_REG", d64);
	d64 = read_reg(EPRO_RSLT_0DEBUG_REG, 0, 31);
	print_register("EPRO_RSLT_0DEBUG_REG", d64);
	d64 = read_reg(EPRO_RSLT_1DEBUG_REG, 0, 31);
	print_register("EPRO_RSLT_1DEBUG_REG", d64);
	d64 = read_reg(EPRO_RSLT_2DEBUG_REG, 0, 31);
	print_register("EPRO_RSLT_2DEBUG_REG", d64);
	d64 = read_reg(EPRO_RSLT_3DEBUG_REG, 0, 31);
	print_register("EPRO_RSLT_3DEBUG_REG", d64);
	d64 = read_reg(EPRO_FIFO_NAFULL_REG_REG, 0, 31);
	print_register("EPRO_FIFO_NAFULL_REG_REG", d64);
	d64 = read_reg(EPRO_FIFO_NEMPTY_REG_REG, 0, 31);
	print_register("EPRO_FIFO_NEMPTY_REG_REG", d64);
	d64 = read_reg(EPRO_FIFO_WOVERFLOW_REG, 0, 31);
	print_register("EPRO_FIFO_WOVERFLOW_REG", d64);
	d64 = read_reg(EPRO_FIFO_ROVERFLOW_REG, 0, 31);
	print_register("EPRO_FIFO_ROVERFLOW_REG", d64);
	d64 = read_reg(EPRO_FIFO_ERRSIDE_REG, 0, 31);
	print_register("EPRO_FIFO_ERRSIDE_REG", d64);
	d64 = read_reg(EPRO_FIFO_WERR_REG, 0, 31);
	print_register("EPRO_FIFO_WERR_REG", d64);
	d64 = read_reg(EPRO_FIFO_RERR_REG, 0, 31);
	print_register("EPRO_FIFO_RERR_REG", d64);
	d64 = read_reg(EPRO_RAM_ERR_REG, 0, 31);
	print_register("EPRO_RAM_ERR_REG", d64);
	d64 = read_reg(EPRO_FLOW_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("EPRO_FLOW_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(EPRO_FLOW_FIFO_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("EPRO_FLOW_FIFO_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(EPRO_FLOW_FIFO_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("EPRO_FLOW_FIFO_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(EPRO_PORT_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("EPRO_PORT_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(EPRO_RSLT_FIFO_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("EPRO_RSLT_FIFO_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(EPRO_CFG_RAM_ERR_DEBUG_REG0, 0, 31);
	print_register("EPRO_CFG_RAM_ERR_DEBUG_REG0", d64);
	d64 = read_reg(EPRO_CFG_RAM_ERR_DEBUG_REG1, 0, 31);
	print_register("EPRO_CFG_RAM_ERR_DEBUG_REG1", d64);
	d64 = read_reg(EPRO_CFG_RAM_ERR_DEBUG_REG2, 0, 31);
	print_register("EPRO_CFG_RAM_ERR_DEBUG_REG2", d64);
	d64 = read_reg(EPRO_CFG_ERR_REG, 0, 31);
	print_register("EPRO_CFG_ERR_REG", d64);
	d64 = read_reg(EPRO_FLOW_ACT_CNT_REG, 0, 31);
	print_register("EPRO_FLOW_ACT_CNT_REG", d64);
	d64 = read_reg(EPRO_CMDQ_0DEBUG_REG, 0, 31);
	print_register("EPRO_CMDQ_0DEBUG_REG", d64);
	d64 = read_reg(EPRO_CMDQ_1DEBUG_REG, 0, 31);
	print_register("EPRO_CMDQ_1DEBUG_REG", d64);
	d64 = read_reg(EPRO_CMDQ_2DEBUG_REG, 0, 31);
	print_register("EPRO_CMDQ_2DEBUG_REG", d64);
	d64 = read_reg(EPRO_CMDQ_3DEBUG_REG, 0, 31);
	print_register("EPRO_CMDQ_3DEBUG_REG", d64);
	d64 = read_reg(EPRO_IPRO_R_DEBUG_REG, 0, 31);
	print_register("EPRO_IPRO_R_DEBUG_REG", d64);
	d64 = read_reg(EPRO_PMC_R_DEBUG_REG, 0, 31);
	print_register("EPRO_PMC_R_DEBUG_REG", d64);
	d64 = read_reg(EPRO_EACL_I_W_DEBUG_REG, 0, 31);
	print_register("EPRO_EACL_I_W_DEBUG_REG", d64);
	d64 = read_reg(EPRO_EACL_I_W2_DEBUG_REG, 0, 31);
	print_register("EPRO_EACL_I_W2_DEBUG_REG", d64);
	d64 = read_reg(EPRO_CMDQ_FSE_R_DEBUG_REG, 0, 31);
	print_register("EPRO_CMDQ_FSE_R_DEBUG_REG", d64);
	d64 = read_reg(EPRO_CMDQ_RSLT_W_DEBUG_REG, 0, 31);
	print_register("EPRO_CMDQ_RSLT_W_DEBUG_REG", d64);
	d64 = read_reg(EPRO_PTR_LEN_SUM_REG, 0, 31);
	print_register("EPRO_PTR_LEN_SUM_REG", d64);
	d64 = read_reg(EPRO_CMDQ_ACTION_CNT_REG, 0, 31);
	print_register("EPRO_CMDQ_ACTION_CNT_REG", d64);
	d64 = read_reg(EPRO_CMDQ_FLOW_ID_WEN_CNT_REG, 0, 31);
	print_register("EPRO_CMDQ_FLOW_ID_WEN_CNT_REG", d64);

	print_color(GREEN, "-----------------EACL---------------");
	d64 = read_reg(EACL_INT_STATUS_REG, 0, 31);
	print_register("EACL_INT_STATUS_REG", d64);
	d64 = read_reg(EACL_INT_MASK_REG, 0, 31);
	print_register("EACL_INT_MASK_REG", d64);
	d64 = read_reg(EACL_CTRL_REG, 0, 31);
	print_register("EACL_CTRL_REG", d64);
	d64 = read_reg(EACL_CAPTURE_INFO_REG, 0, 31);
	print_register("EACL_CAPTURE_INFO_REG", d64);
	d64 = read_reg(EACL_FIFO_RERR0, 0, 31);
	print_register("EACL_FIFO_RERR0", d64);
	d64 = read_reg(EACL_FIFO_WERR0, 0, 31);
	print_register("EACL_FIFO_WERR0", d64);
	d64 = read_reg(EACL_FIFO_ERRSIDE0, 0, 31);
	print_register("EACL_FIFO_ERRSIDE0", d64);
	d64 = read_reg(EACL_FIFO_ROVERFLOW0, 0, 31);
	print_register("EACL_FIFO_ROVERFLOW0", d64);
	d64 = read_reg(EACL_FIFO_WOVERFLOW0, 0, 31);
	print_register("EACL_FIFO_WOVERFLOW0", d64);
	d64 = read_reg(EACL_FIFO_NAFULL0, 0, 31);
	print_register("EACL_FIFO_NAFULL0", d64);
	d64 = read_reg(EACL_FIFO_NFULL0, 0, 31);
	print_register("EACL_FIFO_NFULL0", d64);
	d64 = read_reg(EACL_FIFO_NAEMPTY0, 0, 31);
	print_register("EACL_FIFO_NAEMPTY0", d64);
	d64 = read_reg(EACL_FIFO_NEMPTY0, 0, 31);
	print_register("EACL_FIFO_NEMPTY0", d64);
	d64 = read_reg(DEBUG_EACL_PRE_PROCESS_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_PRE_PROCESS_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_LUT_PROCESS_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_LUT_PROCESS_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_LUT_LUT_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_LUT_LUT_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_LUT_LUT_FAIL_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_LUT_LUT_FAIL_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_CAS_PROCESS_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_CAS_PROCESS_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_CAS_LUT_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_CAS_LUT_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_CAS_LUT_FAIL_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_CAS_LUT_FAIL_PKT_CNT", d64);
	d64 = read_reg(DEBUG_EACL_CAS_MATCH_BUT_CASCADE_PKT_CNT, 0, 31);
	print_register("DEBUG_EACL_CAS_MATCH_BUT_CASCADE_PKT_CNT", d64);
	d64 = read_reg(EACL_PRE_DEBUG_STATUS_REG, 0, 31);
	print_register("EACL_PRE_DEBUG_STATUS_REG", d64);
	d64 = read_reg(EACL_LUT_DEBUG_STATUS_REG, 0, 31);
	print_register("EACL_LUT_DEBUG_STATUS_REG", d64);
	d64 = read_reg(EACL_CAS_DEBUG_STATUS_REG, 0, 31);
	print_register("EACL_CAS_DEBUG_STATUS_REG", d64);
	d64 = read_reg(EACL_LUT1_IASE_PRE_READ_CNT, 0, 31);
	print_register("EACL_LUT1_IASE_PRE_READ_CNT", d64);
	d64 = read_reg(EACL_LUT2_IASE_PRE_READ_CNT, 0, 31);
	print_register("EACL_LUT2_IASE_PRE_READ_CNT", d64);
	d64 = read_reg(EACL_LUT3_IASE_PRE_READ_CNT, 0, 31);
	print_register("EACL_LUT3_IASE_PRE_READ_CNT", d64);
	d64 = read_reg(EACL_LUT4_IASE_PRE_READ_CNT, 0, 31);
	print_register("EACL_LUT4_IASE_PRE_READ_CNT", d64);
	print_color(GREEN, "------------EACL_PROFILE_KEY_TABLE1-------------");
	read_multi_line_ram_register_values(EACL_PROFILE_KEY_TABLE1, 16 * 16, 16);
	print_color(GREEN, "------------EACL_PROFILE_KEY_TABLE2-------------");
	read_multi_line_ram_register_values(EACL_PROFILE_KEY_TABLE2, 16 * 16, 16);
	print_color(GREEN, "------------EACL_SPORT_PROFILE_TABLE-------------");
	read_multi_line_ram_register_values(EACL_SPORT_PROFILE_TABLE, 128, 4);

	print_color(GREEN, "-----------------PMIRR---------------");
	d64 = read_reg(PMIRR_INT_STATUS_REG, 0, 31);
	print_register("PMIRR_INT_STATUS_REG", d64);
	d64 = read_reg(PMIRR_INT_MASK_REG, 0, 31);
	print_register("PMIRR_INT_MASK_REG", d64);
	d64 = read_reg(PMIRR_CTRL_REG, 0, 31);
	print_register("PMIRR_CTRL_REG", d64);
	d64 = read_reg(PMIRR_TBLS_PAGE_ADDR_REG, 0, 31);
	print_register("PMIRR_TBLS_PAGE_ADDR_REG", d64);
	d64 = read_reg(PMIRR_PTYPE_REDIRECT_CTRL_REG, 0, 31);
	print_register("PMIRR_PTYPE_REDIRECT_CTRL_REG", d64);
	d64 = read_reg(PMIRR_PTYPE_REDIRECT_CONTENT_REG, 0, 31);
	print_register("PMIRR_PTYPE_REDIRECT_CONTENT_REG", d64);
	d64 = read_reg(PMIRR_PTYPE_REDIRECT_INFO_REG, 0, 31);
	print_register("PMIRR_PTYPE_REDIRECT_INFO_REG", d64);
	d64 = read_reg(PMIRR_PTYPE_REDIRECT_CNT_REG, 0, 31);
	print_register("PMIRR_PTYPE_REDIRECT_CNT_REG", d64);
	d64 = read_reg(PMIRR_PRE_0DEBUG, 0, 31);
	print_register("PMIRR_PRE_0DEBUG", d64);
	d64 = read_reg(PMIRR_PRE_1DEBUG, 0, 31);
	print_register("PMIRR_PRE_1DEBUG", d64);
	d64 = read_reg(PMIRR_PRE_2DEBUG, 0, 31);
	print_register("PMIRR_PRE_2DEBUG", d64);
	d64 = read_reg(PMIRR_PRE_3DEBUG, 0, 31);
	print_register("PMIRR_PRE_3DEBUG", d64);
	d64 = read_reg(PMIRR_PORT_0DEBUG, 0, 31);
	print_register("PMIRR_PORT_0DEBUG", d64);
	d64 = read_reg(PMIRR_PORT_1DEBUG, 0, 31);
	print_register("PMIRR_PORT_1DEBUG", d64);
	d64 = read_reg(PMIRR_PORT_2DEBUG, 0, 31);
	print_register("PMIRR_PORT_2DEBUG", d64);
	d64 = read_reg(PMIRR_PORT_3DEBUG, 0, 31);
	print_register("PMIRR_PORT_3DEBUG", d64);
	d64 = read_reg(PMIRR_RSLT_0DEBUG, 0, 31);
	print_register("PMIRR_RSLT_0DEBUG", d64);
	d64 = read_reg(PMIRR_RSLT_1DEBUG, 0, 31);
	print_register("PMIRR_RSLT_1DEBUG", d64);
	d64 = read_reg(PMIRR_RSLT_2DEBUG, 0, 31);
	print_register("PMIRR_RSLT_2DEBUG", d64);
	d64 = read_reg(PMIRR_FIFO_NAFULL_REG, 0, 31);
	print_register("PMIRR_FIFO_NAFULL_REG", d64);
	d64 = read_reg(PMIRR_FIFO_NEMPTY_REG, 0, 31);
	print_register("PMIRR_FIFO_NEMPTY_REG", d64);
	d64 = read_reg(PMIRR_FIFO_WOVERFLOW_REG, 0, 31);
	print_register("PMIRR_FIFO_WOVERFLOW_REG", d64);
	d64 = read_reg(PMIRR_FIFO_ROVERFLOW_REG, 0, 31);
	print_register("PMIRR_FIFO_ROVERFLOW_REG", d64);
	d64 = read_reg(PMIRR_FIFO_ERRSIDE_REG, 0, 31);
	print_register("PMIRR_FIFO_ERRSIDE_REG", d64);
	d64 = read_reg(PMIRR_FIFO_WERR_REG, 0, 31);
	print_register("PMIRR_FIFO_WERR_REG", d64);
	d64 = read_reg(PMIRR_FIFO_RERR_REG, 0, 31);
	print_register("PMIRR_FIFO_RERR_REG", d64);
	d64 = read_reg(PMIRR_FIFO_RAM_ERR_REG, 0, 31);
	print_register("PMIRR_FIFO_RAM_ERR_REG", d64);
	d64 = read_reg(PMIRR_PTR_LEN_SUM_REG, 0, 31);
	print_register("PMIRR_PTR_LEN_SUM_REG", d64);
	d64 = read_reg(PMIRR_RSS_LAG_CNT, 0, 31);
	print_register("PMIRR_RSS_LAG_CNT", d64);
	d64 = read_reg(PMIRR_TBLS_WDATA_RADDR, 0, 31);
	print_register("PMIRR_TBLS_WDATA_RADDR", d64);
	print_color(GREEN, "--------PMIRR_LAG_PROFILE_REG---------");
	read_multi_line_ram_register_values(PMIRR_LAG_PROFILE_REG, 2, 2);

	print_color(GREEN, "-----------------PCAR---------------");
	d64 = read_reg(CAR_INT_STATUS_REG, 0, 31);
	print_register("CAR_INT_STATUS_REG", d64);
	d64 = read_reg(CAR_DFX_INFO, 0, 31);
	print_register("CAR_DFX_INFO", d64);
	d64 = read_reg(CAR_PRE_FIFO_REN_CNT, 0, 31);
	print_register("CAR_PRE_FIFO_REN_CNT", d64);
	d64 = read_reg(CAR_POST_FIFO_WEN_CNT, 0, 31);
	print_register("CAR_POST_FIFO_WEN_CNT", d64);
	d64 = read_reg(CAR_POST1_FIFO_WEN_CNT, 0, 31);
	print_register("CAR_POST1_FIFO_WEN_CNT", d64);

	print_color(GREEN, "-----------------TSE---------------");
	d64 = read_reg(TSE_CTRL_REG, 0, 31);
	print_register("TSE_CTRL_REG", d64);
	d64 = read_reg(TSE_INT_REG, 0, 31);
	print_register("TSE_INT_REG", d64);
	d64 = read_reg(TSE_TBL_OP_CTRL_REG, 0, 31);
	print_register("TSE_TBL_OP_CTRL_REG", d64);
	print_color(GREEN, "--------TSE_TBL_OP_INFO_REG---------");
	read_multi_line_ram_register_values(TSE_TBL_OP_INFO_REG, 16, 16);
	print_color(GREEN, "--------TSE_STAT_TABLE---------");
	read_multi_line_ram_register_values(TSE_STAT_TABLE, 16, 16);

	print_color(GREEN, "-----------------PSE---------------");
	d64 = read_reg(PSE_CTRL_REG, 0, 31);
	print_register("PSE_CTRL_REG", d64);
	d64 = read_reg(PSE_INT_REG, 0, 31);
	print_register("PSE_INT_REG", d64);
	d64 = read_reg(PSE_TBL_OP_CTRL_REG, 0, 31);
	print_register("PSE_TBL_OP_CTRL_REG", d64);
	d64 = read_reg(PSE_TBL_RSLT_REG0, 0, 31);
	print_register("PSE_TBL_RSLT_REG0", d64);
	print_color(GREEN, "--------PSE_TBL_RSLT_INFO_REG---------");
	read_multi_line_ram_register_values(PSE_TBL_RSLT_INFO_REG, 16, 16);
	print_color(GREEN, "--------PSE_STAT_TABLE---------");
	read_multi_line_ram_register_values(PSE_STAT_TABLE, 16, 16);

	print_color(GREEN, "-----------------MSE---------------");
	d64 = read_reg(MSE_CTRL_REG, 0, 31);
	print_register("MSE_CTRL_REG", d64);
	d64 = read_reg(MSE_INT_REG, 0, 31);
	print_register("MSE_INT_REG", d64);
	d64 = read_reg(MSE_CAP_CTRL_REG, 0, 31);
	print_register("MSE_CAP_CTRL_REG", d64);
	d64 = read_reg(MSE_TBL_RSLT_REG0, 0, 31);
	print_register("MSE_TBL_RSLT_REG0", d64);
	print_color(GREEN, "--------MSE_TBL_RSLT_INFO_REG---------");
	read_multi_line_ram_register_values(MSE_TBL_RSLT_INFO_REG, 16, 16);
	print_color(GREEN, "--------MSE_STAT_TABLE---------");
	read_multi_line_ram_register_values(MSE_STAT_TABLE, 16, 16);

	print_color(GREEN, "-----------------FSE---------------");
	d64 = read_reg(FSE_CTRL_REG, 0, 31);
	print_register("FSE_CTRL_REG", d64);
	d64 = read_reg(FSE_INT_REG, 0, 31);
	print_register("FSE_INT_REG", d64);
	d64 = read_reg(FSE_CAP_CTRL_REG, 0, 31);
	print_register("FSE_CAP_CTRL_REG", d64);
	d64 = read_reg(FSE_TBL_OP_CTRL_REG, 0, 31);
	print_register("FSE_TBL_OP_CTRL_REG", d64);
	d64 = read_reg(FSE_TBL_RSLT_REG0, 0, 31);
	print_register("FSE_TBL_RSLT_REG0", d64);
	d64 = read_reg(FSE_SE_CMDQ_DEBUG0_REG, 0, 31);
	print_register("FSE_SE_CMDQ_DEBUG0_REG", d64);
	print_color(GREEN, "--------FSE_STAT_TABLE---------");
	read_multi_line_ram_register_values(FSE_STAT_TABLE, 16, 16);
	print_color(GREEN, "--------FSE_TBL_RSLT_INFO_REG---------");
	read_multi_line_ram_register_values(FSE_TBL_RSLT_INFO_REG, 16, 16);

	print_color(GREEN, "-----------------IASE_TCAM---------------");
	d64 = read_reg(IASE_TCAM_CTRL_REG, 0, 31);
	print_register("IASE_TCAM_CTRL_REG", d64);
	d64 = read_reg(IASE_TCAM_INT_REG, 0, 31);
	print_register("IASE_TCAM_INT_REG", d64);
	d64 = read_reg(IASE_TCAM_INT_MASK_REG, 0, 31);
	print_register("IASE_TCAM_INT_MASK_REG", d64);
	d64 = read_reg(IASE_TCAM_TBL_OP_CTRL_REG, 0, 31);
	print_register("IASE_TCAM_TBL_OP_CTRL_REG", d64);
	d64 = read_reg(IASE_TCAM_TBL_OP_ADDR_REG0, 0, 31);
	print_register("IASE_TCAM_TBL_OP_ADDR_REG0", d64);
	d64 = read_reg(IASE_TCAM_TBL_OP_ADDR_REG1, 0, 31);
	print_register("IASE_TCAM_TBL_OP_ADDR_REG1", d64);
	d64 = read_reg(IASE_TCAM_TBL_RSLT_REG0, 0, 31);
	print_register("IASE_TCAM_TBL_RSLT_REG0", d64);
	d64 = read_reg(IASE_TCAM_TBL_RSLT_REG1, 0, 31);
	print_register("IASE_TCAM_TBL_RSLT_REG1", d64);
	d64 = read_reg(IASE_TCAM_TBL_RSLT_REG2, 0, 31);
	print_register("IASE_TCAM_TBL_RSLT_REG2", d64);
	d64 = read_reg(IASE_TCAM_TBL_RSLT_REG3, 0, 31);
	print_register("IASE_TCAM_TBL_RSLT_REG3", d64);
	d64 = read_reg(IASE_TCAM_AGE_CTRL_REG, 0, 31);
	print_register("IASE_TCAM_AGE_CTRL_REG", d64);
	d64 = read_reg(IASE_TCAM_AGE_CYCLE_REG, 0, 31);
	print_register("IASE_TCAM_AGE_CYCLE_REG", d64);
	d64 = read_reg(IASE_TCAM_CFG_0DEBUG, 0, 31);
	print_register("IASE_TCAM_CFG_0DEBUG", d64);
	d64 = read_reg(IASE_TCAM_SE_CMDQ_DEBUG0_REG, 0, 31);
	print_register("IASE_TCAM_SE_CMDQ_DEBUG0_REG", d64);
	print_color(GREEN, "--------IASE_TCAM_STAT_TABLE---------");
	read_multi_line_ram_register_values(IASE_TCAM_STAT_TABLE, 16, 16);

	print_color(GREEN, "-----------------EASE_TCAM---------------");
	d64 = read_reg(EASE_TCAM_CTRL_REG, 0, 31);
	print_register("EASE_TCAM_CTRL_REG", d64);
	d64 = read_reg(EASE_TCAM_INT_REG, 0, 31);
	print_register("EASE_TCAM_INT_REG", d64);
	d64 = read_reg(EASE_TCAM_INT_MASK_REG, 0, 31);
	print_register("EASE_TCAM_INT_MASK_REG", d64);
	d64 = read_reg(EASE_TCAM_TBL_OP_CTRL_REG, 0, 31);
	print_register("EASE_TCAM_TBL_OP_CTRL_REG", d64);
	d64 = read_reg(EASE_TCAM_TBL_OP_ADDR_REG0, 0, 31);
	print_register("EASE_TCAM_TBL_OP_ADDR_REG0", d64);
	d64 = read_reg(EASE_TCAM_TBL_OP_ADDR_REG1, 0, 31);
	print_register("EASE_TCAM_TBL_OP_ADDR_REG1", d64);
	d64 = read_reg(EASE_TCAM_TBL_RSLT_REG0, 0, 31);
	print_register("EASE_TCAM_TBL_RSLT_REG0", d64);
	d64 = read_reg(EASE_TCAM_TBL_RSLT_REG1, 0, 31);
	print_register("EASE_TCAM_TBL_RSLT_REG1", d64);
	d64 = read_reg(EASE_TCAM_TBL_RSLT_REG2, 0, 31);
	print_register("EASE_TCAM_TBL_RSLT_REG2", d64);
	d64 = read_reg(EASE_TCAM_TBL_RSLT_REG3, 0, 31);
	print_register("EASE_TCAM_TBL_RSLT_REG3", d64);
	d64 = read_reg(EASE_TCAM_AGE_CTRL_REG, 0, 31);
	print_register("EASE_TCAM_AGE_CTRL_REG", d64);
	d64 = read_reg(EASE_TCAM_AGE_CYCLE_REG, 0, 31);
	print_register("EASE_TCAM_AGE_CYCLE_REG", d64);
	d64 = read_reg(EASE_TCAM_CFG_0DEBUG, 0, 31);
	print_register("EASE_TCAM_CFG_0DEBUG", d64);
	d64 = read_reg(EASE_TCAM_ARB_0DEBUG, 0, 31);
	print_register("EASE_TCAM_ARB_0DEBUG", d64);
	d64 = read_reg(EASE_TCAM_SE_CMDQ_DEBUG0_REG, 0, 31);
	print_register("EASE_TCAM_SE_CMDQ_DEBUG0_REG", d64);
	d64 = read_reg(EASE_TCAM_SE_CMDQ_R_CNT, 0, 31);
	print_register("EASE_TCAM_SE_CMDQ_R_CNT", d64);
	d64 = read_reg(EASE_TCAM_SE_CMDQ_W_CNT, 0, 31);
	print_register("EASE_TCAM_SE_CMDQ_W_CNT", d64);
	print_color(GREEN, "--------EASE_TCAM_STAT_TABLE---------");
	read_multi_line_ram_register_values(EASE_TCAM_STAT_TABLE, 16, 16);
}

void ptype_display()
{
	uint64_t d64 = 0;
	print_color(YELLOW, "**************** PTYPE ****************");

	for (int i = 0; i < MAX_SPORT; i++)
	{
		if (!i)
			print_color(GREEN, "ETH:");
		else
			printf("\033[;;32m%s%d\033[0m\n", "HOST:", i - 1);
		for (int j = 0; ptype_entry_keys[j] != NULL; j++)
		{
			/* 1 pype is 1K(0x400 = 4B * 256 = 1024), 1 reg is 4B(32bit) */
			d64 = read_reg(PTYPE_BASE + i * PTYPE_CNT_SIZE + j * 4, 0, 31);
			if (d64)
			{
				if (strstr(ptype_entry_keys[j], "ERR") != NULL)
					printf("%s:\033[;;31m[%5ld]\033[0m\n", ptype_entry_keys[j], d64);
				else
					printf("%s:\033[;;34m[%5ld]\033[0m\n", ptype_entry_keys[j], d64);
			}
		}
	}
}

void rdma_debug_display()
{
	uint64_t d64 = 0;

	print_color(YELLOW, "**************** RDMA DEBUG ****************");
	print_color(GREEN, "-----------------BASE INFO---------------");
	d64 = read_reg(PRJ_RDMA_VERSION, 0, 31);
	printf("PRJ_RDMA_VERSION:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INIT_DONE_REG, 0, 31);
	printf("RDMA_INIT_DONE_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INT_REG, 0, 31);
	printf("RDMA_INT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INT_MASK_REG, 0, 31);
	printf("RDMA_INT_MASK_REG:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------STAE-----------------");
	d64 = read_reg(STAE_BASE_ADDR_REG, 0, 31);
	printf("STAE_BASE_ADDR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_INT_REG, 0, 31);
	printf("STAE_INT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_INT_MASK_REG, 0, 31);
	printf("STAE_INT_MASK_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_WOVERFLOW_REG, 0, 31);
	printf("STAE_CMQE_FIFO_WOVERFLOW_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_ROVERFLOW_REG, 0, 31);
	printf("STAE_CMQE_FIFO_ROVERFLOW_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_WERR_REG, 0, 31);
	printf("STAE_CMQE_FIFO_WERR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_RERR_REG, 0, 31);
	printf("STAE_CMQE_FIFO_RERR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_ERRSIDE_REG, 0, 31);
	printf("STAE_CMQE_FIFO_ERRSIDE_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM_ERR_REG, 0, 31);
	printf("STAE_RAM_ERR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM0_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM0_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM1_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM1_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM2_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM2_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM3_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM3_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_DFX_CNT_REG, 0, 31);
	printf("STAE_DFX_CNT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_ERR_RSV_CNT_REG, 0, 31);
	printf("STAE_ERR_RSV_CNT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_FIFO_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_PRO1_FIFO_RAM1_ERR_DEBUG_REG, 0, 31);
	printf("STAE_PRO1_FIFO_RAM1_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_PRO1_FIFO_RAM2_ERR_DEBUG_REG, 0, 31);
	printf("STAE_PRO1_FIFO_RAM2_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);

	show_rdma_stat_vport(g_dev);
	show_rdma_stat_opcode_tx(g_dev);
	show_rdma_stat_opcode_rx(g_dev);

	print_color(MAGENTA, "-----------------VF---------------");
	// VF 总共要读取2K * 4 个64位的寄存器，分1次读取：每次间接读取只能读256 * 32 个 64位寄存器
	write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x60000);
	for (int i = 0; i < MAX_VF; i++)
	{
		for (enum int_rdma_stae_vf j = TX_REQ_WSLD_NML_PKT_CNT; j <= RX_REQ_UD_MC_BYTE_CNT; j++)
		{
			d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + i * 0x100 + j * 8, 0, 63);
			d64 = (d64 >> 32) | (d64 << 32);
			if (d64)
			{
				printf("vf %2d %s:\033[;;35m[%.16lX]\033[0m\n", i, rdma_stae_vf_keys[j], d64);
			}
		}
	}

	show_rdma_stat_ecode(g_dev);

	print_color(GREEN, "-------------------CMQE-----------------");
	d64 = read_reg(CMQE_INT_REG, 0, 31);
	printf("INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(CMQE_DEAL_DEBUG0_REG, 0, 31);
	printf("CMQE_DEAL_DEBUG0_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(CMQE_DEAL_DEBUG1_REG, 0, 31);
	printf("CMQE_DEAL_DEBUG1_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------TPE-----------------");
	d64 = read_reg(TPE_INT_REG, 0, 31);
	printf("TPE_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_FIFO_NAFULL_REG_0, 0, 31);
	printf("TPE_FIFO_NAFULL_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_FIFO_NAFULL_REG_1, 0, 31);
	printf("TPE_FIFO_NAFULL_REG_1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_FIFO_NAFULL_REG_2, 0, 31);
	printf("TPE_FIFO_NAFULL_REG_2*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_FIFO_NEMPTY_REG_0, 0, 31);
	printf("TPE_FIFO_NEMPTY_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_FIFO_NEMPTY_REG_1, 0, 31);
	printf("TPE_FIFO_NEMPTY_REG_1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_FIFO_NEMPTY_REG_2, 0, 31);
	printf("TPE_FIFO_NEMPTY_REG_2*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_KBUSRD_STATUS_REG, 0, 31);
	printf("TPE_KBUSRD_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_KBUSRD_ERR_STATUS_REG, 0, 31);
	printf("TPE_KBUSRD_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_DB_CNT, 0, 7);
	printf("QSCH_TPE_DB_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_DB_CHK_DEBUG0, 0, 31);
	printf("TPE_DB_CHK_DEBUG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_WQERD_DEBUG0, 0, 31);
	printf("TPE_WQERD_DEBUG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_DB_PRO_DEBUG0, 0, 31);
	printf("TPE_DB_PRO_DEBUG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_DB_PRO_DEBUG1, 0, 31);
	printf("TPE_DB_PRO_DEBUG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_WQE_PRO_DEBUG0, 0, 31);
	printf("TPE_WQE_PRO_DEBUG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_WQE_PRO_DEBUG1, 0, 31);
	printf("TPE_WQE_PRO_DEBUG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_WQE_PRO_DEBUG6, 0, 31);
	printf("TPE_WQE_PRO_DEBUG6*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_WQE_PRO_DEBUG18, 0, 31);
	printf("TPE_WQE_PRO_DEBUG18*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_PKT_PRO_DEBUG0, 0, 31);
	printf("TPE_PKT_PRO_DEBUG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_PKT_PRO_DEBUG2, 0, 31);
	printf("TPE_PKT_PRO_DEBUG2*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_PKT_PRO_DEBUG3, 0, 31);
	printf("TPE_PKT_PRO_DEBUG3*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TPE_QSCH_DB_RINGBACK_DEBUG, 0, 31);
	printf("TPE_QSCH_DB_RINGBACK_DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------TME-----------------");
	d64 = read_reg(TME_FIFO_NAFULL_REG, 0, 31);
	printf("TME_FIFO_NAFULL_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_FIFO_NEMPTY_REG, 0, 31);
	printf("TME_FIFO_NEMPTY_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRE_0DEBUG, 0, 31);
	printf("TME_PRE_0DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRE_1DEBUG, 0, 31);
	printf("TME_PRE_1DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRE_2DEBUG, 0, 31);
	printf("TME_PRE_2DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRE_3DEBUG, 0, 31);
	printf("TME_PRE_3DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRO_0DEBUG, 0, 31);
	printf("TME_PRO_0DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRO_1DEBUG, 0, 31);
	printf("TME_PRO_1DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRO_2DEBUG, 0, 31);
	printf("TME_PRO_2DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRO_3DEBUG, 0, 31);
	printf("TME_PRO_3DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MERG_0DEBUG, 0, 31);
	printf("TME_MERG_0DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MERG_1DEBUG, 0, 31);
	printf("TME_MERG_1DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MERG_2DEBUG, 0, 31);
	printf("TME_MERG_2DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MERG_3DEBUG, 0, 31);
	printf("TME_MERG_3DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MRD_0DEBUG, 0, 31);
	printf("TME_MRD_0DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MRD_1DEBUG, 0, 31);
	printf("TME_MRD_1DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MRD_2DEBUG, 0, 31);
	printf("TME_MRD_2DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MWR_0DEBUG, 0, 31);
	printf("TME_MWR_0DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_MWR_1DEBUG, 0, 31);
	printf("TME_MWR_1DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRD_0DEBUG, 0, 31);
	printf("TME_PRD_0DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRD_1DEBUG, 0, 31);
	printf("TME_PRD_1DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRD_2DEBUG, 0, 31);
	printf("TME_PRD_2DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRD_3DEBUG, 0, 31);
	printf("TME_PRD_3DEBUG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRE_CTRL_INFO_DEBUG_CNT, 0, 31);
	printf("TME_PRE_CTRL_INFO_DEBUG_CNT:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TME_PRO_CTRL_INFO_DEBUG_CNT, 0, 31);
	printf("TME_PRO_CTRL_INFO_DEBUG_CNT:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------TDE-----------------");
	d64 = read_reg(TDE_INT_REG, 0, 31);
	printf("TDE_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_WOVERFLOW_REG_0, 0, 31);
	printf("TDE_FIFO_WOVERFLOW_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_ROVERFLOW_REG_0, 0, 31);
	printf("TDE_FIFO_ROVERFLOW_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_WERR_REG_0, 0, 31);
	printf("TDE_FIFO_WERR_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_RERR_REG_0, 0, 31);
	printf("TDE_FIFO_RERR_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_ERRSIDE_REG_0, 0, 31);
	printf("TDE_FIFO_ERRSIDE_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_RAM_ERR_REG_0, 0, 31);
	printf("TDE_RAM_ERR_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_NAFULL_REG_0, 0, 31);
	printf("TDE_FIFO_NAFULL_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_NFULL_REG_0, 0, 31);
	printf("TDE_FIFO_NFULL_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_NAEMPTY_REG_0, 0, 31);
	printf("TDE_FIFO_NAEMPTY_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_FIFO_NEMPTY_REG_0, 0, 31);
	printf("FIFO_NEMPTY_REG_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_DEBUG_PKT_CNT_IN, 0, 31);
	printf("TDE_DEBUG_PKT_CNT_IN*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_DEBUG_PKT_CNT_OUT, 0, 31);
	printf("TDE_DEBUG_PKT_CNT_OUT*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TDE_DEBUG_PKT_CELL_OUT_CNT, 0, 31);
	printf("TDE_DEBUG_PKT_CELL_OUT_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------RPE-----------------");
	d64 = read_reg(RPE_INT_REG, 0, 31);
	printf("RPE_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_INT_MASK_REG, 0, 31);
	printf("RPE_INT_MASK_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_NAFULL_RGE_0, 0, 31);
	printf("RPE_FIFO_NAFULL_RGE_0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_NAFULL_RGE_1, 0, 31);
	printf("RPE_FIFO_NAFULL_RGE_1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_NEMPTY_REG0, 0, 31);
	printf("RPE_FIFO_NEMPTY_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_NEMPTY_REG1, 0, 31);
	printf("RPE_FIFO_NEMPTY_REG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_WOVERFLOW_REG0, 0, 31);
	printf("RPE_FIFO_WOVERFLOW_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_WOVERFLOW_REG1, 0, 31);
	printf("RPE_FIFO_WOVERFLOW_REG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_ROVERFLOW_REG0, 0, 31);
	printf("RPE_FIFO_ROVERFLOW_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_ROVERFLOW_REG1, 0, 31);
	printf("RPE_FIFO_ROVERFLOW_REG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_WERR_REG0, 0, 31);
	printf("RPE_FIFO_WERR_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_WERR_REG1, 0, 31);
	printf("RPE_FIFO_WERR_REG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_RERR_REG0, 0, 31);
	printf("RPE_FIFO_RERR_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_RERR_REG1, 0, 31);
	printf("RPE_FIFO_RERR_REG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_RAM_ERR_REG0, 0, 31);
	printf("RPE_FIFO_RAM_ERR_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_FIFO_RAM_ERR_REG1, 0, 31);
	printf("RPE_FIFO_RAM_ERR_REG1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_VFT_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_VFT_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_VFT_RAM_ERR_REG, 0, 31);
	printf("RPE_VFT_RAM_ERR_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_INTER_ERROR, 0, 7);
	printf("RPE_INTER_ERROR*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC0_STATUS_REG, 0, 31);
	printf("RPE_QPC0_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC0_ERR_STATUS_REG, 0, 31);
	printf("RPE_QPC0_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC0_CNT_REG, 0, 31);
	printf("RPE_QPC0_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC0_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC0_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_PRO_STATUS_REG, 0, 31);
	printf("RPE_QPC1_PRO_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_PRO_CNT_REG, 0, 31);
	printf("RPE_QPC1_PRO_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_PRO_ERR_STATUS_REG, 0, 31);
	printf("RPE_QPC1_PRO_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_PRO_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC1_PRO_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_STATUS_REG, 0, 31);
	printf("RPE_QPC1_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_CNT_REG, 0, 31);
	printf("RPE_QPC1_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_OUT_CNT_REG, 0, 31);
	printf("RPE_QPC1_OUT_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_ERR_STATUS_REG, 0, 31);
	printf("RPE_QPC1_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC1_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_READ_STATUS_REG, 0, 31);
	printf("RPE_REQUEST_WQE_READ_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_READ_ERR_REG, 0, 31);
	printf("RPE_REQUEST_WQE_READ_ERR_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_READ_CNT_REG, 0, 31);
	printf("RPE_REQUEST_WQE_READ_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_READ_ERR_CNT_REG, 0, 31);
	printf("RPE_REQUEST_WQE_READ_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_READ_STATUS_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_READ_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_READ_ERR_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_READ_ERR_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_READ_CNT_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_READ_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_READ_ERR_CNT_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_READ_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_STATUS_REG, 0, 31);
	printf("RPE_QPC_SRFQ_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_IN_CNT_REG, 0, 31);
	printf("RPE_QPC_SRFQ_IN_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC_SRFQ_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_PRO_STATUS_REG, 0, 31);
	printf("RPE_QPC_SRFQ_PRO_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_PRO_CNT_REG, 0, 31);
	printf("RPE_QPC_SRFQ_PRO_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_PRO_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC_SRFQ_PRO_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_WQE_INFO_FIFO_DEBUG_REG, 0, 31);
	printf("RPE_QPC_SRFQ_WQE_INFO_FIFO_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC_SRFQ_WQE_INFO_RAM_ERR_DEBIG_ERG, 0, 31);
	printf("RPE_QPC_SRFQ_WQE_INFO_RAM_ERR_DEBIG_ERG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_READ_STATUS_REG, 0, 31);
	printf("RPE_SRFQ_WQE_READ_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_READ_ERR_STATUS_REG, 0, 31);
	printf("RPE_SRFQ_WQE_READ_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_READ_CNT_REG, 0, 31);
	printf("RPE_SRFQ_WQE_READ_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_READ_ERR_CNT_REG, 0, 31);
	printf("RPE_SRFQ_WQE_READ_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_PRO_STATUS_REG, 0, 31);
	printf("RPE_WQE_PRO_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_PRO_ERR_STATUS_REG, 0, 31);
	printf("RPE_WQE_PRO_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_PRO_CNT_REG, 0, 31);
	printf("RPE_WQE_PRO_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_PRO_SGE_CNT_REG, 0, 31);
	printf("RPE_WQE_PRO_SGE_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_PRO_ERR_CNT_REG, 0, 31);
	printf("RPE_WQE_PRO_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_READ_STATUS_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_READ_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_READ_ERR_STATUS_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_READ_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_READ_CNT_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_READ_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_READ_ERR_CNT_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_READ_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO1_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_ERR_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO1_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO1_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_ERR_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO1_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_ERR_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_ERR_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO2_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_ERR_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO2_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO2_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_ERR_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO2_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_ERR_STATUS_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_ERR_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_ERR_CNT_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC2_PRO_STATUS_REG, 0, 31);
	printf("RPE_QPC2_PRO_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC2_PRO_CNT_REG, 0, 31);
	printf("RPE_QPC2_PRO_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC2_PRO_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC2_PRO_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC2_STATUS_REG, 0, 31);
	printf("RPE_QPC2_STATUS_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC2_IN_CNT_REG, 0, 31);
	printf("RPE_QPC2_IN_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC2_ERR_CNT_REG, 0, 31);
	printf("RPE_QPC2_ERR_CNT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_ING_QPC1_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_ING_QPC1_INFO_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_ING_QPC0_CTRL_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_ING_QPC0_CTRL_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_ING_QPC2_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_ING_QPC2_DATA_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_KBUS_REQ_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_KBUS_REQ_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_KBUS_ACTION_FIFO_RAM_ERR_DEBUG, 0, 31);
	printf("RPE_KBUS_ACTION_FIFO_RAM_ERR_DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_PDMUX_RPE_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_PDMUX_RPE_INFO_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_PDMUX_RPE_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_PDMUX_RPE_DATA_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_IPRO_RPE_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_IPRO_RPE_INFO_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_IPRO_RPE_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_IPRO_RPE_DATA_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_TDE_RPE_INFO_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_TDE_RPE_INFO_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_TDE_RPE_DATA_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_TDE_RPE_DATA_FIFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC0_CTRL_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_QPC0_CTRL_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC0_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_QPC0_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_CCE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_CCE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_ORDER_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_ORDER_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_ORDER_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_ORDER_DATA_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_QPC1_QPC2_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_QPC1_QPC2_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_REQUEST_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RESPONSE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_LAE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_LAE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_KEY_ACTION_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_REQUEST_KEY_ACTION_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_REQUEST_WQE_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_PRO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_REQUEST_WQE_PRO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_REQUEST_WQE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_REQUEST_WQE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_KEY_ACTION_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RESPONSE_KEY_ACTION_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_PRO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_PRO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RESPONSE_WQE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RESPONSE_WQE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_KEY_ACTION_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SRFQ_KEY_ACTION_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SRFQ_WQE_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_PRO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SRFQ_WQE_PRO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SRFQ_WQE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SRFQ_WQE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_SGB_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_WQE_SGB_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_SGB_KEY_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_WQE_SGB_KEY_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_WQE_SGB_SGE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_WQE_SGB_SGE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_KEY_ACTION_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_GET_KEY_ACTION_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_PRO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_PRO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_LEN_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_LEN_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_GET_WQE_KEY_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_GET_WQE_KEY_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_FIRST_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO1_FIRST_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_PRO2_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO1_PRO2_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_PRO1_PRO2_WQE_LEN_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_PRO1_PRO2_WQE_LEN_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_PRO1_PRO2_WQE_KEY_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_PRO1_PRO2_WQE_KEY_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_LEN_PRO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_LEN_PRO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_LEN_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_LEN_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_PRO_SGE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_PRO_SGE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO1_COM_OUT_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO1_COM_OUT_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_FIRST_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO2_FIRST_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_QPC2_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_QPC2_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RME_SGE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RME_SGE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_LEN_PRO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_LEN_PRO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_LEN_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_LEN_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_PRO_SGE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_PRO_SGE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_SGB_PRO2_COM_OUT_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_SGB_PRO2_COM_OUT_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RME_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RME_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RCE_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RCE_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RCE_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RCE_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_RDE_DATA_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_RDE_DATA_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RPE_PKT_INFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("RPE_PKT_INFO_RAM_ERR_DEBUG_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------RME-----------------");
	d64 = read_reg(RME_FIFO_NAFULL_REG, 0, 31);
	printf("RME_FIFO_NAFULL_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_FIFO_NEMPTY_REG, 0, 31);
	printf("RME_FIFO_NEMPTY_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRE_0DEBUG, 0, 31);
	printf("RME_PRE_0DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRE_1DEBUG, 0, 31);
	printf("RME_PRE_1DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRE_2DEBUG, 0, 31);
	printf("RME_PRE_2DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRE_3DEBUG, 0, 31);
	printf("RME_PRE_3DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRO_0DEBUG, 0, 31);
	printf("RME_PRO_0DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRO_1DEBUG, 0, 31);
	printf("RME_PRO_1DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRO_2DEBUG, 0, 31);
	printf("RME_PRO_2DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRO_3DEBUG, 0, 31);
	printf("RME_PRO_3DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MERG_0DEBUG, 0, 31);
	printf("RME_MERG_0DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MERG_1DEBUG, 0, 31);
	printf("RME_MERG_1DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MERG_2DEBUG, 0, 31);
	printf("RME_MERG_2DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MERG_3DEBUG, 0, 31);
	printf("RME_MERG_3DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MRD_0DEBUG, 0, 31);
	printf("RME_MRD_0DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MRD_1DEBUG, 0, 31);
	printf("RME_MRD_1DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MRD_2DEBUG, 0, 31);
	printf("RME_MRD_2DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MWR_0DEBUG, 0, 31);
	printf("RME_MWR_0DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_MWR_1DEBUG, 0, 31);
	printf("RME_MWR_1DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRD_0DEBUG, 0, 31);
	printf("RME_PRD_0DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRD_1DEBUG, 0, 31);
	printf("RME_PRD_1DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRD_2DEBUG, 0, 31);
	printf("RME_PRD_2DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRD_3DEBUG, 0, 31);
	printf("RME_PRD_3DEBUG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRE_CTRL_INFO_DEBUG_CNT, 0, 31);
	printf("RME_PRE_CTRL_INFO_DEBUG_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RME_PRO_CTRL_INFO_DEBUG_CNT, 0, 31);
	printf("RME_PRO_CTRL_INFO_DEBUG_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------RDE-----------------");
	d64 = read_reg(RDE_INTP_STATUS, 0, 31);
	printf("RDE_INTP_STATUS*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDE_DEBUG_PKT_CNT, 0, 31);
	printf("RDE_DEBUG_PKT_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------RCE-----------------");
	d64 = read_reg(RCE_INIT_REG, 0, 31);
	printf("RCE_INIT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_EIRQ_INT_REG, 0, 31);
	printf("RCE_EIRQ_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_EIRQ_FIFO_WOVERFLOW_REG, 0, 31);
	printf("RCE_EIRQ_FIFO_WOVERFLOW_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_EIRQ_FIFO_ROVERFLOW_REG, 0, 31);
	printf("RCE_EIRQ_FIFO_ROVERFLOW_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_EIRQ_FIFO_NEMPTY_REG, 0, 31);
	printf("RCE_EIRQ_FIFO_NEMPTY_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_REQ_PRE_DEBUG_CNT0, 0, 31);
	printf("RCE_REQ_PRE_DEBUG_CNT0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_REQ_PRE_DEBUG_CNT1, 0, 31);
	printf("RCE_REQ_PRE_DEBUG_CNT1*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_QPCQ_INT_REG, 0, 31);
	printf("RCE_QPCQ_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_QPCQ_FIFO_WOVERFLOW_REG, 0, 31);
	printf("RCE_QPCQ_FIFO_WOVERFLOW_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_QPCQ_FIFO_ROVERFLOW_REG, 0, 31);
	printf("RCE_QPCQ_FIFO_ROVERFLOW_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_QPCQ_FIFO_NEMPTY_REG, 0, 31);
	printf("RCE_QPCQ_FIFO_NEMPTY_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_EAT_PRO_DEBUG_CNT0, 0, 31);
	printf("RCE_EAT_PRO_DEBUG_CNT0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_CEAE_INT_REG, 0, 31);
	printf("RCE_CEAE_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_CEAE_FIFO_WOVERFLOW_REG, 0, 31);
	printf("RCE_CEAE_FIFO_WOVERFLOW_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_CEAE_FIFO_ROVERFLOW_REG, 0, 31);
	printf("RCE_CEAE_FIFO_ROVERFLOW_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_CEAE_FIFO_NEMPTY_REG, 0, 31);
	printf("RCE_CEAE_FIFO_NEMPTY_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RCE_STAT_MUX_DEBUG1_REG, 0, 31);
	printf("RCE_STAT_MUX_DEBUG1_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------TQE-----------------");
	d64 = read_reg(TQE_INT_REG, 0, 31);
	printf("TQE_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_DB_DELAY_TIME_LEVEL, 0, 31);
	printf("TQE_DB_DELAY_TIME_LEVEL*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_FLUSH_DELAY_TIME_LEVEL, 0, 31);
	printf("TQE_FLUSH_DELAY_TIME_LEVEL*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_TIME_CODE_MAX_LEVEL, 0, 31);
	printf("TQE_TIME_CODE_MAX_LEVEL*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STANDARD_RTO_EN, 0, 31);
	printf("TQE_STANDARD_RTO_EN*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_TIMEQ_DLY_MAX, 0, 31);
	printf("TQE_TIMEQ_DLY_MAX*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_CMQE_GET_DLY_TIME, 0, 31);
	printf("TQE_CMQE_GET_DLY_TIME*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_WOF, 0, 31);
	printf("TQE_STATUS_FIFO_WOF*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_ROF, 0, 31);
	printf("TQE_STATUS_FIFO_ROF*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_WERR, 0, 31);
	printf("TQE_STATUS_FIFO_WERR*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_RERR, 0, 31);
	printf("TQE_STATUS_FIFO_RERR*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_RAM_ERR, 0, 31);
	printf("TQE_STATUS_RAM_ERR*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_ERRSIDE, 0, 31);
	printf("TQE_STATUS_FIFO_ERRSIDE*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_NAFULL, 0, 31);
	printf("TQE_STATUS_FIFO_NAFULL*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_STATUS_FIFO_NEMPTY, 0, 31);
	printf("TQE_STATUS_FIFO_NEMPTY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_TQ_MEM_NEMPTY, 0, 31);
	printf("TQE_LONGDLY_TQ_MEM_NEMPTY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RTO_CODE_INVALID_CNT, 0, 31);
	printf("TQE_RTO_CODE_INVALID_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_TQ00_07_ONCHIP_DBNUM, 0, 31);
	printf("TQE_LONGDLY_TQ00_07_ONCHIP_DBNUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_TQ08_15_ONCHIP_DBNUM, 0, 31);
	printf("TQE_LONGDLY_TQ08_15_ONCHIP_DBNUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_TQ16_23_ONCHIP_DBNUM, 0, 31);
	printf("TQE_LONGDLY_TQ16_23_ONCHIP_DBNUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_TQ24_31_ONCHIP_DBNUM, 0, 31);
	printf("TQE_LONGDLY_TQ24_31_ONCHIP_DBNUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_DEQ_ATTR_TBL_NEMPTY, 0, 31);
	printf("TQE_LONGDLY_DEQ_ATTR_TBL_NEMPTY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_DBG_PAGE_FREE_HDR, 0, 31);
	printf("TQE_LONGDLY_DBG_PAGE_FREE_HDR*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_DBG_PAGE_FREE_TAIL, 0, 31);
	printf("TQE_LONGDLY_DBG_PAGE_FREE_TAIL*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_DBG_PAGE_FREE_NUM, 0, 31);
	printf("TQE_LONGDLY_DBG_PAGE_FREE_NUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_LONGDLY_DBG_INFO_54BIT_32BIT, 0, 31);
	printf("TQE_LONGDLY_DBG_INFO_54BIT_32BIT*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_DMA_DBG_INFO_40BIT_16BIT, 0, 31);
	printf("TQE_DMA_DBG_INFO_40BIT_16BIT*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RCE_DB_NUM, 0, 31);
	printf("RCE_TQE_DB_NUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_TPE_DB_NUM, 0, 31);
	printf("TPE_TQE_DB_NUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_QSCH_RCE_DB_NUM, 0, 31);
	printf("TQE_QSCH_RCE_DB_NUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_QSCH_TPE_DB_NUM, 0, 31);
	printf("TQE_QSCH_TPE_DB_NUM*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RCE_TQE_CQ_DB_VLD_CNT, 0, 31);
	printf("RCE_TQE_CQ_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RCE_CQ_DB_VLD_CNT, 0, 31);
	printf("TQE_RCE_CQ_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RPE_TQE_QP_FLUSH_GET_CNT, 0, 31);
	printf("RPE_TQE_QP_FLUSH_GET_CNT*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------NTFE-----------------");
	d64 = read_reg(NTFE_INT_REG, 0, 31);
	printf("NTFE_INT_REG*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_WOVERFLOW_REG0, 0, 31);
	printf("NTFE_FIFO_WOVERFLOW_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_ROVERFLOW_REG0, 0, 31);
	printf("NTFE_FIFO_ROVERFLOW_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_WERR_REG0, 0, 31);
	printf("NTFE_FIFO_WERR_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_RERR_REG0, 0, 31);
	printf("NTFE_FIFO_RERR_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_RAM_ERR_REG0, 0, 31);
	printf("NTFE_FIFO_RAM_ERR_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_ERRSIDE_REG0, 0, 31);
	printf("NTFE_FIFO_ERRSIDE_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_NAFULL_REG0, 0, 31);
	printf("NTFE_FIFO_NAFULL_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_FIFO_NEMPTY_REG0, 0, 31);
	printf("NTFE_FIFO_NEMPTY_REG0*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_NOTIFY_VLD_CNT, 0, 31);
	printf("TLPE_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_RQ_INFO_FIFO_WEN_CNT, 0, 31);
	printf("RQ_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_CQ_INFO_FIFO_WEN_CNT, 0, 31);
	printf("CQ_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_CMQE_VLD_CNT, 0, 31);
	printf("CMQE_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_RCE_VLD_CNT, 0, 31);
	printf("RCE_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_QSCH_DB_CNT, 0, 31);
	printf("SW_DB_TO_QSCH*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SRFQ_NTFY_CNT, 0, 31);
	printf("SRFQ_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_QP_FLUSH_NTFY_VLD_CNT, 0, 31);
	printf("QP_FLUSH_NOTIFY*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT34, 24, 31);
	printf("LOSS_QP_FLUSH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 24, 31);
	printf("LOSS_ASM_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 16, 23);
	printf("LOSS_SRFQ_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 8, 15);
	printf("LOSS_CQ_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 0, 7);
	printf("LOSS_RQ_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------QSCH-----------------");
	d64 = read_reg(QSCH_RDMA_SW_DB_FIFO_WEN_CNT, 0, 15);
	printf("NTFE_QSCH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_DB_FIFO_WEN_CNT, 0, 15);
	printf("TPE_QSCH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_RCE_DB_FIFO_WEN_CNT, 0, 15);
	printf("RCE_QSCH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TQE_DB_FIFO_WEN_CNT, 0, 15);
	printf("TQE_QSCH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_CCE_DB_FIFO_WEN_CNT, 0, 15);
	printf("CCE_QSCH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_DIST_DBQM_DB_FIFO_WEN_CNT, 0, 15);
	printf("DBQM_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_CSCH_DB_FIFO_WEN_CNT, 0, 15);
	printf("CSCH_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_INFO_VLD_CNT, 0, 15);
	printf("DB_TO_TPE*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_RDMA_SW_DB_LOSS_CNT, 0, 15);
	printf("LOSS_SW_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_TPE_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_RCE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_RCE_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TQE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_TQE_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_CCE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_CCE_DB*:\033[;;34m[%.8lX]\033[0m\n", d64);
}

void rdma_display()
{
	uint64_t d64 = 0;
	uint64_t d641 = 0;
	uint64_t d642 = 0;
	uint64_t d643 = 0;

	print_color(YELLOW, "**************** RDMA ****************");
	print_color(GREEN, "-----------------BASE INFO---------------");
	d64 = read_reg(PRJ_RDMA_VERSION, 0, 31);
	printf("PRJ_RDMA_VERSION:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INIT_DONE_REG, 0, 31);
	printf("RDMA_INIT_DONE_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INT_REG, 0, 31);
	printf("RDMA_INT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INT_MASK_REG, 0, 31);
	printf("RDMA_INT_MASK_REG:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------STAE-----------------");
	d64 = read_reg(STAE_BASE_ADDR_REG, 0, 31);
	printf("STAE_BASE_ADDR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_INT_REG, 0, 31);
	printf("STAE_INT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_INT_MASK_REG, 0, 31);
	printf("STAE_INT_MASK_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_WOVERFLOW_REG, 0, 31);
	printf("STAE_CMQE_FIFO_WOVERFLOW_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_ROVERFLOW_REG, 0, 31);
	printf("STAE_CMQE_FIFO_ROVERFLOW_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_WERR_REG, 0, 31);
	printf("STAE_CMQE_FIFO_WERR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_RERR_REG, 0, 31);
	printf("STAE_CMQE_FIFO_RERR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_CMQE_FIFO_ERRSIDE_REG, 0, 31);
	printf("STAE_CMQE_FIFO_ERRSIDE_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM_ERR_REG, 0, 31);
	printf("STAE_RAM_ERR_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM0_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM0_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM1_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM1_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM2_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM2_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_RAM3_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_RAM3_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_DFX_CNT_REG, 0, 31);
	printf("STAE_DFX_CNT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_ERR_RSV_CNT_REG, 0, 31);
	printf("STAE_ERR_RSV_CNT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_FIFO_RAM_ERR_DEBUG_REG, 0, 31);
	printf("STAE_FIFO_RAM_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_PRO1_FIFO_RAM1_ERR_DEBUG_REG, 0, 31);
	printf("STAE_PRO1_FIFO_RAM1_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(STAE_PRO1_FIFO_RAM2_ERR_DEBUG_REG, 0, 31);
	printf("STAE_PRO1_FIFO_RAM2_ERR_DEBUG_REG:\033[;;34m[%.8lX]\033[0m\n", d64);

	show_rdma_stat_vport(g_dev);
	show_rdma_stat_opcode_tx(g_dev);
	show_rdma_stat_opcode_rx(g_dev);

	print_color(MAGENTA, "-----------------VF---------------");
	// VF 总共要读取2K * 4 个64位的寄存器，分1次读取：每次间接读取只能读256 * 32 个 64位寄存器
	write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x60000);
	for (int i = 0; i < MAX_VF; i++)
	{
		for (enum int_rdma_stae_vf j = TX_REQ_WSLD_NML_PKT_CNT; j <= RX_REQ_UD_MC_BYTE_CNT; j++)
		{
			d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + i * 0x100 + j * 8, 0, 63);
			d64 = (d64 >> 32) | (d64 << 32);
			if (d64)
			{
				printf("vf %2d %s:\033[;;35m[%.16lX]\033[0m\n", i, rdma_stae_vf_keys[j], d64);
			}
		}
	}

	show_rdma_stat_ecode(g_dev);

	print_color(MAGENTA, "----------------------------------packet loss related stat--------------------------------------------");
	d64 = read_reg(0x642014, 0, 32);
	printf(" \033[;;34m[0x642014]\033[0m \033[;;35m[%.8lX]\033[0m \n", d64);
	d64 = read_reg(0x1190498, 0, 32);
	printf(" \033[;;34m[0x1190498]\033[0m \033[;;35m[%.8lX]\033[0m \n", d64);
	d64 = read_reg(0x292164, 0, 32);
	d641 = read_reg(0x292168, 0, 32);
	d642 = read_reg(0x29216c, 0, 32);
	d643 = read_reg(0x292170, 0, 32);
	printf(" \033[;;34m[0x292164]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x292580, 0, 32);
	d641 = read_reg(0x292584, 0, 32);
	d642 = read_reg(0x292588, 0, 32);
	d643 = read_reg(0x29258c, 0, 32);
	printf(" \033[;;34m[0x292580]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x24c180, 0, 32);
	d641 = read_reg(0x24c184, 0, 32);
	d642 = read_reg(0x24c188, 0, 32);
	d643 = read_reg(0x24c18c, 0, 32);
	printf(" \033[;;34m[0x24c180]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x700090, 0, 32);
	d641 = read_reg(0x700094, 0, 32);
	d642 = read_reg(0x700098, 0, 32);
	d643 = read_reg(0x70009c, 0, 32);
	printf(" \033[;;34m[0x700090]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x25c200, 0, 32);
	d641 = read_reg(0x25c204, 0, 32);
	d642 = read_reg(0x25c208, 0, 32);
	d643 = read_reg(0x25c20c, 0, 32);
	printf(" \033[;;34m[0x25c200]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x444000, 0, 32);
	d641 = read_reg(0x444004, 0, 32);
	d642 = read_reg(0x444008, 0, 32);
	d643 = read_reg(0x44400c, 0, 32);
	printf(" \033[;;34m[0x444000]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);


	}

void rdmaqsch_display()
{
	uint64_t d64 = 0;
	uint64_t d641 = 0;
	uint64_t d642 = 0;
	uint64_t d643 = 0;

	print_color(YELLOW, "**************** RDMA ****************");
	print_color(GREEN, "-----------------BASE INFO---------------");
	d64 = read_reg(PRJ_RDMA_VERSION, 0, 31);
	printf("PRJ_RDMA_VERSION:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INIT_DONE_REG, 0, 31);
	printf("RDMA_INIT_DONE_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INT_REG, 0, 31);
	printf("RDMA_INT_REG:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(RDMA_INT_MASK_REG, 0, 31);
	printf("RDMA_INT_MASK_REG:\033[;;34m[%.8lX]\033[0m\n", d64);

	show_rdma_stat_vport(g_dev);
	show_rdma_stat_opcode_tx(g_dev);
	show_rdma_stat_opcode_rx(g_dev);

	print_color(MAGENTA, "-----------------VF---------------");
	// VF 总共要读取2K * 4 个64位的寄存器，分1次读取：每次间接读取只能读256 * 32 个 64位寄存器
	write_le32( STAE_RAM0_RAM4_WRITE_ADDR, 0x60000);
	for (int i = 0; i < MAX_VF; i++)
	{
		for (enum int_rdma_stae_vf j = TX_REQ_WSLD_NML_PKT_CNT; j <= RX_REQ_UD_MC_BYTE_CNT; j++)
		{
			d64 = read_reg(STAE_RAM0_RAM4_READ_ADDR + i * 0x100 + j * 8, 0, 63);
			d64 = (d64 >> 32) | (d64 << 32);
			if (d64)
			{
				printf("vf %2d %s:\033[;;35m[%.16lX]\033[0m\n", i, rdma_stae_vf_keys[j], d64);
			}
		}
	}

	show_rdma_stat_ecode(g_dev);

	print_color(GREEN, "-------------------NTFE-----------------");
	d64 = read_reg(NTFE_NOTIFY_VLD_CNT, 0, 31);
	printf("TLPE_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_RQ_INFO_FIFO_WEN_CNT, 0, 31);
	printf("RQ_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_CQ_INFO_FIFO_WEN_CNT, 0, 31);
	printf("CQ_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_CMQE_VLD_CNT, 0, 31);
	printf("CMQE_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_RCE_VLD_CNT, 0, 31);
	printf("RCE_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_QSCH_DB_CNT, 0, 31);
	printf("SW_DB_TO_QSCH:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SRFQ_NTFY_CNT, 0, 31);
	printf("SRFQ_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_QP_FLUSH_NTFY_VLD_CNT, 0, 31);
	printf("QP_FLUSH_NOTIFY:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT34, 24, 31);
	printf("LOSS_QP_FLUSH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 24, 31);
	printf("LOSS_ASM_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 16, 23);
	printf("LOSS_SRFQ_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 8, 15);
	printf("LOSS_CQ_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(NTFE_SCNT35, 0, 7);
	printf("LOSS_RQ_DB:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------TQE-----------------");
	d64 = read_reg(TQE_RCE_DB_NUM, 0, 31);
	printf("RCE_TQE_DB_NUM:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_TPE_DB_NUM, 0, 31);
	printf("TPE_TQE_DB_NUM:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_QSCH_RCE_DB_NUM, 0, 31);
	printf("TQE_QSCH_RCE_DB_NUM:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_QSCH_TPE_DB_NUM, 0, 31);
	printf("TQE_QSCH_TPE_DB_NUM:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RCE_TQE_CQ_DB_VLD_CNT, 0, 31);
	printf("RCE_TQE_CQ_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RCE_CQ_DB_VLD_CNT, 0, 31);
	printf("TQE_RCE_CQ_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(TQE_RPE_TQE_QP_FLUSH_GET_CNT, 0, 31);
	printf("RPE_TQE_QP_FLUSH_GET_CNT:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(GREEN, "-------------------QSCH-----------------");
	d64 = read_reg(QSCH_RDMA_SW_DB_FIFO_WEN_CNT, 0, 15);
	printf("NTFE_QSCH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_DB_FIFO_WEN_CNT, 0, 15);
	printf("TPE_QSCH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_RCE_DB_FIFO_WEN_CNT, 0, 15);
	printf("RCE_QSCH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TQE_DB_FIFO_WEN_CNT, 0, 15);
	printf("TQE_QSCH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_CCE_DB_FIFO_WEN_CNT, 0, 15);
	printf("CCE_QSCH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_DIST_DBQM_DB_FIFO_WEN_CNT, 0, 15);
	printf("DBQM_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_CSCH_DB_FIFO_WEN_CNT, 0, 15);
	printf("CSCH_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_INFO_VLD_CNT, 0, 15);
	printf("DB_TO_TPE:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_RDMA_SW_DB_LOSS_CNT, 0, 15);
	printf("LOSS_SW_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TPE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_TPE_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_RCE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_RCE_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_TQE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_TQE_DB:\033[;;34m[%.8lX]\033[0m\n", d64);
	d64 = read_reg(QSCH_CCE_DB_LOSS_CNT, 0, 15);
	printf("LOSS_CCE_DB:\033[;;34m[%.8lX]\033[0m\n", d64);

	print_color(MAGENTA, "----------------------------------packet loss related stat--------------------------------------------");
	d64 = read_reg(0x642014, 0, 32);
	printf(" \033[;;34m[0x00642014]\033[0m \033[;;35m[%.8lX]\033[0m \n", d64);
	d64 = read_reg(0x1190498, 0, 32);
	printf(" \033[;;34m[0x01190498]\033[0m \033[;;35m[%.8lX]\033[0m \n", d64);
	d64 = read_reg(0x292164, 0, 32);
	d641 = read_reg(0x292168, 0, 32);
	d642 = read_reg(0x29216c, 0, 32);
	d643 = read_reg(0x292170, 0, 32);
	printf(" \033[;;34m[0x00292164]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x292580, 0, 32);
	d641 = read_reg(0x292584, 0, 32);
	d642 = read_reg(0x292588, 0, 32);
	d643 = read_reg(0x29258c, 0, 32);
	printf(" \033[;;34m[0x00292580]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x24c180, 0, 32);
	d641 = read_reg(0x24c184, 0, 32);
	d642 = read_reg(0x24c188, 0, 32);
	d643 = read_reg(0x24c18c, 0, 32);
	printf(" \033[;;34m[0x0024c180]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x700090, 0, 32);
	d641 = read_reg(0x700094, 0, 32);
	d642 = read_reg(0x700098, 0, 32);
	d643 = read_reg(0x70009c, 0, 32);
	printf(" \033[;;34m[0x00700090]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x25c200, 0, 32);
	d641 = read_reg(0x25c204, 0, 32);
	d642 = read_reg(0x25c208, 0, 32);
	d643 = read_reg(0x25c20c, 0, 32);
	printf(" \033[;;34m[0x0025c200]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	d64 = read_reg(0x444000, 0, 32);
	d641 = read_reg(0x444004, 0, 32);
	d642 = read_reg(0x444008, 0, 32);
	d643 = read_reg(0x44400c, 0, 32);
	printf(" \033[;;34m[0x00444000]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", d64, d641, d642, d643);
	for (int off = 0; off < 0x80; off += 16)
	{
		d64 = read_reg(0x642800 + off, 0, 31);
		d641 = read_reg(0x642804 + off, 0, 31);
		d642 = read_reg(0x642808 + off, 0, 31);
		d643 = read_reg(0x64280c + off, 0, 31);
		printf(" \033[;;34m[0x%08x]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", 0x642800 + off, d64, d641, d642, d643);
	}

	for (int off = 0; off < 0x50; off += 16)
	{
		d64 = read_reg(0x642200 + off, 0, 31);
		d641 = read_reg(0x642204 + off, 0, 31);
		d642 = read_reg(0x642208 + off, 0, 31);
		d643 = read_reg(0x64220c + off, 0, 31);
		printf(" \033[;;34m[0x%08x]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", 0x642200 + off, d64, d641, d642, d643);
	}

	print_color(MAGENTA, "----------------------------------db loss related stat--------------------------------------------");
	for (int off = 0; off < 0x40; off += 16)
	{
		d64 = read_reg(0x3a1100 + off, 0, 31);
		d641 = read_reg(0x3a1104 + off, 0, 31);
		d642 = read_reg(0x3a1108 + off, 0, 31);
		d643 = read_reg(0x3a110c + off, 0, 31);
		printf(" \033[;;34m[0x%08x]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", 0x3a1100 + off, d64, d641, d642, d643);
	}
	for (int off = 0; off < 0x10; off += 16)
	{
		d64 = read_reg(0x2a11ac + off, 0, 31);
		d641 = read_reg(0x2a11b0 + off, 0, 31);
		d642 = read_reg(0x2a11b4 + off, 0, 31);
		d643 = read_reg(0x2a11b8 + off, 0, 31);
		printf(" \033[;;34m[0x%08x]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m \033[;;35m[%.8lX]\033[0m\n", 0x2a11ac + off, d64, d641, d642, d643);
	}


	}

void rdmabg_display()
{
	uint64_t reg_val;
	uint64_t field_val1;
	uint64_t field_val2;

	print_color(MAGENTA, "--------------------------------------BG_TX--------------------------------------");

	reg_val    = read_reg(TPE_FIFO_NAFULL_REG_1, 0, 31);
	field_val1 = read_reg(TPE_FIFO_NAFULL_REG_1, 27, 27);
	printf("TPE_TME_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m tpe_tme_info_fifo_nafull\033[;;34m[27]\033[0m:   \033[;;35m[%.8lX]\033[0m\n",
		TPE_FIFO_NAFULL_REG_1, reg_val, field_val1);

	reg_val    = read_reg(TME_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(TME_FIFO_NAFULL_REG, 16, 16);
	printf("TME_TDE_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m merg_info_fifo_nafull\033[;;34m[16]\033[0m:      \033[;;35m[%.8lX]\033[0m\n",
		TME_FIFO_NAFULL_REG, reg_val, field_val1);

	reg_val    = read_reg(TDE_FIFO_NAFULL_REG_0, 0, 31);
	field_val1 = read_reg(TDE_FIFO_NAFULL_REG_0, 18, 18);
	printf("TDE_PRMUX_INFO_NAFULL:      \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m prmux_tde_data_fifo_nafull\033[;;34m[18]\033[0m: \033[;;35m[%.8lX]\033[0m\n",
		TDE_FIFO_NAFULL_REG_0, reg_val, field_val1);

	reg_val    = read_reg(TDE_FIFO_NAFULL_REG_0, 0, 31);
	field_val1 = read_reg(TDE_FIFO_NAFULL_REG_0, 21, 21);
	printf("TDE_PRMUX_INFO_NAFULL:      \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m prmux_tde_info_fifo_nafull\033[;;34m[21]\033[0m: \033[;;35m[%.8lX]\033[0m\n",
		TDE_FIFO_NAFULL_REG_0, reg_val, field_val1);

	reg_val    = read_reg(TDE_FIFO_NAFULL_REG_0, 0, 31);
	field_val1 = read_reg(TDE_FIFO_NAFULL_REG_0, 0, 0);
	printf("TDE_RCE_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m tde_rce_info_fifo_nafull\033[;;34m[0]\033[0m:    \033[;;35m[%.8lX]\033[0m\n",
		TDE_FIFO_NAFULL_REG_0, reg_val, field_val1);

	reg_val    = read_reg(TPE_FIFO_NAFULL_REG_0, 0, 31);
	field_val1 = read_reg(TPE_FIFO_NAFULL_REG_0, 15, 15);
	printf("TPE_CCE_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m tpe_cce_info_fifo_nafull\033[;;34m[15]\033[0m:   \033[;;35m[%.8lX]\033[0m\n",
		TPE_FIFO_NAFULL_REG_0, reg_val, field_val1);

	print_color(MAGENTA, "--------------------------------------BG_RX--------------------------------------");

	reg_val    = read_reg(RCE_STAT_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(RCE_STAT_FIFO_NAFULL_REG, 9, 9);
	printf("RCE_STAE_NAFULL:            \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m stat_info_fifo_nafull_id\033[;;34m[9]\033[0m:    \033[;;35m[%.8lX]\033[0m\n",
		RCE_STAT_FIFO_NAFULL_REG, reg_val, field_val1);

	reg_val    = read_reg(RDE_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(RDE_FIFO_NAFULL_REG, 0, 0);
	printf("RDE_RCE_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m rde_rce_info_fifo_nafull\033[;;34m[0]\033[0m:    \033[;;35m[%.8lX]\033[0m\n",
		RDE_FIFO_NAFULL_REG, reg_val, field_val1);

	reg_val    = read_reg(RME_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(RME_FIFO_NAFULL_REG, 16, 16);
	printf("RME_RDE_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m merg_info_fifo_nafull\033[;;34m[16]\033[0m:      \033[;35m[%.8lX]\033[0m\n",
		RME_FIFO_NAFULL_REG, reg_val, field_val1);

	reg_val    = read_reg(RPE_FIFO_NAFULL_RGE_1, 0, 31);
	field_val1 = read_reg(RPE_FIFO_NAFULL_RGE_1, 27, 27);
	printf("RPE_RME_NAFULL:             \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m rpe_rme_fifo_nafull_reg\033[;;34m[27]\033[0m:    \033[;;35m[%.8lX]\033[0m\n",
		RPE_FIFO_NAFULL_RGE_1, reg_val, field_val1);

	print_color(MAGENTA, "--------------------------------------BG_DMI-------------------------------------");

	reg_val    = read_reg(DMI_RW1_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(DMI_RW1_FIFO_NAFULL_REG, 4, 4);
	field_val2 = read_reg(DMI_RW1_FIFO_NAFULL_REG, 1, 1);
	printf("DMA_FIFO_RW_1_DEBUG_INFO:   \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m dma_data_fifo_nafull\033[;;34m[4]\033[0m:        \033[;;35m[%.8lX]\033[0m\n",
		DMI_RW1_FIFO_NAFULL_REG, reg_val, field_val1);
	printf("DMA_FIFO_RW_1_DEBUG_INFO:   \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m dma_info_fifo_nafull\033[:34m[1]\033[0m:        \033[;35m[%.8lX]\033[0m\n",
		DMI_RW1_FIFO_NAFULL_REG, reg_val, field_val2);

	reg_val    = read_reg(DMI_RW2_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(DMI_RW2_FIFO_NAFULL_REG, 4, 4);
	field_val2 = read_reg(DMI_RW2_FIFO_NAFULL_REG, 1, 1);
	printf("DMA_FIFO_RW_2_DEBUG_INFO:   \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m dma_data_fifo_nafull\033[;;34m[4]\033[0m:        \033[;;35m[%.8lX]\033[0m\n",
		DMI_RW2_FIFO_NAFULL_REG, reg_val, field_val1);
	printf("DMA_FIFO_RW_2_DEBUG_INFO:   \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m dma_info_fifo_nafull\033[;;34m[1]\033[0m:        \033[;35m[%.8lX]\033[0m\n",
		DMI_RW2_FIFO_NAFULL_REG, reg_val, field_val2);

	reg_val    = read_reg(DMI_WR_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(DMI_WR_FIFO_NAFULL_REG, 3, 3);
	field_val2 = read_reg(DMI_WR_FIFO_NAFULL_REG, 1, 1);
	printf("DMA_FIFO_RW_WR_DEBUG_INFO:  \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m dma_data_fifo_nafull\033[;;34m[3]\033[0m:        \033[;;35m[%.8lX]\033[0m\n",
		DMI_WR_FIFO_NAFULL_REG, reg_val, field_val1);
	printf("DMA_FIFO_RW_WR_DEBUG_INFO:  \033[;;34m[0x%x]\033[0m \033[;;35m[%.8lX]\033[0m dma_info_fifo_nafull\033[;;34m[1]\033[0m:        \033[;35m[%.8lX]\033[0m\n",
		DMI_WR_FIFO_NAFULL_REG, reg_val, field_val2);

	reg_val    = read_reg(DMI_RD_FIFO_NAFULL_REG, 0, 31);
	field_val1 = read_reg(DMI_RD_FIFO_NAFULL_REG, 1, 1);
	printf("DMA_FIFO_RD_DEBUG_INFO:     \033[;;34m[0x%x]\033[0m \033[;35m[%.8lX]\033[0m dma_info_fifo_nafull\033[:34m[1]\033[0m:        \033[;;35m[%.8lX]\033[0m\n",
		DMI_RD_FIFO_NAFULL_REG, reg_val, field_val1);

	printf("\n");
}


// 桩函数映射表
static struct TableHandler
{
    const char *table_name;
    table_handler handler;
} handler_map[] = {
    {"vport_eport", display_vport_eport_table},
    {"eth_eport", display_eth_eport_table},
    {"epro_flow_act", display_epro_flow_act_table},
    {"vport_iport", display_vport_iport_table},
    {"vport_2nd_iport", display_vport_2nd_iport_table},
    {"eth_iport", display_eth_iport_table},
};

void vport_display()
{
	print_color(YELLOW,"****************VPORT****************");
	for (size_t i = 0; i < sizeof(handler_map) / sizeof(handler_map[0]); ++i)
	{
		printf("Table:%s\n", handler_map[i].table_name);
		handler_map[i].handler(table_value);
	}

	// if (!valid_table)
	// {
	// 	fprintf(stderr, "\033[31m[ERROR] 非法表名 '%s'，有效表名列表：\n", table_name);
	// 	for (int i = 0; i < VALID_TABLE_COUNT; i += 2)
	// 	{
	// 		fprintf(stderr, "  %-16s %s\n",
	// 				VALID_TABLE_STRINGS[i],
	// 				(i + 1 < VALID_TABLE_COUNT) ? VALID_TABLE_STRINGS[i + 1] : "");
	// 	}
	// 	fprintf(stderr, "\033[0m");
	// }
}

int main(int argc, char *argv[])
{
	int opt;
	char *slot = NULL;
	int status;
	struct stat statbuf;
	uint32_t version = 0;
	size_t mmap_size = 0;  /* actual mmap'd size for munmap */
	int color_mode = 0; /* 0=auto, 1=always, 2=never */

	static struct option long_options[] = {
		{"color", required_argument, 0, 0},
		{0, 0, 0, 0}
	};

	g_dev = &g_device;
	memset(g_dev, 0, sizeof(device_t));

	int option_index = 0;
	while ((opt = getopt_long(argc, argv, "b:hs:r:t:T:m:cp:", long_options, &option_index)) != -1)
	{
		switch (opt)
		{
		case 0:
			/* Long option: --color */
			if (strcmp(long_options[option_index].name, "color") == 0) {
				if (strcmp(optarg, "always") == 0 ||
				    strcmp(optarg, "yes") == 0 ||
				    strcmp(optarg, "force") == 0) {
					color_mode = 1;
				} else if (strcmp(optarg, "never") == 0 ||
				           strcmp(optarg, "no") == 0 ||
				           strcmp(optarg, "none") == 0) {
					color_mode = 2;
				} else if (strcmp(optarg, "auto") == 0 ||
				           strcmp(optarg, "tty") == 0 ||
				           strcmp(optarg, "if-tty") == 0) {
					color_mode = 0;
				} else {
					fprintf(stderr, "invalid argument '%s' for '--color'\n"
						"Valid arguments are:\n"
						"  - 'always', 'yes', 'force'\n"
						"  - 'never', 'no', 'none'\n"
						"  - 'auto', 'tty', 'if-tty'\n",
						optarg);
					return -1;
				}
			}
			break;
		case 'b':
			/* Defaults to BAR0 if not provided */
			g_dev->bar = atoi(optarg);
			break;
		case 'h':
			show_usage();
			return -1;
		case 's':
			slot = optarg;
			break;
		case 'r':
			vrx_num = atoi(optarg);
			break;
		case 't':
		{
			if (sscanf(optarg, "%d-%d", &vtx_s, &vtx_e) != 2)
			{
				fprintf(stderr, "Error: Invalid format for -t. Use 'start-end' (e.g., 3-15)\n");
				return -1;
			}

			if (vtx_s > vtx_e)
			{
				fprintf(stderr, "Error: Start value must be <= end value\n");
				return -1;
			}

			if (vtx_e - vtx_s >= 32)
			{
				fprintf(stderr, "Error: The range exceeds 32 entries. Maximum allowed difference is 31\n");
				return -1;
			}
			break;
		}
		case 'T':
		{
			if (sscanf(optarg, "%31[^-]-%d", table_name, &table_value) != 2)
			{
				fprintf(stderr, "Error: Expected 'table-value' format (e.g. vport_eport-16383)\n");
				return -1;
			}

			int is_valid = 0;
			for (int i = 0; i < VALID_TABLE_COUNT; ++i)
			{
				if (strcmp(table_name, VALID_TABLE_STRINGS[i]) == 0)
				{
					is_valid = 1;
					break;
				}
			}

			if (!is_valid)
			{
				fprintf(stderr, "\nInvalid table name '%s'\nValid tables:\n", table_name);
				for (int i = 0; i < VALID_TABLE_COUNT; i += 2)
				{
					fprintf(stderr, "| %-18s | %-18s |\n",
							VALID_TABLE_STRINGS[i],
							(i + 1 < VALID_TABLE_COUNT) ? VALID_TABLE_STRINGS[i + 1] : "");
				}
				return -1;
			}
			break;
		}
		case 'c':
			clear_flag = 1;
			break;
		case 'm':
			status = set_display_mode(optarg);
			if (status)
				return -1;
			break;
		case 'p':
		{
			char type_input[32];
			if (sscanf(optarg, "%31[^,],%d", type_input, &pstat_index) != 2)
			{
				fprintf(stderr, "Error: Invalid format for -p. Expected 'mode,index' (e.g., -p ptype,1)\n");
				return -1;
			}

			const int VALID_MODE_COUNT = sizeof(PSTAT_VALID_TYPES) / sizeof(PSTAT_VALID_TYPES[0]);

			int type_valid = 0;
			for (int i = 0; i < VALID_MODE_COUNT; i++)
			{
				if (strcmp(type_input, PSTAT_VALID_TYPES[i]) == 0)
				{
					strncpy(pstat_type_str, type_input, sizeof(pstat_type_str) - 1);
					pstat_type = i;
					type_valid = 1;
					break;
				}
			}

			if (!type_valid)
			{
				fprintf(stderr, "Error: Invalid mode '%s' for -p.\nValid modes are:\n", type_input);
				for (int i = 0; i < VALID_MODE_COUNT; ++i)
				{
					fprintf(stderr, "  %s\n", PSTAT_VALID_TYPES[i]);
				}
				return -1;
			}

			if (pstat_index < 0 || pstat_index > 16383)
			{
				fprintf(stderr, "Error: Index must be in range [0, 16383], got %d\n", pstat_index);
				return -1;
			}

			pstat_flag = 1;
			print_color(YELLOW, "pstat_type=%d, pstat_index=%d", pstat_type, pstat_index);
			//pstat_display();
			break;
		}
		default:
			show_usage();
			return -1;
		}
	}
	/* Resolve color mode */
	switch (color_mode) {
	case 1: /* always */
		g_color_enabled = 1;
		break;
	case 2: /* never */
		g_color_enabled = 0;
		break;
	default: /* auto */
		g_color_enabled = isatty(STDOUT_FILENO);
		break;
	}
	if (!g_color_enabled)
		setup_nocolor_stdout();

	if (slot == 0)
	{
		show_usage();
		return -1;
	}

	/* ------------------------------------------------------------
	 * Open and map the PCI region
	 * ------------------------------------------------------------
	 */

	/* Extract the PCI parameters from the slot string */
	status = sscanf(slot, "%2x:%2x.%1x",
					&g_dev->bus, &g_dev->slot, &g_dev->function);
	if (status != 3)
	{
		printf("Error parsing slot information!\n");
		show_usage();
		return -1;
	}

	/* Convert to a sysfs resource filename and open the resource */
	snprintf(g_dev->filename, 99, "/sys/bus/pci/devices/%04x:%02x:%02x.%1x/resource%d",
			 g_dev->domain, g_dev->bus, g_dev->slot, g_dev->function, g_dev->bar);
	g_dev->fd = open(g_dev->filename, O_RDWR | O_SYNC);
	if (g_dev->fd < 0)
	{
		printf("Open failed for file '%s': errno %d, %s\n",
			   g_dev->filename, errno, strerror(errno));
		return -1;
	}

	/* PCI memory size */
	status = fstat(g_dev->fd, &statbuf);
	if (status < 0)
	{
		printf("fstat() failed: errno %d, %s\n",
			   errno, strerror(errno));
		close(g_dev->fd);
		return -1;
	}
	g_dev->size = statbuf.st_size;

	/* ------------------------------------------------------------
	 * Get physical address offset
	 * ------------------------------------------------------------
	 */
	{
		char configname[100];
		int fd;

		snprintf(configname, 99, "/sys/bus/pci/devices/%04x:%02x:%02x.%1x/config",
				 g_dev->domain, g_dev->bus, g_dev->slot, g_dev->function);
		fd = open(configname, O_RDWR | O_SYNC);
		if (fd < 0)
		{
			printf("Open failed for file '%s': errno %d, %s\n",
				   configname, errno, strerror(errno));
			close(g_dev->fd);
			return -1;
		}

		status = lseek(fd, 0x10 + 4 * g_dev->bar, SEEK_SET);
		if (status < 0)
		{
			printf("Error: configuration space lseek failed\n");
			close(fd);
			close(g_dev->fd);
			return -1;
		}
		status = read(fd, &g_dev->phys, 4);
		if (status < 0)
		{
			printf("Error: configuration space read failed\n");
			close(fd);
			close(g_dev->fd);
			return -1;
		}
		g_dev->offset = ((g_dev->phys & 0xFFFFFFF0) % 0x1000);
		close(fd);
	}
	/* ------------------------------------------------------------
	 * Create memory mappings with 16K offset for BAR0
	 *
	 * ARM64 kernels (e.g. Kylin V10 on Kunpeng) may use 64KB pages.
	 * mmap offsets must be page-aligned, so when page_size > 16K we
	 * map the entire BAR and adjust the pointer instead.
	 * ------------------------------------------------------------
	 */
	if (g_dev->bar == 0) {
		/* For BAR0: Skip the first 16K (doorbell region) */
		long page_size = sysconf(_SC_PAGESIZE);
		if (page_size <= 0)
			page_size = 4096;

		/* Check if BAR size is sufficient */
		if (g_dev->size <= DPU_BAR0_REMAINING_OFFSET) {
			printf("Error: BAR0 size (0x%x) is too small for 16K offset mapping\n", g_dev->size);
			printf("       Minimum required size: 0x%x\n", DPU_BAR0_REMAINING_OFFSET + 1);
			close(g_dev->fd);
			return -1;
		}

		if (page_size > DPU_BAR0_REMAINING_OFFSET) {
			/* Large pages (e.g. 64KB on ARM64): cannot use 16K mmap offset,
			 * map the whole BAR and skip the first 16K via pointer arithmetic */
			printf("Large page size (%ld), mapping entire BAR0 (size: 0x%x)\n",
				   page_size, g_dev->size);

			g_dev->maddr = (unsigned char *)mmap(
				NULL,
				(size_t)(g_dev->size),
				PROT_READ | PROT_WRITE,
				MAP_SHARED,
				g_dev->fd,
				0);

			if (g_dev->maddr == (unsigned char *)MAP_FAILED)
			{
				printf("Failed to map BAR0: %s\n", strerror(errno));
				printf("BARs that are I/O ports are not supported by this tool\n");
				g_dev->maddr = 0;
				close(g_dev->fd);
				return -1;
			}

			/* Point addr past the 16K doorbell region */
			g_dev->addr = g_dev->maddr + DPU_BAR0_REMAINING_OFFSET + g_dev->offset;

			/* Track full mmap size for munmap, update size for accessible region */
			mmap_size = g_dev->size;
			g_dev->size = g_dev->size - DPU_BAR0_REMAINING_OFFSET;

			printf("BAR0 successfully mapped (whole): 0x%p (accessible size: 0x%x)\n",
				   g_dev->addr, g_dev->size);
		} else {
			/* Normal pages: map from 16K offset directly */
			size_t map_size = g_dev->size - DPU_BAR0_REMAINING_OFFSET;

			printf("Mapping BAR0 from offset 0x%x, size: 0x%zx (original size: 0x%x)\n",
				   DPU_BAR0_REMAINING_OFFSET, map_size, g_dev->size);

			g_dev->maddr = (unsigned char *)mmap(
				NULL,
				map_size,
				PROT_READ | PROT_WRITE,
				MAP_SHARED,
				g_dev->fd,
				DPU_BAR0_REMAINING_OFFSET);

			if (g_dev->maddr == (unsigned char *)MAP_FAILED)
			{
				printf("Failed to map BAR0 from 16K offset: %s\n", strerror(errno));
				printf("BARs that are I/O ports are not supported by this tool\n");
				g_dev->maddr = 0;
				close(g_dev->fd);
				return -1;
			}

			g_dev->addr = g_dev->maddr + g_dev->offset;
			mmap_size = map_size;
			g_dev->size = map_size;

			printf("BAR0 successfully mapped: 0x%p (size: 0x%x)\n", g_dev->addr, g_dev->size);
		}

	} else {
		/* For other BARs: Map entire region */
		printf("Mapping BAR%d, size: 0x%x\n", g_dev->bar, g_dev->size);

		g_dev->maddr = (unsigned char *)mmap(
			NULL,
			(size_t)(g_dev->size),
			PROT_READ | PROT_WRITE,
			MAP_SHARED,
			g_dev->fd,
			0);  /* File offset = 0 */

		if (g_dev->maddr == (unsigned char *)MAP_FAILED)
		{
			printf("Failed to map BAR: %s\n", strerror(errno));
			printf("BARs that are I/O ports are not supported by this tool\n");
			g_dev->maddr = 0;
			close(g_dev->fd);
			return -1;
		}

		/* Adjust addr pointer with physical offset */
		g_dev->addr = g_dev->maddr + g_dev->offset;
		mmap_size = g_dev->size;

		printf("BAR%d successfully mapped: 0x%p (size: 0x%x)\n", g_dev->bar, g_dev->addr, g_dev->size);
	}

	/* ------------------------------------------------------------
	 * Tests
	 * ------------------------------------------------------------
	 */
	printf("\n");
	printf("REG DISPLAY\n");
	printf("-----------------------\n\n - reg_display version %s (git_hash:%s)\n", TOOL_VERSION, GIT_COMMIT_HASH);
	version = read_reg(VERSION_GREG, 0, 31);
	printf(" - logical version:%.8X\n", version);

	if (g_dev->bar == 0) {
		printf(" - BAR0 mapping: First 16K (0x0000-0x3FFF) NOT accessible\n");
		printf(" - BAR0 accessible range: 0x%x - 0x%x\n",
			   DPU_BAR0_REMAINING_OFFSET,
			   DPU_BAR0_REMAINING_OFFSET + g_dev->size - 1);
	}

	if (clear_flag)
	{
		clear_cnt();
		printf("clear cnt...\n");
		goto end;
	} else if (pstat_flag) {
		pstat_display();
		goto end;
	} else if (traverse_flag) {
		perform_module_traversal();
		goto end;
	}
	check_greg();

	if (!display_mode) {
		printf("No block specified. Use -m <block> to display registers.\n");
		printf("Available blocks: pp,dptx,dprx,vtx,vrx,eth,ethv2,intf,ptype,rdma,rdmadebug,rdmaqsch,vport,rdmabg,pcie,psw\n");
		goto end;
	}

	if (display_mode & MODE_ETH)
		eth_display();
	if (display_mode & MODE_VTX)
		vtx_display();
	if (display_mode & MODE_DPRX)
		dprx_display();
	if (display_mode & MODE_PP)
		pp_display();
	if (display_mode & MODE_PTYPE)
		ptype_display();
	if (display_mode & MODE_DPTX)
		dptx_display();
	if (display_mode & MODE_VRX)
		vrx_display();
	if (display_mode & MODE_RDMA)
		rdma_display();
	if (display_mode & MODE_RDMAD)
		rdma_debug_display();
	if (display_mode & MODE_VPORT)
		vport_display();
	if (display_mode & MODE_RDMABG)
		rdmabg_display();
	if (display_mode & MODE_RDMAQSCH)
		rdmaqsch_display();

	/* show interface register */
	if (display_mode & MODE_INTF)
		intf_display();

	/* show eth v2 extended registers */
	if (display_mode & MODE_ETHV2)
		ethv2_display();

	/* show pcie register */
	if (display_mode & MODE_PCIE)
		pcie_display();

	/* show pcie switch register */
	if (display_mode & MODE_PSW)
		psw_display();
end:
	/* ------------------------------------------------------------
	 * Cleanup
	 * ------------------------------------------------------------
	 */
	printf("\nCleaning up...\n");

	if (g_dev->maddr && g_dev->maddr != MAP_FAILED) {
		munmap(g_dev->maddr, mmap_size);
		printf("Unmapped memory region\n");
	}

	close(g_dev->fd);
	printf("Closed file descriptor\n");

	return 0;
}
