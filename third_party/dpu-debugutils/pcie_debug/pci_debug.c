/* pci_debug.c
 *
 * Update version:6/21/2021 Léo Dumez leo.dumez@outlook.com
 * Add commands file support.
 * Add verbosity level:
 * 	- 0: only error and warning
 *  - 1: 0 + the current BAR
 *  - 2: 1 + the sent command
 *  - 3: Everything
 *
 * First version :6/21/2010 D. W. Hawkins
 *
 * PCI debug registers interface.
 *
 * This tool provides a debug interface for reading and writing
 * to PCI registers via the device base address registers (BARs).
 * The tool uses the PCI resource nodes automatically created
 * by recently Linux kernels.
 *
 * The readline library is used for the command line interface
 * so that up-arrow command recall works. Command-line history
 * is not implemented. Use -lreadline -lcurses when building.
 *
 * ----------------------------------------------------------------
 */
#include <stdio.h>
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
#include <linux/types.h>
#include <stdbool.h>

/* Readline support */
#include <readline/readline.h>
#include <readline/history.h>


static inline void decimalToBinary(int n, const char *info) {
	char binaryStr[9];
	int i;
	for (i = 7; i >= 0; i--) {
		binaryStr[7 - i] = (n & (1 << i)) ? '1' : '0';
	}
	binaryStr[8] = '\0';  // Null-terminate the string
	printf("%s:%s\n", info, binaryStr);
}

static inline void print_hex_bin(void *obj, __u32 byte, bool reverse_endian)
{
	__u8 *pchar = (__u8 *)obj;
	__u32 i;
	__u32 byte4_num = byte / 4;

	printf("\n");
	for(i = 0; i < byte4_num; i++) {
		if (reverse_endian) {
			printf("0x%.2x%.2x %.2x%.2x\n",
				*(pchar + 3), *(pchar + 2), *(pchar + 1), *pchar);
			decimalToBinary(*(pchar + 3), "BYTE3");
			decimalToBinary(*(pchar + 2), "BYTE2");
			decimalToBinary(*(pchar + 1), "BYTE1");
			decimalToBinary(*pchar, "BYTE0");
		} else {
			printf("0x%.2x%.2x %.2x%.2x\n", *pchar, *(pchar + 1),
				*(pchar + 2), *(pchar + 3));
			decimalToBinary(*pchar, "BYTE0");
			decimalToBinary(*(pchar + 1), "BYTE1");
			decimalToBinary(*(pchar + 2), "BYTE2");
			decimalToBinary(*(pchar + 3), "BYTE3");
		}
		pchar += 4;
	}
	printf("\n");
}

int quit = 0;
int verbosity = 3;
int debug = 0;

/* DPU-specific constants */
#define DPU_BAR0_VIO_DB_SIZE		  0x2000	  /* 8KB */
#define DPU_BAR0_RDMA_DB_OFFSET	   0x2000
#define DPU_BAR0_RDMA_DB_SIZE		 0x2000	  /* 8KB */
#define DPU_BAR0_REMAINING_OFFSET	 0x4000

/* Page size detection for FWQE segmentation.
 * ARM64 kernels (e.g. Kylin V10 on Kunpeng) may use 64KB pages,
 * so we must detect page size at runtime via sysconf(_SC_PAGESIZE). */
#define SZ_16K 0x4000

static long get_system_page_size(void)
{
	static long page_size = 0;
	if (page_size == 0) {
		page_size = sysconf(_SC_PAGESIZE);
		if (page_size <= 0)
			page_size = 4096;
	}
	return page_size;
}

static inline bool dpu_support_fwqe_segmentation(void)
{
	if (get_system_page_size() >= SZ_16K)
		return false;
	return true;
}

/* PCI device with FWQE segmentation support */
typedef struct {
	/* Base address region */
	unsigned int bar;

	/* Slot info */
	unsigned int domain;
	unsigned int bus;
	unsigned int slot;
	unsigned int function;

	/* Resource filename */
	char		 filename[100];

	/* File descriptor of the resource */
	int		  fd;

	/* Memory mapped resources for FWQE segmentation */
	unsigned char *maddr;		  /* whole map*/
	unsigned char *vio_mem_base;   /* VIO Doorbell (0-8K) */
	unsigned char *rdma_mem_base;  /* RDMA Doorbell (8K-16K) - 可能为NULL */
	unsigned char *rem_mem_base;   /* REMAIN MEM (16K-end) */
	unsigned int   size;		   /* TOTAL SIZE */
	unsigned int   offset;		 /* PHY OFFSET */

	/* PCI physical address */
	unsigned int   phys;

	unsigned char *addr;
} device_t;

