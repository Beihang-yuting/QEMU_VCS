#!/bin/sh
# Ensure cosim tools are in PATH
export PATH="/usr/local/bin:$PATH"

# 彩色欢迎信息（登录后显示）
CYAN='\033[0;36m'
GREEN='\033[0;32m'
BOLD_GREEN='\033[1;32m'
YELLOW='\033[0;33m'
BOLD_CYAN='\033[1;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${BOLD_CYAN}        CoSim Guest — Alpine Linux            ${NC}${CYAN}║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${BOLD_GREEN}  Welcome to CoSim Platform!                  ${NC}${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  QEMU-VCS 软硬件协同仿真系统                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}┌─ 快速开始 ────────────────────────────┐${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}│${NC} 1. 启动 VCS:    make run-vcs          ${GREEN}│${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}│${NC} 2. 配置网络:    cosim-start           ${GREEN}│${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}│${NC} 3. 测试连通:    ping -c 1 10.0.0.1    ${GREEN}│${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}│${NC} 4. 吞吐测试:    iperf3 -c 10.0.0.1    ${GREEN}│${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}│${NC} 5. PCIe 诊断:   lspci -vv             ${GREEN}│${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${GREEN}└───────────────────────────────────────┘${NC}   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${YELLOW}  退出: cosim-stop (通知VCS) | Ctrl+A X (强制)${NC} ${CYAN}║${NC}"
echo -e "${CYAN}║${YELLOW}  调试: make run-qemu VERBOSE=1               ${NC} ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  文档: docs/SETUP-GUIDE.md                   ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                              ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════╝${NC}"
echo ""
