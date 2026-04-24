//-----------------------------------------------------------------------------
// PCIe Transaction Layer VIP - Type Definitions
//-----------------------------------------------------------------------------

// TLP Format encoding (Fmt[2:0] per PCIe Spec)
typedef enum bit [2:0] {
    FMT_3DW_NO_DATA   = 3'b000,
    FMT_3DW_WITH_DATA = 3'b010,
    FMT_4DW_NO_DATA   = 3'b001,
    FMT_4DW_WITH_DATA = 3'b011,
    FMT_TLP_PREFIX     = 3'b100
} tlp_fmt_e;

// TLP Type encoding (Type[4:0] per PCIe Spec)
// Note: Per PCIe spec, MEM_RD/MEM_WR share the same Type field (differentiated
// by Fmt). Same for IO_RD/IO_WR, CFG_RD0/CFG_WR0, CFG_RD1/CFG_WR1, MSG/MSG_RC.
// We keep only one enum label per unique value; aliases are provided as constants below.
typedef enum bit [4:0] {
    // Memory (RD and WR share Type=00000, distinguished by Fmt)
    TLP_TYPE_MEM_RD          = 5'b0_0000,
    TLP_TYPE_MEM_RD_LK       = 5'b0_0001,
    // IO (RD and WR share Type=00010, distinguished by Fmt)
    TLP_TYPE_IO_RD           = 5'b0_0010,
    // Config Type 0 (RD and WR share Type=00100, distinguished by Fmt)
    TLP_TYPE_CFG_RD0         = 5'b0_0100,
    // Config Type 1 (RD and WR share Type=00101, distinguished by Fmt)
    TLP_TYPE_CFG_RD1         = 5'b0_0101,
    // Completion
    TLP_TYPE_CPL             = 5'b0_1010,
    TLP_TYPE_CPL_LK          = 5'b0_1011,
    // Message
    TLP_TYPE_MSG_RC          = 5'b1_0000,
    TLP_TYPE_MSG_ADDR        = 5'b1_0001,
    TLP_TYPE_MSG_ID          = 5'b1_0010,
    TLP_TYPE_MSG_BCAST       = 5'b1_0011,
    TLP_TYPE_MSG_LOCAL       = 5'b1_0100,
    TLP_TYPE_MSG_PME_TO_ACK  = 5'b1_0101,
    // AtomicOp
    TLP_TYPE_ATOMIC_FETCHADD = 5'b0_1100,
    TLP_TYPE_ATOMIC_SWAP     = 5'b0_1101,
    TLP_TYPE_ATOMIC_CAS      = 5'b0_1110,
    // Vendor Defined
    TLP_TYPE_VENDOR_MSG      = 5'b1_0111
} tlp_type_e;

// Aliases for duplicate Type field values (RD/WR share same encoding)
parameter tlp_type_e TLP_TYPE_MEM_WR  = TLP_TYPE_MEM_RD;
parameter tlp_type_e TLP_TYPE_IO_WR   = TLP_TYPE_IO_RD;
parameter tlp_type_e TLP_TYPE_CFG_WR0 = TLP_TYPE_CFG_RD0;
parameter tlp_type_e TLP_TYPE_CFG_WR1 = TLP_TYPE_CFG_RD1;
parameter tlp_type_e TLP_TYPE_MSG     = TLP_TYPE_MSG_RC;

// High-level TLP type for user convenience (abstracts Fmt+Type combination)
typedef enum int {
    TLP_MEM_RD,
    TLP_MEM_RD_LK,
    TLP_MEM_WR,
    TLP_IO_RD,
    TLP_IO_WR,
    TLP_CFG_RD0,
    TLP_CFG_WR0,
    TLP_CFG_RD1,
    TLP_CFG_WR1,
    TLP_CPL,
    TLP_CPLD,
    TLP_CPL_LK,
    TLP_CPLD_LK,
    TLP_MSG,
    TLP_MSGD,
    TLP_ATOMIC_FETCHADD,
    TLP_ATOMIC_SWAP,
    TLP_ATOMIC_CAS,
    TLP_VENDOR_MSG,
    TLP_VENDOR_MSGD,
    TLP_LTR
} tlp_kind_e;

// Constraint mode for TLP randomization
typedef enum int {
    CONSTRAINT_LEGAL,
    CONSTRAINT_ILLEGAL,
    CONSTRAINT_CORNER_CASE
} tlp_constraint_mode_e;

// TLP category for ordering rules
typedef enum int {
    TLP_CAT_POSTED,
    TLP_CAT_NON_POSTED,
    TLP_CAT_COMPLETION
} tlp_category_e;

// Flow Control credit type
typedef enum int {
    FC_POSTED_HDR,
    FC_POSTED_DATA,
    FC_NONPOSTED_HDR,
    FC_NONPOSTED_DATA,
    FC_CPL_HDR,
    FC_CPL_DATA
} fc_type_e;

// Flow Control credit counter
typedef struct {
    int unsigned current;
    int unsigned limit;
} fc_credit_t;

// Interface mode
typedef enum int {
    TLM_MODE,
    SV_IF_MODE
} pcie_tl_if_mode_e;

// Completion status
typedef enum bit [2:0] {
    CPL_STATUS_SC  = 3'b000,
    CPL_STATUS_UR  = 3'b001,
    CPL_STATUS_CRS = 3'b010,
    CPL_STATUS_CA  = 3'b100
} cpl_status_e;

