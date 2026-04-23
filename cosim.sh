#!/bin/bash
# cosim-platform/cosim.sh
# CoSim Platform 统一入口脚本
# 用于运行所有测试、启动组件、查看状态等操作

# 注意：不在顶层使用 set -euo pipefail，以保证 cleanup 正常运行

# ============================================================
# 颜色定义
# ============================================================
if [ -t 1 ]; then
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_CYAN='\033[0;36m'
    C_BOLD='\033[1m'
    C_RESET='\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
    C_BOLD=''
    C_RESET=''
fi

# ============================================================
# 全局变量
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
PIDS=()

# ============================================================
# 通用函数
# ============================================================

log_info()  { echo -e "${C_CYAN}[CoSim]${C_RESET} $*"; }
log_ok()    { echo -e "${C_GREEN}[CoSim]${C_RESET} $*"; }
log_warn()  { echo -e "${C_YELLOW}[警告]${C_RESET} $*"; }
log_err()   { echo -e "${C_RED}[错误]${C_RESET} $*"; }
log_pass()  { echo -e "${C_GREEN}[PASS]${C_RESET} $*"; }
log_fail()  { echo -e "${C_RED}[FAIL]${C_RESET} $*"; }

load_config() {
    local config_file="${PROJECT_DIR}/config.env"
    if [ -f "$config_file" ]; then
        # shellcheck disable=SC1090
        source "$config_file"
    else
        log_warn "配置文件不存在: $config_file，使用默认值"
    fi

    # 从 config.env 或默认值设置变量
    GUEST1_IP="${GUEST1_IP:-10.0.0.1}"
    GUEST2_IP="${GUEST2_IP:-10.0.0.2}"
    GUEST1_MAC="${GUEST1_MAC:-de:ad:be:ef:00:01}"
    GUEST2_MAC="${GUEST2_MAC:-de:ad:be:ef:00:02}"
    TAP_IP="${TAP_IP:-10.0.0.1}"
    GUEST_IP="${GUEST_IP:-10.0.0.2}"
    GUEST_MEMORY="${GUEST_MEMORY:-256M}"
    PHASE5_TIMEOUT="${PHASE5_TIMEOUT:-300}"
    TAP_TIMEOUT="${TAP_TIMEOUT:-120}"

    # VCS license
    export SNPSLMD_LICENSE_FILE="${SNPSLMD_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
    export LM_LICENSE_FILE="${LM_LICENSE_FILE:-/opt/synopsys/license/license.dat}"
}

find_binary() {
    # find_binary <描述> <环境变量值> <构建路径> <workspace路径>
    local desc="$1"
    local env_val="$2"
    local build_path="$3"
    local workspace_path="$4"

    # 优先级 1: 环境变量覆盖
    if [ -n "$env_val" ] && [ -f "$env_val" ]; then
        echo "$env_val"
        return 0
    fi

    # 优先级 2: 项目构建目录
    if [ -f "$build_path" ]; then
        echo "$build_path"
        return 0
    fi

    # 优先级 3: 用户 workspace
    if [ -f "$workspace_path" ]; then
        echo "$workspace_path"
        return 0
    fi

    # 未找到
    return 1
}

resolve_qemu() {
    find_binary "QEMU" \
        "${QEMU:-}" \
        "${PROJECT_DIR}/third_party/qemu/build/qemu-system-x86_64" \
        "$HOME/workspace/qemu-9.2.0/build/qemu-system-x86_64"
}

resolve_simv() {
    # 优先级: 环境变量 > build/simv_vip (VIP模式) > 旧路径 (legacy)
    if [ -n "${SIMV:-}" ] && [ -f "${SIMV:-}" ]; then
        echo "$SIMV"
        return 0
    fi
    for candidate in \
        "${PROJECT_DIR}/build/simv_vip" \
        "${PROJECT_DIR}/vcs-tb/sim_build/simv" \
        "$HOME/workspace/cosim-platform/build/simv_vip" \
        "$HOME/cosim-platform/build/simv_vip"; do
        if [ -f "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

resolve_tap_bridge() {
    find_binary "eth_tap_bridge" \
        "${TAP_BRIDGE:-}" \
        "${PROJECT_DIR}/tools/eth_tap_bridge" \
        "$HOME/workspace/cosim-platform/tools/eth_tap_bridge"
}

resolve_kernel() {
    find_binary "Guest kernel" \
        "${KERNEL:-}" \
        "${PROJECT_DIR}/guest/bzImage" \
        "$HOME/workspace/alpine-vmlinuz-new"
}

resolve_initrd() {
    local phase="${1:-}"
    local env_val="${INITRD:-}"

    # 如果用户明确指定了 INITRD，优先使用
    if [ -n "$env_val" ] && [ -f "$env_val" ]; then
        echo "$env_val"
        return 0
    fi

    # 根据 phase 选择不同的 initramfs
    local suffix=""
    case "$phase" in
        phase4) suffix="-phase4" ;;
        phase5) suffix="-phase5" ;;
        tap)    suffix="-tap" ;;
        *)      suffix="" ;;
    esac

    local ws_path="$HOME/workspace/custom-initramfs${suffix}.gz"
    local proj_path="${PROJECT_DIR}/guest/initramfs${suffix}.gz"

    if [ -f "$proj_path" ]; then
        echo "$proj_path"
        return 0
    fi
    if [ -f "$ws_path" ]; then
        echo "$ws_path"
        return 0
    fi

    # 回退到无后缀版本
    if [ -n "$suffix" ]; then
        local ws_fallback="$HOME/workspace/custom-initramfs.gz"
        local proj_fallback="${PROJECT_DIR}/guest/initramfs.gz"
        if [ -f "$proj_fallback" ]; then
            echo "$proj_fallback"
            return 0
        fi
        if [ -f "$ws_fallback" ]; then
            echo "$ws_fallback"
            return 0
        fi
    fi

    return 1
}

check_prereqs() {
    local missing=0

    if ! resolve_qemu >/dev/null 2>&1; then
        log_err "找不到 QEMU 二进制文件"
        log_err "  尝试: 设置 QEMU=/path/to/qemu-system-x86_64"
        log_err "  或运行 setup.sh 构建 QEMU"
        missing=1
    fi

    if ! resolve_simv >/dev/null 2>&1; then
        log_err "找不到 VCS simv 二进制文件"
        log_err "  尝试: 设置 SIMV=/path/to/simv"
        log_err "  或运行 scripts/rebuild_vcs.sh 构建 VCS testbench"
        missing=1
    fi

    if ! resolve_kernel >/dev/null 2>&1; then
        log_err "找不到 Guest kernel"
        log_err "  尝试: 设置 KERNEL=/path/to/bzImage"
        missing=1
    fi

    return $missing
}

cleanup() {
    echo ""
    log_info "正在关闭所有进程..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    log_info "清理完成"
}

cleanup_all() {
    log_info "正在清理所有 CoSim 资源..."

    # 终止相关进程
    pkill -f "cosim-pcie-rc" 2>/dev/null || true
    pkill -f "eth_tap_bridge" 2>/dev/null || true
    # 使用进程名终止 simv（仅匹配 cosim 相关的）
    pkill -f "simv.*SHM_NAME" 2>/dev/null || true

    sleep 1

    # 清理 SHM 文件
    rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/cosim_eth0 2>/dev/null || true
    # 清理所有 cosim 相关的 SHM
    for f in /dev/shm/cosim*; do
        [ -e "$f" ] && rm -f "$f" 2>/dev/null
    done

    # 清理 socket 文件
    rm -f /tmp/cosim*.sock 2>/dev/null || true

    # 清理 TAP 设备
    if command -v ip >/dev/null 2>&1; then
        if ip link show cosim0 >/dev/null 2>&1; then
            ip link set cosim0 down 2>/dev/null || true
            ip tuntap del dev cosim0 mode tap 2>/dev/null || true
        fi
    fi

    log_ok "清理完成"
}

