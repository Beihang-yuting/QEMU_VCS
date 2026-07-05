#!/usr/bin/env bash
# remote_xilinx_adapter.sh — 在远程 VCS 机上编译+跑 xilinx PCIe adapter 端到端。
# 本机无 VCS，推 vendored 子集到远程编译。adapter 协议层委托 pcie_tl_vip，
# 工厂 override 接入，SV_IF 模式，薄 e2e_checker 校验 req<->cpl。
#
# 用法（默认 61，可环境变量覆盖）:
#   REMOTE=ryan@10.11.10.61 SSH_PORT=2222 DEST=/tmp/xbuild-cosim \
#   ENVSH=/home/ryan/set-env.sh  scripts/remote_xilinx_adapter.sh
set -euo pipefail

REMOTE="${REMOTE:-ryan@10.11.10.61}"
SSH_PORT="${SSH_PORT:-2222}"
DEST="${DEST:-/tmp/xbuild-cosim}"
ENVSH="${ENVSH:-/home/ryan/set-env.sh}"
SSH="ssh -p ${SSH_PORT} ${REMOTE}"
FL="third_party/xilinx_pcie/sim/filelist_adapter_local.f"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 功能用例（判据 UVM_ERROR=0 & UVM_FATAL=0）
FUNC_TESTS=(
  xilinx_pcie_adapter_smoke_test
  xilinx_pcie_adapter_rdwr_test
  xilinx_pcie_adapter_backpressure_test
  xilinx_pcie_adapter_enum_dma_test
  xilinx_pcie_adapter_cfg_test
)
# 诊断用例（跑但不作 pass/fail 门，见 integration_guide §6）
DIAG_TESTS=( xilinx_pcie_adapter_err_poisoned_test xilinx_pcie_adapter_no_rc_test )

echo "==> [1/4] 推送 vendored 子集到 ${REMOTE}:${DEST}"
$SSH "mkdir -p ${DEST}"
tar --exclude='.git' -cf - pcie_tl_vip third_party/axis_vip third_party/host_mem third_party/xilinx_pcie \
  | $SSH "tar -C ${DEST} -xf -"

run_matrix() {   # $1=DATA_WIDTH  $2=STRADDLE_EN
  local DW="$1" STR="$2" TAG="dw${1}_str${2}"
  echo "==> 编译 DATA_WIDTH=${DW} STRADDLE_EN=${STR}"
  $SSH "source ${ENVSH} >/dev/null 2>&1; cd ${DEST} && mkdir -p work logs && \
    vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
        -f ${FL} +define+DATA_WIDTH=${DW} +define+STRADDLE_EN=${STR} \
        -o work/simv_${TAG} -l logs/compile_${TAG}.log" \
    || { echo "!! 编译失败 ${TAG}"; $SSH "tail -40 ${DEST}/logs/compile_${TAG}.log"; return 1; }
  local t RES
  for t in "${FUNC_TESTS[@]}"; do
    $SSH "source ${ENVSH} >/dev/null 2>&1; cd ${DEST} && \
      ./work/simv_${TAG} +UVM_TESTNAME=${t} +DATA_WIDTH=${DW} +STRADDLE_EN=${STR} \
        +ntb_random_seed=1 +UVM_VERBOSITY=UVM_MEDIUM -l logs/${t}_${TAG}.log >/dev/null 2>&1 || true"
    RES=$($SSH "cd ${DEST} && \
      E=\$(grep -aoE 'UVM_ERROR +: +[0-9]+' logs/${t}_${TAG}.log | tail -1); \
      F=\$(grep -aoE 'UVM_FATAL +: +[0-9]+' logs/${t}_${TAG}.log | tail -1); echo \"\$E | \$F\"")
    if echo "$RES" | grep -qE 'UVM_ERROR +: +0' && echo "$RES" | grep -qE 'UVM_FATAL +: +0'; then
      printf '   [PASS] %-40s %-12s %s\n' "$t" "$TAG" "$RES"
    else
      printf '   [FAIL] %-40s %-12s %s\n' "$t" "$TAG" "$RES"; FAILED=1
    fi
  done
  for t in "${DIAG_TESTS[@]}"; do
    $SSH "source ${ENVSH} >/dev/null 2>&1; cd ${DEST} && \
      ./work/simv_${TAG} +UVM_TESTNAME=${t} +DATA_WIDTH=${DW} +STRADDLE_EN=${STR} \
        +ntb_random_seed=1 -l logs/${t}_${TAG}.log >/dev/null 2>&1 || true"
    printf '   [DIAG] %-40s %-12s (见 logs/%s_%s.log)\n' "$t" "$TAG" "$t" "$TAG"
  done
}

echo "==> [2/4] DW256 直通 (STRADDLE=0)"; FAILED=0; run_matrix 256 0
echo "==> [3/4] DW512 直通 (STRADDLE=0)"; run_matrix 512 0
echo "==> [4/4] DW256 straddle (STRADDLE=1)"; run_matrix 256 1

echo "日志: ${REMOTE}:${DEST}/logs/"
[ "${FAILED:-0}" -eq 0 ] && echo "功能用例全部 PASS" || { echo "有 FAIL，见上"; exit 1; }