void display_help(device_t *dev);
void parse_command(device_t *dev, char* cmdFilePath);
int process_command(device_t *dev, char *cmd);
int change_mem(device_t *dev, char *cmd);
void useCmdFile(device_t *dev, char* cmdFilePath);
int fill_mem(device_t *dev, char *cmd);
int display_mem(device_t *dev, char *cmd);
int change_endian(device_t *dev, char *cmd);

/* Endian read/write mode */
static int big_endian = 0;

/* Low-level access functions */
static void
write_8(
	device_t     *dev,
	unsigned int  addr,
	unsigned char data);

static unsigned char
read_8(
	device_t    *dev,
	unsigned int addr);

static void
write_le16(
	device_t          *dev,
	unsigned int       addr,
	unsigned short int data);

static unsigned short int
read_le16(
	device_t    *dev,
	unsigned int addr);

static void
write_be16(
	device_t          *dev,
	unsigned int       addr,
	unsigned short int data);

static unsigned short int
read_be16(
	device_t    *dev,
	unsigned int addr);

static void
write_le32(
	device_t    *dev,
	unsigned int addr,
	unsigned int data);

static unsigned int
read_le32(
	device_t    *dev,
	unsigned int addr);

static void
write_be32(
	device_t    *dev,
	unsigned int addr,
	unsigned int data);

static unsigned int
read_be32(
	device_t    *dev,
	unsigned int addr);

/* Usage */
static void show_usage()
{
	printf("\nUsage: pci_debug -s <device>\n"\
		 "  -h            Help (this message)\n"\
		 "  -s <device>   Slot/device (as per lspci)\n" \
	 	 "  -b <BAR>      Base address region (BAR) to access, eg. 0 for BAR0\n" \
		 "  -q            Quit after send a command file\n" \
		 "  -d            Quit after send a command file\n" \
		 "  -v <level>    Verbosity (0 to 3 - Default is 3)\n" \
	 	 "  -f <file> 	  Use commands file to play before display prompt\n\n");
}

static unsigned char *
get_fwqe_addr(device_t *dev, unsigned int addr)
{
	bool fwqe_supported = dpu_support_fwqe_segmentation();

	if (addr >= dev->size) return NULL;

	if (!fwqe_supported || dev->bar != 0) {
		return dev->addr + addr;
	}

	if (addr < DPU_BAR0_VIO_DB_SIZE) {
		return dev->vio_mem_base + addr;
	} else if (addr >= DPU_BAR0_RDMA_DB_OFFSET &&
			   addr < DPU_BAR0_RDMA_DB_OFFSET + DPU_BAR0_RDMA_DB_SIZE) {
		if (dev->rdma_mem_base) {
			return dev->rdma_mem_base + (addr - DPU_BAR0_RDMA_DB_OFFSET);
		} else {
			printf("Error: RDMA DB region (0x%x-0x%x) is not accessible\n",
				   DPU_BAR0_RDMA_DB_OFFSET,
				   DPU_BAR0_RDMA_DB_OFFSET + DPU_BAR0_RDMA_DB_SIZE - 1);
			printf("Reason: Write-combining (WC) mapping not supported on this system\n");
			return NULL;
		}
	} else if (addr >= DPU_BAR0_REMAINING_OFFSET) {
		return dev->rem_mem_base + (addr - DPU_BAR0_REMAINING_OFFSET);
	}

	printf("Error: Invalid address 0x%x for FWQE segmentation\n", addr);
	return NULL;
}