wait_for_shm() {
    local shm_name="$1"
    local timeout="${2:-10}"
    local shm_path="/dev/shm/${shm_name#/}"

    local elapsed=0
    while [ $elapsed -lt "$timeout" ]; do
        if [ -e "$shm_path" ]; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_err "等待 SHM 超时 (${timeout}s): $shm_path"
    return 1
}

wait_for_processes() {
    local timeout="$1"
    shift
    local pids=("$@")

    local deadline=$((SECONDS + timeout))
    while [ $SECONDS -lt $deadline ]; do
        local all_done=true
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                all_done=false
            fi
        done
        if $all_done; then
            return 0
        fi
        sleep 1
    done

    log_warn "超时 (${timeout}s)，强制停止..."
    return 1
}

# ============================================================
# 使用帮助
# ============================================================

show_help() {
    cat <<'HELP'
CoSim Platform 统一入口

用法: ./cosim.sh <命令> [选项]

命令:
  test <模式>       运行测试
    phase1          Config Space 测试（单 QEMU + VCS）
    phase2          MMIO + MSI/DMA 测试
    phase3          Virtio-net 单向 TX 测试
    phase4          双向网络 Ping 测试（双 VCS）
    phase5          TCP/iperf 吞吐测试（双 VCS）
    tap             TAP Bridge 测试（单 VCS + TAP）
    unit            仅运行单元测试
    integration     仅运行集成测试
    all             按顺序运行所有阶段

  test-guide        交互式功能测试向导（ping/iperf/arping/压力测试）

  start <组件>      启动单个组件
    qemu [选项]       SHM: --shm NAME --sock PATH
                      TCP: --transport tcp [--port-base N] [--instance-id N]
                      Guest: --initrd FILE 或 --drive FILE [--append ARGS]
    vcs  [选项]       SHM: --shm NAME --sock PATH
                      TCP: --transport tcp --remote-host IP [--port-base N]
                      通用: [--role A|B] [--eth-shm NAME] [--mac-last N]
                            [--timeout MS] [--test NAME]
    tap  [--eth-shm NAME] [--ip ADDR] [--tap-dev NAME]

  status            显示运行中的 CoSim 进程
  clean             终止所有 CoSim 进程并清理 SHM/socket
  log [组件]        查看最新日志 (qemu|vcs|tap|all)
  info              显示构建信息和路径
  help              显示此帮助信息

环境变量覆盖:
  QEMU=<path>       QEMU 二进制路径
  SIMV=<path>       VCS simv 路径
  KERNEL=<path>     Guest kernel 路径
  INITRD=<path>     Guest initramfs 路径
  TAP_BRIDGE=<path> eth_tap_bridge 路径

示例:
  ./cosim.sh test phase1              # 运行 Phase 1 测试
  ./cosim.sh test all                 # 运行所有测试
  ./cosim.sh start qemu --shm /cosim0 --sock /tmp/cosim0.sock     # SHM 本地模式
  ./cosim.sh start qemu --transport tcp --port-base 9100           # TCP 跨机模式
  ./cosim.sh start qemu --transport tcp --drive rootfs.ext4        # TCP + 磁盘镜像
  ./cosim.sh status                   # 查看运行状态
  ./cosim.sh clean                    # 清理所有资源
HELP
}

# ============================================================
# 测试运行: 单 QEMU + 单 VCS 模式 (Phase 1/2/3)
# ============================================================

