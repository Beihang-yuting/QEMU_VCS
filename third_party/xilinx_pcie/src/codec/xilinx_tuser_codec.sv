//=============================================================================
// Xilinx PCIe TL-Layer BFM - AXI-Stream tuser 编解码器
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 本文件提供四个通道的 tuser 字段编解码：
//   RQ (Requester Request)  : 62/62/62/137 位  (64/128/256/512)
//   RC (Requester Completion): 75/75/75/161 位
//   CQ (Completer Request)  : 88/88/88/183 位
//   CC (Completer Completion): 33/33/33/81 位
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

    // calc_byte_parity: 计算单字节的奇校验位（PG213 tuser 为 ODD parity）
    // odd parity：校验位使 {byte, parity} 的 1 的总数为奇数，即 ~(^b)。
    static function bit calc_byte_parity(bit [7:0] b);
        // ^b = 1 表示字节内 1 的个数为奇；odd parity 位取反 -> ~^b
        return ~(^b);
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
    // 宽度映射（PG213 Table 2-8/2-35）：
    //   DATA_WIDTH=64/128/256 -> 62-bit tuser（单 seq_num，无 tag_9_8；
    //                            parity 有效位数随 D/8 缩放）
    //   DATA_WIDTH=512        -> 137-bit tuser（双 seq_num straddle）
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
        bit         sop,             // 512: is_sop[0] (TLP0 起始; narrow 用 tlast, 忽略)
        bit         is_eop,          // 512: is_eop[0]
        bit [3:0]   eop_ptr,         // 512: is_eop0_ptr[3:0] (DW 指针)
        bit [511:0] tdata
    );
        bit [284:0] tuser;           // 最大宽度返回值，未使用位填零
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        // first_be TLP0 (bit[3:0]) 两档同位，其余字段位置随宽度不同
        tuser[3:0] = first_be;       // [3:0] first_be (TLP0)

        if (DATA_WIDTH <= 256) begin
            // ---------------------------------------------------------------
            // 64/128/256-bit 模式：固定 62-bit tuser (PG213 Table 2-8/2-35)
            // 单 seq_num（双 seq_num 仅 512 straddle）；parity 有效位数随 D/8
            // 缩放。RQ tuser 内无 tag_9_8（10-bit tag 走 RQ descriptor）。
            // ---------------------------------------------------------------
            tuser[7:4]   = last_be;          // [7:4]   last_be
            tuser[10:8]  = addr_offset;      // [10:8]  addr_offset
            tuser[11]    = discontinue;      // [11]    discontinue
            tuser[12]    = tph_present;      // [12]    tph_present
            tuser[14:13] = tph_type;         // [14:13] tph_type
            // [15] tph_indirect_tag_en = 0 (无 sig 参数)
            tuser[23:16] = tph_st_tag;       // [23:16] tph_st_tag[7:0]
            tuser[27:24] = seq_num_0[3:0];   // [27:24] seq_num[3:0]
            tuser[59:28] = parity[31:0];     // [59:28] parity (低 D/8 位有效)
            tuser[61:60] = seq_num_0[5:4];   // [61:60] seq_num[5:4]

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：137-bit tuser (straddle, PG213 Table 2-35)
            // 单 TLP/beat：字段映射到 TLP0 槽，TLP1 槽(first_be[7:4]/
            // last_be[15:12]/sop1_ptr/eop1_ptr/tph[1]/seq_num1)置 0。
            // is_sop[0]/is_eop[0]/is_eop0_ptr 由 adapter 按 beat 位置传入。
            // ---------------------------------------------------------------
            tuser[11:8]    = last_be;              // [11:8]   last_be (TLP0)
            tuser[19:16]   = {1'b0, addr_offset};  // [19:16]  addr_offset[3:0]
            tuser[20]      = sop;                  // [21:20] is_sop[0] (TLP0)
            // [23:22] is_sop0_ptr = 0 (从 beat 边界起); [25:24] is_sop1_ptr = 0
            tuser[26]      = is_eop;               // [27:26] is_eop[0]
            tuser[31:28]   = eop_ptr;              // [31:28] is_eop0_ptr[3:0]
            // [35:32] is_eop1_ptr = 0
            tuser[36]      = discontinue;          // [36]     discontinue
            tuser[37]      = tph_present;          // [38:37]  tph_present[1:0] (TLP0=37)
            tuser[40:39]   = tph_type;             // [42:39]  tph_type[3:0] (TLP0=[40:39])
            // [44:43] tph_indirect_tag_en = 0
            tuser[52:45]   = tph_st_tag;           // [60:45]  tph_st_tag[15:0] (TLP0=[52:45])
            tuser[66:61]   = seq_num_0[5:0];       // [66:61]  seq_num0[5:0]
            tuser[72:67]   = seq_num_1[5:0];       // [72:67]  seq_num1[5:0]
            tuser[136:73]  = parity[63:0];         // [136:73] parity (64 bits)

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
        // first_be TLP0 (bit[3:0]) 两档同位；其余字段位置随宽度不同
        first_be = tuser[3:0];       // [3:0] first_be (TLP0)

        // 初始化输出为默认值
        last_be     = '0;
        addr_offset = '0;
        discontinue = '0;
        tph_present = '0;
        tph_type    = '0;
        tph_st_tag  = '0;
        seq_num_0   = '0;
        seq_num_1   = '0;
        tag_9_8     = '0;            // RQ tuser 无 tag_9_8 (走 descriptor)

        if (DATA_WIDTH <= 256) begin
            // 64/128/256-bit 模式：固定 62-bit (与 encode 对称)
            last_be     = tuser[7:4];    // [7:4]   last_be
            addr_offset = tuser[10:8];   // [10:8]  addr_offset
            discontinue = tuser[11];     // [11]    discontinue
            tph_present = tuser[12];     // [12]    tph_present
            tph_type    = tuser[14:13];  // [14:13] tph_type
            // [15] tph_indirect_tag_en (忽略)
            tph_st_tag  = tuser[23:16];  // [23:16] tph_st_tag[7:0]
            seq_num_0   = {tuser[61:60], tuser[27:24]}; // [61:60]+[27:24]
            // seq_num_1 / tag_9_8 无字段 -> 保持初始 0

        end else begin
            // 512-bit 模式：137-bit (PG213 Table 2-35; 单 TLP=TLP0 槽)
            last_be     = tuser[11:8];   // [11:8]  last_be (TLP0)
            addr_offset = tuser[18:16];  // [18:16] addr_offset[2:0] (of [19:16])
            discontinue = tuser[36];     // [36]    discontinue
            tph_present = tuser[37];     // tph_present[0]
            tph_type    = tuser[40:39];  // tph_type[1:0]
            tph_st_tag  = tuser[52:45];  // tph_st_tag[7:0]
            seq_num_0   = tuser[66:61];  // [66:61] seq_num0[5:0]
            seq_num_1   = tuser[72:67];  // [72:67] seq_num1[5:0]
            // tag_9_8 无字段 -> 保持初始 0

        end
    endfunction : decode_rq_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // RC 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-48）：
    //   DATA_WIDTH=64/128/256 -> 75-bit tuser（字段位置固定，byte_en/parity
    //                            有效位数随 D/8 缩放）
    //   DATA_WIDTH=512        -> 161-bit tuser（byte_en 64 bits，parity 64 bits）
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
        bit [3:0]   eof_offset_0,    // 512: is_eop0_ptr[3:0] (DW 指针 0~15)
        bit         is_eof_1,
        bit [3:0]   eof_offset_1,
        bit         discontinue,
        bit [511:0] tdata
    );
        bit [320:0] tuser;           // 最大宽度返回值
        bit [63:0]  parity;          // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        if (DATA_WIDTH <= 256) begin
            // ---------------------------------------------------------------
            // 64/128/256-bit 模式：固定 75-bit tuser (PG213 Table 2-48)
            // 字段位置对三档固定；byte_en/parity 有效位数随 D/8 缩放
            // (64->8, 128->16, 256->32)，高位补零。
            // ---------------------------------------------------------------
            tuser[31:0]  = byte_en[31:0];    // [31:0]  byte_en (低 D/8 位有效)
            tuser[32]    = is_sof_0;         // [32]    is_sof_0
            tuser[33]    = is_sof_1;         // [33]    is_sof_1
            tuser[34]    = is_eof_0;         // [34]    is_eof_0
            tuser[37:35] = eof_offset_0;     // [37:35] eof_offset_0
            tuser[38]    = is_eof_1;         // [38]    is_eof_1
            tuser[41:39] = eof_offset_1;     // [41:39] eof_offset_1
            tuser[42]    = discontinue;      // [42]    discontinue
            tuser[74:43] = parity[31:0];     // [74:43] parity (低 D/8 位有效)

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：161-bit tuser (straddle, PG213 Table 2-48)
            // RC 512 每 beat 可含 4 个 completion (is_sop[3:0]/is_eop[3:0])。
            // 现有 sig 支持 2 个(sof_0/1, eof_0/1) -> 映射到 slot0/1，slot2/3 置 0。
            // is_eop*_ptr 为 512-beat 内 DW 指针；由 eof_offset 映射(低 3 位)。
            // ---------------------------------------------------------------
            tuser[63:0]    = byte_en[63:0];          // [63:0]   byte_en (64 bits)
            tuser[65:64]   = {is_sof_1, is_sof_0};   // [67:64]  is_sop[3:0] (slot0/1)
            // [69:68]/[71:70]/[73:72]/[75:74] is_sop0..3_ptr = 0 (从 beat 边界起)
            tuser[77:76]   = {is_eof_1, is_eof_0};   // [79:76]  is_eop[3:0] (slot0/1)
            tuser[83:80]   = eof_offset_0;           // [83:80]  is_eop0_ptr[3:0]
            tuser[87:84]   = eof_offset_1;           // [87:84]  is_eop1_ptr[3:0]
            // [91:88]/[95:92] is_eop2/3_ptr = 0
            tuser[96]      = discontinue;            // [96]     discontinue
            tuser[160:97]  = parity[63:0];           // [160:97] parity (64 bits)

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
        output bit [3:0]   eof_offset_0,
        output bit         is_eof_1,
        output bit [3:0]   eof_offset_1,
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

        if (DATA_WIDTH <= 256) begin
            // 64/128/256-bit 模式：固定 75-bit 布局 (与 encode 对称)
            byte_en[31:0] = tuser[31:0];     // [31:0]  byte_en (低 D/8 位有效)
            is_sof_0      = tuser[32];       // [32]    is_sof_0
            is_sof_1      = tuser[33];       // [33]    is_sof_1
            is_eof_0      = tuser[34];       // [34]    is_eof_0
            eof_offset_0  = tuser[37:35];    // [37:35] eof_offset_0
            is_eof_1      = tuser[38];       // [38]    is_eof_1
            eof_offset_1  = tuser[41:39];    // [41:39] eof_offset_1
            discontinue   = tuser[42];       // [42]    discontinue

        end else begin
            // 512-bit 模式：161-bit (PG213 Table 2-48; slot0/1 映射)
            byte_en[63:0] = tuser[63:0];     // [63:0]  byte_en
            is_sof_0      = tuser[64];       // is_sop[0]
            is_sof_1      = tuser[65];       // is_sop[1]
            is_eof_0      = tuser[76];       // is_eop[0]
            eof_offset_0  = tuser[83:80];    // is_eop0_ptr[3:0]
            is_eof_1      = tuser[77];       // is_eop[1]
            eof_offset_1  = tuser[87:84];    // is_eop1_ptr[3:0]
            discontinue   = tuser[96];       // [96]    discontinue

        end

    endfunction : decode_rc_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // CQ 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-52）：
    //   DATA_WIDTH=64/128/256 -> 88-bit tuser（字段位置固定，byte_en/parity
    //                            有效位数随 D/8 缩放）
    //   DATA_WIDTH=512        -> 183-bit tuser（straddle 接口，PG213 Table 2-52）
    //
    // 88-bit 布局（64/128/256 通用）：
    //   [3:0]     first_be
    //   [7:4]     last_be
    //   [39:8]    byte_en（低 D/8 位有效）
    //   [40]      sop
    //   [41]      discontinue
    //   [42]      tph_present
    //   [44:43]   tph_type
    //   [52:45]   tph_st_tag
    //   [84:53]   parity（低 D/8 位有效）
    //   [87:85]   保留
    // 注：非-512 CQ 用 tlast 表示 EOP，tuser 内无 is_eop/sop_1/tag_9_8。
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
        bit [3:0]   eop_offset,      // 512: is_eop0_ptr[3:0] (DW 指针 0~15)
        bit         is_eop_1,
        bit [3:0]   eop_offset_1,
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

        if (DATA_WIDTH <= 256) begin
            // ---------------------------------------------------------------
            // 64/128/256-bit 模式：固定 88-bit tuser (PG213 Table 2-52)
            // 字段位置对 64/128/256 三档固定不变；byte_en/parity 有效位数
            // 随宽度缩放 (D/8: 64->8, 128->16, 256->32)，高位补零。
            // 非-512 CQ 用 m_axis_cq_tlast 表示 EOP —— tuser 内没有
            // is_eop/eop_offset/sop_1/parity_en/tag 字段（那些仅 512 straddle 才有）。
            // ---------------------------------------------------------------
            tuser[39:8]  = byte_en[31:0];    // [39:8]  byte_en (低 D/8 位有效)
            tuser[40]    = sop;              // [40]    sop
            tuser[41]    = discontinue;      // [41]    discontinue
            tuser[42]    = tph_present;      // [42]    tph_present
            tuser[44:43] = tph_type;         // [44:43] tph_type
            tuser[52:45] = tph_st_tag;       // [52:45] tph_st_tag
            tuser[84:53] = parity[31:0];     // [84:53] parity (低 D/8 位有效)
            // [87:85] 保留

        end else begin
            // ---------------------------------------------------------------
            // 512-bit 模式：183-bit tuser (straddle 接口, PG213 Table 2-52)
            // 单 TLP/beat：现有字段映射到 TLP0 槽，TLP1 槽(first_be[7:4]/
            // last_be[15:12]/sop1_ptr/eop1_ptr/tph[1])置 0。
            // 注：is_sop*_ptr/is_eop*_ptr 为 512-beat 内的 DW 指针；单 TLP 从
            //    beat 边界起 sop_ptr=0，eop_ptr 由 eop_offset 映射(低 3 位)。
            //    完整 2-TLP straddle 打包需 straddle_engine 支持(当前单 TLP)。
            // ---------------------------------------------------------------
            tuser[7:4]     = 4'h0;               // first_be TLP1 = 0 (覆盖 common 里的 last_be)
            tuser[11:8]    = last_be;            // [11:8]   last_be TLP0 ([15:12]=TLP1=0)
            tuser[79:16]   = byte_en[63:0];      // [79:16]  byte_en (64 bits)
            tuser[80]      = sop;                // [80]     is_sop[0] (TLP0 起始)
            tuser[81]      = sop_1;              // [81]     is_sop[1] (TLP1 起始)
            // [83:82] is_sop0_ptr = 0 (从 beat 边界起)；[85:84] is_sop1_ptr = 0
            tuser[86]      = is_eop;             // [86]     is_eop[0]
            tuser[87]      = is_eop_1;           // [87]     is_eop[1]
            tuser[91:88]   = eop_offset;         // [91:88]  is_eop0_ptr[3:0]
            tuser[95:92]   = eop_offset_1;       // [95:92]  is_eop1_ptr[3:0]
            tuser[96]      = discontinue;        // [96]     discontinue
            tuser[97]      = tph_present;        // [98:97]  tph_present[1:0] (TLP0=bit97)
            tuser[100:99]  = tph_type;           // [102:99] tph_type[3:0] (TLP0=[100:99])
            tuser[110:103] = tph_st_tag;         // [118:103] tph_st_tag[15:0] (TLP0=[110:103])
            tuser[182:119] = parity[63:0];       // [182:119] parity (64 bits)
            // 注：512-bit CQ tuser 无 tag_9_8 字段(10-bit tag 走 CQ descriptor)。

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
        output bit [3:0]   eop_offset,
        output bit         is_eop_1,
        output bit [3:0]   eop_offset_1,
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

        if (DATA_WIDTH <= 256) begin
            // 64/128/256-bit 模式：固定 88-bit 布局 (与 encode 对称)
            byte_en[31:0] = tuser[39:8];      // [39:8]  byte_en (低 D/8 位有效)
            sop           = tuser[40];        // [40]    sop
            discontinue   = tuser[41];        // [41]    discontinue
            tph_present   = tuser[42];        // [42]    tph_present
            tph_type      = tuser[44:43];     // [44:43] tph_type
            tph_st_tag    = tuser[52:45];     // [52:45] tph_st_tag
            // [84:53] parity 仅用于完整性校验，不提取
            // 非-512: sop_1/is_eop/eop_offset/tag_9_8 无字段 -> 保持初始 0

        end else begin
            // 512-bit 模式 (straddle, PG213 Table 2-52; 单 TLP=TLP0 槽)
            last_be       = tuser[11:8];      // [11:8]  last_be TLP0 (覆盖 common [7:4])
            byte_en[63:0] = tuser[79:16];     // [79:16] byte_en
            sop           = tuser[80];        // [80]    is_sop[0]
            sop_1         = tuser[81];        // [81]    is_sop[1]
            is_eop        = tuser[86];        // [86]    is_eop[0]
            is_eop_1      = tuser[87];        // [87]    is_eop[1]
            eop_offset    = tuser[91:88];     // is_eop0_ptr[3:0]
            eop_offset_1  = tuser[95:92];     // is_eop1_ptr[3:0]
            discontinue   = tuser[96];        // [96]    discontinue
            tph_present   = tuser[97];        // tph_present[0]
            tph_type      = tuser[100:99];    // tph_type[1:0]
            tph_st_tag    = tuser[110:103];   // tph_st_tag[7:0]
            // 512 CQ tuser 无 tag_9_8 -> 保持初始 0

        end

    endfunction : decode_cq_tuser

    //=========================================================================
    // -------------------------------------------------------------------------
    // CC 通道 tuser 编解码
    // 宽度映射（PG213 Table 2-42）：
    //   DATA_WIDTH=64/128/256 -> 33-bit tuser（parity 有效位数随 D/8 缩放）
    //   DATA_WIDTH=512        -> 81-bit tuser（parity 64 bits）
    //
    // 64/128/256 (33-bit)：[0] discontinue，[32:1] parity（D/8 位有效）。
    // 512 (81-bit)：straddle —— is_sop[1:0]@[1:0]/sop_ptr/is_eop[1:0]@[7:6]/
    //   eop_ptr/discontinue@[16]/parity@[80:17]。
    // -------------------------------------------------------------------------

    // encode_cc_tuser: 将 discontinue 和 parity 打包成 CC tuser 向量
    // 返回类型为最大宽度 bit[160:0]
    //
    // 参数说明：
    //   discontinue          不连续标志
    //   tdata       [511:0]  对应 AXI-Stream 数据（用于 parity 计算）
    function bit [160:0] encode_cc_tuser(
        bit         discontinue,
        bit         sop,             // 512: is_sop[0] (narrow 用 tlast, 忽略)
        bit         is_eop,          // 512: is_eop[0]
        bit [3:0]   eop_ptr,         // 512: is_eop0_ptr[3:0]
        bit [511:0] tdata
    );
        bit [160:0] tuser;       // 最大宽度返回值
        bit [63:0]  parity;      // 计算得到的 parity 向量

        tuser  = '0;
        parity = calc_parity(tdata);

        if (DATA_WIDTH <= 256) begin
            // 64/128/256 -> 33-bit: discontinue@0, parity@[32:1] (低 D/8 位有效)
            tuser[0]    = discontinue;
            tuser[32:1] = parity[31:0];
        end else begin
            // 512 -> 81-bit (PG213 Table 2-42): straddle 布局
            //   is_sop[1:0]@[1:0] / is_sop0_ptr@[3:2] / is_sop1_ptr@[5:4]
            //   is_eop[1:0]@[7:6] / is_eop0_ptr@[11:8] / is_eop1_ptr@[15:12]
            //   discontinue@[16] / parity@[80:17]
            // 单 TLP/beat：TLP0 槽由 adapter 传入 sop/is_eop/eop_ptr，TLP1 槽=0。
            tuser[0]     = sop;              // [1:0]   is_sop[0] (TLP0)
            // [3:2] is_sop0_ptr = 0; [5:4] is_sop1_ptr = 0
            tuser[6]     = is_eop;           // [7:6]   is_eop[0]
            tuser[11:8]  = eop_ptr;          // [11:8]  is_eop0_ptr[3:0]
            // [15:12] is_eop1_ptr = 0
            tuser[16]    = discontinue;      // [16]    discontinue
            tuser[80:17] = parity[63:0];     // [80:17] parity (64 bits)
        end

        return tuser;
    endfunction : encode_cc_tuser

    // decode_cc_tuser: 从 CC tuser 向量中提取 discontinue 字段
    // parity 字段用于数据完整性验证，此处只提取控制字段
    function void decode_cc_tuser(
        input  bit [160:0] tuser,
        output bit         discontinue
    );
        // discontinue 位置随宽度不同：64/128/256 -> bit0，512 -> bit16
        discontinue = (DATA_WIDTH <= 256) ? tuser[0] : tuser[16];
    endfunction : decode_cc_tuser

endclass : xilinx_tuser_codec
