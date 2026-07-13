#!/bin/bash
# build_cosim_multirc.sh — 编译 & 运行 2-RC cosim over Xilinx-AXIS testbench。
#
# 在 61 (VCS 机) 上跑。依赖三个库(可用环境变量覆盖路径):
#   AXIS_VIP   (default /home/ubuntu/ryan/axis_work/axis_vip)
#   PCIE_TL    (default /home/ubuntu/ryan/pcie_work/pcie_tl_vip)
#   HOST_MEM   (default /home/ubuntu/ryan/shm_work/host_mem)
#   XILINX     (default /home/ubuntu/ryan/xilinx_pcie)
#
# 用法:
#   ./scripts/build_cosim_multirc.sh build          # 只编译出 simv
#   ./scripts/build_cosim_multirc.sh run            # 编译+运行(默认 2 RC, REMOTE_HOST=10.11.10.53)
#   REMOTE_HOST=10.11.10.53 PORT_BASE=9000 ./scripts/build_cosim_multirc.sh run
#
# 注: C 用 VCS 的 -CFLAGS inline 编译(与 VCS gcc 同 ABI)。想用 .a 见 build_cosim_lib.sh。
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COSIM="$(dirname "$SCRIPT_DIR")"
OUT="${OUT:-$COSIM/build/cosim_multirc}"

AXIS_VIP="${AXIS_VIP:-/home/ubuntu/ryan/axis_work/axis_vip}"
PCIE_TL="${PCIE_TL:-/home/ubuntu/ryan/pcie_work/pcie_tl_vip}"
HOST_MEM="${HOST_MEM:-/home/ubuntu/ryan/shm_work/host_mem}"
XILINX="${XILINX:-/home/ubuntu/ryan/xilinx_pcie}"
DATA_WIDTH="${DATA_WIDTH:-256}"

VCS_TEST="cosim_xrc_test"
TOP="tb_cosim_multirc_top"

# ---- cosim C 源(PCIe MMIO 通路，与 VCS gcc 同 ABI，inline 编) ----
CSRCS=(
  "$COSIM/bridge/vcs/bridge_vcs.c"
  "$COSIM/bridge/vcs/sock_sync_vcs.c"
  "$COSIM/bridge/common/shm_layout.c"
  "$COSIM/bridge/common/ring_buffer.c"
  "$COSIM/bridge/common/dma_manager.c"
  "$COSIM/bridge/common/trace_log.c"
  "$COSIM/bridge/common/transport_shm.c"
  "$COSIM/bridge/common/transport_tcp.c"
  "$COSIM/bridge/common/eth_shm.c"        # transport_shm.c 依赖 eth_shm_* 符号
)
VCS_CFLAGS="-std=gnu11 -D_DEFAULT_SOURCE -I $COSIM/bridge/common -I $COSIM/bridge/vcs -I $COSIM/bridge/qemu"
VCS_LDFLAGS="-Wl,--no-as-needed -lrt -lpthread"

gen_filelist() {
  mkdir -p "$OUT"
  local f="$OUT/filelist.f"
  {
    echo "+incdir+$AXIS_VIP/src"
    echo "+incdir+$PCIE_TL/src"
    echo "+incdir+$HOST_MEM/src"
    echo "+incdir+$XILINX/src"
    echo "+incdir+$XILINX/tb"
    echo "+incdir+$COSIM/bridge/vcs"
    echo "+incdir+$COSIM/vcs-tb"
    echo "$AXIS_VIP/src/axis_if.sv"
    echo "$AXIS_VIP/src/axis_pkg.sv"
    echo "$HOST_MEM/src/host_mem_pkg.sv"
    echo "$HOST_MEM/src/host_mem_manager.sv"
    echo "$PCIE_TL/src/pcie_tl_if.sv"
    echo "$PCIE_TL/src/pcie_tl_pkg.sv"
    echo "$XILINX/src/adapter/xilinx_pcie_adapter_pkg.sv"
    echo "$XILINX/src/interface/xilinx_pcie_if.sv"
    echo "$XILINX/src/interface/xilinx_pcie_cfg_if.sv"
    echo "$COSIM/bridge/vcs/bridge_vcs.sv"          # cosim_bridge_pkg (DPI)
    echo "$COSIM/vcs-tb/cosim_xrc_pkg.sv"           # env_config + driver + test
    echo "$COSIM/vcs-tb/tb_cosim_multirc_top.sv"    # top
  } > "$f"
  echo "$f"
}

do_build() {
  local f; f="$(gen_filelist)"
  echo "[build] filelist: $f"
  ( cd "$OUT" && vcs -full64 -sverilog -timescale=1ns/1ps +v2k -debug_access+all -cc gcc \
      -ntb_opts uvm-1.2 \
      +define+DATA_WIDTH=$DATA_WIDTH \
      -CFLAGS "$VCS_CFLAGS" -LDFLAGS "$VCS_LDFLAGS" \
      -f "$f" "${CSRCS[@]}" \
      -top "$TOP" -o "$OUT/simv_cosim_mrc" -l "$OUT/compile.log" )
  echo "[build] simv: $OUT/simv_cosim_mrc"
}

do_run() {
  [ -x "$OUT/simv_cosim_mrc" ] || do_build
  local host="${REMOTE_HOST:-10.11.10.53}"
  local pbase="${PORT_BASE:-9000}"
  local nrc="${NUM_RC:-2}"
  echo "[run] NUM_RC=$nrc REMOTE_HOST=$host PORT_BASE=$pbase"
  ( cd "$OUT" && ./simv_cosim_mrc \
      +UVM_TESTNAME=$VCS_TEST +UVM_VERBOSITY=UVM_MEDIUM \
      +NUM_RC=$nrc +REMOTE_HOST=$host +PORT_BASE=$pbase \
      ${EXTRA_PLUSARGS:-} \
      -l "$OUT/run.log" )
}

case "${1:-run}" in
  build) do_build ;;
  run)   do_run ;;
  *) echo "usage: $0 [build|run]"; exit 1 ;;
esac