static int map_fwqe_segments(device_t *dev)
{
	bool fwqe_supported = dpu_support_fwqe_segmentation();
	int mapping_failed = 0;

	if (!fwqe_supported || dev->bar != 0) {
		dev->maddr = (unsigned char *)mmap(
			NULL,
			(size_t)(dev->size),
			PROT_READ|PROT_WRITE,
			MAP_SHARED,
			dev->fd,
			0);

		if (dev->maddr == MAP_FAILED) {
			printf("Failed to map BAR: %s\n", strerror(errno));
			return -1;
		}

		dev->addr = dev->maddr + dev->offset;
		dev->vio_mem_base = dev->addr;
		dev->rdma_mem_base = dev->addr;
		dev->rem_mem_base = dev->addr;
		return 0;
	}

	dev->rdma_mem_base = NULL;

	unsigned char *vio_map = (unsigned char *)mmap(
		NULL,
		DPU_BAR0_VIO_DB_SIZE,
		PROT_READ | PROT_WRITE,
		MAP_SHARED,
		dev->fd,
		0);

	if (vio_map == MAP_FAILED) {
		printf("Failed to map VIO segment: %s\n", strerror(errno));
		mapping_failed++;
		dev->vio_mem_base = NULL;
	} else
		dev->vio_mem_base = vio_map + dev->offset;

	off_t remaining_size = dev->size - DPU_BAR0_REMAINING_OFFSET;
	unsigned char *rem_map = NULL;
	
	if (remaining_size > 0) {
		rem_map = (unsigned char *)mmap(
			NULL,
			remaining_size,
			PROT_READ | PROT_WRITE,
			MAP_SHARED,
			dev->fd,
			DPU_BAR0_REMAINING_OFFSET);

		if (rem_map == MAP_FAILED) {
			printf("Failed to map remaining segment: %s\n", strerror(errno));
			mapping_failed++;
			dev->rem_mem_base = NULL;
		} else
			dev->rem_mem_base = rem_map + dev->offset;
	} else
		dev->rem_mem_base = NULL;


	dev->maddr = NULL;
	dev->addr = NULL;
	
	if (mapping_failed == 2) {
		dev->maddr = (unsigned char *)mmap(
			NULL,
			(size_t)(dev->size),
			PROT_READ|PROT_WRITE,
			MAP_SHARED,
			dev->fd,
			0);

		if (dev->maddr == MAP_FAILED) {
			printf("All mappings failed, including full mapping: %s\n", strerror(errno));
			if (dev->vio_mem_base)
				munmap(dev->vio_mem_base - dev->offset, DPU_BAR0_VIO_DB_SIZE);
			if (dev->rem_mem_base)
				munmap(dev->rem_mem_base - dev->offset, remaining_size);
			return -1;
		} else {
			dev->addr = dev->maddr + dev->offset;
			dev->vio_mem_base = dev->addr;
			dev->rem_mem_base = dev->addr;

			if (vio_map != MAP_FAILED && vio_map != NULL) {
				munmap(vio_map, DPU_BAR0_VIO_DB_SIZE);
			}
			if (rem_map != MAP_FAILED && rem_map != NULL) {
				munmap(rem_map, remaining_size);
			}
		}
	}

	if (verbosity >= 2) {
		printf("FWQE segmentation enabled for BAR0:\n");
		printf("  - VIO segment: ");
		if (dev->vio_mem_base)
			printf("%p (size: 0x%x)\n", (void *)dev->vio_mem_base, DPU_BAR0_VIO_DB_SIZE);
		else
			printf("NOT MAPPED\n");
		printf("  - RDMA segment: NOT MAPPED (disabled as requested)\n");
		printf("  - Remaining segment: ");
		if (dev->rem_mem_base)
			printf("%p (size: 0x%lx)\n", (void *)dev->rem_mem_base, (long)remaining_size);
		else
			printf("NOT MAPPED\n");
		if (dev->maddr)
			printf("  - Full mapping (fallback): %p (size: 0x%x)\n", (void *)dev->maddr, dev->size);
	}

	return 0;
}
static void unmap_fwqe_segments(device_t *dev)
{
	bool fwqe_supported = dpu_support_fwqe_segmentation();

	if (fwqe_supported && dev->bar == 0) {

		if (dev->vio_mem_base) {
			unsigned char *vio_map = dev->vio_mem_base - dev->offset;
			munmap(vio_map, DPU_BAR0_VIO_DB_SIZE);
		}

		if (dev->rdma_mem_base) {
			unsigned char *rdma_map = dev->rdma_mem_base - dev->offset;
			munmap(rdma_map, DPU_BAR0_RDMA_DB_SIZE);
		}

		if (dev->rem_mem_base) {
			off_t remaining_size = dev->size - DPU_BAR0_REMAINING_OFFSET;
			if (remaining_size > 0) {
				unsigned char *rem_map = dev->rem_mem_base - dev->offset;
				munmap(rem_map, remaining_size);
			}
		}
	}

	if (dev->maddr && dev->maddr != MAP_FAILED) {
		munmap(dev->maddr, dev->size);
	}

	dev->maddr = NULL;
	dev->addr = NULL;
	dev->vio_mem_base = NULL;
	dev->rdma_mem_base = NULL;
	dev->rem_mem_base = NULL;
}

