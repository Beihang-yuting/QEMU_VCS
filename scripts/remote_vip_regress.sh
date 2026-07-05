#!/usr/bin/env bash
# remote_vip_regress.sh — 在远程 VCS 机上编译+回归 pcie_tl_vip 独立测试集
# (multi-root / unified-mem / 向后兼容 smoke)。本机无 VCS，故推到远程跑。
#
# 用法（默认指向 61，可用环境变量覆盖）:
#   REMOTE=ryan@10.11.10.61 SSH_PORT=2222 DEST=/tmp/cosim-vip-regress \
#   ENVSH=/home/ryan/set-env.sh  scripts/remote_vip_regress.sh
#
# 只推 pcie_tl_vip/ + third_party/host_mem/（standalone VIP 回归所需最小集），
# 不含 bridge/vcs-tb（那是 cosim 集成构建，走 make vcs-vip）。
# standalone 回归**不**定义 PCIE_COSIM_ENABLE（无 bridge DPI 可链）。
set -euo pipefail

REMOTE="${REMOTE:-ryan@10.11.10.61}"
SSH_PORT="${SSH_PORT:-2222}"
DEST="${DEST:-/tmp/cosim-vip-regress}"
ENVSH="${ENVSH:-/home/ryan/set-env.sh}"
SSH="ssh -p ${SSH_PORT} ${REMOTE}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TESTS=(
  pcie_tl_base_test               # 基础
  pcie_tl_smoke_mem_test          # 向后兼容：num_usp=1 mem roundtrip，回归零漂移基准
  pcie_tl_smoke_cfg_test
  pcie_tl_smoke_err_test
  pcie_tl_smoke_fc_test
  pcie_tl_smoke_ordering_test
  pcie_tl_stress_test             # advanced 压测
  pcie_tl_unified_mem_test        # 统一内存 PER_BUFFER 双向
  pcie_tl_switch_unified_mem_test
  pcie_tl_multi_root_route_test   # 多根路由
  pcie_tl_cross_root_isolation_test
  pcie_tl_uneven_ownership_test
  pcie_tl_per_root_tag_test
  pcie_tl_multi_root_stress_test
)

echo "==> [1/4] 推送 pcie_tl_vip + third_party/host_mem 到 ${REMOTE}:${DEST}"
$SSH "mkdir -p ${DEST}/pcie_tl_vip ${DEST}/third_party"
tar --exclude='.git' -cf - pcie_tl_vip third_party/host_mem \
  | $SSH "tar -C ${DEST} -xf -"

echo "==> [2/4] 远程编译 (filelist_local.f)"
$SSH "source ${ENVSH} >/dev/null 2>&1; cd ${DEST} && \
  mkdir -p pcie_tl_vip/sim/logs && \
  vcs -sverilog -full64 -ntb_opts uvm-1.2 -timescale=1ns/1ps \
      -f pcie_tl_vip/sim/filelist_local.f \
      -o pcie_tl_vip/sim/simv -l pcie_tl_vip/sim/logs/compile.log" \
  || { echo '!! 编译失败，看 compile.log'; $SSH "tail -40 ${DEST}/pcie_tl_vip/sim/logs/compile.log"; exit 1; }
echo "   编译 OK"

echo "==> [3/4] 逐用例跑"
FAIL=0
for t in "${TESTS[@]}"; do
  $SSH "source ${ENVSH} >/dev/null 2>&1; cd ${DEST}/pcie_tl_vip/sim && \
    ./simv +UVM_TESTNAME=${t} +UVM_VERBOSITY=UVM_MEDIUM -l logs/run_${t}.log >/dev/null 2>&1 || true"
  RES=$($SSH "cd ${DEST}/pcie_tl_vip/sim && \
    E=\$(grep -aoE 'UVM_ERROR +: +[0-9]+' logs/run_${t}.log | tail -1); \
    F=\$(grep -aoE 'UVM_FATAL +: +[0-9]+' logs/run_${t}.log | tail -1); \
    echo \"\$E | \$F\"")
  if echo "$RES" | grep -qE 'UVM_ERROR +: +0' && echo "$RES" | grep -qE 'UVM_FATAL +: +0'; then
    printf '   [PASS] %-34s %s\n' "$t" "$RES"
  else
    printf '   [FAIL] %-34s %s\n' "$t" "$RES"; FAIL=1
  fi
done

echo "==> [4/4] 日志在 ${REMOTE}:${DEST}/pcie_tl_vip/sim/logs/"
[ "$FAIL" -eq 0 ] && echo "全部 PASS" || { echo "有 FAIL，见上"; exit 1; }
