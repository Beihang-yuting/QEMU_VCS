#include <stdio.h>
#include "test_check.h"
#include <string.h>
#include <unistd.h>
#include "trace_log.h"
#include "cosim_types.h"

static void test_csv_write(void) {
    const char *path = "/tmp/cosim_trace_test.csv";
    unlink(path);
    trace_log_t log;
    CHECK(trace_log_open(&log, path, TRACE_FMT_CSV) == 0);

    tlp_entry_t req = { .type = TLP_MRD, .tag = 5, .addr = 0x1000, .len = 4,
                         .timestamp = 100 };
    trace_log_tlp(&log, &req);

    cpl_entry_t cpl = { .type = TLP_CPL, .tag = 5, .status = 0, .len = 4,
                         .timestamp = 150 };
    cpl.data[0] = 0xEF; cpl.data[1] = 0xBE; cpl.data[2] = 0xAD; cpl.data[3] = 0xDE;
    trace_log_cpl(&log, &cpl);

    trace_log_close(&log);

    FILE *f = fopen(path, "r");
    CHECK(f);
    char line[256];
    CHECK(fgets(line, sizeof(line), f));
    CHECK(strstr(line, "timestamp"));
    CHECK(fgets(line, sizeof(line), f));
    CHECK(strstr(line, "MRd"));
    CHECK(strstr(line, "0x1000"));
    CHECK(fgets(line, sizeof(line), f));
    CHECK(strstr(line, "Cpl"));
    CHECK(strstr(line, "EFBEADDE") || strstr(line, "efbeadde"));
    fclose(f);

    unlink(path);
    printf("  PASS: test_csv_write\n");
}

static void test_json_write(void) {
    const char *path = "/tmp/cosim_trace_test.json";
    unlink(path);
    trace_log_t log;
    CHECK(trace_log_open(&log, path, TRACE_FMT_JSON) == 0);

    tlp_entry_t req = { .type = TLP_MWR, .tag = 7, .addr = 0x2000, .len = 4,
                         .timestamp = 200 };
    trace_log_tlp(&log, &req);
    trace_log_close(&log);

    FILE *f = fopen(path, "r");
    CHECK(f);
    /* JSON should start with [ and end with ] */
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    CHECK(size > 10);
    fseek(f, 0, SEEK_SET);
    char buf[512];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    buf[n] = '\0';
    fclose(f);
    CHECK(buf[0] == '[');
    CHECK(strstr(buf, "\"kind\":\"tlp\""));
    CHECK(strstr(buf, "\"type\":\"MWr\""));

    unlink(path);
    printf("  PASS: test_json_write\n");
}

int main(void) {
    printf("=== trace_log tests ===\n");
    test_csv_write();
    test_json_write();
    printf("=== ALL PASSED ===\n");
    return 0;
}
