//=============================================================================
// Xilinx PCIe TL-Layer BFM - AXI-Stream tuser 编解码器
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 本文件提供四个通道的 tuser 字段编解码：
//   RQ (Requester Request)  : 62/62/137/285 位
//   RC (Requester Completion): 75/75/161/321 位
//   CQ (Completer Request)  : 88/88/183/375 位
//   CC (Completer Completion): 33/33/81/161 位
//
// 每个通道的 tuser 位宽随 DATA_WIDTH 变化（64/128/256/512 bit）。
// 本类通过构造函数接收 DATA_WIDTH，实例方法根据宽度自动选择正确布局。
//
// 注意：本类为普通 class，不继承 UVM 基类，需要实例化后使用。
//
// 修复说明：所有 part select 均使用硬编码常量索引，避免 VCS
// Error-[IRIPS] Illegal range in part select 错误。
// 不再使用 tuser[var1:var2] 形式，改为按 DATA_WIDTH 分支使用常量。
//=============================================================================

class xilinx_tuser_codec;

    //=========================================================================
    // 成员变量
    //=========================================================================

    // AXI-Stream 数据总线宽度（bits），支持 64/128/256/512
    int DATA_WIDTH;

    //=========================================================================
    // 构造函数
    //=========================================================================

    // new: 创建编解码器实例，绑定数据总线宽度
    // 参数 data_width 必须为 64/128/256/512 之一，否则运行时报错
    function new(int data_width = 256);
        if (data_width != 64 && data_width != 128 &&
            data_width != 256 && data_width != 512) begin
            $fatal(1, "[xilinx_tuser_codec] new: 不支持的数据宽度 %0d，必须为 64/128/256/512",
                data_width);
        end
        this.DATA_WIDTH = data_width;
    endfunction : new

    //=========================================================================
    // Parity 计算辅助函数
    //=========================================================================

    // calc_byte_parity: 计算单字节的奇偶校验位
    // 对字节内所有位执行 XOR，结果为 1 表示奇数个 1（奇校验）
    static function bit calc_byte_parity(bit [7:0] b);
        // 将 8 位全部 XOR 折叠，得到单 bit 校验值
        return ^b;
    endfunction : calc_byte_parity

    // calc_parity: 计算 tdata 中有效字节的逐字节奇偶校验
    // 根据 DATA_WIDTH 决定需要计算的字节数（DATA_WIDTH/8）
    // 返回 64 位向量，每 bit 对应一个字节的校验结果
    // 超出有效范围的高位补零
    function bit [63:0] calc_parity(bit [511:0] tdata);
        int num_bytes;            // 有效字节数 = DATA_WIDTH / 8
        bit [63:0] parity_result; // 校验结果向量

        num_bytes     = DATA_WIDTH / 8;   // 例如 256-bit -> 32 字节
        parity_result = '0;

        // 对每个有效字节独立计算 parity
        for (int i = 0; i < num_bytes; i++) begin
            // 从 tdata 中提取第 i 个字节（小端，字节 0 在低位）
            parity_result[i] = calc_byte_parity(tdata[i*8 +: 8]);
        end

        return parity_result;
    endfunction : calc_parity

    //=========================================================================
    // -------------------------------------------------------------------------
    // RQ 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-8）：
    //   DATA_WIDTH=64/128  -> 62-bit tuser（无 seq_num 高位、无 tag_9_8）
    //   DATA_WIDTH=256     -> 137-bit tuser
    //   DATA_WIDTH=512     -> 285-bit tuser
    // -------------------------------------------------------------------------

    // encode_rq_tuser: 将各字段打包成 RQ tuser 向量
    // 返回类型为最大宽度 bit[284:0]，调用方根据实际宽度截取低位
    //
    // 参数说明：
    //   first_be    [3:0]   首 DW 字节使能
    //   last_be     [3:0]   末 DW 字节使能
    //   addr_offset [2:0]   地址偏移（用于非 DW 对齐传输）
    //   discontinue         不连续位（强制 flush 当前传输）
    //   tph_present         TPH（TLP Processing Hints）存在标志
    //   tph_type    [1:0]   TPH 类型
    //   tph_st_tag  [7:0]   TPH Steering Tag
    //   seq_num_0   [5:0]   序列号 0（256/512-bit 模式有效）
    //   seq_num_1   [5:0]   序列号 1（512-bit 模式有效）
    //   tag_9_8     [1:0]   Tag 高 2 位（10-bit Tag 扩展，256/512-bit 有效）
    //   tdata       [511:0] 对应 AXI-Stream 数据（用于 parity 计算）
    function bit [284:0] encode_rq_tuser(
        bit [3:0]   first_be,
        bit [3:0]   last_be,
        bit [2:0]   addr_offset,
        bit         discontinue,
        bit         tph_present,
        bit [1:0]   tph_type,
        bit [7:0]   tph_st_tag,
        bit [5:0]   seq_num_0,
        bit [5:0]   seq_num_1,
        bit [1:0]   tag_9_8,
        bit [511:0] tdata
    );
        bit [284:0] tuser;           // 最大宽度返回值，未使用位填零
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        // ---------------------------------------------------------------
        // 共同字段：所有数据宽度均相同的基础字段（[22:0]）
        // 参考 PG213 Table 2-8 (RQ tuser)
        // ---------------------------------------------------------------
        tuser[3:0]   = first_be;     // [3:0]   首 DW 字节使能
        tuser[7:4]   = last_be;      // [7:4]   末 DW 字节使能
        tuser[10:8]  = addr_offset;  // [10:8]  地址字节偏移
        tuser[11]    = discontinue;  // [11]    传输不连续标志
        tuser[12]    = tph_present;  // [12]    TPH 存在标志
        tuser[14:13] = tph_type;     // [14:13] TPH 类型
        tuser[22:15] = tph_st_tag;   // [22:15] TPH Steering Tag

        if (DATA_WIDTH <= 128) begin
            // ---------------------------------------------------------------
            // 64/128-bit 模式：62-bit tuser
            // 无 seq_num 高位扩展和 tag_9_8
            // parity: 64-bit -> 8 bits, 128-bit -> 16 bits
            // 两者均放在 [62:31]，高位为零（tuser 已初始化为 0）
            // ---------------------------------------------------------------
            tuser[26:23] = seq_num_0[3:0]; // [26:23] seq_num_0 低 4 位
            tuser[30:27] = seq_num_1[3:0]; // [30:27] seq_num_1 低 4 位
            // parity 最多 16 位放入 [46:31]，[62:47] 保持为零
            if (DATA_WIDTH == 64) begin
                tuser[38:31] = parity[7:0];    // 8 字节 parity
            end else begin
                tuser[46:31] = parity[15:0];   // 16 字节 parity
            end

        end else if (DATA_WIDTH == 256) begin
            // ---------------------------------------------------------------
            // 256-bit 模式：137-bit tuser
            // parity 32 bits（256/8=32 字节）
            // ---------------------------------------------------------------
            tuser[26:23] = seq_num_0[3:0]; // [26:23] seq_num_0 低 4 位
            tuser[30:27] = seq_num_1[3:0]; // [30:27] seq_num_1 低 4 位
            tuser[62:31] = parity[31:0];   // [62:31] parity 32 bits
            tuser[68:63] = seq_num_0[5:0]; // [68:63] seq_num_0 全 6 位
            tuser[74:69] = seq_num_1[5:0]; // [74:69] seq_num_1 全 6 位
            tuser[76:75] = tag_9_8;        // [76:75] tag_9_8

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：285-bit tuser
            // parity 64 bits（512/8=64 字节）
            // ---------------------------------------------------------------
            tuser[26:23]   = seq_num_0[3:0]; // [26:23] seq_num_0 低 4 位
            tuser[30:27]   = seq_num_1[3:0]; // [30:27] seq_num_1 低 4 位
            tuser[94:31]   = parity[63:0];   // [94:31] parity 64 bits
            tuser[100:95]  = seq_num_0[5:0]; // [100:95] seq_num_0 全 6 位
            tuser[106:101] = seq_num_1[5:0]; // [106:101] seq_num_1 全 6 位
            tuser[108:107] = tag_9_8;        // [108:107] tag_9_8

        end

        return tuser;
    endfunction : encode_rq_tuser

    // decode_rq_tuser: 从 RQ tuser 向量中提取各字段
    // 输入为最大宽度向量，根据 DATA_WIDTH 选择正确的字段位置
    //
    // 输出参数均为 output，通过引用返回各字段值
    function void decode_rq_tuser(
        input  bit [284:0] tuser,
        output bit [3:0]   first_be,
        output bit [3:0]   last_be,
        output bit [2:0]   addr_offset,
        output bit         discontinue,
        output bit         tph_present,
        output bit [1:0]   tph_type,
        output bit [7:0]   tph_st_tag,
        output bit [5:0]   seq_num_0,
        output bit [5:0]   seq_num_1,
        output bit [1:0]   tag_9_8
    );
        // ---------------------------------------------------------------
        // 共同字段提取（所有数据宽度均使用相同位置）
        // ---------------------------------------------------------------
        first_be    = tuser[3:0];    // [3:0]   首 DW 字节使能
        last_be     = tuser[7:4];    // [7:4]   末 DW 字节使能
        addr_offset = tuser[10:8];   // [10:8]  地址字节偏移
        discontinue = tuser[11];     // [11]    传输不连续标志
        tph_present = tuser[12];     // [12]    TPH 存在标志
        tph_type    = tuser[14:13];  // [14:13] TPH 类型
        tph_st_tag  = tuser[22:15];  // [22:15] TPH Steering Tag

        // 初始化扩展字段为默认值
        seq_num_0 = '0;
        seq_num_1 = '0;
        tag_9_8   = '0;

        if (DATA_WIDTH <= 128) begin
            // 64/128-bit 模式：seq_num 仅有低 4 位，无高位扩展
            seq_num_0 = {2'b00, tuser[26:23]}; // [26:23] seq_num_0 低 4 位
            seq_num_1 = {2'b00, tuser[30:27]}; // [30:27] seq_num_1 低 4 位

        end else if (DATA_WIDTH == 256) begin
            // 256-bit 模式：提取完整 seq_num 和 tag_9_8
            seq_num_0 = tuser[68:63]; // [68:63] seq_num_0 全 6 位
            seq_num_1 = tuser[74:69]; // [74:69] seq_num_1 全 6 位
            tag_9_8   = tuser[76:75]; // [76:75] tag_9_8

        end else begin
            // 512-bit 模式：提取扩展字段
            seq_num_0 = tuser[100:95];  // [100:95] seq_num_0 全 6 位
            seq_num_1 = tuser[106:101]; // [106:101] seq_num_1 全 6 位
            tag_9_8   = tuser[108:107]; // [108:107] tag_9_8

        end
    endfunction : decode_rq_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // RC 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-10）：
    //   DATA_WIDTH=64/128  -> 75-bit tuser（byte_en 宽度为 DATA_WIDTH/8）
    //   DATA_WIDTH=256     -> 161-bit tuser（byte_en 32 bits，parity 32 bits）
    //   DATA_WIDTH=512     -> 321-bit tuser（byte_en 64 bits，parity 64 bits）
    //
    // 布局结构（以 256-bit 为例）：
    //   [31:0]    byte_en（32 bits）
    //   [32]      is_sof_0
    //   [33]      is_sof_1
    //   [34]      is_eof_0
    //   [37:35]   eof_offset_0
    //   [38]      is_eof_1
    //   [41:39]   eof_offset_1
    //   [42]      discontinue
    //   [74:43]   parity（32 bits）
    // -------------------------------------------------------------------------

    // encode_rc_tuser: 将各字段打包成 RC tuser 向量
    // 返回类型为最大宽度 bit[320:0]
    //
    // 参数说明：
    //   byte_en       [63:0]  字节使能向量（有效位宽 = DATA_WIDTH/8，高位补零）
    //   is_sof_0              Start-of-Frame 0 标志
    //   is_sof_1              Start-of-Frame 1 标志（512-bit 模式）
    //   is_eof_0              End-of-Frame 0 标志
    //   eof_offset_0  [2:0]   EOF 0 字节偏移
    //   is_eof_1              End-of-Frame 1 标志（512-bit 模式）
    //   eof_offset_1  [2:0]   EOF 1 字节偏移（512-bit 模式）
    //   discontinue           不连续位
    //   tdata         [511:0] 对应 AXI-Stream 数据（用于 parity 计算）
    function bit [320:0] encode_rc_tuser(
        bit [63:0]  byte_en,
        bit         is_sof_0,
        bit         is_sof_1,
        bit         is_eof_0,
        bit [2:0]   eof_offset_0,
        bit         is_eof_1,
        bit [2:0]   eof_offset_1,
        bit         discontinue,
        bit [511:0] tdata
    );
        bit [320:0] tuser;           // 最大宽度返回值
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        if (DATA_WIDTH == 64) begin
            // ---------------------------------------------------------------
            // 64-bit 模式：75-bit tuser
            // byte_en = 8 bits [7:0]，ctrl 从 bit 8 开始，parity 8 bits
            // ---------------------------------------------------------------
            tuser[7:0]   = byte_en[7:0];     // [7:0]   byte_en (8 bits)
            tuser[8]     = is_sof_0;         // [8]     is_sof_0
            tuser[9]     = is_sof_1;         // [9]     is_sof_1
            tuser[10]    = is_eof_0;         // [10]    is_eof_0
            tuser[13:11] = eof_offset_0;     // [13:11] eof_offset_0
            tuser[14]    = is_eof_1;         // [14]    is_eof_1
            tuser[17:15] = eof_offset_1;     // [17:15] eof_offset_1
            tuser[18]    = discontinue;      // [18]    discontinue
            tuser[26:19] = parity[7:0];      // [26:19] parity (8 bits)

        end else if (DATA_WIDTH == 128) begin
            // ---------------------------------------------------------------
            // 128-bit 模式：75-bit tuser
            // byte_en = 16 bits [15:0]，ctrl 从 bit 16 开始，parity 16 bits
            // ---------------------------------------------------------------
            tuser[15:0]  = byte_en[15:0];    // [15:0]  byte_en (16 bits)
            tuser[16]    = is_sof_0;         // [16]    is_sof_0
            tuser[17]    = is_sof_1;         // [17]    is_sof_1
            tuser[18]    = is_eof_0;         // [18]    is_eof_0
            tuser[21:19] = eof_offset_0;     // [21:19] eof_offset_0
            tuser[22]    = is_eof_1;         // [22]    is_eof_1
            tuser[25:23] = eof_offset_1;     // [25:23] eof_offset_1
            tuser[26]    = discontinue;      // [26]    discontinue
            tuser[42:27] = parity[15:0];     // [42:27] parity (16 bits)

        end else if (DATA_WIDTH == 256) begin
            // ---------------------------------------------------------------
            // 256-bit 模式：161-bit tuser
            // byte_en = 32 bits [31:0]，ctrl 从 bit 32 开始，parity 32 bits
            // ---------------------------------------------------------------
            tuser[31:0]  = byte_en[31:0];    // [31:0]  byte_en (32 bits)
            tuser[32]    = is_sof_0;         // [32]    is_sof_0
            tuser[33]    = is_sof_1;         // [33]    is_sof_1
            tuser[34]    = is_eof_0;         // [34]    is_eof_0
            tuser[37:35] = eof_offset_0;     // [37:35] eof_offset_0
            tuser[38]    = is_eof_1;         // [38]    is_eof_1
            tuser[41:39] = eof_offset_1;     // [41:39] eof_offset_1
            tuser[42]    = discontinue;      // [42]    discontinue
            tuser[74:43] = parity[31:0];     // [74:43] parity (32 bits)

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：321-bit tuser
            // byte_en = 64 bits [63:0]，ctrl 从 bit 64 开始，parity 64 bits
            // ---------------------------------------------------------------
            tuser[63:0]    = byte_en[63:0];  // [63:0]   byte_en (64 bits)
            tuser[64]      = is_sof_0;       // [64]     is_sof_0
            tuser[65]      = is_sof_1;       // [65]     is_sof_1
            tuser[66]      = is_eof_0;       // [66]     is_eof_0
            tuser[69:67]   = eof_offset_0;   // [69:67]  eof_offset_0
            tuser[70]      = is_eof_1;       // [70]     is_eof_1
            tuser[73:71]   = eof_offset_1;   // [73:71]  eof_offset_1
            tuser[74]      = discontinue;    // [74]     discontinue
            tuser[138:75]  = parity[63:0];   // [138:75] parity (64 bits)

        end

        return tuser;
    endfunction : encode_rc_tuser

    // decode_rc_tuser: 从 RC tuser 向量中提取各字段
    function void decode_rc_tuser(
        input  bit [320:0] tuser,
        output bit [63:0]  byte_en,
        output bit         is_sof_0,
        output bit         is_sof_1,
        output bit         is_eof_0,
        output bit [2:0]   eof_offset_0,
        output bit         is_eof_1,
        output bit [2:0]   eof_offset_1,
        output bit         discontinue
    );
        // 初始化输出为全零
        byte_en      = '0;
        is_sof_0     = '0;
        is_sof_1     = '0;
        is_eof_0     = '0;
        eof_offset_0 = '0;
        is_eof_1     = '0;
        eof_offset_1 = '0;
        discontinue  = '0;

        if (DATA_WIDTH == 64) begin
            // 64-bit 模式：byte_en 8 bits，ctrl 从 bit 8 开始
            byte_en[7:0] = tuser[7:0];      // [7:0]   byte_en
            is_sof_0     = tuser[8];         // [8]     is_sof_0
            is_sof_1     = tuser[9];         // [9]     is_sof_1
            is_eof_0     = tuser[10];        // [10]    is_eof_0
            eof_offset_0 = tuser[13:11];     // [13:11] eof_offset_0
            is_eof_1     = tuser[14];        // [14]    is_eof_1
            eof_offset_1 = tuser[17:15];     // [17:15] eof_offset_1
            discontinue  = tuser[18];        // [18]    discontinue

        end else if (DATA_WIDTH == 128) begin
            // 128-bit 模式：byte_en 16 bits，ctrl 从 bit 16 开始
            byte_en[15:0] = tuser[15:0];     // [15:0]  byte_en
            is_sof_0      = tuser[16];       // [16]    is_sof_0
            is_sof_1      = tuser[17];       // [17]    is_sof_1
            is_eof_0      = tuser[18];       // [18]    is_eof_0
            eof_offset_0  = tuser[21:19];    // [21:19] eof_offset_0
            is_eof_1      = tuser[22];       // [22]    is_eof_1
            eof_offset_1  = tuser[25:23];    // [25:23] eof_offset_1
            discontinue   = tuser[26];       // [26]    discontinue

        end else if (DATA_WIDTH == 256) begin
            // 256-bit 模式：byte_en 32 bits，ctrl 从 bit 32 开始
            byte_en[31:0] = tuser[31:0];     // [31:0]  byte_en
            is_sof_0      = tuser[32];       // [32]    is_sof_0
            is_sof_1      = tuser[33];       // [33]    is_sof_1
            is_eof_0      = tuser[34];       // [34]    is_eof_0
            eof_offset_0  = tuser[37:35];    // [37:35] eof_offset_0
            is_eof_1      = tuser[38];       // [38]    is_eof_1
            eof_offset_1  = tuser[41:39];    // [41:39] eof_offset_1
            discontinue   = tuser[42];       // [42]    discontinue

        end else begin
            // 512-bit 模式：byte_en 64 bits，ctrl 从 bit 64 开始
            byte_en[63:0] = tuser[63:0];     // [63:0]  byte_en
            is_sof_0      = tuser[64];       // [64]    is_sof_0
            is_sof_1      = tuser[65];       // [65]    is_sof_1
            is_eof_0      = tuser[66];       // [66]    is_eof_0
            eof_offset_0  = tuser[69:67];    // [69:67] eof_offset_0
            is_eof_1      = tuser[70];       // [70]    is_eof_1
            eof_offset_1  = tuser[73:71];    // [73:71] eof_offset_1
            discontinue   = tuser[74];       // [74]    discontinue

        end

    endfunction : decode_rc_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // CQ 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-9）：
    //   DATA_WIDTH=64/128  -> 88-bit tuser
    //   DATA_WIDTH=256     -> 183-bit tuser（byte_en 32 bits，parity 32 bits）
    //   DATA_WIDTH=512     -> 375-bit tuser（byte_en 64 bits，parity 64 bits）
    //
    // 布局结构（以 256-bit 为例）：
    //   [3:0]     first_be
    //   [7:4]     last_be
    //   [39:8]    byte_en（32 bits）
    //   [40]      sop
    //   [41]      sop_1
    //   [42]      discontinue
    //   [43]      tph_present
    //   [45:44]   tph_type
    //   [53:46]   tph_st_tag
    //   [54]      parity_en（置 1）
    //   [86:55]   parity（32 bits）
    //   [87]      is_eop
    //   [90:88]   eop_offset
    //   [91]      is_eop_1
    //   [94:92]   eop_offset_1
    //   [96:95]   tag_9_8
    // -------------------------------------------------------------------------

    // encode_cq_tuser: 将各字段打包成 CQ tuser 向量
    // 返回类型为最大宽度 bit[374:0]
    //
    // 参数说明：
    //   first_be     [3:0]   首 DW 字节使能
    //   last_be      [3:0]   末 DW 字节使能
    //   byte_en      [63:0]  字节使能（有效宽度 = DATA_WIDTH/8）
    //   sop                  Start-of-Packet 标志
    //   sop_1                Start-of-Packet 1 标志（512-bit 模式）
    //   discontinue          不连续标志
    //   tph_present          TPH 存在标志
    //   tph_type     [1:0]   TPH 类型
    //   tph_st_tag   [7:0]   TPH Steering Tag
    //   is_eop               End-of-Packet 标志
    //   eop_offset   [2:0]   EOP 字节偏移
    //   is_eop_1             End-of-Packet 1 标志（512-bit 模式）
    //   eop_offset_1 [2:0]   EOP 1 字节偏移（512-bit 模式）
    //   tag_9_8      [1:0]   Tag 高 2 位（10-bit Tag 扩展）
    //   tdata        [511:0] 对应 AXI-Stream 数据（用于 parity 计算）
    function bit [374:0] encode_cq_tuser(
        bit [3:0]   first_be,
        bit [3:0]   last_be,
        bit [63:0]  byte_en,
        bit         sop,
        bit         sop_1,
        bit         discontinue,
        bit         tph_present,
        bit [1:0]   tph_type,
        bit [7:0]   tph_st_tag,
        bit         is_eop,
        bit [2:0]   eop_offset,
        bit         is_eop_1,
        bit [2:0]   eop_offset_1,
        bit [1:0]   tag_9_8,
        bit [511:0] tdata
    );
        bit [374:0] tuser;           // 最大宽度返回值
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        // [3:0] first_be 和 [7:4] last_be 所有模式相同
        tuser[3:0] = first_be;
        tuser[7:4] = last_be;

        if (DATA_WIDTH == 64) begin
            // ---------------------------------------------------------------
            // 64-bit 模式：88-bit tuser
            // byte_en 8 bits [15:8]，ctrl 从 bit 16，parity 8 bits
            // be_off=8, be_top=15, ctrl_base=16, parity_base=31, eop_base=39
            // ---------------------------------------------------------------
            tuser[15:8]  = byte_en[7:0];     // [15:8]  byte_en (8 bits)
            tuser[16]    = sop;              // [16]    sop
            tuser[17]    = sop_1;            // [17]    sop_1
            tuser[18]    = discontinue;      // [18]    discontinue
            tuser[19]    = tph_present;      // [19]    tph_present
            tuser[21:20] = tph_type;         // [21:20] tph_type
            tuser[29:22] = tph_st_tag;       // [29:22] tph_st_tag
            tuser[30]    = 1'b1;             // [30]    parity_en
            tuser[38:31] = parity[7:0];      // [38:31] parity (8 bits)
            tuser[39]    = is_eop;           // [39]    is_eop
            tuser[42:40] = eop_offset;       // [42:40] eop_offset
            tuser[43]    = is_eop_1;         // [43]    is_eop_1
            tuser[46:44] = eop_offset_1;     // [46:44] eop_offset_1
            tuser[48:47] = tag_9_8;          // [48:47] tag_9_8

        end else if (DATA_WIDTH == 128) begin
            // ---------------------------------------------------------------
            // 128-bit 模式：88-bit tuser
            // byte_en 16 bits [23:8]，ctrl 从 bit 24，parity 16 bits
            // be_off=8, be_top=23, ctrl_base=24, parity_base=39, eop_base=55
            // ---------------------------------------------------------------
            tuser[23:8]  = byte_en[15:0];    // [23:8]  byte_en (16 bits)
            tuser[24]    = sop;              // [24]    sop
            tuser[25]    = sop_1;            // [25]    sop_1
            tuser[26]    = discontinue;      // [26]    discontinue
            tuser[27]    = tph_present;      // [27]    tph_present
            tuser[29:28] = tph_type;         // [29:28] tph_type
            tuser[37:30] = tph_st_tag;       // [37:30] tph_st_tag
            tuser[38]    = 1'b1;             // [38]    parity_en
            tuser[54:39] = parity[15:0];     // [54:39] parity (16 bits)
            tuser[55]    = is_eop;           // [55]    is_eop
            tuser[58:56] = eop_offset;       // [58:56] eop_offset
            tuser[59]    = is_eop_1;         // [59]    is_eop_1
            tuser[62:60] = eop_offset_1;     // [62:60] eop_offset_1
            tuser[64:63] = tag_9_8;          // [64:63] tag_9_8

        end else if (DATA_WIDTH == 256) begin
            // ---------------------------------------------------------------
            // 256-bit 模式：183-bit tuser
            // byte_en 32 bits [39:8]，ctrl 从 bit 40，parity 32 bits
            // be_off=8, be_top=39, ctrl_base=40, parity_base=55, eop_base=87
            // ---------------------------------------------------------------
            tuser[39:8]  = byte_en[31:0];    // [39:8]  byte_en (32 bits)
            tuser[40]    = sop;              // [40]    sop
            tuser[41]    = sop_1;            // [41]    sop_1
            tuser[42]    = discontinue;      // [42]    discontinue
            tuser[43]    = tph_present;      // [43]    tph_present
            tuser[45:44] = tph_type;         // [45:44] tph_type
            tuser[53:46] = tph_st_tag;       // [53:46] tph_st_tag
            tuser[54]    = 1'b1;             // [54]    parity_en
            tuser[86:55] = parity[31:0];     // [86:55] parity (32 bits)
            tuser[87]    = is_eop;           // [87]    is_eop
            tuser[90:88] = eop_offset;       // [90:88] eop_offset
            tuser[91]    = is_eop_1;         // [91]    is_eop_1
            tuser[94:92] = eop_offset_1;     // [94:92] eop_offset_1
            tuser[96:95] = tag_9_8;          // [96:95] tag_9_8

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：375-bit tuser
            // byte_en 64 bits [71:8]，ctrl 从 bit 72，parity 64 bits
            // be_off=8, be_top=71, ctrl_base=72, parity_base=87, eop_base=151
            // ---------------------------------------------------------------
            tuser[71:8]    = byte_en[63:0];  // [71:8]   byte_en (64 bits)
            tuser[72]      = sop;            // [72]     sop
            tuser[73]      = sop_1;          // [73]     sop_1
            tuser[74]      = discontinue;    // [74]     discontinue
            tuser[75]      = tph_present;    // [75]     tph_present
            tuser[77:76]   = tph_type;       // [77:76]  tph_type
            tuser[85:78]   = tph_st_tag;     // [85:78]  tph_st_tag
            tuser[86]      = 1'b1;           // [86]     parity_en
            tuser[150:87]  = parity[63:0];   // [150:87] parity (64 bits)
            tuser[151]     = is_eop;         // [151]    is_eop
            tuser[154:152] = eop_offset;     // [154:152] eop_offset
            tuser[155]     = is_eop_1;       // [155]    is_eop_1
            tuser[158:156] = eop_offset_1;   // [158:156] eop_offset_1
            tuser[160:159] = tag_9_8;        // [160:159] tag_9_8

        end

        return tuser;
    endfunction : encode_cq_tuser

    // decode_cq_tuser: 从 CQ tuser 向量中提取各字段
    function void decode_cq_tuser(
        input  bit [374:0] tuser,
        output bit [3:0]   first_be,
        output bit [3:0]   last_be,
        output bit [63:0]  byte_en,
        output bit         sop,
        output bit         sop_1,
        output bit         discontinue,
        output bit         tph_present,
        output bit [1:0]   tph_type,
        output bit [7:0]   tph_st_tag,
        output bit         is_eop,
        output bit [2:0]   eop_offset,
        output bit         is_eop_1,
        output bit [2:0]   eop_offset_1,
        output bit [1:0]   tag_9_8
    );
        // 初始化输出
        first_be     = '0;
        last_be      = '0;
        byte_en      = '0;
        sop          = '0;
        sop_1        = '0;
        discontinue  = '0;
        tph_present  = '0;
        tph_type     = '0;
        tph_st_tag   = '0;
        is_eop       = '0;
        eop_offset   = '0;
        is_eop_1     = '0;
        eop_offset_1 = '0;
        tag_9_8      = '0;

        // [3:0] first_be 和 [7:4] last_be 所有模式相同
        first_be = tuser[3:0];
        last_be  = tuser[7:4];

        if (DATA_WIDTH == 64) begin
            // 64-bit 模式
            byte_en[7:0] = tuser[15:8];      // [15:8]  byte_en
            sop          = tuser[16];         // [16]    sop
            sop_1        = tuser[17];         // [17]    sop_1
            discontinue  = tuser[18];         // [18]    discontinue
            tph_present  = tuser[19];         // [19]    tph_present
            tph_type     = tuser[21:20];      // [21:20] tph_type
            tph_st_tag   = tuser[29:22];      // [29:22] tph_st_tag
            // [30] parity_en（只读/忽略）
            is_eop       = tuser[39];         // [39]    is_eop
            eop_offset   = tuser[42:40];      // [42:40] eop_offset
            is_eop_1     = tuser[43];         // [43]    is_eop_1
            eop_offset_1 = tuser[46:44];      // [46:44] eop_offset_1
            tag_9_8      = tuser[48:47];      // [48:47] tag_9_8

        end else if (DATA_WIDTH == 128) begin
            // 128-bit 模式
            byte_en[15:0] = tuser[23:8];      // [23:8]  byte_en
            sop           = tuser[24];        // [24]    sop
            sop_1         = tuser[25];        // [25]    sop_1
            discontinue   = tuser[26];        // [26]    discontinue
            tph_present   = tuser[27];        // [27]    tph_present
            tph_type      = tuser[29:28];     // [29:28] tph_type
            tph_st_tag    = tuser[37:30];     // [37:30] tph_st_tag
            // [38] parity_en（只读/忽略）
            is_eop        = tuser[55];        // [55]    is_eop
            eop_offset    = tuser[58:56];     // [58:56] eop_offset
            is_eop_1      = tuser[59];        // [59]    is_eop_1
            eop_offset_1  = tuser[62:60];     // [62:60] eop_offset_1
            tag_9_8       = tuser[64:63];     // [64:63] tag_9_8

        end else if (DATA_WIDTH == 256) begin
            // 256-bit 模式
            byte_en[31:0] = tuser[39:8];      // [39:8]  byte_en
            sop           = tuser[40];        // [40]    sop
            sop_1         = tuser[41];        // [41]    sop_1
            discontinue   = tuser[42];        // [42]    discontinue
            tph_present   = tuser[43];        // [43]    tph_present
            tph_type      = tuser[45:44];     // [45:44] tph_type
            tph_st_tag    = tuser[53:46];     // [53:46] tph_st_tag
            // [54] parity_en（只读/忽略）
            is_eop        = tuser[87];        // [87]    is_eop
            eop_offset    = tuser[90:88];     // [90:88] eop_offset
            is_eop_1      = tuser[91];        // [91]    is_eop_1
            eop_offset_1  = tuser[94:92];     // [94:92] eop_offset_1
            tag_9_8       = tuser[96:95];     // [96:95] tag_9_8

        end else begin
            // 512-bit 模式
            byte_en[63:0] = tuser[71:8];      // [71:8]   byte_en
            sop           = tuser[72];        // [72]     sop
            sop_1         = tuser[73];        // [73]     sop_1
            discontinue   = tuser[74];        // [74]     discontinue
            tph_present   = tuser[75];        // [75]     tph_present
            tph_type      = tuser[77:76];     // [77:76]  tph_type
            tph_st_tag    = tuser[85:78];     // [85:78]  tph_st_tag
            // [86] parity_en（只读/忽略）
            is_eop        = tuser[151];       // [151]    is_eop
            eop_offset    = tuser[154:152];   // [154:152] eop_offset
            is_eop_1      = tuser[155];       // [155]    is_eop_1
            eop_offset_1  = tuser[158:156];   // [158:156] eop_offset_1
            tag_9_8       = tuser[160:159];   // [160:159] tag_9_8

        end

    endfunction : decode_cq_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // CC 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-11）：
    //   DATA_WIDTH=64/128  -> 33-bit tuser（parity 8/16 bits）
    //   DATA_WIDTH=256     -> 81-bit tuser（parity 32 bits）
    //   DATA_WIDTH=512     -> 161-bit tuser（parity 64 bits）
    //
    // CC tuser 结构最简单，只含 discontinue 和 parity 两个有意义的字段：
    //   [0]                discontinue
    //   [parity_bits:1]    parity（DATA_WIDTH/8 bits）
    // -------------------------------------------------------------------------

    // encode_cc_tuser: 将 discontinue 和 parity 打包成 CC tuser 向量
    // 返回类型为最大宽度 bit[160:0]
    //
    // 参数说明：
    //   discontinue          不连续标志
    //   tdata       [511:0]  对应 AXI-Stream 数据（用于 parity 计算）
    function bit [160:0] encode_cc_tuser(
        bit         discontinue,
        bit [511:0] tdata
    );
        bit [160:0] tuser;       // 最大宽度返回值
        bit [63:0]  parity;      // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        // [0] discontinue：不连续标志
        tuser[0] = discontinue;

        // parity 字段：从 bit 1 开始，宽度取决于 DATA_WIDTH
        if (DATA_WIDTH == 64) begin
            tuser[8:1]  = parity[7:0];      // [8:1]   parity (8 bits)
        end else if (DATA_WIDTH == 128) begin
            tuser[16:1] = parity[15:0];     // [16:1]  parity (16 bits)
        end else if (DATA_WIDTH == 256) begin
            tuser[32:1] = parity[31:0];     // [32:1]  parity (32 bits)
        end else begin
            tuser[64:1] = parity[63:0];     // [64:1]  parity (64 bits)
        end

        return tuser;
    endfunction : encode_cc_tuser

    // decode_cc_tuser: 从 CC tuser 向量中提取 discontinue 字段
    // parity 字段用于数据完整性验证，此处只提取控制字段
    function void decode_cc_tuser(
        input  bit [160:0] tuser,
        output bit         discontinue
    );
        // [0] discontinue：不连续标志（CC tuser 中唯一的控制字段）
        discontinue = tuser[0];
    endfunction : decode_cc_tuser

endclass : xilinx_tuser_codec