run_single_phase() {
    local phase="$1"
    local phase_label="$2"
    local timeout="${3:-120}"
    local extra_append="${4:-}"

    log_info "=========================================="
    log_info "  ${phase_label}"
    log_info "=========================================="

    local qemu_bin simv_bin kernel_bin initrd_bin
    qemu_bin="$(resolve_qemu)" || { log_err "找不到 QEMU"; return 1; }
    simv_bin="$(resolve_simv)" || { log_err "找不到 simv"; return 1; }
    kernel_bin="$(resolve_kernel)" || { log_err "找不到 kernel"; return 1; }
    initrd_bin="$(resolve_initrd "$phase")" || { log_err "找不到 initramfs ($phase)"; return 1; }

    log_info "QEMU:    $qemu_bin"
    log_info "simv:    $simv_bin"
    log_info "kernel:  $kernel_bin"
    log_info "initrd:  $initrd_bin"
    log_info "超时:    ${timeout}s"

    local SHM="/cosim0"
    local SOCK="/tmp/cosim0.sock"

    # 清理旧资源
    rm -f /dev/shm/"${SHM#/}" 2>/dev/null || true
    rm -f "$SOCK" 2>/dev/null || true

    # 日志目录
    local LOGDIR="/tmp/cosim_${phase}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$LOGDIR"
    log_info "日志目录: $LOGDIR/"

    local LOCAL_PIDS=()
    _single_cleanup() {
        for pid in "${LOCAL_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        rm -f /dev/shm/"${SHM#/}" 2>/dev/null || true
        rm -f "$SOCK" 2>/dev/null || true
    }

    # 启动 QEMU
    local append_str="console=ttyS0 init=/init"
    [ -n "$extra_append" ] && append_str="${append_str} ${extra_append}"

    log_info "启动 QEMU..."
    "$qemu_bin" \
        -M q35 -m "${GUEST_MEMORY}" -smp 1 \
        -kernel "$kernel_bin" \
        -initrd "$initrd_bin" \
        -append "$append_str" \
        -device "cosim-pcie-rc,shm_name=$SHM,sock_path=$SOCK" \
        -nographic -no-reboot \
        -d unimp -D "$LOGDIR/qemu_debug.log" \
        > "$LOGDIR/qemu.log" 2>&1 &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  QEMU PID: ${LOCAL_PIDS[-1]}"
    sleep 2

    # 检查 SHM
    if ! wait_for_shm "$SHM" 10; then
        log_err "PCIe SHM 未创建，QEMU 可能启动失败"
        log_err "--- QEMU 日志 ---"
        tail -20 "$LOGDIR/qemu.log" 2>/dev/null
        _single_cleanup
        return 1
    fi

    # 启动 VCS
    local simv_dir
    simv_dir="$(dirname "$simv_bin")"
    log_info "启动 VCS..."
    (cd "$simv_dir" && ./simv \
        +SHM_NAME="$SHM" +SOCK_PATH="$SOCK" \
        +SIM_TIMEOUT_MS=$((timeout * 1000)) +MAC_LAST=1 \
        > "$LOGDIR/vcs.log" 2>&1) &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  VCS PID: ${LOCAL_PIDS[-1]}"

    # 等待完成
    log_info "等待测试完成..."
    wait_for_processes "$timeout" "${LOCAL_PIDS[@]}" || true

    # 收集结果
    echo ""
    log_info "========== ${phase_label} 结果 =========="
    echo ""
    echo "--- QEMU 输出 ---"
    grep -E "(Phase|Config|MMIO|MSI|DMA|Virtio|TX|RX|PASS|FAIL|error)" "$LOGDIR/qemu.log" 2>/dev/null | tail -30
    echo ""
    echo "--- VCS 输出 ---"
    grep -E "(VQ-TX|VQ-RX|BAR|CFG|NOTIFY|ISR|DMA|MSI|PASS|FAIL)" "$LOGDIR/vcs.log" 2>/dev/null | tail -20
    echo ""
    echo "--- QEMU Debug (MSI/DMA) ---"
    grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu_debug.log" 2>/dev/null | tail -10

    # 判断结果
    local result=0
    if grep -q "FAIL" "$LOGDIR/qemu.log" 2>/dev/null; then
        result=1
    fi
    if grep -q "PASS" "$LOGDIR/qemu.log" 2>/dev/null; then
        result=0
    fi

    echo ""
    log_info "完整日志: $LOGDIR/"
    if [ $result -eq 0 ]; then
        log_pass "$phase_label"
    else
        log_fail "$phase_label"
    fi

    _single_cleanup
    return $result
}

# ============================================================
# 测试运行: 双 VCS 模式 (Phase 4/5)
# ============================================================

run_dual_phase() {
    local phase="$1"
    local phase_label="$2"
    local timeout="${3:-120}"

    log_info "=========================================="
    log_info "  ${phase_label}"
    log_info "=========================================="

    local qemu_bin simv_bin kernel_bin initrd_bin
    qemu_bin="$(resolve_qemu)" || { log_err "找不到 QEMU"; return 1; }
    simv_bin="$(resolve_simv)" || { log_err "找不到 simv"; return 1; }
    kernel_bin="$(resolve_kernel)" || { log_err "找不到 kernel"; return 1; }
    initrd_bin="$(resolve_initrd "$phase")" || { log_err "找不到 initramfs ($phase)"; return 1; }

    log_info "QEMU:    $qemu_bin"
    log_info "simv:    $simv_bin"
    log_info "kernel:  $kernel_bin"
    log_info "initrd:  $initrd_bin"
    log_info "超时:    ${timeout}s"

    local SHM1="/cosim0"
    local SHM2="/cosim1"
    local SOCK1="/tmp/cosim0.sock"
    local SOCK2="/tmp/cosim1.sock"
    local ETH_SHM="/cosim_eth0"

    # 角色配置
    local SERVER_IP="$GUEST1_IP"
    local CLIENT_IP="$GUEST2_IP"

    # 清理旧资源
    rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/cosim_eth0 2>/dev/null || true
    rm -f "$SOCK1" "$SOCK2" 2>/dev/null || true

    # 日志目录
    local LOGDIR="/tmp/cosim_${phase}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$LOGDIR"
    log_info "日志目录: $LOGDIR/"

    local LOCAL_PIDS=()
    _dual_cleanup() {
        for pid in "${LOCAL_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        rm -f /dev/shm/cosim0 /dev/shm/cosim1 /dev/shm/cosim_eth0 2>/dev/null || true
        rm -f "$SOCK1" "$SOCK2" 2>/dev/null || true
    }

    # 构建 append 参数
    local role_append_server=""
    local role_append_client=""
    if [ "$phase" = "phase5" ]; then
        role_append_server="role=server wait_sec=25"
        role_append_client="role=client wait_sec=25"
    else
        role_append_server="wait_sec=25"
        role_append_client="wait_sec=25"
    fi

    # 启动 QEMU1 (Server)
    log_info "启动 QEMU1 (Server: $SERVER_IP)..."
    "$qemu_bin" \
        -M q35 -m "${GUEST_MEMORY}" -smp 1 \
        -kernel "$kernel_bin" \
        -initrd "$initrd_bin" \
        -append "console=ttyS0 init=/init guest_ip=$SERVER_IP peer_ip=$CLIENT_IP $role_append_server" \
        -device "cosim-pcie-rc,shm_name=$SHM1,sock_path=$SOCK1" \
        -nographic -no-reboot \
        -d unimp -D "$LOGDIR/qemu1_debug.log" \
        > "$LOGDIR/qemu1.log" 2>&1 &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  QEMU1 PID: ${LOCAL_PIDS[-1]}"
    sleep 2

    # 启动 QEMU2 (Client)
    log_info "启动 QEMU2 (Client: $CLIENT_IP)..."
    "$qemu_bin" \
        -M q35 -m "${GUEST_MEMORY}" -smp 1 \
        -kernel "$kernel_bin" \
        -initrd "$initrd_bin" \
        -append "console=ttyS0 init=/init guest_ip=$CLIENT_IP peer_ip=$SERVER_IP $role_append_client" \
        -device "cosim-pcie-rc,shm_name=$SHM2,sock_path=$SOCK2" \
        -nographic -no-reboot \
        -d unimp -D "$LOGDIR/qemu2_debug.log" \
        > "$LOGDIR/qemu2.log" 2>&1 &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  QEMU2 PID: ${LOCAL_PIDS[-1]}"
    sleep 2

    # 检查 SHM
    if ! wait_for_shm "$SHM1" 10 || ! wait_for_shm "$SHM2" 10; then
        log_err "PCIe SHM 未创建，QEMU 可能启动失败"
        tail -20 "$LOGDIR/qemu1.log" 2>/dev/null
        _dual_cleanup
        return 1
    fi

    # 启动 VCS1 (Role A)
    local simv_dir
    simv_dir="$(dirname "$simv_bin")"
    log_info "启动 VCS1 (Role A, MAC=01)..."
    (cd "$simv_dir" && ./simv \
        +SHM_NAME="$SHM1" +SOCK_PATH="$SOCK1" \
        +ETH_SHM="$ETH_SHM" +ETH_ROLE=0 +ETH_CREATE=1 \
        +SIM_TIMEOUT_MS=$((timeout * 1000)) +MAC_LAST=1 \
        > "$LOGDIR/vcs1.log" 2>&1) &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  VCS1 PID: ${LOCAL_PIDS[-1]}"
    sleep 3

    # 启动 VCS2 (Role B)
    log_info "启动 VCS2 (Role B, MAC=02)..."
    (cd "$simv_dir" && ./simv \
        +SHM_NAME="$SHM2" +SOCK_PATH="$SOCK2" \
        +ETH_SHM="$ETH_SHM" +ETH_ROLE=1 +ETH_CREATE=0 \
        +SIM_TIMEOUT_MS=$((timeout * 1000)) +MAC_LAST=2 \
        > "$LOGDIR/vcs2.log" 2>&1) &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  VCS2 PID: ${LOCAL_PIDS[-1]}"

    # 等待完成
    echo ""
    log_info "Server: $SERVER_IP  (QEMU1 + VCS1/RoleA)"
    log_info "Client: $CLIENT_IP  (QEMU2 + VCS2/RoleB)"
    log_info "ETH SHM: $ETH_SHM"
    log_info "等待测试完成..."

    wait_for_processes "$timeout" "${LOCAL_PIDS[@]}" || true

    # 收集结果
    echo ""
    log_info "========== ${phase_label} 结果 =========="

    echo ""
    echo "--- QEMU1 (Server: $SERVER_IP) ---"
    grep -E "(Phase|TCP|nc|iperf|ping|Sending|packets|PASS|FAIL|rx_|tx_|bytes)" "$LOGDIR/qemu1.log" 2>/dev/null | tail -30

    echo ""
    echo "--- QEMU2 (Client: $CLIENT_IP) ---"
    grep -E "(Phase|TCP|nc|iperf|ping|Sending|packets|PASS|FAIL|rx_|tx_|bytes)" "$LOGDIR/qemu2.log" 2>/dev/null | tail -30

    echo ""
    echo "--- VCS1 (Role A) ---"
    grep -E "(VQ-TX|VQ-RX|ETH|Forwarded|Injected)" "$LOGDIR/vcs1.log" 2>/dev/null | tail -15

    echo ""
    echo "--- VCS2 (Role B) ---"
    grep -E "(VQ-TX|VQ-RX|ETH|Forwarded|Injected)" "$LOGDIR/vcs2.log" 2>/dev/null | tail -15

    echo ""
    echo "--- QEMU1 Debug (MSI/DMA) ---"
    grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu1_debug.log" 2>/dev/null | tail -10

    echo ""
    echo "--- QEMU2 Debug (MSI/DMA) ---"
    grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu2_debug.log" 2>/dev/null | tail -10

    # 判断结果
    local result=0
    if grep -q "FAIL" "$LOGDIR/qemu1.log" "$LOGDIR/qemu2.log" 2>/dev/null; then
        result=1
    fi
    if grep -q "PASS" "$LOGDIR/qemu1.log" "$LOGDIR/qemu2.log" 2>/dev/null; then
        result=0
    fi

    echo ""
    log_info "完整日志: $LOGDIR/"
    if [ $result -eq 0 ]; then
        log_pass "$phase_label"
    else
        log_fail "$phase_label"
    fi

    _dual_cleanup
    return $result
}

# ============================================================
# 测试运行: TAP Bridge 模式
# ============================================================

run_tap_test() {
    local timeout="${TAP_TIMEOUT:-120}"

    log_info "=========================================="
    log_info "  TAP Bridge 集成测试"
    log_info "=========================================="

    local qemu_bin simv_bin kernel_bin initrd_bin tap_bin
    qemu_bin="$(resolve_qemu)" || { log_err "找不到 QEMU"; return 1; }
    simv_bin="$(resolve_simv)" || { log_err "找不到 simv"; return 1; }
    kernel_bin="$(resolve_kernel)" || { log_err "找不到 kernel"; return 1; }
    initrd_bin="$(resolve_initrd "tap")" || { log_err "找不到 initramfs (tap)"; return 1; }
    tap_bin="$(resolve_tap_bridge)" || { log_err "找不到 eth_tap_bridge"; return 1; }

    if [ ! -x "$tap_bin" ]; then
        log_err "eth_tap_bridge 不可执行: $tap_bin"
        return 1
    fi

    log_info "QEMU:       $qemu_bin"
    log_info "simv:       $simv_bin"
    log_info "kernel:     $kernel_bin"
    log_info "initrd:     $initrd_bin"
    log_info "TAP bridge: $tap_bin"
    log_info "超时:       ${timeout}s"

    local SHM="/cosim0"
    local SOCK="/tmp/cosim0.sock"
    local ETH_SHM="/cosim_eth0"
    local TAP_DEV="cosim0"

    # 清理旧资源
    rm -f /dev/shm/"${SHM#/}" /dev/shm/"${ETH_SHM#/}" 2>/dev/null || true
    rm -f "$SOCK" 2>/dev/null || true
    if ip link show "$TAP_DEV" >/dev/null 2>&1; then
        ip link set "$TAP_DEV" down 2>/dev/null || true
        ip tuntap del dev "$TAP_DEV" mode tap 2>/dev/null || true
    fi

    # 日志目录
    local LOGDIR="/tmp/cosim_tap_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$LOGDIR"
    log_info "日志目录: $LOGDIR/"

    local LOCAL_PIDS=()
    _tap_cleanup() {
        for pid in "${LOCAL_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        if ip link show "$TAP_DEV" >/dev/null 2>&1; then
            ip link set "$TAP_DEV" down 2>/dev/null || true
            ip tuntap del dev "$TAP_DEV" mode tap 2>/dev/null || true
        fi
        rm -f /dev/shm/"${SHM#/}" /dev/shm/"${ETH_SHM#/}" 2>/dev/null || true
        rm -f "$SOCK" 2>/dev/null || true
    }

    # 启动 QEMU
    log_info "启动 QEMU (Guest: $GUEST_IP)..."
    "$qemu_bin" \
        -M q35 -m "${GUEST_MEMORY}" -smp 1 \
        -kernel "$kernel_bin" \
        -initrd "$initrd_bin" \
        -append "console=ttyS0 init=/init" \
        -device "cosim-pcie-rc,shm_name=$SHM,sock_path=$SOCK" \
        -nographic -no-reboot \
        -d unimp -D "$LOGDIR/qemu_debug.log" \
        > "$LOGDIR/qemu.log" 2>&1 &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  QEMU PID: ${LOCAL_PIDS[-1]}"
    sleep 2

    # 检查 PCIe SHM
    if ! wait_for_shm "$SHM" 10; then
        log_err "PCIe SHM 未创建，QEMU 可能启动失败"
        tail -20 "$LOGDIR/qemu.log" 2>/dev/null
        _tap_cleanup
        return 1
    fi

    # 启动 VCS (Role A)
    local simv_dir
    simv_dir="$(dirname "$simv_bin")"
    log_info "启动 VCS (Role A, 创建 ETH SHM)..."
    (cd "$simv_dir" && ./simv \
        +SHM_NAME="$SHM" +SOCK_PATH="$SOCK" \
        +ETH_SHM="$ETH_SHM" +ETH_ROLE=0 +ETH_CREATE=1 \
        +SIM_TIMEOUT_MS=$((timeout * 1000)) +MAC_LAST=1 \
        > "$LOGDIR/vcs.log" 2>&1) &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  VCS PID: ${LOCAL_PIDS[-1]}"
    sleep 3

    # 检查 ETH SHM
    if ! wait_for_shm "$ETH_SHM" 10; then
        log_err "ETH SHM 未创建，VCS 可能启动失败"
        tail -20 "$LOGDIR/vcs.log" 2>/dev/null
        _tap_cleanup
        return 1
    fi

    # 启动 eth_tap_bridge (Role B)
    log_info "启动 eth_tap_bridge..."
    log_info "  ETH SHM: $ETH_SHM"
    log_info "  TAP dev: $TAP_DEV"
    log_info "  TAP IP:  $TAP_IP/24"

    PATH=/sbin:/usr/sbin:$PATH "$tap_bin" -s "$ETH_SHM" -t "$TAP_DEV" -i "$TAP_IP/24" \
        > "$LOGDIR/tap_bridge.log" 2>&1 &
    LOCAL_PIDS+=($!)
    PIDS+=($!)
    log_info "  TAP bridge PID: ${LOCAL_PIDS[-1]}"
    sleep 3

    # 设置 TAP MAC
    if /sbin/ip link show "$TAP_DEV" >/dev/null 2>&1; then
        /sbin/ip link set "$TAP_DEV" down 2>/dev/null || true
        /sbin/ip link set "$TAP_DEV" address "${TAP_MAC:-de:ad:be:ef:00:02}" 2>/dev/null || true
        /sbin/ip link set "$TAP_DEV" up 2>/dev/null || true
        log_info "  TAP MAC 已设置为 ${TAP_MAC:-de:ad:be:ef:00:02}"

        # 添加静态 ARP
        arp -s "$GUEST_IP" "${GUEST_MAC:-de:ad:be:ef:00:01}" -i "$TAP_DEV" 2>/dev/null || \
            /sbin/ip neigh add "$GUEST_IP" lladdr "${GUEST_MAC:-de:ad:be:ef:00:01}" dev "$TAP_DEV" nud permanent 2>/dev/null || \
            log_warn "Host ARP 设置失败，将使用动态 ARP"
    else
        log_warn "TAP 设备尚未可见，bridge 可能仍在初始化..."
    fi

    # 等待 Guest 启动
    log_info "等待 Guest 启动 (30s)..."
    sleep 30

    # Host -> Guest ping 测试
    echo ""
    log_info "=== Host -> Guest Ping 测试 ==="
    log_info "从 Host ping $GUEST_IP (通过 TAP $TAP_DEV)..."
    local host_ping_ret=0
    ping -c 5 -W 3 -I "$TAP_DEV" "$GUEST_IP" 2>&1 | tee "$LOGDIR/host_ping.log" || host_ping_ret=$?

    if [ $host_ping_ret -eq 0 ]; then
        log_pass "HOST->GUEST Ping"
    else
        log_fail "HOST->GUEST Ping (rc=$host_ping_ret)"
    fi

    # 等待所有进程结束
    echo ""
    log_info "等待所有进程完成 (超时: ${timeout}s)..."
    wait_for_processes "$timeout" "${LOCAL_PIDS[@]}" || true

    # 收集结果
    echo ""
    log_info "========== TAP Bridge 测试结果 =========="

    echo ""
    echo "--- QEMU Guest ---"
    grep -E "(TAP|Ping|PASS|FAIL|rx_|tx_|Configure|ARP|Loading|eth0|10\.0\.0)" "$LOGDIR/qemu.log" 2>/dev/null | tail -40

    echo ""
    echo "--- VCS (Role A) ---"
    grep -E "(VQ-TX|VQ-RX|ETH|Forwarded|Injected|MAC)" "$LOGDIR/vcs.log" 2>/dev/null | tail -15

    echo ""
    echo "--- TAP Bridge ---"
    tail -20 "$LOGDIR/tap_bridge.log" 2>/dev/null

    echo ""
    echo "--- Host Ping ---"
    cat "$LOGDIR/host_ping.log" 2>/dev/null

    echo ""
    echo "--- QEMU Debug (MSI/DMA) ---"
    grep -E "(cosim: MSI|cosim: DMA)" "$LOGDIR/qemu_debug.log" 2>/dev/null | tail -10

    # 判断结果
    local result=$host_ping_ret
    if grep -q "PASS" "$LOGDIR/qemu.log" 2>/dev/null; then
        result=0
    fi

    echo ""
    log_info "完整日志: $LOGDIR/"
    if [ $result -eq 0 ]; then
        log_pass "TAP Bridge 集成测试"
    else
        log_fail "TAP Bridge 集成测试"
    fi

    _tap_cleanup
    return $result
}

# ============================================================
# 单元测试 / 集成测试
# ============================================================

run_unit_tests() {
    log_info "=========================================="
    log_info "  运行单元测试"
    log_info "=========================================="

    local test_dir="${PROJECT_DIR}/tests/unit"
    if [ ! -d "$test_dir" ]; then
        log_warn "单元测试目录不存在: $test_dir"
        return 1
    fi

    local result=0
    (set -euo pipefail && cd "$PROJECT_DIR" && make test-unit 2>&1) || result=$?

    if [ $result -eq 0 ]; then
        log_pass "单元测试"
    else
        log_fail "单元测试"
    fi
    return $result
}

run_integration_tests() {
    log_info "=========================================="
    log_info "  运行集成测试"
    log_info "=========================================="

    local test_dir="${PROJECT_DIR}/tests/integration"
    if [ ! -d "$test_dir" ]; then
        log_warn "集成测试目录不存在: $test_dir"
        return 1
    fi

    local result=0
    (set -euo pipefail && cd "$PROJECT_DIR" && make test-integration 2>&1) || result=$?

    if [ $result -eq 0 ]; then
        log_pass "集成测试"
    else
        log_fail "集成测试"
    fi
    return $result
}

# ============================================================
# test all - 顺序运行所有阶段
# ============================================================

run_all_tests() {
    log_info "=========================================="
    log_info "  运行所有测试阶段"
    log_info "=========================================="
    echo ""

    local phases=("phase1" "phase2" "phase3" "phase4" "phase5" "tap")
    local labels=(
        "Phase 1: Config Space 测试"
        "Phase 2: MMIO + MSI/DMA 测试"
        "Phase 3: Virtio-net 单向 TX 测试"
        "Phase 4: 双向网络 Ping 测试"
        "Phase 5: TCP/iperf 吞吐测试"
        "TAP Bridge 测试"
    )
    local total=${#phases[@]}
    local passed=0
    local failed=0
    local results=()

    for i in "${!phases[@]}"; do
        local phase="${phases[$i]}"
        local label="${labels[$i]}"

        echo ""
        log_info "[$((i+1))/$total] $label"
        echo ""

        local rc=0
        cmd_test "$phase" || rc=$?

        if [ $rc -eq 0 ]; then
            results+=("PASS")
            passed=$((passed + 1))
        else
            results+=("FAIL")
            failed=$((failed + 1))
        fi

        # 每个阶段之间清理
        cleanup_all 2>/dev/null
        sleep 2
    done

    # 打印汇总表
    echo ""
    echo ""
    log_info "=========================================="
    log_info "  测试汇总"
    log_info "=========================================="
    echo ""
    printf "  %-40s %s\n" "测试阶段" "结果"
    printf "  %-40s %s\n" "────────────────────────────────────────" "──────"

    for i in "${!phases[@]}"; do
        local label="${labels[$i]}"
        local result="${results[$i]}"

        if [ "$result" = "PASS" ]; then
            printf "  %-40s ${C_GREEN}%s${C_RESET}\n" "$label" "PASS"
        else
            printf "  %-40s ${C_RED}%s${C_RESET}\n" "$label" "FAIL"
        fi
    done

    echo ""
    printf "  通过: ${C_GREEN}%d${C_RESET} / %d\n" "$passed" "$total"
    printf "  失败: ${C_RED}%d${C_RESET} / %d\n" "$failed" "$total"
    echo ""

    if [ $failed -eq 0 ]; then
        log_pass "所有测试通过"
        return 0
    else
        log_fail "有 $failed 个测试失败"
        return 1
    fi
}

# ============================================================
# start 命令: 启动单个组件
# ============================================================

cmd_start_qemu() {
    local transport="shm"
    local shm_name="/cosim0"
    local sock_path="/tmp/cosim0.sock"
    local port_base="9100"
    local instance_id="0"
    local initrd_file=""
    local drive_file=""
    local extra_append=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --transport)   transport="$2"; shift 2 ;;
            --shm)         shm_name="$2"; shift 2 ;;
            --sock)        sock_path="$2"; shift 2 ;;
            --port-base)   port_base="$2"; shift 2 ;;
            --instance-id) instance_id="$2"; shift 2 ;;
            --initrd)      initrd_file="$2"; shift 2 ;;
            --drive)       drive_file="$2"; shift 2 ;;
            --append)      extra_append="$2"; shift 2 ;;
            *) log_err "未知选项: $1"; return 1 ;;
        esac
    done

    # 参数校验
    case "$transport" in
        shm|tcp) ;;
        *) log_err "无效 transport: $transport（可选: shm, tcp）"; return 1 ;;
    esac

    local qemu_bin
    qemu_bin="$(resolve_qemu)" || { log_err "找不到 QEMU"; return 1; }

    # ---- 构建 -device 参数 ----
    local device_arg
    if [ "$transport" = "tcp" ]; then
        device_arg="cosim-pcie-rc,transport=tcp,port_base=$port_base,instance_id=$instance_id"
    else
        device_arg="cosim-pcie-rc,shm_name=$shm_name,sock_path=$sock_path"
    fi

    # ---- 构建 QEMU 命令行 ----
    local QEMU_ARGS=(
        -M q35 -m "${GUEST_MEMORY}" -smp 1
        -device "$device_arg"
        -nographic -no-reboot
    )

    # ---- Guest 启动方式: drive 模式 vs initramfs 模式 ----
    local append_str="console=ttyS0"

    if [ -n "$drive_file" ]; then
        # 磁盘镜像模式 (full guest)
        if [ ! -f "$drive_file" ]; then
            log_err "磁盘镜像不存在: $drive_file"
            return 1
        fi
        # 自动检测格式
        local drive_fmt="raw"
        case "$drive_file" in
            *.qcow2) drive_fmt="qcow2" ;;
            *.img)   drive_fmt="qcow2" ;;
        esac
        QEMU_ARGS+=(-drive "file=$drive_file,format=$drive_fmt,if=virtio")
        append_str="${append_str} root=/dev/vda"

        # kernel 可选：有则用，无则依赖镜像内置引导
        local kernel_bin
        kernel_bin="$(resolve_kernel 2>/dev/null)" || true
        if [ -n "$kernel_bin" ]; then
            QEMU_ARGS+=(-kernel "$kernel_bin")
        fi
    else
        # initramfs 模式 (minimal guest)
        local kernel_bin
        kernel_bin="$(resolve_kernel)" || { log_err "找不到 kernel"; return 1; }
        QEMU_ARGS+=(-kernel "$kernel_bin")

        if [ -z "$initrd_file" ]; then
            initrd_file="$(resolve_initrd "")" || true
        fi
        if [ -n "$initrd_file" ] && [ -f "$initrd_file" ]; then
            QEMU_ARGS+=(-initrd "$initrd_file")
        fi
        append_str="${append_str} init=/init"
    fi

    # 附加 append 参数
    [ -n "$extra_append" ] && append_str="${append_str} ${extra_append}"
    QEMU_ARGS+=(-append "$append_str")

    # ---- KVM 检测 ----
    if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
        QEMU_ARGS+=(-cpu host -enable-kvm)
        log_info "KVM 加速已启用"
    else
        QEMU_ARGS+=(-cpu max)
        log_warn "KVM 不可用，使用 TCG（较慢）"
    fi

    # ---- 启动信息 ----
    log_info "启动 QEMU..."
    log_info "  Transport: $transport"
    if [ "$transport" = "tcp" ]; then
        log_info "  端口基数: $port_base (占用 ${port_base}-$((port_base + 2)))"
        log_info "  实例 ID:  $instance_id"
        log_info "  提示: QEMU 将监听端口等待 VCS 连接，启动后终端无输出是正常的"
    else
        log_info "  SHM:    $shm_name"
        log_info "  Socket: $sock_path"
    fi
    if [ -n "$drive_file" ]; then
        log_info "  磁盘:   $drive_file"
    fi
    [ -n "${kernel_bin:-}" ] && log_info "  Kernel: $kernel_bin"
    [ -n "$initrd_file" ] && [ -f "$initrd_file" ] && log_info "  Initrd: $initrd_file"

    exec "$qemu_bin" "${QEMU_ARGS[@]}"
}

