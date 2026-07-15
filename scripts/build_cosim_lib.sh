#!/bin/bash
# build_cosim_lib.sh — 把 cosim bridge 的 C 侧打成库，供外部 UVM 平台链接。
# 产出两份: libcosim_bridge.a(静态) + libcosim_bridge.so(共享)。
# 推荐用 .so 走 vcs -sv_lib（运行期 dlopen，DPI 符号不会被链接器 strip）。
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
# ETH 版的 eth_mac_dpi.c 用 svGetArrayPtr(svdpi.h),需 VCS 头;设了 VCS_HOME 就带上。
[ -n "$VCS_HOME" ] && INCS="$INCS -I $VCS_HOME/include"

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
  if [ -z "$VCS_HOME" ]; then
    echo "[warn] --with-eth 里 eth_mac_dpi.c 需要 svdpi.h(VCS 头),但 VCS_HOME 未设。" >&2
    echo "[warn] 请用 VCS gcc 编: CC=\$VCS_HOME/.../gcc VCS_HOME=<vcs> $0 --with-eth" >&2
  fi
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

# ---- 共享库 libcosim_bridge.so（供 VCS -sv_lib 运行期 dlopen）----
# 走 -sv_lib 时 VCS 用 dlsym 找 DPI 符号，不存在静态归档成员被 strip 的问题。
# .so 自带 -lrt -lpthread，自包含。
SO="$OUT/libcosim_bridge.so"
rm -f "$SO"
$CC -shared -o "$SO" "${OBJS[@]}" -lrt -lpthread
echo "[build] shared:   $SO"

echo
echo "[link 示例 — 推荐: -sv_lib 导 .so]"
echo "  vcs ... \\"
echo "    -CFLAGS \"-I $ROOT/bridge/common -I $ROOT/bridge/vcs\" \\"
echo "    -sv_lib $OUT/libcosim_bridge \\"
echo "    $ROOT/bridge/vcs/bridge_vcs.sv <你的 uvm 文件...>"
echo "  # 注: -sv_lib 路径不带 .so 后缀；运行 simv 前确保能找到 .so:"
echo "  #   export LD_LIBRARY_PATH=$OUT:\$LD_LIBRARY_PATH"
echo
echo "[link 示例 — 备选: 静态 .a 全归档链接]"
echo "  vcs ... \\"
echo "    -CFLAGS \"-I $ROOT/bridge/common -I $ROOT/bridge/vcs\" \\"
echo "    -LDFLAGS \"-Wl,--whole-archive $LIB -Wl,--no-whole-archive -lrt -lpthread\" \\"
echo "    $ROOT/bridge/vcs/bridge_vcs.sv <你的 uvm 文件...>"