// Message code
typedef enum bit [7:0] {
    MSG_ASSERT_INTA     = 8'h20,
    MSG_ASSERT_INTB     = 8'h21,
    MSG_ASSERT_INTC     = 8'h22,
    MSG_ASSERT_INTD     = 8'h23,
    MSG_DEASSERT_INTA   = 8'h24,
    MSG_DEASSERT_INTB   = 8'h25,
    MSG_DEASSERT_INTC   = 8'h26,
    MSG_DEASSERT_INTD   = 8'h27,
    MSG_PM_PME          = 8'h18,
    MSG_PME_TO_ACK      = 8'h19,
    MSG_ERR_COR         = 8'h30,
    MSG_ERR_NONFATAL    = 8'h31,
    MSG_ERR_FATAL       = 8'h33,
    MSG_UNLOCK          = 8'h00,
    MSG_SET_SLOT_PWR    = 8'h50,
    MSG_VENDOR_TYPE0    = 8'h7E,
    MSG_VENDOR_TYPE1    = 8'h7F,
    MSG_LTR             = 8'h10
} msg_code_e;

// Alias for duplicate message code value
parameter msg_code_e MSG_PME_TURN_OFF = MSG_PME_TO_ACK;

// AtomicOp operation size
typedef enum int {
    ATOMIC_SIZE_32  = 4,
    ATOMIC_SIZE_64  = 8
} atomic_op_size_e;

// Config space field attribute
typedef enum int {
    CFG_FIELD_RO,
    CFG_FIELD_RW,
    CFG_FIELD_RW1C,
    CFG_FIELD_ROS,
    CFG_FIELD_RWS,
    CFG_FIELD_RSVD
} cfg_field_attr_e;

// Standard Capability IDs
typedef enum bit [7:0] {
    CAP_ID_PM       = 8'h01,
    CAP_ID_MSI      = 8'h05,
    CAP_ID_PCIE     = 8'h10,
    CAP_ID_MSIX     = 8'h11,
    CAP_ID_VENDOR   = 8'h09
} cap_id_e;

// Max Payload Size (MPS) - PCIe Device Capabilities/Control
typedef enum int unsigned {
    MPS_128  = 128,
    MPS_256  = 256,
    MPS_512  = 512,
    MPS_1024 = 1024,
    MPS_2048 = 2048,
    MPS_4096 = 4096
} mps_e;

// Max Read Request Size (MRRS) - PCIe Device Control
typedef enum int unsigned {
    MRRS_128  = 128,
    MRRS_256  = 256,
    MRRS_512  = 512,
    MRRS_1024 = 1024,
    MRRS_2048 = 2048,
    MRRS_4096 = 4096
} mrrs_e;

// Read Completion Boundary (RCB) - PCIe Link Capabilities/Control
typedef enum int unsigned {
    RCB_64  = 64,
    RCB_128 = 128
} rcb_e;

// Extended Capability IDs
typedef enum bit [15:0] {
    EXT_CAP_ID_AER     = 16'h0001,
    EXT_CAP_ID_VC      = 16'h0002,
    EXT_CAP_ID_SN      = 16'h0003,
    EXT_CAP_ID_PWR_BDG = 16'h0004,
    EXT_CAP_ID_ACS     = 16'h000D,
    EXT_CAP_ID_ARI     = 16'h000E,
    EXT_CAP_ID_ATS     = 16'h000F,
    EXT_CAP_ID_SRIOV   = 16'h0010,
    EXT_CAP_ID_LTR     = 16'h0018,
    EXT_CAP_ID_VENDOR  = 16'h000B,
    EXT_CAP_ID_PASID   = 16'h001B,
    EXT_CAP_ID_TPH     = 16'h0017
} ext_cap_id_e;

// TLP Prefix type (byte 0 of prefix DW: Fmt[2:0]=100 + Type[4:0])
typedef enum bit [7:0] {
    PREFIX_MRIOV         = 8'h80,  // Local:  MR-IOV Routing ID
    PREFIX_LOCAL_VENDOR  = 8'h8E,  // Local:  Vendor-Defined
    PREFIX_EXT_TPH       = 8'h90,  // E2E:    Extended TPH
    PREFIX_PASID         = 8'h91,  // E2E:    PASID
    PREFIX_IDE           = 8'h92,  // E2E:    IDE
    PREFIX_E2E_VENDOR    = 8'h9E   // E2E:    Vendor-Defined
} tlp_prefix_type_e;

// Function locator (for SR-IOV PF/VF identification)
typedef struct {
    int        pf_index;    // PF number (0..N-1)
    int        vf_index;    // VF number within PF (-1 = PF itself)
    bit [15:0] bdf;         // Full Bus/Device/Function
    bit        is_vf;
} func_id_t;

// Switch port role
typedef enum int {
    SWITCH_USP,
    SWITCH_DSP
} switch_port_role_e;

// Switch routing result
typedef enum int {
    SWITCH_ROUTE_USP    = 0,
    SWITCH_ROUTE_LOCAL  = -1,
    SWITCH_ROUTE_DROP   = -2,
    SWITCH_ROUTE_BCAST  = -3
} switch_route_special_e;

// Switch route table entry (per port)
typedef struct {
    bit [7:0]  primary_bus;
    bit [7:0]  secondary_bus;
    bit [7:0]  subordinate_bus;
    bit [31:0] mem_base;
    bit [31:0] mem_limit;
    bit [63:0] pref_base;
    bit [63:0] pref_limit;
    bit [15:0] io_base;
    bit [15:0] io_limit;
} switch_route_entry_t;