cmd_start_vcs() {
    local transport="shm"
    local role="A"
    local eth_shm="/cosim_eth0"
    local mac_last="1"
    local shm_name="/cosim0"
    local sock_path="/tmp/cosim0.sock"
    local remote_host=""
    local port_base="9100"
    local instance_id="0"
    local sim_timeout="600000"
    local test_name="cosim_test"

    while [ $# -gt 0 ]; do
        case "$1" in
            --transport)   transport="$2"; shift 2 ;;
            --role)        role="$2"; shift 2 ;;
            --eth-shm)     eth_shm="$2"; shift 2 ;;
            --mac-last)    mac_last="$2"; shift 2 ;;
            --shm)         shm_name="$2"; shift 2 ;;
            --sock)        sock_path="$2"; shift 2 ;;
            --remote-host) remote_host="$2"; shift 2 ;;
            --port-base)   port_base="$2"; shift 2 ;;
            --instance-id) instance_id="$2"; shift 2 ;;
            --timeout)     sim_timeout="$2"; shift 2 ;;
            --test)        test_name="$2"; shift 2 ;;
            *) log_err "未知选项: $1"; return 1 ;;
        esac
    done

    # 参数校验
    case "$transport" in
        shm|tcp) ;;
        *) log_err "无效 transport: $transport（可选: shm, tcp）"; return 1 ;;
    esac

    if [ "$transport" = "tcp" ] && [ -z "$remote_host" ]; then
        log_err "TCP 模式必须指定 --remote-host <QEMU机器IP>"
        return 1
    fi

    local simv_bin
    simv_bin="$(resolve_simv)" || { log_err "找不到 simv"; return 1; }
    local simv_dir
    simv_dir="$(dirname "$simv_bin")"

    local eth_role=0
    local eth_create=1
    if [ "$role" = "B" ] || [ "$role" = "b" ]; then
        eth_role=1
        eth_create=0
    fi

    # ---- 构建 simv 参数 ----
    local SIMV_ARGS=(
        +ETH_SHM="$eth_shm" +ETH_ROLE=$eth_role +ETH_CREATE=$eth_create
        +MAC_LAST="$mac_last"
        +UVM_TESTNAME="$test_name"
        +SIM_TIMEOUT_MS="$sim_timeout"
    )

    if [ "$transport" = "tcp" ]; then
        SIMV_ARGS+=(
            +transport=tcp
            +REMOTE_HOST="$remote_host"
            +PORT_BASE="$port_base"
            +INSTANCE_ID="$instance_id"
        )
    else
        SIMV_ARGS+=(
            +SHM_NAME="$shm_name"
            +SOCK_PATH="$sock_path"
        )
    fi

    # ---- 启动信息 ----
    log_info "启动 VCS simv..."
    log_info "  Transport: $transport"
    if [ "$transport" = "tcp" ]; then
        log_info "  远程 QEMU: $remote_host"
        log_info "  端口基数:  $port_base (连接 ${port_base}-$((port_base + 2)))"
        log_info "  实例 ID:   $instance_id"
        log_info "  提示: VCS 将连接 QEMU（最多重试 15 秒），请确保 QEMU 已启动"
    else
        log_info "  SHM:     $shm_name"
        log_info "  Socket:  $sock_path"
    fi
    log_info "  Role:    $role (ETH_ROLE=$eth_role)"
    log_info "  ETH SHM: $eth_shm"
    log_info "  MAC:     de:ad:be:ef:00:0$mac_last"
    log_info "  Test:    $test_name"
    log_info "  Timeout: ${sim_timeout}ms"

    cd "$simv_dir"
    exec ./simv "${SIMV_ARGS[@]}"
}