int main(int argc, char *argv[])
{
	int opt;
	char *slot = NULL;
	char *cmdFilePath = NULL;
	int status;
	struct stat statbuf;
	device_t device;
	device_t *dev = &device;

	/* Clear the structure fields */
	memset(dev, 0, sizeof(device_t));

	while ((opt = getopt(argc, argv, "b:hs:f:qdv:")) != -1) {
		switch (opt) {
			case 'b':
				/* Defaults to BAR0 if not provided */
				dev->bar = atoi(optarg);
				break;
			case 'h':
				show_usage();
				return -1;
			case 'q':
				quit = 1;
				break;
			case 'v':
				verbosity = atoi(optarg);
				break;
			case 's':
				slot = optarg;
				break;
			case 'f':
				cmdFilePath = optarg;
				break;
			case 'd':
				debug = 1;
				break;
			default:
				show_usage();
				return -1;
		}
	}
	if (slot == 0) {
		show_usage();
		return -1;
	}

	/* ------------------------------------------------------------
	 * Parse PCI slot information
	 * ------------------------------------------------------------
	 */

	/* Extract the PCI parameters from the slot string */
	if (strchr(slot, ':')) {
		int colon_count = 0;
		for (char *p = slot; *p; p++) {
			if (*p == ':') colon_count++;
		}
		
		if (colon_count == 2) {
	
			status = sscanf(slot, "%4x:%2x:%2x.%1x",
					&dev->domain, &dev->bus, &dev->slot, &dev->function);
			if (status != 4) {
				printf("Error parsing slot information (domain:bus:slot.function format)!\n");
				show_usage();
				return -1;
			}
		} else if (colon_count == 1) {
			status = sscanf(slot, "%2x:%2x.%1x",
					&dev->bus, &dev->slot, &dev->function);
			if (status != 3) {
				printf("Error parsing slot information (bus:slot.function format)!\n");
				show_usage();
				return -1;
			}
			dev->domain = 0;
		} else {
			printf("Invalid slot format: %s\n", slot);
			show_usage();
			return -1;
		}
	} else {
		printf("Invalid slot format: %s\n", slot);
		show_usage();
		return -1;
	}
	

	/* Convert to a sysfs resource filename and open the resource */
	snprintf(dev->filename, 99, "/sys/bus/pci/devices/%04x:%02x:%02x.%1x/resource%d",
			dev->domain, dev->bus, dev->slot, dev->function, dev->bar);
	dev->fd = open(dev->filename, O_RDWR | O_SYNC);
	if (dev->fd < 0) {
		printf("Open failed for file '%s': errno %d, %s\n",
			dev->filename, errno, strerror(errno));
		return -1;
	}

	/* PCI memory size */
	status = fstat(dev->fd, &statbuf);
	if (status < 0) {
		printf("fstat() failed: errno %d, %s\n",
			errno, strerror(errno));
		close(dev->fd);
		return -1;
	}
	dev->size = statbuf.st_size;

	/* ------------------------------------------------------------
	 * Get physical address offset
	 * ------------------------------------------------------------
	 */
	{
		char configname[100];
		int fd;

		snprintf(configname, 99, "/sys/bus/pci/devices/%04x:%02x:%02x.%1x/config",
				dev->domain, dev->bus, dev->slot, dev->function);
		fd = open(configname, O_RDWR | O_SYNC);
		if (fd < 0) {
			printf("Open failed for file '%s': errno %d, %s\n",
				configname, errno, strerror(errno));
			close(dev->fd);
			return -1;
		}

		status = lseek(fd, 0x10 + 4*dev->bar, SEEK_SET);
		if (status < 0) {
			printf("Error: configuration space lseek failed\n");
			close(fd);
			close(dev->fd);
			return -1;
		}
		status = read(fd, &dev->phys, 4);
		if (status < 0) {
			printf("Error: configuration space read failed\n");
			close(fd);
			close(dev->fd);
			return -1;
		}
		dev->offset = ((dev->phys & 0xFFFFFFF0) % 0x1000);
		close(fd);
	}

	/* ------------------------------------------------------------
	 * Create memory mappings
	 * ------------------------------------------------------------
	 */

	/* Try FWQE segmented mappings first if applicable */
	bool fwqe_supported = dpu_support_fwqe_segmentation();

	if (fwqe_supported && dev->bar == 0) {
		/* Try FWQE segmentation for BAR0 */
		if (map_fwqe_segments(dev) < 0) {
			/* FWQE segmentation failed, fall back to full mapping */
			printf("FWQE segmentation failed, trying full mapping...\n");

			dev->maddr = (unsigned char *)mmap(
				NULL,
				(size_t)(dev->size),
				PROT_READ|PROT_WRITE,
				MAP_SHARED,
				dev->fd,
				0);

			if (dev->maddr == MAP_FAILED) {
				printf("All mapping attempts failed. BAR may be I/O port or unsupported.\n");
				close(dev->fd);
				return -1;
			}


			dev->addr = dev->maddr + dev->offset;
			dev->vio_mem_base = dev->addr;
			dev->rdma_mem_base = dev->addr;
			dev->rem_mem_base = dev->addr;

			printf("Using full mapping (FWQE segmentation not available)\n");
		}
	} else {
		/* Non-BAR0 or FWQE not supported: use full mapping */
		dev->maddr = (unsigned char *)mmap(
			NULL,
			(size_t)(dev->size),
			PROT_READ|PROT_WRITE,
			MAP_SHARED,
			dev->fd,
			0);

		if (dev->maddr == MAP_FAILED) {
			printf("Failed to map BAR: %s\n", strerror(errno));
			printf("BARs that are I/O ports are not supported by this tool\n");
			close(dev->fd);
			return -1;
		}

		dev->addr = dev->maddr + dev->offset;
		dev->vio_mem_base = dev->addr;
		dev->rdma_mem_base = dev->addr;
		dev->rem_mem_base = dev->addr;
	}

	/* ------------------------------------------------------------
	 * Display information
	 * ------------------------------------------------------------
	 */
	if (verbosity >= 3)
	{
		printf("\n");
		printf("PCI debug\n");
		printf("---------\n\n");
		printf(" - accessing BAR%d\n", dev->bar);
		printf(" - region size is %d-bytes (0x%x)\n", dev->size, dev->size);
		printf(" - offset into region is %d-bytes (0x%x)\n", dev->offset, dev->offset);

		if (fwqe_supported && dev->bar == 0) {
			printf(" - FWQE segmentation: ENABLED for BAR0\n");
			printf("   * VIO segment: %p (size: 0x%x)\n",
				   (void *)dev->vio_mem_base, DPU_BAR0_VIO_DB_SIZE);
			printf("   * RDMA segment: %s", dev->rdma_mem_base ? "MAPPED" : "NOT MAPPED");
			if (dev->rdma_mem_base) {
				printf(" (%p, size: 0x%x, WC: yes)\n",
					   (void *)dev->rdma_mem_base, DPU_BAR0_RDMA_DB_SIZE);
			} else {
				printf(" (requires WC, not accessible)\n");
			}
			off_t remaining_size = dev->size - DPU_BAR0_REMAINING_OFFSET;
			printf("   * Remaining segment: %p (size: 0x%lx)\n",
				   (void *)dev->rem_mem_base, (long)remaining_size);
		} else if (dev->bar == 0) {
			printf(" - FWQE segmentation: DISABLED (page size %ld >= 16KB)\n",
				   get_system_page_size());
		}

		/* Display help */
		display_help(dev);
	}

	verbosity==1?printf("\nAccessing BAR%d\n", dev->bar):0;

	/* ------------------------------------------------------------
	 * Process commands
	 * ------------------------------------------------------------
	 */
	parse_command(dev, cmdFilePath);

	/* ------------------------------------------------------------
	 * Cleanup
	 * ------------------------------------------------------------
	 */
	unmap_fwqe_segments(dev);
	close(dev->fd);
	return 0;
}

