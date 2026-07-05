//=============================================================================
// Xilinx PCIe TL-Layer BFM - TLP 通道路由器
// 基于 Xilinx PG213 PCIe IP 接口规范
//
// 本文件根据 BFM 角色（RC/EP）和 TLP 类别（请求/完成）决定：
//   - get_tx_channel: 发送方向应使用哪个 AXI-Stream 通道
//   - get_rx_channel: 接收方向预期从哪个 AXI-Stream 通道到达
//
// 通道与角色的映射关系（参考 PG213 图 1-1）：
//   RC 角色发送：COMPLETION -> RC 通道，其他 -> CQ 通道
//   RC 角色接收：COMPLETION -> CC 通道，其他 -> RQ 通道
//   EP 角色发送：COMPLETION -> CC 通道，其他 -> RQ 通道
//   EP 角色接收：COMPLETION -> RC 通道，其他 -> CQ 通道
//
// 注意：本类为普通 class，不继承 UVM 基类，需要实例化后使用。
//=============================================================================

class xilinx_pcie_channel_router;

    //=========================================================================
    // 成员变量
    //=========================================================================

    // BFM 角色：XILINX_PCIE_RC（根复合体）或 XILINX_PCIE_EP（端点）
    xilinx_pcie_role_e role;

    //=========================================================================
    // 构造函数
    //=========================================================================

    // new: 创建通道路由器实例，绑定 BFM 角色
    // 参数：
    //   role - BFM 角色（默认为 EP）
    function new(xilinx_pcie_role_e role = XILINX_PCIE_EP);
        this.role = role;
    endfunction : new

    //=========================================================================
    // get_tx_channel: 根据 TLP 类别确定发送通道
    //=========================================================================
    //
    // 根据当前角色和 TLP 的类别（完成包 vs 请求包），
    // 返回应将该 TLP 发送到的 AXI-Stream 通道。
    //
    // 映射逻辑：
    //   RC 角色：COMPLETION -> XILINX_CH_RC；其他 -> XILINX_CH_CQ
    //   EP 角色：COMPLETION -> XILINX_CH_CC；其他 -> XILINX_CH_RQ
    //
    // 参数：
    //   tlp - 待发送的 TLP 对象（通过 get_category() 获取类别）
    // 返回：目标通道枚举值
    //
    function xilinx_channel_e get_tx_channel(pcie_tl_tlp tlp);
        tlp_category_e category;
        category = tlp.get_category();

        case (role)
            XILINX_PCIE_RC: begin
                // RC 角色发送侧
                if (category == TLP_CAT_COMPLETION)
                    // 完成包经 RC 通道传输（RC 接收 EP 返回的完成）
                    return XILINX_CH_RC;
                else
                    // 请求包经 CQ 通道传输（RC 向 EP 发送请求）
                    return XILINX_CH_CQ;
            end

            XILINX_PCIE_EP: begin
                // EP 角色发送侧
                if (category == TLP_CAT_COMPLETION)
                    // 完成包经 CC 通道传输（EP 向 RC 发送完成）
                    return XILINX_CH_CC;
                else
                    // 请求包经 RQ 通道传输（EP 向 RC 发起请求）
                    return XILINX_CH_RQ;
            end

            default: begin
                $fatal(1, "[xilinx_pcie_channel_router] get_tx_channel: 未知角色 %0d", role);
                return XILINX_CH_RQ;
            end
        endcase
    endfunction : get_tx_channel

    //=========================================================================
    // get_rx_channel: 根据 TLP 类别确定接收通道
    //=========================================================================
    //
    // 根据当前角色和 TLP 的类别，返回该 TLP 预期到达的 AXI-Stream 通道。
    // 通常供 monitor / scoreboard 确定应从哪个通道读取数据。
    //
    // 映射逻辑：
    //   RC 角色：COMPLETION -> XILINX_CH_CC；其他 -> XILINX_CH_RQ
    //   EP 角色：COMPLETION -> XILINX_CH_RC；其他 -> XILINX_CH_CQ
    //
    // 参数：
    //   tlp - 待接收的 TLP 对象（通过 get_category() 获取类别）
    // 返回：来源通道枚举值
    //
    function xilinx_channel_e get_rx_channel(pcie_tl_tlp tlp);
        tlp_category_e category;
        category = tlp.get_category();

        case (role)
            XILINX_PCIE_RC: begin
                // RC 角色接收侧
                if (category == TLP_CAT_COMPLETION)
                    // 完成包从 CC 通道接收（EP 通过 CC 通道发送完成给 RC）
                    return XILINX_CH_CC;
                else
                    // 请求包从 RQ 通道接收（EP 通过 RQ 通道发起请求到 RC）
                    return XILINX_CH_RQ;
            end

            XILINX_PCIE_EP: begin
                // EP 角色接收侧
                if (category == TLP_CAT_COMPLETION)
                    // 完成包从 RC 通道接收（RC 通过 RC 通道返回完成给 EP）
                    return XILINX_CH_RC;
                else
                    // 请求包从 CQ 通道接收（RC 通过 CQ 通道向 EP 发送请求）
                    return XILINX_CH_CQ;
            end

            default: begin
                $fatal(1, "[xilinx_pcie_channel_router] get_rx_channel: 未知角色 %0d", role);
                return XILINX_CH_CQ;
            end
        endcase
    endfunction : get_rx_channel

endclass : xilinx_pcie_channel_router
