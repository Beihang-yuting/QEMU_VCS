#ifndef COSIM_TABLE_VCS_CORE_H
#define COSIM_TABLE_VCS_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

#ifndef COSIM_MAX_RCS
#define COSIM_MAX_RCS 4
#endif

#define TABLE_VCS_REQUEST_NONE 0
#define TABLE_VCS_REQUEST_WRITE 1
#define TABLE_VCS_REQUEST_READ_DWORD 2

/*
 * Lifecycle order for each RC is load, register, init, activate, poll/complete,
 * then interrupt/cleanup.  Activation starts a per-RC receive worker which
 * assembles one whole request before publishing it.  Poll is an immediate
 * state query: it returns zero when no complete request is ready, one exactly
 * once for a newly published request, and -1 for an invalid/terminal state or
 * an already-delivered request awaiting completion.  Exactly one successful
 * complete call consumes that request and releases the worker to receive the
 * next one.
 */
int table_vcs_init_rc(int rc, const char *remote_host,
                      int table_port_base, int instance_id,
                      int connect_timeout_ms);
int table_vcs_load_routes_rc(int rc, const char *absolute_path);
int table_vcs_register_handler_rc(int rc, const char *name,
                                  int supports_read);
int table_vcs_activate_routes_rc(int rc);
int table_vcs_poll_request_rc(int rc);
int table_vcs_get_request_kind_rc(int rc);
/* Owned by the RC state; valid until complete, the next request, or cleanup. */
const char *table_vcs_get_request_handler_rc(int rc);
int table_vcs_get_request_rc_id_rc(int rc);
int table_vcs_get_request_device_instance_rc(int rc);
int table_vcs_get_request_pci_domain_rc(int rc);
int table_vcs_get_request_target_bdf_rc(int rc);
int table_vcs_get_request_target_type_rc(int rc);
int table_vcs_get_request_pf_index_rc(int rc);
int table_vcs_get_request_vf_index_rc(int rc);
int table_vcs_get_request_bar_index_rc(int rc);
unsigned int table_vcs_get_request_generation_rc(int rc);
unsigned int table_vcs_get_request_route_id_rc(int rc);
unsigned long long table_vcs_get_request_first_index_rc(int rc);
unsigned long long table_vcs_get_request_bar_offset_rc(int rc);
unsigned int table_vcs_get_request_entry_count_rc(int rc);
unsigned int table_vcs_get_request_entry_bytes_rc(int rc);
unsigned int table_vcs_get_request_payload_bytes_rc(int rc);
unsigned int table_vcs_get_request_byte_offset_rc(int rc);
unsigned int table_vcs_get_request_flags_rc(int rc);
unsigned long long table_vcs_get_request_transaction_id_rc(int rc);
unsigned long long table_vcs_get_request_payload_u64_rc(
    int rc, unsigned int word);
/* Payload words are little-endian; a final short word is zero padded. */
int table_vcs_complete_rc(int rc, int status,
                          unsigned long long failed_index,
                          unsigned int committed, int handler_error,
                          unsigned int read_data);
void table_vcs_interrupt_rc(int rc);
void table_vcs_cleanup_rc(int rc);

#ifdef __cplusplus
}
#endif

#endif /* COSIM_TABLE_VCS_CORE_H */