void useCmdFile(device_t *dev, char* cmdFilePath)
{

    FILE * fp;
    char * line = NULL;
    size_t len = 0;
    int status;
    int firstLine = 1;
    int bar = -1;
    ssize_t read;

	verbosity>=3?printf("Exectue a commands file\n"):0;

    fp = fopen(cmdFilePath, "r");
    if (fp == NULL)
    {
		printf("Can not open the commands file\n");
		exit(EXIT_FAILURE);
    }

    while ((read = getline(&line, &len, fp)) != -1) {
	len = strlen(line);
	if(len > 1)
	{

		if (firstLine == 1)
		{
			sscanf(line, "bar%d", &bar);
			if(dev->bar != bar)
			{
				printf("Warning: BAR is no compliant with the command file (Expected: %d - Found: %d)\n", dev->bar, bar);
				break;
			}
			firstLine = 0;
		} else {
			verbosity >=2 ? printf("Send: %s, %ld", line, len) : 0;
			status = process_command(dev, line);
			if (status < 0) {
				printf("Warning: Command failure - %s", line);
			}
		}

	}
    }

    fclose(fp);
    if (line)
        free(line);
}



void
parse_command(
	device_t *dev, char* cmdFilePath)
{
	char *line;
	int len;
	int status;
	if (cmdFilePath != NULL)
		useCmdFile(dev, cmdFilePath);

	if(quit) return;

	while(1) {
		line = readline("PCI> ");
		/* Ctrl-D check */
		if (line == NULL) {
			printf("\n");
			continue;
		}
		/* Empty line check */
		len = strlen(line);
		if (len == 0) {
			continue;
		}
		/* Process the line */
		status = process_command(dev, line);
		if (status < 0) {
			break;
		}

		/* Add it to the history */
		add_history(line);
		free(line);
	}
	return;
}

