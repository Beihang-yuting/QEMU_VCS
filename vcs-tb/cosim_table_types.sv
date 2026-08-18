`ifndef COSIM_TABLE_TYPES_SV
`define COSIM_TABLE_TYPES_SV

typedef enum int unsigned {
    COSIM_TABLE_PROTECTION_NONE,
    COSIM_TABLE_PROTECTION_PARITY_EVEN,
    COSIM_TABLE_PROTECTION_PARITY_ODD,
    COSIM_TABLE_PROTECTION_ECC,
    COSIM_TABLE_PROTECTION_SECDED,
    COSIM_TABLE_PROTECTION_CUSTOM
} cosim_table_protection_e;

typedef enum int unsigned {
    COSIM_TABLE_STATUS_SUCCESS = 0,
    COSIM_TABLE_STATUS_NOT_READY = 1,
    COSIM_TABLE_STATUS_NO_ROUTE = 2,
    COSIM_TABLE_STATUS_UNSUPPORTED = 3,
    COSIM_TABLE_STATUS_SLOT_BUSY = 4,
    COSIM_TABLE_STATUS_EXEC_ERROR = 5,
    COSIM_TABLE_STATUS_TIMEOUT = 6,
    COSIM_TABLE_STATUS_UNKNOWN = 7,
    COSIM_TABLE_STATUS_TARGET_GONE = 8,
    COSIM_TABLE_STATUS_PROTOCOL = 9
} cosim_table_status_e;

typedef struct {
    int unsigned rc_id;
    int unsigned device_instance;
    int unsigned pci_domain;
    int unsigned target_bdf;
    int unsigned target_type;
    int unsigned pf_index;
    int unsigned vf_index;
    int unsigned bar_index;
    int unsigned generation;
    int unsigned route_id;
    int unsigned entry_count;
    int unsigned entry_bytes;
    int unsigned payload_bytes;
    int unsigned byte_offset;
    int unsigned flags;
    cosim_table_protection_e protection;
    bit protection_bits[];
    longint unsigned transaction_id;
    longint unsigned first_index;
    longint unsigned bar_offset;
    string handler_name;
} cosim_table_context;

localparam longint unsigned COSIM_TABLE_FAILED_INDEX_NONE =
    64'h0000_0000_ffff_ffff;
localparam int unsigned COSIM_TABLE_RESULT_VALID_COOKIE = 32'h4354_5253;

typedef struct {
    cosim_table_status_e status;
    longint unsigned failed_index;
    int unsigned committed_count;
    int handler_error;
    bit [31:0] read_data;
    // SV-only completion marker; this field is never transferred on the wire.
    int unsigned valid_cookie;
} cosim_table_result;

function automatic void cosim_table_result_mark_valid(
    ref cosim_table_result result
);
    result.valid_cookie = COSIM_TABLE_RESULT_VALID_COOKIE;
endfunction

function automatic bit cosim_table_result_is_valid(
    input cosim_table_result result
);
    return result.valid_cookie === COSIM_TABLE_RESULT_VALID_COOKIE;
endfunction

`endif
