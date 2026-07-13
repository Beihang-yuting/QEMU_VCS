#!/bin/bash
# build_cosim_lib.sh — 把 cosim bridge 的 C 侧打成静态库 libcosim_bridge.a，
# 供外部 UVM 平台直接链接（vcs -LDFLAGS "-L<out> -lcosim_bridge -lrt -lpthread"）。
#
# 用法:
#   ./scripts/build_cosim_lib.sh            # 默认: PCIe MMIO 通路
#   ./scripts/build_cosim_lib.sh --with-eth # 追加 ETH 数据面 C 文件
#   CC=<vcs自带gcc> ./scripts/build_cosim_lib.sh   # 用 VCS 的 gcc 保证 ABI 兼容
#
# 关键: 编库的 gcc 应与 VCS 用的 gcc ABI 兼容 —— 最稳用 $VCS_HOME/.../gcc。
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
OUT="${OUT:-$ROOT/build/lib}"
CC="${CC:-gcc}"
AR="${AR:-ar}"

CFLAGS="-std=c11 -D_DEFAULT_SOURCE -O2 -fPIC -Wall -Wextra -Wno-unused-parameter"
INCS="-I $ROOT/bridge/common -I $ROOT/bridge/vcs -I $ROOT/bridge/qemu -I $ROOT/bridge/eth"

# ---- PCIe MMIO 通路（2-RC DPI 全在 bridge_vcs.c）----
SRCS=(
  bridge/vcs/bridge_vcs.c
  bridge/vcs/sock_sync_vcs.c
  bridge/common/shm_layout.c
  bridge/common/ring_buffer.c
  bridge/common/dma_manager.c
  bridge/common/trace_log.c
  bridge/common/transport_shm.c
  bridge/common/transport_tcp.c
  bridge/common/eth_shm.c          # transport_shm.c 依赖 eth_shm_* 符号，必带
)

# ---- 可选 ETH 数据面（完整 eth 通路，MMIO-only 不需要）----
if [ "$1" = "--with-eth" ]; then
  SRCS+=(
    bridge/common/link_model.c
    bridge/eth/eth_mac_dpi.c
    bridge/eth/eth_port.c
    bridge/vcs/virtqueue_dma.c
  )
fi

mkdir -p "$OUT"
OBJS=()
echo "[build] CC=$CC  OUT=$OUT"
for src in "${SRCS[@]}"; do
  obj="$OUT/$(basename "${src%.c}").o"
  echo "  CC  $src"
  $CC $CFLAGS $INCS -c "$ROOT/$src" -o "$obj"
  OBJS+=("$obj")
done

LIB="$OUT/libcosim_bridge.a"
rm -f "$LIB"
$AR rcs "$LIB" "${OBJS[@]}"
echo "[build] archived: $LIB"
$AR t "$LIB" | sed 's/^/  - /'
echo
echo "[link 示例]"
echo "  vcs ... \\"
echo "    -CFLAGS \"-I $ROOT/bridge/common -I $ROOT/bridge/vcs\" \\"
echo "    -LDFLAGS \"-L$OUT -lcosim_bridge -Wl,--no-as-needed -lrt -lpthread\" \\"
echo "    $ROOT/bridge/vcs/bridge_vcs.sv <你的 uvm 文件...>"