/*--------------------------------------------------------------------
 * User interface
 *--------------------------------------------------------------------
 */
void
display_help(
	device_t *dev)
{
	printf("\n");
	printf("  ?                         Help\n");
	printf("  d[width] addr len         Display memory starting from addr\n");
	printf("                            [width]\n");
	printf("                              8   - 8-bit access\n");
	printf("                              16  - 16-bit access\n");
	printf("                              32  - 32-bit access (default)\n");
	printf("  c[width] addr val         Change memory at addr to val\n");
	printf("  e                         Print the endian access mode\n");
	printf("  e[mode]                   Change the endian access mode\n");
	printf("                            [mode]\n");
	printf("                              b - big-endian (default)\n");
	printf("                              l - little-endian\n");
	printf("  f[width] addr val len inc  Fill memory\n");
	printf("                              addr - start address\n");
	printf("                              val  - start value\n");
	printf("                              len  - length (in bytes)\n");
	printf("                              inc  - increment (defaults to 1)\n");
	printf("  q                          Quit\n");
	printf("\n  Notes:\n");
	printf("    1. addr, len, and val are interpreted as hex values\n");
	printf("       addresses are always byte based\n");
	printf("\n");
}

int process_command(device_t *dev, char *cmd)
{
	/* Skip leading whitespace */
	while (*cmd == ' ' || *cmd == '\t')
		cmd++;

	if (cmd[0] == '\0') {
		return 0;
	}
	switch (cmd[0]) {
		case '?':
			display_help(dev);
			break;
		case 'c':
		case 'C':
			return change_mem(dev, cmd);
		case 'd':
		case 'D':
			return display_mem(dev, cmd);
		case 'e':
		case 'E':
			return change_endian(dev, cmd);
		case 'f':
		case 'F':
			return fill_mem(dev, cmd);
		case 'q':
		case 'Q':
			return -1;
		default:
			break;
	}
	return 0;
}

