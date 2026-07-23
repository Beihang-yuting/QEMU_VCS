//=============================================================================
// Xilinx PCIe TL-Layer BFM - Straddle 组包/拆包引擎
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 本文件实现单个 TLP 在 AXI-Stream beat 序列中的组包与拆包：
//   - pack_single_tlp  : 将 descriptor + payload 打包为 beat 序列
//   - unpack_single_tlp: 从 beat 序列中提取 descriptor + payload
//
// 支持四个通道的描述符宽度差异：
//   RQ/CQ：128 位描述符（4 DW）
//   RC/CC：96 位描述符（3 DW）
//
// 支持数据总线宽度：64 / 128 / 256 / 512 位
// 注意：本类为普通 class，不继承 UVM 基类，需要实例化后使用。
//=============================================================================

class xilinx_straddle_engine;

    //=========================================================================
    // 成员变量
    //=========================================================================

    // Straddle 模式使能标志（使能后允许 TLP 跨 beat 边界放置）
    bit straddle_enable;

    // AXI-Stream 数据总线宽度（bits），支持 64/128/256/512
    int DATA_WIDTH;

    //=========================================================================
    // 构造函数
    //=========================================================================

    // new: 创建 straddle 引擎实例
    // 参数：
    //   enable     - 是否使能 straddle 模式（默认关闭）
    //   data_width - AXI-Stream 数据总线宽度（默认 256 bit）
    function new(bit enable = 0, int data_width = 256);
        this.straddle_enable = enable;
        this.DATA_WIDTH      = data_width;
    endfunction : new

    //=========================================================================
    // 内部辅助函数
    //=========================================================================

    // get_desc_dws: 根据通道类型返回描述符占用的 DW 数
    // RQ/CQ 使用 128 位描述符（4 DW）；RC/CC 使用 96 位描述符（3 DW）
    local function int get_desc_dws(xilinx_channel_e channel);
        case (channel)
            XILINX_CH_RQ: return 4;   // 128-bit / 32 = 4 DW
            XILINX_CH_CQ: return 4;   // 128-bit / 32 = 4 DW
            XILINX_CH_RC: return 3;   // 96-bit  / 32 = 3 DW
            XILINX_CH_CC: return 3;   // 96-bit  / 32 = 3 DW
            default:      return 4;
        endcase
    endfunction : get_desc_dws

    // get_dw_from_desc: 从 128 位描述符中提取第 dw_idx 个 DW（32 位）
    // 小端布局：DW0 在 desc[31:0]，DW1 在 desc[63:32]，以此类推
    local function bit [31:0] get_dw_from_desc(bit [127:0] desc, int dw_idx);
        return desc[dw_idx*32 +: 32];
    endfunction : get_dw_from_desc

    // set_dw_in_desc: 将 32 位 DW 写入 128 位描述符的第 dw_idx 个位置
    // 返回新的描述符（不修改原值，保持不可变原则）
    local function bit [127:0] set_dw_in_desc(
        bit [127:0] desc,
        int         dw_idx,
        bit [31:0]  dw_val
    );
        bit [127:0] result;
        result = desc;
        result[dw_idx*32 +: 32] = dw_val;
        return result;
    endfunction : set_dw_in_desc

    // get_beat_dw: 从 beat 数据中提取第 dw_idx 个 DW（32 位）
    // 小端布局：DW0 在 beat[31:0]，DW1 在 beat[63:32]，以此类推
    local function bit [31:0] get_beat_dw(bit [511:0] beat, int dw_idx);
        return beat[dw_idx*32 +: 32];
    endfunction : get_beat_dw

    // set_beat_dw: 将 32 位 DW 写入 beat 数据的第 dw_idx 个位置
    // 返回新的 beat（不修改原值）
    local function bit [511:0] set_beat_dw(
        bit [511:0] beat,
        int         dw_idx,
        bit [31:0]  dw_val
    );
        bit [511:0] result;
        result = beat;
        result[dw_idx*32 +: 32] = dw_val;
        return result;
    endfunction : set_beat_dw

    //=========================================================================
    // pack_single_tlp: 将单个 TLP 打包为 AXI-Stream beat 序列
    //=========================================================================
    //
    // 将编码后的描述符与 payload 按 AXI-Stream 格式组装为若干 beat：
    //   - Beat 0：放入描述符 DW，剩余空间填充 payload（如有）
    //   - 后续 beat：继续填充 payload
    //   - 最后一个 beat：tlast=1，tkeep 仅置位有效 DW 对应位
    //
    // 特殊情况 DATA_WIDTH=64：
    //   - 每 beat 仅 2 个 DW，128 位描述符（4 DW）需占用 2 个 beat
    //   - 96 位描述符（3 DW）首 beat 放 DW0-1，第二 beat 放 DW2 + payload
    //
    // 参数：
    //   descriptor - 编码后的 128 位描述符（RC/CC 仅使用低 96 位）
    //   payload    - TLP payload 字节数组（无数据 TLP 可为空）
    //   channel    - 通道类型，决定描述符 DW 数量
    //   beats      - 输出：tdata 队列（每元素 512 位，未使用高位补零）
    //   keeps      - 输出：tkeep 队列（每位对应一个 DW，1 = 有效）
    //   lasts      - 输出：tlast 队列（最后一个 beat 为 1）
    //
    function void pack_single_tlp(
        input  bit [127:0]       descriptor,
        input  bit [7:0]         payload[],
        input  xilinx_channel_e  channel,
        output bit [511:0]       beats[$],
        output bit [15:0]        keeps[$],
        output bit               lasts[$]
    );
        int         beat_dws;       // 每个 beat 包含的 DW 数量
        int         desc_dws;       // 描述符占用的 DW 数（RQ/CQ=4，RC/CC=3）
        int         payload_bytes;  // payload 字节总数
        int         payload_dws;    // payload 转换为 DW 数（向上取整）
        int         dw_pos;         // 当前 beat 中已填充的 DW 位置
        bit [511:0] cur_beat;       // 当前 beat 数据缓冲
        bit [15:0]  cur_keep;       // 当前 beat 的有效 DW 掩码
        int         pay_byte_off;   // payload 已处理的字节偏移
        bit [31:0]  pay_dw;         // 从 payload 中组合的一个 DW

        // 清空输出队列（保持不可变原则：输出全新队列）
        beats.delete();
        keeps.delete();
        lasts.delete();

        // 计算基本参数
        beat_dws      = DATA_WIDTH / 32;    // 每 beat 的 DW 数
        desc_dws      = get_desc_dws(channel);
        payload_bytes = payload.size();
        // payload DW 数向上取整（末尾不足 4 字节的 DW 也算一个）
        payload_dws   = (payload_bytes + 3) / 4;

        // 初始化第一个 beat 缓冲
        cur_beat = '0;
        cur_keep = '0;
        dw_pos   = 0;

        // -------------------------------------------------------------------
        // 阶段 1：填充描述符 DW
        // 逐 DW 写入，当 beat 填满时 flush 进队列
        // -------------------------------------------------------------------
        for (int i = 0; i < desc_dws; i++) begin
            cur_beat = set_beat_dw(cur_beat, dw_pos, get_dw_from_desc(descriptor, i));
            cur_keep[dw_pos] = 1'b1;
            dw_pos++;

            // 当前 beat 已满则 flush（主要针对 DATA_WIDTH=64 时 beat_dws=2 的情况）
            if (dw_pos >= beat_dws) begin
                beats.push_back(cur_beat);
                keeps.push_back(cur_keep);
                lasts.push_back(1'b0);   // tlast 暂标 0，最后统一修正
                cur_beat = '0;
                cur_keep = '0;
                dw_pos   = 0;
            end
        end

        // -------------------------------------------------------------------
        // 阶段 2：填充 payload DW（按 4 字节对齐，末尾不足补零）
        // -------------------------------------------------------------------
        pay_byte_off = 0;
        for (int pd = 0; pd < payload_dws; pd++) begin
            // 从 payload 字节数组中组合一个 DW（小端字节序）
            pay_dw = '0;
            for (int b = 0; b < 4; b++) begin
                if (pay_byte_off < payload_bytes) begin
                    pay_dw[b*8 +: 8] = payload[pay_byte_off];
                    pay_byte_off++;
                end
                // 超出 payload 范围的字节已由 pay_dw='0 初始化为 0
            end

            cur_beat = set_beat_dw(cur_beat, dw_pos, pay_dw);
            cur_keep[dw_pos] = 1'b1;
            dw_pos++;

            // beat 填满则 flush
            if (dw_pos >= beat_dws) begin
                beats.push_back(cur_beat);
                keeps.push_back(cur_keep);
                lasts.push_back(1'b0);
                cur_beat = '0;
                cur_keep = '0;
                dw_pos   = 0;
            end
        end

        // -------------------------------------------------------------------
        // 阶段 3：flush 最后一个未满的 beat
        // dw_pos > 0 表示当前缓冲有未提交的有效 DW
        // -------------------------------------------------------------------
        if (dw_pos > 0) begin
            beats.push_back(cur_beat);
            keeps.push_back(cur_keep);
            lasts.push_back(1'b0);
        end

        // -------------------------------------------------------------------
        // 修正最后一个 beat 的 tlast=1
        // -------------------------------------------------------------------
        if (beats.size() > 0)
            lasts[beats.size() - 1] = 1'b1;

    endfunction : pack_single_tlp

    //=========================================================================
    // unpack_single_tlp: 从 AXI-Stream beat 序列提取 descriptor + payload
    //=========================================================================
    //
    // 反向操作：从 tdata/tkeep 队列中还原描述符和 payload 字节数组：
    //   - 从 beat 0 起，按 tkeep 有效的 DW 顺序先提取 desc_dws 个描述符 DW
    //   - 剩余所有 tkeep=1 的 DW 拆解为字节追加到 payload
    //
    // 注意：unpack 后 payload 末尾可能含对齐填充字节（0），
    //       调用方应根据 TLP length 字段裁剪至实际长度。
    //
    // 参数：
    //   beats      - 输入：tdata 队列
    //   keeps      - 输入：tkeep 队列（每位对应一个 DW）
    //   channel    - 通道类型，决定描述符 DW 数量
    //   descriptor - 输出：128 位描述符（RC/CC 高 32 位补零）
    //   payload    - 输出：payload 字节队列
    //
    function void unpack_single_tlp(
        input  bit [511:0]       beats[$],
        input  bit [15:0]        keeps[$],
        input  xilinx_channel_e  channel,
        output bit [127:0]       descriptor,
        output bit [7:0]         payload[$]
    );
        int         beat_dws;           // 每个 beat 包含的 DW 数量
        int         desc_dws;           // 描述符占用的 DW 数
        int         desc_dws_collected; // 已提取的描述符 DW 计数
        int         num_beats;          // beat 队列总数
        bit [511:0] cur_beat;           // 当前处理的 beat 数据
        bit [15:0]  cur_keep;           // 当前 beat 的 tkeep
        bit [31:0]  dw_val;             // 提取的 DW 值

        // 初始化输出
        descriptor = '0;
        payload.delete();

        // 计算基本参数
        beat_dws           = DATA_WIDTH / 32;
        desc_dws           = get_desc_dws(channel);
        desc_dws_collected = 0;
        num_beats          = beats.size();

        // -------------------------------------------------------------------
        // 逐 beat、逐 DW 处理
        // -------------------------------------------------------------------
        for (int bi = 0; bi < num_beats; bi++) begin
            cur_beat = beats[bi];
            cur_keep = keeps[bi];

            for (int dw_pos = 0; dw_pos < beat_dws; dw_pos++) begin
                // 跳过 tkeep=0 的无效 DW（不携带有效数据）
                if (!cur_keep[dw_pos]) continue;

                dw_val = get_beat_dw(cur_beat, dw_pos);

                if (desc_dws_collected < desc_dws) begin
                    // 仍在提取描述符：将 DW 写入描述符对应位置
                    descriptor = set_dw_in_desc(descriptor, desc_dws_collected, dw_val);
                    desc_dws_collected++;
                end else begin
                    // 描述符已完整：后续有效 DW 均为 payload
                    // 将 DW 拆解为 4 个字节（小端序）追加到 payload
                    for (int b = 0; b < 4; b++)
                        payload.push_back(dw_val[b*8 +: 8]);
                end
            end
        end

    endfunction : unpack_single_tlp

    //=========================================================================
    // calc_eop_offset: 计算最后一个 beat 中 TLP 结束的 DW 偏移
    //=========================================================================
    //
    // 当 straddle_enable=1 时，tuser 中 eop_offset/eof_offset 字段指示
    // TLP 在最后一个 beat 中结束于哪个 DW 位置。
    //
    // 返回值：最后一个 beat 中最高有效 DW 的索引（从 0 开始计数）。
    // 256-bit beat 有 8 个 DW (0~7, 3 位足够)；512-bit beat 有 16 个 DW (0~15)，
    // 需 4 位 —— 故返回 [3:0] (对应 PG213 512 的 is_eop*_ptr[3:0])。
    //
    // 参数：
    //   last_keep - 最后一个 beat 的 tkeep（per-DW 掩码）
    //
    function bit [3:0] calc_eop_offset(bit [15:0] last_keep);
        int beat_dws;
        int last_valid_dw;

        beat_dws      = DATA_WIDTH / 32;
        last_valid_dw = 0;

        // 找到最后一个 tkeep=1 的 DW 位置
        for (int i = 0; i < beat_dws; i++) begin
            if (last_keep[i])
                last_valid_dw = i;
        end

        return last_valid_dw[3:0];
    endfunction : calc_eop_offset

endclass : xilinx_straddle_engine
