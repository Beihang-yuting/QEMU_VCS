/* cfgspace_test.c - Guest-side PCI config space read test
 * Reads standard PCI config header fields via sysfs and verifies
 * they match the values provided by VCS EP stub's cfg_space[].
 *
 * Usage: /cfgspace_test
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

/* Read raw config space bytes via sysfs "config" file */
static int read_config_raw(const char *dev_path, uint8_t *buf, int len) {
    char path[512];
    snprintf(path, sizeof(path), "%s/config", dev_path);
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open config");
        return -1;
    }
    int n = read(fd, buf, len);
    close(fd);
    return n;
}

int main(void) {
    const char *target_vendor = "0x1af4";
    const char *target_device = "0x1041";
    char dev_path[512] = {0};
    char path_buf[512];
    char val_buf[32];

    printf("=== PCI Config Space Test ===\n\n");

    /* Find our cosim device */
    for (int bus = 0; bus < 256; bus++) {
        for (int dev = 0; dev < 32; dev++) {
            for (int fn = 0; fn < 8; fn++) {
                snprintf(path_buf, sizeof(path_buf),
                         "/sys/bus/pci/devices/0000:%02x:%02x.%d/vendor",
                         bus, dev, fn);
                int fd = open(path_buf, O_RDONLY);
                if (fd < 0) continue;
                int n = read(fd, val_buf, sizeof(val_buf) - 1);
                close(fd);
                if (n <= 0) continue;
                val_buf[n] = '\0';
                char *nl = strchr(val_buf, '\n');
                if (nl) *nl = '\0';

                if (strcmp(val_buf, target_vendor) != 0) continue;

                snprintf(path_buf, sizeof(path_buf),
                         "/sys/bus/pci/devices/0000:%02x:%02x.%d/device",
                         bus, dev, fn);
                fd = open(path_buf, O_RDONLY);
                if (fd < 0) continue;
                n = read(fd, val_buf, sizeof(val_buf) - 1);
                close(fd);
                if (n <= 0) continue;
                val_buf[n] = '\0';
                nl = strchr(val_buf, '\n');
                if (nl) *nl = '\0';

                if (strcmp(val_buf, target_device) == 0) {
                    snprintf(dev_path, sizeof(dev_path),
                             "/sys/bus/pci/devices/0000:%02x:%02x.%d",
                             bus, dev, fn);
                    goto found;
                }
            }
        }
    }

    printf("ERROR: CoSim device (1234:0001) not found\n");
    return 1;

found:
    printf("Found device at: %s\n\n", dev_path);

    /* Read raw config space (first 64 bytes = standard header) */
    uint8_t cfg[256];
    memset(cfg, 0xFF, sizeof(cfg));
    int cfg_len = read_config_raw(dev_path, cfg, 256);
    if (cfg_len < 64) {
        printf("ERROR: could only read %d config bytes (need 64)\n", cfg_len);
        return 1;
    }
    printf("Read %d bytes of config space\n\n", cfg_len);

    /* Parse and verify standard header fields */
    uint16_t vendor_id = cfg[0] | (cfg[1] << 8);
    uint16_t device_id = cfg[2] | (cfg[3] << 8);
    uint16_t command   = cfg[4] | (cfg[5] << 8);
    uint8_t  revision  = cfg[8];
    uint8_t  prog_if   = cfg[9];
    uint8_t  subclass  = cfg[10];
    uint8_t  base_class = cfg[11];
    uint8_t  hdr_type  = cfg[14];
    uint16_t subsys_vendor = cfg[44] | (cfg[45] << 8);
    uint16_t subsys_id     = cfg[46] | (cfg[47] << 8);

    int errors = 0;

    printf("[1] Vendor ID:      0x%04X", vendor_id);
    if (vendor_id == 0x1AF4) printf("  PASS\n");
    else { printf("  FAIL (expect 0x1AF4)\n"); errors++; }

    printf("[2] Device ID:      0x%04X", device_id);
    if (device_id == 0x1041) printf("  PASS\n");
    else { printf("  FAIL (expect 0x1041)\n"); errors++; }

    printf("[3] Command:        0x%04X", command);
    if (command & 0x0007) printf("  OK (IO+MEM+Master)\n");
    else { printf("  WARN (expected bits 0-2 set)\n"); }

    printf("[4] Revision:       0x%02X", revision);
    if (revision == 0x01) printf("  PASS\n");
    else { printf("  FAIL (expect 0x01)\n"); errors++; }

    printf("[5] Class Code:     %02X:%02X:%02X", base_class, subclass, prog_if);
    if (base_class == 0x02) printf("  PASS (Network)\n");
    else { printf("  FAIL (expect 02:xx:xx)\n"); errors++; }

    printf("[6] Header Type:    0x%02X", hdr_type);
    if ((hdr_type & 0x7F) == 0x00) printf("  PASS (Type 0)\n");
    else { printf("  INFO (Type %d)\n", hdr_type & 0x7F); }

    printf("[7] Subsys Vendor:  0x%04X\n", subsys_vendor);
    printf("[8] Subsys ID:      0x%04X\n", subsys_id);

    /* Hex dump first 64 bytes */
    printf("\nConfig Space Hex Dump (first 64 bytes):\n");
    for (int i = 0; i < 64; i++) {
        if (i % 16 == 0) printf("  %02X: ", i);
        printf("%02X ", cfg[i]);
        if (i % 16 == 15) printf("\n");
    }

    printf("\n=== Config Space Test: %s ===\n",
           errors == 0 ? "PASS" : "FAIL");
    return errors ? 1 : 0;
}