cmd_start_tap() {
    local eth_shm="/cosim_eth0"
    local ip_addr="${TAP_IP:-10.0.0.1}"
    local tap_dev="cosim0"

    while [ $# -gt 0 ]; do
        case "$1" in
            --eth-shm) eth_shm="$2"; shift 2 ;;
            --ip)      ip_addr="$2"; shift 2 ;;
            --tap-dev) tap_dev="$2"; shift 2 ;;
            *) log_err "未知选项: $1"; return 1 ;;
        esac
    done

    local tap_bin
    tap_bin="$(resolve_tap_bridge)" || { log_err "找不到 eth_tap_bridge"; return 1; }

    if [ ! -x "$tap_bin" ]; then
        log_err "eth_tap_bridge 不可执行: $tap_bin"
        return 1
    fi

    log_info "启动 eth_tap_bridge..."
    log_info "  ETH SHM: $eth_shm"
    log_info "  TAP dev: $tap_dev"
    log_info "  TAP IP:  $ip_addr/24"

    exec env PATH=/sbin:/usr/sbin:$PATH "$tap_bin" -s "$eth_shm" -t "$tap_dev" -i "$ip_addr/24"
}

# ============================================================
# status 命令
# ============================================================

cmd_status() {
    log_info "CoSim 进程状态"
    echo ""

    echo "--- QEMU 进程 ---"
    ps aux 2>/dev/null | grep -E "[q]emu.*cosim-pcie-rc" || echo "  (无)"

    echo ""
    echo "--- VCS simv 进程 ---"
    ps aux 2>/dev/null | grep -E "[s]imv.*SHM_NAME" || echo "  (无)"

    echo ""
    echo "--- eth_tap_bridge 进程 ---"
    ps aux 2>/dev/null | grep -E "[e]th_tap_bridge" || echo "  (无)"

    echo ""
    echo "--- 共享内存文件 (/dev/shm/cosim*) ---"
    ls -la /dev/shm/cosim* 2>/dev/null || echo "  (无)"

    echo ""
    echo "--- Socket 文件 (/tmp/cosim*.sock) ---"
    ls -la /tmp/cosim*.sock 2>/dev/null || echo "  (无)"

    echo ""
    echo "--- TAP 设备 ---"
    ip link show cosim0 2>/dev/null || echo "  (无)"
}

