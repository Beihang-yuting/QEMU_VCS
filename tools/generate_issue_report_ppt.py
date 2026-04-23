#!/usr/bin/env python3
"""生成 CoSim Platform 问题排查与修复报告 PPT"""

from pptx import Presentation
from pptx.util import Inches, Pt
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR

# 颜色
DARK_BLUE = RGBColor(0x00, 0x2B, 0x5C)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)
BLACK = RGBColor(0x00, 0x00, 0x00)
DARK_GRAY = RGBColor(0x33, 0x33, 0x33)
HEADER_BG = RGBColor(0x00, 0x3D, 0x7A)
ROW_ALT = RGBColor(0xE8, 0xF0, 0xFA)

CN_FONT = "SimHei"


def add_title_slide(prs, title, subtitle):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    bg = slide.background
    fill = bg.fill
    fill.solid()
    fill.fore_color.rgb = DARK_BLUE
    txBox = slide.shapes.add_textbox(Inches(0.8), Inches(2.5), Inches(8.4), Inches(1.5))
    tf = txBox.text_frame
    tf.word_wrap = True
    p = tf.paragraphs[0]
    p.text = title
    p.font.size = Pt(36)
    p.font.color.rgb = WHITE
    p.font.bold = True
    p.font.name = CN_FONT
    p.alignment = PP_ALIGN.CENTER
    p2 = tf.add_paragraph()
    p2.text = subtitle
    p2.font.size = Pt(18)
    p2.font.color.rgb = RGBColor(0xA0, 0xC0, 0xE0)
    p2.font.name = CN_FONT
    p2.alignment = PP_ALIGN.CENTER
    p2.space_before = Pt(20)


def add_content_slide(prs, title, bullets):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    title_box = slide.shapes.add_textbox(Inches(0), Inches(0), Inches(10), Inches(0.9))
    tf = title_box.text_frame
    tf.paragraphs[0].text = title
    tf.paragraphs[0].font.size = Pt(24)
    tf.paragraphs[0].font.bold = True
    tf.paragraphs[0].font.color.rgb = DARK_BLUE
    tf.paragraphs[0].font.name = CN_FONT
    tf.paragraphs[0].alignment = PP_ALIGN.LEFT
    tf.margin_left = Inches(0.5)
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    body_box = slide.shapes.add_textbox(Inches(0.5), Inches(1.1), Inches(9), Inches(6))
    tf2 = body_box.text_frame
    tf2.word_wrap = True
    for i, b in enumerate(bullets):
        p = tf2.paragraphs[0] if i == 0 else tf2.add_paragraph()
        p.text = b
        p.font.size = Pt(15)
        p.font.color.rgb = DARK_GRAY
        p.font.name = CN_FONT
        p.space_before = Pt(6)


def add_table_slide(prs, title, headers, rows):
    slide = prs.slides.add_slide(prs.slide_layouts[6])
    title_box = slide.shapes.add_textbox(Inches(0), Inches(0), Inches(10), Inches(0.9))
    tf = title_box.text_frame
    tf.paragraphs[0].text = title
    tf.paragraphs[0].font.size = Pt(24)
    tf.paragraphs[0].font.bold = True
    tf.paragraphs[0].font.color.rgb = DARK_BLUE
    tf.paragraphs[0].font.name = CN_FONT
    tf.margin_left = Inches(0.5)
    tf.vertical_anchor = MSO_ANCHOR.MIDDLE
    n_rows = len(rows) + 1
    n_cols = len(headers)
    width = Inches(9.2)
    table_shape = slide.shapes.add_table(n_rows, n_cols, Inches(0.4), Inches(1.2), width, Inches(0.4) * n_rows)
    table = table_shape.table
    col_w = int(width / n_cols)
    for ci in range(n_cols):
        table.columns[ci].width = col_w
    for ci, h in enumerate(headers):
        cell = table.cell(0, ci)
        cell.text = h
        for p in cell.text_frame.paragraphs:
            p.font.size = Pt(13)
            p.font.bold = True
            p.font.color.rgb = WHITE
            p.font.name = CN_FONT
            p.alignment = PP_ALIGN.CENTER
        cell.fill.solid()
        cell.fill.fore_color.rgb = HEADER_BG
    for ri, row in enumerate(rows):
        for ci, val in enumerate(row):
            cell = table.cell(ri + 1, ci)
            cell.text = str(val)
            for p in cell.text_frame.paragraphs:
                p.font.size = Pt(12)
                p.font.color.rgb = BLACK
                p.font.name = CN_FONT
                p.alignment = PP_ALIGN.LEFT
            if ri % 2 == 1:
                cell.fill.solid()
                cell.fill.fore_color.rgb = ROW_ALT