int display_mem(device_t *dev, char *cmd)
{
	int width = 32;
	int addr = 0;
	int len = 0;
	int status;
	int i;
	unsigned char d8;
	unsigned short d16;
	unsigned int d32;

	/* d, d8, d16, d32 */
	if (cmd[1] == ' ') {
		status = sscanf(cmd, "%*c %x %x", &addr, &len);
		if (status != 2) {
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			return 0;
		}
	} else {
		status = sscanf(cmd, "%*c%d %x %x", &width, &addr, &len);
		if (status != 3) {
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			return 0;
		}
	}

	if (get_fwqe_addr(dev, addr) == NULL) {
		return 0;
	}

	if (addr > dev->size) {
		printf("Error: invalid address (maximum allowed is %.8X\n", dev->size);
		return 0;
	}
	/* Length is in bytes */
	if ((addr + len) > dev->size) {
		/* Truncate */
		len = dev->size;
	}
	switch (width) {
		case 8:
			for (i = 0; i < len; i++) {
				if ((i%16) == 0) {
					printf("\n%.8X: ", addr+i);
				}
				d8 = read_8(dev, addr+i);
				printf("%.2X ", d8);
			}
			printf("\n");
			break;
		case 16:
			for (i = 0; i < len; i+=2) {
				if ((i%16) == 0) {
					printf("\n%.8X: ", addr+i);
				}
				if (big_endian == 0) {
					d16 = read_le16(dev, addr+i);
				} else {
					d16 = read_be16(dev, addr+i);
				}
				printf("%.4X ", d16);
			}
			printf("\n");
			break;
		case 32:
			for (i = 0; i < len; i+=4) {
				if ((i%16) == 0) {
					printf("\n%.8X: ", addr+i);
				}
				if (big_endian == 0) {
					d32 = read_le32(dev, addr+i);
				} else {
					d32 = read_be32(dev, addr+i);
				}
				printf("%.8X ", d32);
				if (debug)
					print_hex_bin(&d32, 4, true);
			}
			printf("\n");
			break;
		default:
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			break;
	}
	printf("\n");
	return 0;
}

int change_mem(device_t *dev, char *cmd)
{
	int width = 32;
	int addr = 0;
	int status;
	unsigned char d8;
	unsigned short d16;
	unsigned int d32;

	/* c, c8, c16, c32 */
	if (cmd[1] == ' ') {
		status = sscanf(cmd, "%*c %x %x", &addr, &d32);
		if (status != 2) {
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			return 0;
		}
	} else {
		status = sscanf(cmd, "%*c%d %x %x", &width, &addr, &d32);
		if (status != 3) {
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			return 0;
		}
	}

	if (get_fwqe_addr(dev, addr) == NULL) {
		return 0;
	}

	if (addr > dev->size) {
		printf("Error: invalid address (maximum allowed is %.8X\n", dev->size);
		return 0;
	}
	switch (width) {
		case 8:
			d8 = (unsigned char)d32;
			write_8(dev, addr, d8);
			break;
		case 16:
			d16 = (unsigned short)d32;
			if (big_endian == 0) {
				write_le16(dev, addr, d16);
			} else {
				write_be16(dev, addr, d16);
			}
			break;
		case 32:
			if (big_endian == 0) {
				write_le32(dev, addr, d32);
			} else {
				write_be32(dev, addr, d32);
			}
			break;
		default:
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			break;
	}
	return 0;
}

int fill_mem(device_t *dev, char *cmd)
{
	int width = 32;
	int addr = 0;
	int len = 0;
	int inc = 0;
	int status;
	int i;
	unsigned char d8;
	unsigned short d16;
	unsigned int d32;

	/* c, c8, c16, c32 */
	if (cmd[1] == ' ') {
		status = sscanf(cmd, "%*c %x %x %x %x", &addr, &d32, &len, &inc);
		if ((status != 3) && (status != 4)) {
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			return 0;
		}
		if (status == 3) {
			inc = 1;
		}
	} else {
		status = sscanf(cmd, "%*c%d %x %x %x %x", &width, &addr, &d32, &len, &inc);
		if ((status != 3) && (status != 4)) {
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			return 0;
		}
		if (status == 4) {
			inc = 1;
		}
	}
	if (addr > dev->size) {
		printf("Error: invalid address (maximum allowed is %.8X\n", dev->size);
		return 0;
	}
	/* Length is in bytes */
	if ((addr + len) > dev->size) {
		/* Truncate */
		len = dev->size;
	}
	switch (width) {
		case 8:
			for (i = 0; i < len; i++) {
				d8 = (unsigned char)(d32 + i*inc);
				write_8(dev, addr+i, d8);
			}
			break;
		case 16:
			for (i = 0; i < len/2; i++) {
				d16 = (unsigned short)(d32 + i*inc);
				if (big_endian == 0) {
					write_le16(dev, addr+2*i, d16);
				} else {
					write_be16(dev, addr+2*i, d16);
				}
			}
			break;
		case 32:
			for (i = 0; i < len/4; i++) {
				if (big_endian == 0) {
					write_le32(dev, addr+4*i, d32 + i*inc);
				} else {
					write_be32(dev, addr+4*i, d32 + i*inc);
				}
			}
			break;
		default:
			printf("Syntax error (use ? for help)\n");
			/* Don't break out of command processing loop */
			break;
	}
	return 0;
}

