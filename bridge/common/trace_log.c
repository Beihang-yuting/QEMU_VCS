#include "trace_log.h"
#include <stdlib.h>
#include <string.h>

static const char *tlp_type_str(uint8_t t) {
    switch (t) {
        case TLP_MWR: return "MWr";
        case TLP_MRD: return "MRd";
        case TLP_CFGWR: return "CfgWr";
        case TLP_CFGRD: return "CfgRd";
        case TLP_CPL: return "Cpl";
        default: return "Unknown";
    }
}

static void write_hex(FILE *fp, const uint8_t *data, int len) {
    for (int i = 0; i < len; i++) fprintf(fp, "%02X", data[i]);
}

int trace_log_open(trace_log_t *log, const char *path, trace_fmt_t fmt) {
    log->fp = fopen(path, "w");
    if (!log->fp) return -1;
    log->fmt = fmt;
    log->first_record = 1;

    if (fmt == TRACE_FMT_CSV) {
        fprintf(log->fp, "timestamp,kind,type,tag,addr,len,requester_id,target_bdf,data\n");
    } else {
        fprintf(log->fp, "[\n");
    }
    return 0;
}

static void json_sep(trace_log_t *log) {
    if (!log->first_record) fprintf(log->fp, ",\n");
    log->first_record = 0;
}

void trace_log_tlp(trace_log_t *log, const tlp_entry_t *tlp) {
    if (log->fmt == TRACE_FMT_CSV) {
        fprintf(log->fp, "%lu,tlp,%s,%u,0x%lX,%u,0x%04X,0x%04X,",
                (unsigned long)tlp->timestamp, tlp_type_str(tlp->type),
                tlp->tag, (unsigned long)tlp->addr, tlp->len,
                tlp->requester_id, tlp->target_bdf);
        write_hex(log->fp, tlp->data, tlp->len > 64 ? 64 : tlp->len);
        fprintf(log->fp, "\n");
    } else {
        json_sep(log);
        fprintf(log->fp,
                "  {\"timestamp\":%lu,\"kind\":\"tlp\",\"type\":\"%s\",\"tag\":%u,"
                "\"addr\":\"0x%lX\",\"len\":%u,\"requester_id\":\"0x%04X\","
                "\"target_bdf\":\"0x%04X\",\"data\":\"",
                (unsigned long)tlp->timestamp, tlp_type_str(tlp->type),
                tlp->tag, (unsigned long)tlp->addr, tlp->len,
                tlp->requester_id, tlp->target_bdf);
        write_hex(log->fp, tlp->data, tlp->len > 64 ? 64 : tlp->len);
        fprintf(log->fp, "\"}");
    }
}

void trace_log_cpl(trace_log_t *log, const cpl_entry_t *cpl) {
    if (log->fmt == TRACE_FMT_CSV) {
        fprintf(log->fp, "%lu,cpl,%s,%u,,%u,0x%04X,0x%04X,",
                (unsigned long)cpl->timestamp, tlp_type_str(cpl->type),
                cpl->tag, cpl->len,
                cpl->requester_id, cpl->completer_id);
        write_hex(log->fp, cpl->data, cpl->len > 64 ? 64 : cpl->len);
        fprintf(log->fp, "\n");
    } else {
        json_sep(log);
        fprintf(log->fp,
                "  {\"timestamp\":%lu,\"kind\":\"cpl\",\"type\":\"%s\",\"tag\":%u,"
                "\"len\":%u,\"requester_id\":\"0x%04X\",\"completer_id\":\"0x%04X\",\"data\":\"",
                (unsigned long)cpl->timestamp, tlp_type_str(cpl->type),
                cpl->tag, cpl->len,
                cpl->requester_id, cpl->completer_id);
        write_hex(log->fp, cpl->data, cpl->len > 64 ? 64 : cpl->len);
        fprintf(log->fp, "\"}");
    }
}

void trace_log_dma(trace_log_t *log, const dma_req_t *dma) {
    const char *dir = (dma->direction == DMA_DIR_WRITE) ? "write" : "read";
    if (log->fmt == TRACE_FMT_CSV) {
        fprintf(log->fp, "%u,dma,%s,%u,0x%lX,%u,0x%04X\n",
                (unsigned)dma->timestamp, dir, dma->tag,
                (unsigned long)dma->host_addr, dma->len,
                dma->requester_id);
    } else {
        json_sep(log);
        fprintf(log->fp,
                "  {\"timestamp\":%u,\"kind\":\"dma\",\"dir\":\"%s\",\"tag\":%u,"
                "\"host_addr\":\"0x%lX\",\"len\":%u,\"requester_id\":\"0x%04X\"}",
                (unsigned)dma->timestamp, dir, dma->tag,
                (unsigned long)dma->host_addr, dma->len,
                dma->requester_id);
    }
}

void trace_log_msi(trace_log_t *log, const msi_event_t *msi) {
    if (log->fmt == TRACE_FMT_CSV) {
        fprintf(log->fp, "%lu,msi,,,,,0x%04X,%u\n",
                (unsigned long)msi->timestamp, msi->requester_id, msi->vector);
    } else {
        json_sep(log);
        fprintf(log->fp,
                "  {\"timestamp\":%lu,\"kind\":\"msi\",\"requester_id\":\"0x%04X\",\"vector\":%u}",
                (unsigned long)msi->timestamp, msi->requester_id, msi->vector);
    }
}

void trace_log_close(trace_log_t *log) {
    if (!log->fp) return;
    if (log->fmt == TRACE_FMT_JSON) {
        fprintf(log->fp, "\n]\n");
    }
    fclose(log->fp);
    log->fp = NULL;
}
