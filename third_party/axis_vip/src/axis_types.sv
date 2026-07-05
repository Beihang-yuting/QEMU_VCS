// Agent mode
typedef enum bit [1:0] {
    AXIS_MASTER       = 2'b00,
    AXIS_SLAVE        = 2'b01,
    AXIS_MONITOR_ONLY = 2'b10
} axis_agent_mode_e;

// Master valid generation mode
typedef enum bit [2:0] {
    VALID_ZERO_IDLE    = 3'b000,
    VALID_FIXED_IDLE   = 3'b001,
    VALID_RANDOM_IDLE  = 3'b010,
    VALID_WEIGHTED     = 3'b011,
    VALID_BURST_PAUSE  = 3'b100,
    VALID_PROFILE      = 3'b101
} axis_valid_gen_mode_e;

// Slave ready generation mode
typedef enum bit [2:0] {
    READY_ALWAYS         = 3'b000,
    READY_BEFORE_VALID   = 3'b001,
    READY_WITH_VALID     = 3'b010,
    READY_AFTER_VALID    = 3'b011,
    READY_WEIGHTED       = 3'b100,
    READY_TOGGLE         = 3'b101,
    READY_PROFILE        = 3'b110
} axis_ready_gen_mode_e;

// Reset polarity
typedef enum bit {
    AXIS_RESET_ACTIVE_LOW  = 1'b0,
    AXIS_RESET_ACTIVE_HIGH = 1'b1
} axis_reset_polarity_e;

// Reset sync mode
typedef enum bit {
    AXIS_RESET_SYNC  = 1'b0,
    AXIS_RESET_ASYNC = 1'b1
} axis_reset_sync_mode_e;

// Assertion severity
typedef enum bit [1:0] {
    AXIS_SEV_INFO    = 2'b00,
    AXIS_SEV_WARNING = 2'b01,
    AXIS_SEV_ERROR   = 2'b10,
    AXIS_SEV_FATAL   = 2'b11
} axis_severity_e;

// Valid profile entry
typedef struct {
    int unsigned            start_cycle;
    int unsigned            end_cycle;
    axis_valid_gen_mode_e   mode;
    int unsigned            idle_cycles;
    int unsigned            idle_min;
    int unsigned            idle_max;
    int unsigned            valid_weight;
    int unsigned            burst_len;
    int unsigned            pause_len;
} axis_valid_profile_entry_t;

// Ready profile entry
typedef struct {
    int unsigned            start_cycle;
    int unsigned            end_cycle;
    axis_ready_gen_mode_e   mode;
    int unsigned            ready_delay;
    int unsigned            ready_delay_min;
    int unsigned            ready_delay_max;
    int unsigned            ready_advance_cycles;
    int unsigned            ready_weight;
    int unsigned            ready_high;
    int unsigned            ready_low;
} axis_ready_profile_entry_t;

// Bandwidth profile entry
typedef struct {
    int unsigned    start_cycle;
    int unsigned    end_cycle;
    real            min_threshold;
    real            max_threshold;
} axis_bw_profile_entry_t;

// Sequence state (for virtual sequence state machine)
typedef enum bit [2:0] {
    AXIS_SEQ_STATE_NORMAL       = 3'b000,
    AXIS_SEQ_STATE_ERROR_INJECT = 3'b001,
    AXIS_SEQ_STATE_RECOVERY     = 3'b010,
    AXIS_SEQ_STATE_IDLE         = 3'b011,
    AXIS_SEQ_STATE_DONE         = 3'b100
} axis_seq_state_e;

// Packet boundary mode (for HAS_TLAST=0 scenarios)
typedef enum bit [1:0] {
    PKT_BOUNDARY_TLAST     = 2'b00,
    PKT_BOUNDARY_TIMEOUT   = 2'b01,
    PKT_BOUNDARY_FIXED_LEN = 2'b10
} axis_pkt_boundary_mode_e;

// Slave driver mode
typedef enum bit {
    SLAVE_AUTO       = 1'b0,
    SLAVE_SEQ_DRIVEN = 1'b1
} axis_slave_drive_mode_e;