int change_endian(device_t *dev, char *cmd)
{
	char endian = 0;
	int status;

	/* e, el, eb */
	status = sscanf(cmd, "%*c%c", &endian);
	if (status < 0) {
		/* Display the current setting */
		if (big_endian == 0) {
			printf("Endian mode: little-endian\n");
		} else {
			printf("Endian mode: big-endian\n");
		}
		return 0;
	} else if (status == 1) {
		switch (endian) {
			case 'b':
				big_endian = 1;
				break;
			case 'l':
				big_endian = 0;
				break;
			default:
				printf("Syntax error (use ? for help)\n");
				/* Don't break out of command processing loop */
				break;
		}
	} else {
		printf("Syntax error (use ? for help)\n");
		/* Don't break out of command processing loop */
	}
	return 0;
}

/* ----------------------------------------------------------------
 * Raw pointer read/write access
 * ----------------------------------------------------------------
 */
static void
write_8(
	device_t	  *dev,
	unsigned int   addr,
	unsigned char  data)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return;
	}
	*(volatile unsigned char *)reg_addr = data;
	msync((void *)reg_addr, 1, MS_SYNC | MS_INVALIDATE);
}

static unsigned char
read_8(
	device_t	  *dev,
	unsigned int   addr)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return 0;
	}
	return *(volatile unsigned char *)reg_addr;
}

static void
write_le16(
	device_t	  *dev,
	unsigned int   addr,
	unsigned short int data)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return;
	}
	if (__BYTE_ORDER != __LITTLE_ENDIAN) {
		data = bswap_16(data);
	}
	*(volatile unsigned short int *)reg_addr = data;
	msync((void *)reg_addr, 2, MS_SYNC | MS_INVALIDATE);
}

static unsigned short int
read_le16(
	device_t	  *dev,
	unsigned int   addr)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return 0;
	}
	unsigned int data = *(volatile unsigned short int *)reg_addr;
	if (__BYTE_ORDER != __LITTLE_ENDIAN) {
		data = bswap_16(data);
	}
	return data;
}

static void
write_be16(
	device_t	  *dev,
	unsigned int   addr,
	unsigned short int data)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return;
	}
	if (__BYTE_ORDER == __LITTLE_ENDIAN) {
		data = bswap_16(data);
	}
	*(volatile unsigned short int *)reg_addr = data;
	msync((void *)reg_addr, 2, MS_SYNC | MS_INVALIDATE);
}

static unsigned short int
read_be16(
	device_t	  *dev,
	unsigned int   addr)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return 0;
	}
	unsigned int data = *(volatile unsigned short int *)reg_addr;
	if (__BYTE_ORDER == __LITTLE_ENDIAN) {
		data = bswap_16(data);
	}
	return data;
}

static void
write_le32(
	device_t	  *dev,
	unsigned int   addr,
	unsigned int data)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return;
	}
	if (__BYTE_ORDER != __LITTLE_ENDIAN) {
		data = bswap_32(data);
	}
	*(volatile unsigned int *)reg_addr = data;
	msync((void *)reg_addr, 4, MS_SYNC | MS_INVALIDATE);
}

static unsigned int
read_le32(
	device_t	  *dev,
	unsigned int   addr)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return 0;
	}
	unsigned int data = *(volatile unsigned int *)reg_addr;
	if (__BYTE_ORDER != __LITTLE_ENDIAN) {
		data = bswap_32(data);
	}
	return data;
}

static void
write_be32(
	device_t	  *dev,
	unsigned int   addr,
	unsigned int data)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return;
	}
	if (__BYTE_ORDER == __LITTLE_ENDIAN) {
		data = bswap_32(data);
	}
	*(volatile unsigned int *)reg_addr = data;
	msync((void *)reg_addr, 4, MS_SYNC | MS_INVALIDATE);
}

static unsigned int
read_be32(
	device_t	  *dev,
	unsigned int   addr)
{
	unsigned char *reg_addr = get_fwqe_addr(dev, addr);
	if (reg_addr == NULL) {
		return 0;
	}
	unsigned int data = *(volatile unsigned int *)reg_addr;
	if (__BYTE_ORDER == __LITTLE_ENDIAN) {
		data = bswap_32(data);
	}
	return data;
}