def main():
    prs = Presentation()
    prs.slide_width = Inches(10)
    prs.slide_height = Inches(7.5)

    # ── 封面 ──
    add_title_slide(prs,
        "CoSim Platform 问题排查与修复报告",
        "Setup 流程集成 · VIP MSI 修复 · TCP 消息交错分析\n2026-04-23")

    # ── 问题总览 ──
    add_table_slide(prs, "问题总览",
        ["#", "问题", "严重性", "状态"],
        [
            ["1", "cosim.sh 不支持 TCP transport 参数", "高", "✅ 已修复"],
            ["2", "cosim.sh 不支持磁盘镜像启动 (--drive)", "高", "✅ 已修复"],
            ["3", "setup.sh NEED_TAP_BRIDGE 归属错误", "高", "✅ 已修复"],
            ["4", "setup.sh VCS 编译为 legacy 而非 VIP", "严重", "✅ 已修复"],
            ["5", "setup.sh VCS 源文件列表缺失 transport_tcp.c 等", "严重", "✅ 已修复"],
            ["6", "cosim_vip_top.sv VIP 模式缺少 MSI 中断注入", "严重", "✅ 已修复"],
            ["7", "glue_if_to_stub.sv stub_isr_set 多驱动冲突", "高", "✅ 已修复"],
            ["8", "TCP transport DMA read 消费 TLP_READY 导致协议错位", "严重", "🔍 分析中"],
        ])

    # ── 问题 1-2 ──
    add_content_slide(prs, "问题 1-2: cosim.sh 不支持 TCP / 磁盘镜像",
        [
            "现象: setup.sh 提示的跨机命令无法执行",
            "  ./cosim.sh start qemu --transport tcp --port-base 9100 → 报错「未知选项」",
            "",
            "根因: cmd_start_qemu 只有 --shm/--sock/--initrd 三个参数",
            "  -device 参数硬编码为 SHM 模式",
            "",
            "修复: 新增 --transport, --port-base, --instance-id, --drive, --append",
            "  TCP: -device cosim-pcie-rc,transport=tcp,port_base=N,instance_id=N",
            "  Drive: -drive file=X,format=raw/qcow2,if=virtio",
            "",
            "VCS 侧同步修复: cmd_start_vcs 新增 --transport tcp --remote-host IP",
            "  TCP 必须指定 --remote-host, 缺失时报错提示",
        ])

    # ── 问题 3 ──
    add_content_slide(prs, "问题 3: NEED_TAP_BRIDGE 归属错误",
        [
            "现象: vcs-only 模式不编译 eth_tap_bridge",
            "",
            "跨机拓扑: eth_tap_bridge 运行在 VCS 机器 (61) 上",
            "  VCS 机器: simv_vip → ETH SHM → eth_tap_bridge → TAP cosim0",
            "  QEMU 机器: 只有 QEMU + Guest, 不需要 TAP",
            "",
            "原代码:   qemu-only: NEED_TAP_BRIDGE=true ← 错误",
            "          vcs-only:  NEED_TAP_BRIDGE=false ← 错误",
            "",
            "修复: 翻转归属",
            "  qemu-only: NEED_TAP_BRIDGE=false",
            "  vcs-only:  NEED_TAP_BRIDGE=true",
        ])

    # ── 问题 4-5 ──
    add_content_slide(prs, "问题 4-5: setup.sh VCS 编译模式错误",
        [
            "现象: setup.sh 编译产出 legacy simv, 跨机联调需要 VIP simv_vip",
            "",
            "缺失项:",
            "  +define+COSIM_VIP_MODE — VIP 宏开关",
            "  -ntb_opts uvm-1.2 — UVM 框架",
            "  pcie_tl_if.sv / pcie_tl_pkg.sv — VIP 源文件",
            "  transport_tcp.c / transport_shm.c / trace_log.c — C 源文件",
            "  sock_sync.c 错误引用（应为 sock_sync_vcs.c）",
            "",
            "修复: setup.sh 直接调用 make vcs-vip",
            "  产出路径统一: build/simv_vip",
            "  cosim.sh resolve_simv 优先搜 build/simv_vip",
        ])

    # ── 问题 6-7 ──
    add_content_slide(prs, "问题 6-7: VIP 模式 MSI 中断未注入",
        [
            "现象: Guest virtio0 中断 = 0, TX packets = 0",
            "  virtio_net driver 未完成初始化, TX queue 未激活",
            "",
            "根因: cosim_vip_top.sv RX poll 成功后缺少 MSI 触发",
            "  tb_top.sv (legacy): isr_set → bridge_vcs_raise_msi(0)  ✅",
            "  cosim_vip_top.sv (VIP): 无 MSI 代码  ❌",
            "  virtqueue_dma.c 注释: \"tb_top.sv handles it\" — 但 VIP 不走 tb_top",
            "",
            "修复:",
            "  cosim_vip_top.sv: RX inject 后 stub_isr_set 脉冲 + raise_msi",
            "  glue_if_to_stub.sv: stub_isr_set 从 output 改为 input",
            "  时序关键: 先设 ISR bit → 再发 MSI（Guest 读 ISR 必须非零）",
        ])

    # ── 问题 8 ──
    add_content_slide(prs, "问题 8: TCP Transport DMA Read 消息交错 [分析中]",
        [
            "现象: QEMU 发 278 个 TLP, VCS 只处理 208 个, 之后停滞",
            "  QEMU 阻塞在 MRd(addr=0x1014 device_status) 等 completion",
            "  VCS poll 正常运行但 recv_sync_timed 返回无数据",
            "",
            "分析: bridge_dma_read_bytes 中的 recv_sync 循环",
            "  遇到 SYNC_MSG_TLP_READY 时: g_pending_tlp_ready++ 并 continue",
            "  但 TLP 数据仍在 data channel buffer 中未被读取",
            "  DMA 完成后 poll_tlp 调 recv_tlp — 读到错位的消息",
            "",
            "死锁场景:",
            "  QEMU: send MRd → wait recv_sync(CPL_READY) ← 阻塞",
            "  VCS: DMA read 循环消费了 MRd 的 TLP_READY, 但未读 TLP 数据",
            "  VCS poll: pending_tlp 归零后 recv_tlp 与 data channel 错位",
        ])

    # ── TCP channel 架构 ──
    add_content_slide(prs, "TCP Transport Channel 架构分析",
        [
            "当前 v2 三连接架构:",
            "  ctrl (port_base+0): sync_msg — TLP_READY, CPL_READY, DMA_CPL, SHUTDOWN",
            "  data (port_base+1): TLP, CPL 数据",
            "  aux  (port_base+2): DMA_REQ, DMA_CPL, MSI, ETH, DMA_DATA",
            "",
            "问题: ctrl channel 是共享的",
            "  TLP_READY 和 DMA_CPL 都走 ctrl channel",
            "  DMA read 循环 recv_sync 消费本属于 poll 的 TLP_READY",
            "  消费后只计数 (pending_tlp++), 不读 data channel 上的 TLP 数据",
            "  后续 recv_tlp 与 data channel 上的消息错位",
            "",
            "解决方案 (选项):",
            "  A: DMA read 消费 TLP_READY 时同步 recv_tlp 缓存完整 TLP",
            "  B: 将 TLP_READY 和 DMA_CPL 拆分到不同 channel",
            "  C: 消息自描述 — data channel 每条消息带 type header",
        ])

    # ── 验证结果 ──
    add_table_slide(prs, "跨机测试验证结果 (53 ↔ 61)",
        ["测试项", "结果", "说明"],
        [
            ["QEMU TCP listen (53)", "✅ 通过", "端口 9100 监听成功"],
            ["VCS TCP connect (61)", "✅ 通过", "连接 QEMU 成功"],
            ["ETH SHM 创建", "✅ 通过", "VCS 创建 /cosim_eth0"],
            ["TAP bridge", "✅ 通过", "cosim0 IP 10.0.0.1/24"],
            ["Guest boot", "✅ 通过", "buildroot 登录成功"],
            ["Guest eth0 配置", "✅ 通过", "10.0.0.2/24, virtio_net"],
            ["PCIe TLP 交换", "✅ 通过", "278 个 TLP"],
            ["DMA (config)", "✅ 通过", "4 次 DMA read"],
            ["VQ-TX (MLD)", "✅ 通过", "1 包 90B → TAP"],
            ["virtio MSI", "❌ 未触发", "已修复, 待验证"],
            ["Guest ping", "❌ 100% loss", "TCP 消息交错"],
        ])

    # ── 提交记录 ──
    add_content_slide(prs, "修复提交记录",
        [
            "Commit 1: feat(setup): cosim.sh start qemu/vcs 支持 TCP transport",
            "  cmd_start_qemu: --transport, --port-base, --instance-id, --drive, --append",
            "  cmd_start_vcs: --transport, --remote-host, --port-base, --instance-id",
            "  setup.sh: TAP_BRIDGE 归属翻转, VCS 源文件修正, setcap 提示",
            "",
            "Commit 2: fix(vcs): setup.sh 改用 make vcs-vip + VIP 模式补 MSI",
            "  setup.sh VCS 编译从内联 vcs 改为 make vcs-vip",
            "  cosim_vip_top.sv RX inject 后补 ISR + raise_msi",
            "  resolve_simv 优先搜 build/simv_vip",
            "",
            "Commit 3: fix(glue): stub_isr_set 改为 input",
            "  消除 assign 0 与过程化驱动的多驱动冲突",
            "",
            "待修复: TCP transport DMA read 消息交错",
        ])

    # ── 下一步 ──
    add_content_slide(prs, "下一步计划",
        [
            "1. 修复 TCP transport 消息交错问题",
            "  bridge_dma_read_bytes 消费 TLP_READY 时同步缓存 TLP 数据",
            "  避免 pending_tlp 计数与 data channel 消息错位",
            "",
            "2. 重新编译 VCS simv_vip（含 MSI + glue 修复）",
            "",
            "3. 跨机端到端验证",
            "  目标: Guest ping 10.0.0.1 成功",
            "  目标: iperf 吞吐测试通过",
            "",
            "4. 更新文档",
            "  补充 kernel/rootfs 外部依赖说明",
            "  补充 EDA 环境前置要求",
        ])

    out = "/home/ubuntu/ryan/software/cosim-platform/docs/cosim_issue_report.pptx"
    prs.save(out)
    print(f"PPT 已生成: {out}")


if __name__ == "__main__":
    main()