# ============================================================
# log 命令
# ============================================================

cmd_log() {
    local component="${1:-all}"

    # 找到最新的日志目录
    local latest_dir
    latest_dir=$(ls -dt /tmp/cosim_*/ 2>/dev/null | head -1)

    if [ -z "$latest_dir" ]; then
        log_warn "没有找到日志目录 (/tmp/cosim_*/)"
        return 1
    fi

    log_info "最新日志目录: $latest_dir"
    echo ""

    case "$component" in
        qemu)
            for f in "$latest_dir"/qemu*.log; do
                [ -f "$f" ] || continue
                echo "=== $(basename "$f") ==="
                tail -50 "$f"
                echo ""
            done
            ;;
        vcs)
            for f in "$latest_dir"/vcs*.log; do
                [ -f "$f" ] || continue
                echo "=== $(basename "$f") ==="
                tail -50 "$f"
                echo ""
            done
            ;;
        tap)
            for f in "$latest_dir"/tap*.log "$latest_dir"/host_ping.log; do
                [ -f "$f" ] || continue
                echo "=== $(basename "$f") ==="
                tail -50 "$f"
                echo ""
            done
            ;;
        all)
            for f in "$latest_dir"/*.log; do
                [ -f "$f" ] || continue
                echo "=== $(basename "$f") ==="
                tail -30 "$f"
                echo ""
            done
            ;;
        *)
            log_err "未知组件: $component (可选: qemu|vcs|tap|all)"
            return 1
            ;;
    esac
}

# ============================================================
# info 命令
# ============================================================

cmd_info() {
    log_info "CoSim Platform 构建信息"
    echo ""

    echo "--- 项目路径 ---"
    echo "  PROJECT_DIR: $PROJECT_DIR"
    echo ""

    echo "--- 二进制文件 ---"
    local qemu_path simv_path tap_path kernel_path
    qemu_path="$(resolve_qemu 2>/dev/null)" && echo "  QEMU:        $qemu_path" || echo "  QEMU:        (未找到)"
    simv_path="$(resolve_simv 2>/dev/null)" && echo "  simv:        $simv_path" || echo "  simv:        (未找到)"
    tap_path="$(resolve_tap_bridge 2>/dev/null)" && echo "  TAP bridge:  $tap_path" || echo "  TAP bridge:  (未找到)"
    kernel_path="$(resolve_kernel 2>/dev/null)" && echo "  Kernel:      $kernel_path" || echo "  Kernel:      (未找到)"
    echo ""

    echo "--- 版本信息 ---"
    if [ -n "${qemu_path:-}" ] && [ -x "${qemu_path:-}" ]; then
        echo -n "  QEMU 版本: "
        "$qemu_path" --version 2>/dev/null | head -1 || echo "(无法获取)"
    fi
    echo ""

    echo "--- 构建时间戳 ---"
    if [ -n "${qemu_path:-}" ] && [ -f "${qemu_path:-}" ]; then
        echo "  QEMU:       $(stat -c '%y' "$qemu_path" 2>/dev/null || echo '未知')"
    fi
    if [ -n "${simv_path:-}" ] && [ -f "${simv_path:-}" ]; then
        echo "  simv:       $(stat -c '%y' "$simv_path" 2>/dev/null || echo '未知')"
    fi
    if [ -n "${tap_path:-}" ] && [ -f "${tap_path:-}" ]; then
        echo "  TAP bridge: $(stat -c '%y' "$tap_path" 2>/dev/null || echo '未知')"
    fi
    echo ""

    echo "--- 网络配置 ---"
    echo "  Guest1 IP:  $GUEST1_IP  MAC: $GUEST1_MAC"
    echo "  Guest2 IP:  $GUEST2_IP  MAC: $GUEST2_MAC"
    echo "  TAP IP:     $TAP_IP     MAC: ${TAP_MAC:-de:ad:be:ef:00:02}"
    echo "  Guest 内存: $GUEST_MEMORY"
    echo ""

    echo "--- 超时设置 ---"
    echo "  Phase 5: ${PHASE5_TIMEOUT}s"
    echo "  TAP:     ${TAP_TIMEOUT}s"
}

# ============================================================
# test-guide: 交互式功能测试（跨机 TCP 模式）
# ============================================================

cmd_test_guide() {
    echo ""
    echo -e "${C_BOLD}============================================================${C_RESET}"
    echo -e "${C_BOLD}       CoSim 功能测试向导${C_RESET}"
    echo -e "${C_BOLD}============================================================${C_RESET}"
    echo ""
    echo "  前置条件:"
    echo "    - QEMU 已启动:  ./cosim.sh start qemu --transport tcp --port-base 9100"
    echo "    - VCS  已启动:  ./cosim.sh start vcs --transport tcp --remote-host <QEMU-IP>"
    echo "    - TAP  已启动:  ./cosim.sh start tap --eth-shm /cosim_eth0"
    echo ""
    echo -e "${C_BOLD}选择测试类型:${C_RESET}"
    echo ""
    echo "  1) ping 连通性测试"
    echo "     从 Guest (10.0.0.2) ping TAP (10.0.0.1)"
    echo "     验证: virtio TX → VCS VQ → ETH SHM → TAP → 回复 → Guest RX"
    echo ""
    echo "  2) iperf3 吞吐量测试"
    echo "     TAP 侧启动 iperf3 server，Guest 侧作为 client"
    echo "     验证: 端到端 TCP/UDP 吞吐量"
    echo ""
    echo "  3) arping ARP 测试"
    echo "     从 Guest 发 ARP 请求到 TAP 侧"
    echo "     验证: L2 层连通性"
    echo ""
    echo "  4) 批量 ping 压力测试"
    echo "     发送 200 个 ping 包（长超时），验证持续稳定性"
    echo ""
    echo "  5) 显示测试环境信息"
    echo ""

    local choice
    read -rp "请选择 [1-5]: " choice

    case "$choice" in
        1) test_guide_ping ;;
        2) test_guide_iperf ;;
        3) test_guide_arping ;;
        4) test_guide_ping_stress ;;
        5) test_guide_info ;;
        *) log_err "无效选择"; return 1 ;;
    esac
}

test_guide_info() {
    echo ""
    log_info "测试环境配置:"
    echo "  Guest IP:  10.0.0.2/24  (virtio-net eth0)"
    echo "  TAP IP:    10.0.0.1/24  (cosim0)"
    echo "  Guest MAC: de:ad:be:ef:00:01"
    echo "  TAP MAC:   由 eth_tap_bridge 自动分配"
    echo ""
    echo "  Guest 内部需要执行的配置命令:"
    echo "    ip addr add 10.0.0.2/24 dev eth0"
    echo "    ip link set eth0 up"
    echo "    arp -s 10.0.0.1 <TAP的MAC地址>"
    echo ""
    echo "  TAP 侧（VCS 机器）需要执行的配置:"
    echo "    # 查看 TAP MAC:"
    echo "    ip link show cosim0"
    echo "    # 添加静态 ARP（Guest MAC）:"
    echo "    ip neigh add 10.0.0.2 lladdr de:ad:be:ef:00:01 dev cosim0 nud permanent"
    echo ""
    echo "  注意事项:"
    echo "    - 仿真速度较慢，每个 TLP 往返约 5-10 秒"
    echo "    - ping 超时建议设为 600 秒以上"
    echo "    - iperf 测试需要 Guest 中安装 iperf3"
}

test_guide_ping() {
    local count="${1:-5}"
    echo ""
    log_info "=== Ping 连通性测试 ==="
    echo ""
    echo "  测试方案: Guest (10.0.0.2) → TAP (10.0.0.1)"
    echo "  包数: $count"
    echo "  超时: 每包 600 秒（仿真速度较慢）"
    echo ""
    echo -e "  ${C_BOLD}步骤 1 — 在 Guest 串口中执行:${C_RESET}"
    echo "    ip addr add 10.0.0.2/24 dev eth0"
    echo "    ip link set eth0 up"
    echo "    arp -s 10.0.0.1 <TAP侧cosim0的MAC>  # 通过 ip link show cosim0 查看"
    echo "    ping -c $count -W 600 10.0.0.1"
    echo ""
    echo -e "  ${C_BOLD}步骤 2 — 在 VCS 机器上监控:${C_RESET}"
    echo "    # 查看 TAP 收发统计"
    echo "    watch -n 5 'tail -1 /tmp/eth_tap_bridge.log'"
    echo ""
    echo "    # 查看 VCS VQ-TX 转发计数"
    echo "    grep -c 'VQ-TX.*Forwarded' /tmp/vcs_e2e.log"
    echo ""
    echo -e "  ${C_BOLD}步骤 3 — 在 QEMU 机器上监控:${C_RESET}"
    echo "    grep -c 'DMA read OK' /tmp/qemu_e2e.log"
    echo "    grep -c 'DMA write OK' /tmp/qemu_e2e.log"
    echo "    grep -c 'MSI' /tmp/qemu_e2e.log"
    echo ""
    echo -e "  ${C_BOLD}成功标志:${C_RESET}"
    echo "    - Guest 收到 ping reply (0% packet loss)"
    echo "    - VCS VQ-TX Forwarded 计数 >= $count"
    echo "    - QEMU DMA write 计数递增（RX 注入 Guest）"
    echo "    - MSI 计数递增（中断通知 Guest）"
}

test_guide_iperf() {
    echo ""
    log_info "=== iperf3 吞吐量测试 ==="
    echo ""
    echo "  前置: Guest rootfs 需包含 iperf3（buildroot menuconfig 启用）"
    echo ""
    echo -e "  ${C_BOLD}步骤 1 — 在 VCS 机器（TAP 侧）启动 server:${C_RESET}"
    echo "    iperf3 -s -B 10.0.0.1 -p 5201"
    echo ""
    echo -e "  ${C_BOLD}步骤 2 — 在 Guest 串口中执行:${C_RESET}"
    echo "    ip addr add 10.0.0.2/24 dev eth0"
    echo "    ip link set eth0 up"
    echo "    arp -s 10.0.0.1 <TAP侧cosim0的MAC>"
    echo ""
    echo "    # TCP 测试（默认 10 秒）"
    echo "    iperf3 -c 10.0.0.1 -p 5201 -t 10"
    echo ""
    echo "    # UDP 测试"
    echo "    iperf3 -c 10.0.0.1 -p 5201 -u -b 1M -t 10"
    echo ""
    echo "  注意:"
    echo "    - 仿真速度限制，实际吞吐量远低于真实网络"
    echo "    - 建议先用 ping 确认连通性后再测 iperf"
    echo "    - 超时可能需要加大: iperf3 -c ... --connect-timeout 60000"
}

test_guide_arping() {
    echo ""
    log_info "=== ARP 连通性测试 ==="
    echo ""
    echo "  测试方案: Guest 发 ARP 请求到 TAP 侧"
    echo ""
    echo -e "  ${C_BOLD}在 Guest 串口中执行:${C_RESET}"
    echo "    ip addr add 10.0.0.2/24 dev eth0"
    echo "    ip link set eth0 up"
    echo "    arping -c 3 -I eth0 10.0.0.1"
    echo ""
    echo -e "  ${C_BOLD}成功标志:${C_RESET}"
    echo "    - arping 收到 reply"
    echo "    - VCS 日志出现 VQ-TX Forwarded"
    echo "    - TAP bridge 日志 SHM->TAP 计数递增"
}

test_guide_ping_stress() {
    echo ""
    log_info "=== 批量 Ping 压力测试（200 包）==="
    echo ""
    echo -e "  ${C_BOLD}在 Guest 串口中执行:${C_RESET}"
    echo "    ip addr add 10.0.0.2/24 dev eth0"
    echo "    ip link set eth0 up"
    echo "    arp -s 10.0.0.1 <TAP侧cosim0的MAC>"
    echo "    ping -c 200 -W 600 -i 0 10.0.0.1 > /tmp/ping200.txt 2>&1 &"
    echo ""
    echo -e "  ${C_BOLD}监控进度（在 VCS 机器上）:${C_RESET}"
    echo "    watch -n 10 'echo \"TX: \$(grep -c VQ-TX.*Forwarded /tmp/vcs_e2e.log)"
    echo "      RX: \$(grep -c VIP-VQ.*RX.injected /tmp/vcs_e2e.log)"
    echo "      TAP: \$(tail -1 /tmp/eth_tap_bridge.log)\"'"
    echo ""
    echo "  预估时间: 根据仿真速度，可能需要数小时"
    echo "  成功标志: TX Forwarded >= 200, Guest /tmp/ping200.txt 显示收到 reply"
}

# ============================================================
# test 命令路由
# ============================================================

cmd_test() {
    local mode="${1:-}"
    shift 2>/dev/null || true

    case "$mode" in
        phase1)
            run_single_phase "phase1" "Phase 1: Config Space 测试（单 QEMU + VCS）" 120
            ;;
        phase2)
            run_single_phase "phase2" "Phase 2: MMIO + MSI/DMA 测试" 120
            ;;
        phase3)
            run_single_phase "phase3" "Phase 3: Virtio-net 单向 TX 测试" 120
            ;;
        phase4)
            run_dual_phase "phase4" "Phase 4: 双向网络 Ping 测试（双 VCS）" 120
            ;;
        phase5)
            run_dual_phase "phase5" "Phase 5: TCP/iperf 吞吐测试（双 VCS）" "${PHASE5_TIMEOUT}"
            ;;
        tap)
            run_tap_test
            ;;
        unit)
            run_unit_tests
            ;;
        integration)
            run_integration_tests
            ;;
        all)
            run_all_tests
            ;;
        "")
            log_err "请指定测试模式"
            echo ""
            echo "可用模式: phase1, phase2, phase3, phase4, phase5, tap, unit, integration, all"
            return 1
            ;;
        *)
            log_err "未知测试模式: $mode"
            echo ""
            echo "可用模式: phase1, phase2, phase3, phase4, phase5, tap, unit, integration, all"
            return 1
            ;;
    esac
}

# ============================================================
# start 命令路由
# ============================================================

cmd_start() {
    local component="${1:-}"
    shift 2>/dev/null || true

    case "$component" in
        qemu) cmd_start_qemu "$@" ;;
        vcs)  cmd_start_vcs "$@" ;;
        tap)  cmd_start_tap "$@" ;;
        "")
            log_err "请指定要启动的组件"
            echo ""
            echo "可用组件: qemu, vcs, tap"
            return 1
            ;;
        *)
            log_err "未知组件: $component"
            echo ""
            echo "可用组件: qemu, vcs, tap"
            return 1
            ;;
    esac
}

# ============================================================
# 主入口
# ============================================================

main() {
    load_config

    local command="${1:-}"
    shift 2>/dev/null || true

    case "$command" in
        test)    cmd_test "$@" ;;
        test-guide) cmd_test_guide "$@" ;;
        start)   cmd_start "$@" ;;
        status)  cmd_status ;;
        clean)   cleanup_all ;;
        log)     cmd_log "$@" ;;
        info)    cmd_info ;;
        help|--help|-h)
            show_help
            ;;
        "")
            show_help
            return 1
            ;;
        *)
            log_err "未知命令: $command"
            echo ""
            show_help
            return 1
            ;;
    esac
}

main "$@"
