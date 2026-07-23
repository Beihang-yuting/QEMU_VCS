//=============================================================================
// Xilinx PCIe TL-Layer BFM - 描述符编解码器
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 本文件提供四个通道的描述符与 pcie_tl_tlp 对象之间的相互转换：
//   RQ (Requester Request)  : 128 位描述符，RC 侧发送请求时使用
//   RC (Requester Completion): 96 位描述符，RC 侧接收完成时使用
//   CQ (Completer Request)  : 128 位描述符，EP 侧接收请求时使用
//   CC (Completer Completion): 96 位描述符，EP 侧发送完成时使用
//
// 所有函数均为静态函数，通过类名直接调用，无需实例化。
// 注意：addr/first_be/last_be 字段来自 pcie_tl_mem_tlp 子类；
//       lower_addr/byte_count/completer_id/cpl_status 字段来自 pcie_tl_cpl_tlp 子类。
//=============================================================================

class xilinx_desc_codec;

    //=========================================================================
    // -------------------------------------------------------------------------
    // 辅助函数：TLP 种类与 Xilinx req_type 枚举之间的相互转换
    // -------------------------------------------------------------------------

    // kind_to_req_type: 将 tlp_kind_e 映射为 Xilinx PG213 req_type 编码
    // 参考 PG213 Table 2-22，仅支持 RQ/CQ 通道使用的请求类型
    static function xilinx_req_type_e kind_to_req_type(tlp_kind_e kind);
        case (kind)
            TLP_MEM_RD:           return XILINX_REQ_MRD;       // 内存读请求
            TLP_MEM_RD_LK:        return XILINX_REQ_MRD_LK;    // 内存读锁定请求
            TLP_MEM_WR:           return XILINX_REQ_MWR;       // 内存写请求
            TLP_IO_RD:            return XILINX_REQ_IORD;      // IO 读请求
            TLP_IO_WR:            return XILINX_REQ_IOWR;      // IO 写请求
            TLP_ATOMIC_FETCHADD:  return XILINX_REQ_FETCH_ADD; // 原子 FetchAdd
            TLP_ATOMIC_SWAP:      return XILINX_REQ_SWAP;      // 原子 Swap
            TLP_ATOMIC_CAS:       return XILINX_REQ_CAS;       // 原子 CAS
            TLP_CFG_RD0:          return XILINX_REQ_CFGRD0;    // Type0 配置读
            TLP_CFG_WR0:          return XILINX_REQ_CFGWR0;    // Type0 配置写
            TLP_CFG_RD1:          return XILINX_REQ_CFGRD1;    // Type1 配置读
            TLP_CFG_WR1:          return XILINX_REQ_CFGWR1;    // Type1 配置写
            default: begin
                `uvm_error("XILINX_CODEC",
                    $sformatf("kind_to_req_type: 不支持的 TLP 种类 %s", kind.name()))
                return XILINX_REQ_MRD;
            end
        endcase
    endfunction : kind_to_req_type

    // req_type_to_kind: 将 Xilinx req_type 编码映射回 tlp_kind_e
    // has_data 参数保留供未来扩展使用（Xilinx 已用独立编码区分读/写）
    static function tlp_kind_e req_type_to_kind(xilinx_req_type_e req_type, bit has_data);
        case (req_type)
            XILINX_REQ_MRD:       return TLP_MEM_RD;           // 内存读
            XILINX_REQ_MWR:       return TLP_MEM_WR;           // 内存写
            XILINX_REQ_IORD:      return TLP_IO_RD;            // IO 读
            XILINX_REQ_IOWR:      return TLP_IO_WR;            // IO 写
            XILINX_REQ_MRD_LK:    return TLP_MEM_RD_LK;       // 内存读锁定
            XILINX_REQ_FETCH_ADD: return TLP_ATOMIC_FETCHADD;  // 原子 FetchAdd
            XILINX_REQ_SWAP:      return TLP_ATOMIC_SWAP;      // 原子 Swap
            XILINX_REQ_CAS:       return TLP_ATOMIC_CAS;       // 原子 CAS
            XILINX_REQ_CFGRD0:    return TLP_CFG_RD0;          // Type0 配置读
            XILINX_REQ_CFGWR0:    return TLP_CFG_WR0;          // Type0 配置写
            XILINX_REQ_CFGRD1:    return TLP_CFG_RD1;          // Type1 配置读
            XILINX_REQ_CFGWR1:    return TLP_CFG_WR1;          // Type1 配置写
            default: begin
                `uvm_error("XILINX_CODEC",
                    $sformatf("req_type_to_kind: 未知 req_type 0x%0h", req_type))
                return TLP_MEM_RD;
            end
        endcase
    endfunction : req_type_to_kind

    // encode_error_code: 将 PCIe cpl_status[2:0] 编码为描述符中的 error_code 字段
    // PG213 RC/CC 描述符 [11:9] 的 error_code 与 PCIe Spec cpl_status 编码相同
    static function bit [2:0] encode_error_code(bit [2:0] cpl_status);
        // PG213 error_code 编码与 PCIe cpl_status 一致，直接透传
        // SC=3'b000, UR=3'b001, CRS=3'b010, CA=3'b100
        return cpl_status;
    endfunction : encode_error_code

    // get_desc_bits: 根据通道类型返回对应描述符的位宽
    // RQ/CQ 使用 128 位描述符；RC/CC 使用 96 位描述符
    static function int get_desc_bits(xilinx_channel_e channel);
        case (channel)
            XILINX_CH_RQ: return 128;   // Requester Request 通道：128 位
            XILINX_CH_CQ: return 128;   // Completer Request 通道：128 位
            XILINX_CH_RC: return 96;    // Requester Completion 通道：96 位
            XILINX_CH_CC: return 96;    // Completer Completion 通道：96 位
            default: begin
                `uvm_error("XILINX_CODEC",
                    $sformatf("get_desc_bits: 未知通道 %s", channel.name()))
                return 128;
            end
        endcase
    endfunction : get_desc_bits

    //=========================================================================
    // -------------------------------------------------------------------------
    // Config-TLP 辅助：CfgRd0/CfgWr0/CfgRd1/CfgWr1 走 RQ(发) / CQ(收) 通道，
    // 复用 128 位请求描述符家族。配置请求不携带 BAR 定位信息，故 RQ 与 CQ 的
    // 配置描述符布局完全相同，由下面的 encode_cfg_desc/decode_cfg_desc 共享。
    //
    // 配置请求描述符字段放置（已按 PG213 config RQ 描述符逐位校准）：
    //   [7:2]     reg_num[5:0]      寄存器号低 6 位
    //   [11:8]    ext_reg[3:0]      扩展寄存器号（合起来 desc[11:2]=reg_num[9:0]，DW 对齐）
    //   [119:104] completer_id[15:0] 目标 BDF（by-ID 路由，配置/消息专用字段）
    //   [120]     req_id_enable     恒 0
    //   [123:121] tc / [126:124] attr / [127] force_ecrc(td)
    // 其余 length/req_type/ep_bit/requester_id/tag 与内存 RQ 同位置。
    // first_be/last_be 不在描述符，经 RQ/CQ tuser 携带（PG213）。
    // encode 与 decode 对称，BFM 内部往返自洽，且线格式匹配真实 PG213 IP。
    // -------------------------------------------------------------------------

    // is_cfg_kind: 判断 tlp_kind_e 是否为配置请求种类
    static function bit is_cfg_kind(tlp_kind_e kind);
        return (kind == TLP_CFG_RD0 || kind == TLP_CFG_WR0 ||
                kind == TLP_CFG_RD1 || kind == TLP_CFG_WR1);
    endfunction : is_cfg_kind

    // is_cfg_req_type: 判断 req_type 编码是否为配置请求
    static function bit is_cfg_req_type(xilinx_req_type_e rt);
        return (rt == XILINX_REQ_CFGRD0 || rt == XILINX_REQ_CFGWR0 ||
                rt == XILINX_REQ_CFGRD1 || rt == XILINX_REQ_CFGWR1);
    endfunction : is_cfg_req_type

    // encode_cfg_desc: 将配置请求 TLP 编码为 128 位请求描述符（RQ/CQ 共用）
    static function bit [127:0] encode_cfg_desc(pcie_tl_tlp tlp);
        bit [127:0]      desc;
        pcie_tl_cfg_tlp  cfg;

        desc = '0;
        if (!$cast(cfg, tlp)) begin
            `uvm_error("XILINX_CODEC",
                "encode_cfg_desc: tlp 无法转型为 pcie_tl_cfg_tlp")
            return '0;
        end

        // [11:2]    reg_num[9:0]：DW 寄存器号（[7:2]=reg[5:0]，[11:8]=ext_reg[3:0]）
        desc[11:2]    = cfg.reg_num;
        // [74:64]   length：配置请求恒为 1 DW
        desc[74:64]   = tlp.length;
        // [78:75]   req_type：配置请求类型编码
        desc[78:75]   = kind_to_req_type(tlp.kind);
        // [79]      ep_bit：Poisoned 位
        desc[79]      = tlp.ep_bit;
        // [95:80]   requester_id：请求方 BDF
        desc[95:80]   = tlp.requester_id;
        // [103:96]  tag[7:0]：Tag 低 8 位（高 2 位经 tuser 携带）
        desc[103:96]  = tlp.tag[7:0];
        // [119:104] completer_id：目标 BDF（配置/消息 by-ID 路由）
        desc[119:104] = cfg.completer_id;
        // [120]     req_id_enable：恒 0
        desc[120]     = 1'b0;
        // [123:121] tc：流量类别
        desc[123:121] = tlp.tc;
        // [126:124] attr：属性字段
        desc[126:124] = tlp.attr;
        // [127]     force_ecrc（td）：TLP Digest / ECRC 标志
        desc[127]     = tlp.td;
        // 注：first_be 不在描述符，经 RQ/CQ tuser 携带（PG213）

        return desc;
    endfunction : encode_cfg_desc

    // decode_cfg_desc: 将 128 位配置请求描述符解码为 pcie_tl_cfg_tlp（RQ/CQ 共用）
    static function pcie_tl_tlp decode_cfg_desc(bit [127:0] desc, bit [7:0] payload[]);
        pcie_tl_cfg_tlp   cfg;
        xilinx_req_type_e req_type;
        bit               has_data;

        cfg = pcie_tl_cfg_tlp::type_id::create("cfg_decoded");

        req_type    = xilinx_req_type_e'(desc[78:75]);
        has_data    = (payload.size() > 0);
        cfg.kind    = req_type_to_kind(req_type, has_data);

        // type_f：Type0 / Type1 配置请求
        if (cfg.kind == TLP_CFG_RD1 || cfg.kind == TLP_CFG_WR1)
            cfg.type_f = TLP_TYPE_CFG_RD1;
        else
            cfg.type_f = TLP_TYPE_CFG_RD0;

        // 配置请求 fmt 固定为 3DW；写带数据、读不带数据
        cfg.fmt = has_data ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;

        // 字段还原（与 encode_cfg_desc 对称）
        cfg.reg_num      = desc[11:2];
        cfg.length       = desc[74:64];
        cfg.ep_bit       = desc[79];
        cfg.requester_id = desc[95:80];
        cfg.tag          = {2'b00, desc[103:96]};
        cfg.completer_id = desc[119:104];
        cfg.attr         = desc[126:124];
        cfg.tc           = desc[123:121];
        cfg.td           = desc[127];
        // first_be 经 tuser 携带（adapter apply_tuser_be 填充）；描述符不含 BE

        // 复制 payload 字节数组（CfgWr 携带 1 DW）
        cfg.payload = new[payload.size()];
        foreach (payload[i])
            cfg.payload[i] = payload[i];

        return cfg;
    endfunction : decode_cfg_desc

    //=========================================================================
    // -------------------------------------------------------------------------
    // RQ 通道编解码：Requester Request 描述符（128 位）
    // 参考 PG213 Table 2-22 (RQ Descriptor)
    // 仅适用于内存/IO/原子操作请求类型
    // -------------------------------------------------------------------------

    // encode_rq: 将请求 TLP 编码为 128 位 RQ 描述符
    // tlp 应为 pcie_tl_mem_tlp、pcie_tl_io_tlp 或 pcie_tl_atomic_tlp 的实例
    static function bit [127:0] encode_rq(pcie_tl_tlp tlp);
        bit [127:0]        desc;
        pcie_tl_mem_tlp    mem_tlp;
        pcie_tl_io_tlp     io_tlp;
        pcie_tl_atomic_tlp atomic_tlp;
        bit [63:0]  addr;
        bit [3:0]   first_be;
        bit [3:0]   last_be;

        // 初始化描述符为全零
        desc = '0;

        // 配置请求：走专用配置描述符布局（不携带地址）
        if (is_cfg_kind(tlp.kind))
            return encode_cfg_desc(tlp);

        // 根据 TLP 子类类型提取地址和字节使能字段
        if ($cast(mem_tlp, tlp)) begin
            // pcie_tl_mem_tlp：提供 64 位地址与首/末字节使能
            addr     = mem_tlp.addr;
            first_be = mem_tlp.first_be;
            last_be  = mem_tlp.last_be;
        end else if ($cast(io_tlp, tlp)) begin
            // pcie_tl_io_tlp：地址为 32 位，末字节使能固定为 0
            addr     = {32'h0, io_tlp.addr};
            first_be = io_tlp.first_be;
            last_be  = 4'h0;
        end else if ($cast(atomic_tlp, tlp)) begin
            // pcie_tl_atomic_tlp：仅提供地址，无字节使能
            addr     = atomic_tlp.addr;
            first_be = 4'h0;
            last_be  = 4'h0;
        end else begin
            // 基类 TLP：地址和 BE 均为 0（异常情况，打印警告）
            `uvm_warning("XILINX_CODEC", "encode_rq: 无法识别 TLP 子类型，addr/BE 置零")
            addr     = '0;
            first_be = 4'h0;
            last_be  = 4'h0;
        end

        // [1:0]     addr_type：地址类型，默认为未翻译地址（XILINX_ADDR_UNTRANSLATED）
        desc[1:0]     = 2'b00;

        // [63:2]    addr[63:2]：64 位地址高 62 位（低 2 位由 addr_type 占用，保证 DW 对齐）
        desc[63:2]    = addr[63:2];

        // [74:64]   length：TLP 数据长度（单位 DW，0 表示 1024 DW）
        desc[74:64]   = tlp.length;

        // [78:75]   req_type：请求类型编码，由 kind_to_req_type 转换
        desc[78:75]   = kind_to_req_type(tlp.kind);

        // [79]      poisoned（ep_bit）：TLP 毒化位
        desc[79]      = tlp.ep_bit;

        // [95:80]   requester_id：请求方 BDF（Bus[15:8] / Device[7:3] / Func[2:0]）
        desc[95:80]   = tlp.requester_id;

        // [103:96]  tag[7:0]：TLP Tag 低 8 位（扩展 Tag[9:8] 通过 tuser 携带）
        desc[103:96]  = tlp.tag[7:0];

        // [119:104] completer_id：内存/IO/原子请求恒 0（仅配置/消息 by-ID 路由使用）
        desc[119:104] = 16'h0;

        // [120]     requester_id_enable：BFM 显式提供 requester_id，恒 0
        desc[120]     = 1'b0;

        // [123:121] tc[2:0]：流量类别（Traffic Class）
        desc[123:121] = tlp.tc;

        // [126:124] attr[2:0]：属性字段 [0]=RO, [1]=IDO, [2]=NS
        desc[126:124] = tlp.attr;

        // [127]     force_ecrc（td）：TLP Digest / ECRC 标志
        desc[127]     = tlp.td;

        // 注：first_be/last_be 不在 RQ 描述符（PG213），仅经 s_axis_rq_tuser 携带；
        //     上文提取的 first_be/last_be 在此路径不写入描述符（tuser codec 负责）。

        return desc;
    endfunction : encode_rq

    // decode_rq: 将 128 位 RQ 描述符解码为 pcie_tl_mem_tlp 对象
    // payload 参数用于判断 has_data，从而正确设置 fmt 字段
    static function pcie_tl_tlp decode_rq(bit [127:0] desc, bit [7:0] payload[]);
        pcie_tl_mem_tlp   tlp;
        xilinx_req_type_e req_type;
        bit               has_data;
        bit               is_64bit;

        // 配置请求：走专用配置解码，返回 pcie_tl_cfg_tlp
        if (is_cfg_req_type(xilinx_req_type_e'(desc[78:75])))
            return decode_cfg_desc(desc, payload);

        // 通过 UVM 工厂创建 pcie_tl_mem_tlp 对象（支持 factory override）
        tlp = pcie_tl_mem_tlp::type_id::create("rq_decoded");

        // 提取 req_type[3:0] 并映射为 tlp_kind_e
        req_type  = xilinx_req_type_e'(desc[78:75]);
        has_data  = (payload.size() > 0);
        tlp.kind  = req_type_to_kind(req_type, has_data);

        // [63:2] addr[63:2]：还原 64 位地址，低 2 位补零保证 DW 对齐
        tlp.addr     = {desc[63:2], 2'b00};

        // 根据高 32 位是否非零判断 64 位地址
        is_64bit     = (tlp.addr[63:32] != 32'h0);
        tlp.is_64bit = is_64bit;

        // 根据地址宽度与 has_data 设置 fmt 字段
        if (is_64bit)
            tlp.fmt = has_data ? FMT_4DW_WITH_DATA : FMT_4DW_NO_DATA;
        else
            tlp.fmt = has_data ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;

        // [74:64]   length：DW 长度
        tlp.length       = desc[74:64];

        // [79]      ep_bit：Poisoned 位
        tlp.ep_bit       = desc[79];

        // [95:80]   requester_id：请求方 BDF
        tlp.requester_id = desc[95:80];

        // [103:96]  tag[7:0]：Tag 低 8 位（高 2 位默认 0，由 tuser 扩展）
        tlp.tag          = {2'b00, desc[103:96]};

        // first_be/last_be 不在 RQ 描述符（PG213）；由 adapter apply_tuser_be 从 tuser 填充。
        // 此处保持默认 0，避免从 Completer ID 区误读。

        // [123:121] tc：流量类别
        tlp.tc           = desc[123:121];

        // [126:124] attr：属性字段
        tlp.attr         = desc[126:124];

        // [127]     force_ecrc（td）：TLP Digest 标志
        tlp.td           = desc[127];

        // 复制 payload 字节数组
        tlp.payload = new[payload.size()];
        foreach (payload[i])
            tlp.payload[i] = payload[i];

        return tlp;
    endfunction : decode_rq

    //=========================================================================
    // -------------------------------------------------------------------------
    // RC 通道编解码：Requester Completion 描述符（96 位）
    // RC 侧接收来自 EP 的完成包，参考 PG213 Table 2-26 (RC Descriptor)
    // -------------------------------------------------------------------------

    // encode_rc: 将完成 TLP 编码为 96 位 RC 描述符
    // tlp 必须可以 $cast 为 pcie_tl_cpl_tlp（提供 lower_addr/byte_count 等完成字段）
    static function bit [95:0] encode_rc(pcie_tl_tlp tlp);
        bit [95:0]       desc;
        pcie_tl_cpl_tlp  cpl;
        bit              locked;

        // 初始化描述符为全零
        desc = '0;

        // 转型为完成 TLP 子类以访问完成专有字段
        if (!$cast(cpl, tlp)) begin
            `uvm_error("XILINX_CODEC", "encode_rc: tlp 无法转型为 pcie_tl_cpl_tlp")
            return '0;
        end

        // #3 守卫：RC/CC 完成描述符按 PG213 Table 2-26/2-27 仅携带 tag[7:0]，
        // 无 tag[9:8] 位置。当前 max_outstanding=256 已把 tag 压在 8 位内（恒 0xFF 以下），
        // 截断为无操作。若有人调大 max_outstanding 启用扩展 tag(>0xFF)，此处立即报错，
        // 避免完成路径静默丢失高 2 位导致 scoreboard 失配。
        if (tlp.tag > 10'h0FF) begin
            `uvm_error("XILINX_CODEC",
                $sformatf("encode_rc: tag=0x%03h 超过 8 位，completion 描述符无法携带 tag[9:8]。请限制 max_outstanding<=256，或扩展完成路径以传递 tag[9:8]",
                    tlp.tag))
        end

        // 判断是否为锁定完成（Locked Completion：CPL_LK 或 CPLD_LK）
        locked = (tlp.kind == TLP_CPL_LK || tlp.kind == TLP_CPLD_LK);

        // [11:0]    lower_addr：完成首字节地址低 12 位（模型 lower_addr 仅 7 位，高位补 0）
        desc[11:0]  = {5'h0, cpl.lower_addr};

        // [15:12]   error_code[3:0]：由 cpl_status 转换的错误码（cpl_status 3 位，[15] 恒 0）
        desc[15:12] = {1'b0, encode_error_code(cpl_status_e'(cpl.cpl_status))};

        // [28:16]   byte_count[12:0]：剩余完成字节数（模型 byte_count 12 位，高位补 0）
        desc[28:16] = {1'b0, cpl.byte_count};

        // [29]      locked：是否为锁定完成（1=CPL_LK 或 CPLD_LK）
        desc[29]    = locked;

        // [30]      request_completed（映射 bcm）：请求最后一个完成置 1
        desc[30]    = cpl.bcm;

        // [31]      保留（Reserved），保持 0
        desc[31]    = 1'b0;

        // [42:32]   length：DW 长度（11 位，0 表示 1024 DW）
        desc[42:32] = tlp.length;

        // [45:43]   cpl_status：PCIe 完成状态码（SC/UR/CRS/CA）
        desc[45:43] = cpl_status_e'(cpl.cpl_status);

        // [46]      ep_bit：Poisoned 位
        desc[46]    = tlp.ep_bit;

        // [47]      保留（Reserved），保持 0
        desc[47]    = 1'b0;

        // [63:48]   requester_id：原始请求方 BDF
        desc[63:48] = tlp.requester_id;

        // [71:64]   tag[7:0]：对应原始请求的 Tag 低 8 位
        desc[71:64] = tlp.tag[7:0];

        // [87:72]   completer_id：完成方 BDF
        desc[87:72] = cpl.completer_id;

        // [88]      保留（Reserved），保持 0
        desc[88]    = 1'b0;

        // [91:89]   tc：流量类别（PG213 Table 2-26）
        desc[91:89] = tlp.tc;

        // [94:92]   attr：属性字段
        desc[94:92] = tlp.attr;

        // [95]      保留（Reserved），保持 0
        desc[95]    = 1'b0;

        return desc;
    endfunction : encode_rc

    // decode_rc: 将 96 位 RC 描述符解码为 pcie_tl_cpl_tlp 对象
    // payload 参数用于判断是否为 CPLD（带数据完成）
    static function pcie_tl_tlp decode_rc(bit [95:0] desc, bit [7:0] payload[]);
        pcie_tl_cpl_tlp  cpl;
        bit              locked;
        bit              has_data;

        // 通过 UVM 工厂创建 pcie_tl_cpl_tlp 对象（支持 factory override）
        cpl = pcie_tl_cpl_tlp::type_id::create("rc_decoded");

        // 根据 payload 是否存在与 locked 位共同确定 TLP 种类
        has_data = (payload.size() > 0);
        locked   = desc[29];

        if (locked)
            cpl.kind = has_data ? TLP_CPLD_LK : TLP_CPL_LK;
        else
            cpl.kind = has_data ? TLP_CPLD    : TLP_CPL;

        // 完成 TLP 的 fmt 固定为 3DW 格式
        cpl.fmt = has_data ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;

        // [6:0]     lower_addr：首字节地址低 7 位（模型 lower_addr 为 7 位）
        cpl.lower_addr   = desc[6:0];

        // [28:16]   byte_count[12:0]：剩余字节数（取低 12 位对齐模型宽度）
        cpl.byte_count   = desc[27:16];

        // [30]      request_completed → bcm
        cpl.bcm          = desc[30];

        // [42:32]   length：DW 长度
        cpl.length       = desc[42:32];

        // [45:43]   cpl_status：完成状态码
        cpl.cpl_status   = cpl_status_e'(desc[45:43]);

        // [46]      ep_bit：Poisoned 位
        cpl.ep_bit       = desc[46];

        // [63:48]   requester_id：原始请求方 BDF
        cpl.requester_id = desc[63:48];

        // [71:64]   tag[7:0]：Tag 低 8 位（高 2 位补零）
        cpl.tag          = {2'b00, desc[71:64]};

        // [87:72]   completer_id：完成方 BDF
        cpl.completer_id = desc[87:72];

        // [91:89]   tc：流量类别（PG213 Table 2-26）
        cpl.tc           = desc[91:89];

        // [94:92]   attr：属性字段
        cpl.attr         = desc[94:92];

        // 复制 payload 字节数组
        cpl.payload = new[payload.size()];
        foreach (payload[i])
            cpl.payload[i] = payload[i];

        return cpl;
    endfunction : decode_rc

    //=========================================================================
    // -------------------------------------------------------------------------
    // CQ 通道编解码：Completer Request 描述符（128 位）
    // EP 侧接收来自 RC 的请求，格式基于 RQ 但额外携带 BAR 定位信息
    // 参考 PG213 Table 2-23 (CQ Descriptor)
    // -------------------------------------------------------------------------

    // encode_cq: 将请求 TLP 编码为 128 位 CQ 描述符
    // 相比 RQ，CQ 在高位字段中用 target_func/bar_id/bar_aperture 替换了 last_be/first_be
    // 参数：
    //   tlp          - 待编码的请求 TLP 对象
    //   bar_id       - 命中的 BAR 编号（[2:0]，0-5）
    //   bar_aperture - BAR 孔径大小编码（[5:0]，等于 log2(BAR_size_bytes)-12）
    //   target_func  - 目标功能编号（[7:0]，SR-IOV 场景下的 PF/VF 功能号）
    static function bit [127:0] encode_cq(
        pcie_tl_tlp tlp,
        bit [2:0]   bar_id       = 3'h0,
        bit [5:0]   bar_aperture = 6'h0,
        bit [7:0]   target_func  = 8'h0
    );
        bit [127:0]        desc;
        pcie_tl_mem_tlp    mem_tlp;
        pcie_tl_io_tlp     io_tlp;
        pcie_tl_atomic_tlp atomic_tlp;
        bit [63:0]  addr;
        bit [3:0]   first_be;
        bit [3:0]   last_be;

        // 初始化描述符为全零
        desc = '0;

        // 配置请求：走专用配置描述符布局（与 RQ 共用，不携带 BAR 信息）
        if (is_cfg_kind(tlp.kind))
            return encode_cfg_desc(tlp);

        // 根据 TLP 子类提取地址和字节使能（与 RQ 相同逻辑）
        if ($cast(mem_tlp, tlp)) begin
            addr     = mem_tlp.addr;
            first_be = mem_tlp.first_be;
            last_be  = mem_tlp.last_be;
        end else if ($cast(io_tlp, tlp)) begin
            addr     = {32'h0, io_tlp.addr};
            first_be = io_tlp.first_be;
            last_be  = 4'h0;
        end else if ($cast(atomic_tlp, tlp)) begin
            addr     = atomic_tlp.addr;
            first_be = 4'h0;
            last_be  = 4'h0;
        end else begin
            `uvm_warning("XILINX_CODEC", "encode_cq: 无法识别 TLP 子类型，addr/BE 置零")
            addr     = '0;
            first_be = 4'h0;
            last_be  = 4'h0;
        end

        // [1:0]     addr_type：地址类型，默认未翻译
        desc[1:0]     = 2'b00;

        // [63:2]    addr[63:2]：64 位地址高 62 位
        desc[63:2]    = addr[63:2];

        // [74:64]   length：DW 长度
        desc[74:64]   = tlp.length;

        // [78:75]   req_type：请求类型
        desc[78:75]   = kind_to_req_type(tlp.kind);

        // [79]      ep_bit：Poisoned 位
        desc[79]      = tlp.ep_bit;

        // [95:80]   requester_id：请求方 BDF
        desc[95:80]   = tlp.requester_id;

        // [103:96]  tag[7:0]：TLP Tag 低 8 位
        desc[103:96]  = tlp.tag[7:0];

        // [111:104] target_func[7:0]：目标功能编号（CQ 特有，PG213 Table 2-23）
        desc[111:104] = target_func;

        // [114:112] bar_id[2:0]：命中的 BAR 编号（CQ 特有）
        desc[114:112] = bar_id;

        // [120:115] bar_aperture[5:0]：BAR 孔径大小编码（CQ 特有）
        desc[120:115] = bar_aperture;

        // [123:121] tc[2:0]：流量类别
        desc[123:121] = tlp.tc;

        // [126:124] attr[2:0]：属性字段 [0]=RO, [1]=IDO, [2]=NS
        desc[126:124] = tlp.attr;

        // [127]     PG213 保留位；BFM 透传 td 便于内部往返，真实 IP 忽略
        desc[127]     = tlp.td;

        // 注：first_be/last_be 不在 CQ 描述符（PG213），仅经 m_axis_cq_tuser 携带。

        return desc;
    endfunction : encode_cq

    // decode_cq: 将 128 位 CQ 描述符解码为 pcie_tl_mem_tlp 对象
    static function pcie_tl_tlp decode_cq(bit [127:0] desc, bit [7:0] payload[]);
        pcie_tl_mem_tlp   tlp;
        xilinx_req_type_e req_type;
        bit               has_data;
        bit               is_64bit;

        // 配置请求：走专用配置解码，返回 pcie_tl_cfg_tlp
        if (is_cfg_req_type(xilinx_req_type_e'(desc[78:75])))
            return decode_cfg_desc(desc, payload);

        // 通过 UVM 工厂创建 pcie_tl_mem_tlp 对象（支持 factory override）
        tlp = pcie_tl_mem_tlp::type_id::create("cq_decoded");

        // 提取 req_type 并转换为 tlp_kind_e
        req_type  = xilinx_req_type_e'(desc[78:75]);
        has_data  = (payload.size() > 0);
        tlp.kind  = req_type_to_kind(req_type, has_data);

        // [63:2]    addr[63:2]：还原 64 位地址
        tlp.addr     = {desc[63:2], 2'b00};
        is_64bit     = (tlp.addr[63:32] != 32'h0);
        tlp.is_64bit = is_64bit;

        // 根据地址宽度与 has_data 设置 fmt
        if (is_64bit)
            tlp.fmt = has_data ? FMT_4DW_WITH_DATA : FMT_4DW_NO_DATA;
        else
            tlp.fmt = has_data ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;

        // [74:64]   length：DW 长度
        tlp.length       = desc[74:64];

        // [79]      ep_bit：Poisoned 位
        tlp.ep_bit       = desc[79];

        // [95:80]   requester_id：请求方 BDF
        tlp.requester_id = desc[95:80];

        // [103:96]  tag[7:0]：Tag 低 8 位
        tlp.tag          = {2'b00, desc[103:96]};

        // [123:121] tc：流量类别（PG213 Table 2-23）
        tlp.tc           = desc[123:121];

        // [126:124] attr：属性字段
        tlp.attr         = desc[126:124];

        // [127]     PG213 保留位；BFM 透传 td
        tlp.td           = desc[127];
        // first_be/last_be 经 tuser 携带（adapter apply_tuser_be 填充）；描述符不含 BE

        // 复制 payload 字节数组
        tlp.payload = new[payload.size()];
        foreach (payload[i])
            tlp.payload[i] = payload[i];

        return tlp;
    endfunction : decode_cq

    // get_cq_bar_id: 从 128 位 CQ 描述符中提取命中的 BAR 编号
    // 位于描述符 [114:112]（3 位，PG213 Table 2-23）
    static function bit [2:0] get_cq_bar_id(bit [127:0] desc);
        // [114:112] bar_id：目标 BAR 编号（0-5，或 6/7 用于 ROM/扩展 ROM）
        return desc[114:112];
    endfunction : get_cq_bar_id

    // get_cq_bar_aperture: 从 128 位 CQ 描述符中提取 BAR 孔径大小编码
    // 位于描述符 [120:115]（6 位，PG213 Table 2-23）
    static function bit [5:0] get_cq_bar_aperture(bit [127:0] desc);
        // [120:115] bar_aperture：BAR 孔径编码值，等于 log2(BAR_size_bytes)-12
        return desc[120:115];
    endfunction : get_cq_bar_aperture

    // get_cq_target_func: 从 128 位 CQ 描述符中提取目标功能编号
    // 位于描述符 [111:104]（8 位，PG213 Table 2-23）
    static function bit [7:0] get_cq_target_func(bit [127:0] desc);
        // [111:104] target_func[7:0]：目标功能编号
        return desc[111:104];
    endfunction : get_cq_target_func

    //=========================================================================
    // -------------------------------------------------------------------------
    // CC 通道编解码：Completer Completion 描述符（96 位）
    // EP 侧发送完成响应给 RC，格式与 RC 通道完全相同（均为 96 位描述符）
    // 参考 PG213 Table 2-27 (CC Descriptor)
    // -------------------------------------------------------------------------

    // encode_cc: 将完成 TLP 编码为 96 位 CC 描述符（PG213 Table 2-27）
    // CC 与 RC 描述符不同：CC 用 AT[9:8]（无 error_code）、completer_id 拆分为
    // func/dev[79:72]+bus[87:80]、[88]=completer_id_enable、[95]=force_ecrc。
    // 公共字段（byte_count/length/cpl_status/poison/requester_id/tag/completer_id/
    // tc/attr/locked）与 RC 同位，保证 CC↔RC 跨通道解码兼容。
    static function bit [95:0] encode_cc(pcie_tl_tlp tlp);
        bit [95:0]       desc;
        pcie_tl_cpl_tlp  cpl;
        bit              locked;

        desc = '0;
        if (!$cast(cpl, tlp)) begin
            `uvm_error("XILINX_CODEC", "encode_cc: tlp 无法转型为 pcie_tl_cpl_tlp")
            return '0;
        end

        // 完成 tag 仅 8 位（CC 描述符无 tag[9:8] 位置），扩展 tag 报错（同 encode_rc 守卫）
        if (tlp.tag > 10'h0FF) begin
            `uvm_error("XILINX_CODEC",
                $sformatf("encode_cc: tag=0x%03h 超过 8 位，CC 描述符无法携带 tag[9:8]", tlp.tag))
        end

        locked = (tlp.kind == TLP_CPL_LK || tlp.kind == TLP_CPLD_LK);

        // [6:0]     lower_addr：完成首字节地址低 7 位
        desc[6:0]   = cpl.lower_addr;
        // [9:8]     addr_type(AT)：模型无 AT 字段，置 0
        desc[9:8]   = 2'b00;
        // [28:16]   byte_count[12:0]：模型 byte_count 12 位，高位补 0
        desc[28:16] = {1'b0, cpl.byte_count};
        // [29]      locked：锁定完成
        desc[29]    = locked;
        // [30]      PG213 保留（RC 才是 request_completed）；CC 不携带 bcm
        // [42:32]   length：DW 长度
        desc[42:32] = tlp.length;
        // [45:43]   cpl_status：完成状态码
        desc[45:43] = cpl_status_e'(cpl.cpl_status);
        // [46]      ep_bit：Poisoned 位
        desc[46]    = tlp.ep_bit;
        // [63:48]   requester_id：原始请求方 BDF
        desc[63:48] = tlp.requester_id;
        // [71:64]   tag[7:0]
        desc[71:64] = tlp.tag[7:0];
        // [79:72]   completer_id[7:0]：目标 func/dev
        desc[79:72] = cpl.completer_id[7:0];
        // [87:80]   completer_id[15:8]：completer bus
        desc[87:80] = cpl.completer_id[15:8];
        // [88]      completer_id_enable：恒 0
        desc[88]    = 1'b0;
        // [91:89]   tc：流量类别
        desc[91:89] = tlp.tc;
        // [94:92]   attr：属性字段
        desc[94:92] = tlp.attr;
        // [95]      force_ecrc（td）
        desc[95]    = tlp.td;

        return desc;
    endfunction : encode_cc

    // decode_cc: 将 96 位 CC 描述符解码为 pcie_tl_cpl_tlp 对象（PG213 Table 2-27）
    static function pcie_tl_tlp decode_cc(bit [95:0] desc, bit [7:0] payload[]);
        pcie_tl_cpl_tlp  cpl;
        bit              locked;
        bit              has_data;

        cpl = pcie_tl_cpl_tlp::type_id::create("cc_decoded");

        has_data = (payload.size() > 0);
        locked   = desc[29];

        if (locked)
            cpl.kind = has_data ? TLP_CPLD_LK : TLP_CPL_LK;
        else
            cpl.kind = has_data ? TLP_CPLD    : TLP_CPL;

        cpl.fmt = has_data ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;

        // [6:0]     lower_addr
        cpl.lower_addr   = desc[6:0];
        // [28:16]   byte_count[12:0]（取低 12 位对齐模型宽度）
        cpl.byte_count   = desc[27:16];
        // [42:32]   length
        cpl.length       = desc[42:32];
        // [45:43]   cpl_status
        cpl.cpl_status   = cpl_status_e'(desc[45:43]);
        // [46]      ep_bit
        cpl.ep_bit       = desc[46];
        // [63:48]   requester_id
        cpl.requester_id = desc[63:48];
        // [71:64]   tag[7:0]（高 2 位补零）
        cpl.tag          = {2'b00, desc[71:64]};
        // [87:72]   completer_id（[79:72]=func/dev, [87:80]=bus）
        cpl.completer_id = desc[87:72];
        // [91:89]   tc
        cpl.tc           = desc[91:89];
        // [94:92]   attr
        cpl.attr         = desc[94:92];
        // [95]      force_ecrc（td）
        cpl.td           = desc[95];

        cpl.payload = new[payload.size()];
        foreach (payload[i])
            cpl.payload[i] = payload[i];

        return cpl;
    endfunction : decode_cc

    //=========================================================================
    // 扩展 tag 支持的 with_tag98 重载 (PG213: tag[9:8] 在 tuser 中携带)
    // RQ/CQ 通道使用; 与原 encode/decode 并存, 不破坏现有调用.
    //=========================================================================

    // RQ encode with tag[9:8] output (送到 tuser)
    static function bit [127:0] encode_rq_with_tag98(
        pcie_tl_tlp tlp,
        output bit [1:0] tag_9_8
    );
        tag_9_8 = tlp.tag[9:8];
        return encode_rq(tlp);
    endfunction : encode_rq_with_tag98

    // RQ decode reassembling tag[9:0] from desc[103:96] + tag_9_8
    static function pcie_tl_tlp decode_rq_with_tag98(
        bit [127:0] desc,
        bit [1:0]   tag_9_8,
        bit [7:0]   payload[]
    );
        pcie_tl_tlp t;
        t = decode_rq(desc, payload);
        if (t != null)
            t.tag = {tag_9_8, desc[103:96]};
        return t;
    endfunction : decode_rq_with_tag98

    // CQ encode with tag[9:8] output (送到 tuser)
    static function bit [127:0] encode_cq_with_tag98(
        pcie_tl_tlp tlp,
        output bit [1:0] tag_9_8
    );
        tag_9_8 = tlp.tag[9:8];
        return encode_cq(tlp);
    endfunction : encode_cq_with_tag98

    // CQ decode reassembling tag[9:0] from desc[103:96] + tag_9_8
    static function pcie_tl_tlp decode_cq_with_tag98(
        bit [127:0] desc,
        bit [1:0]   tag_9_8,
        bit [7:0]   payload[]
    );
        pcie_tl_tlp t;
        t = decode_cq(desc, payload);
        if (t != null)
            t.tag = {tag_9_8, desc[103:96]};
        return t;
    endfunction : decode_cq_with_tag98

endclass : xilinx_desc_codec
