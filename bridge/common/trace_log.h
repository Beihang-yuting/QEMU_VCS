#ifndef TRACE_LOG_H
#define TRACE_LOG_H

#include <stdio.h>
#include "cosim_types.h"

typedef enum {
    TRACE_FMT_CSV  = 0,
    TRACE_FMT_JSON = 1,
} trace_fmt_t;

typedef struct {
    FILE        *fp;
    trace_fmt_t  fmt;
    int          first_record;
} trace_log_t;

int  trace_log_open(trace_log_t *log, const char *path, trace_fmt_t fmt);
void trace_log_tlp(trace_log_t *log, const tlp_entry_t *tlp);
void trace_log_cpl(trace_log_t *log, const cpl_entry_t *cpl);
void trace_log_dma(trace_log_t *log, const dma_req_t *dma);
void trace_log_msi(trace_log_t *log, const msi_event_t *msi);
void trace_log_close(trace_log_t *log);

#endif
