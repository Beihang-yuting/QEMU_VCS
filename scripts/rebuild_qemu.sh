#!/bin/bash
# rebuild_qemu.sh — QEMU 侧重编封装。在 QEMU 机(如 53)上跑。
#
# cosim 的 QEMU 侧有两个独立产物,改动位置决定重编哪个:
#   1) bridge 库  build/bridge/libcosim_bridge.so   ← QEMU 动态链接(rpath)
#        触发: bridge/qemu/*.c   bridge/common/*.c   (如 tag_mask、transport)
#        重编: make bridge        (cmake;ninja 不管这个!)
#   2) QEMU 设备模型  qemu-system-x86_64
#        触发: qemu-plugin/cosim_pcie_{rc,pf,vf}.c  (设备模型本身)
#        重编: ninja -C third_party/qemu/build qemu-system-x86_64
#
# 用法:
#   ./scripts/rebuild_qemu.sh bridge     # 只重建 libcosim_bridge.so
#   ./scripts/rebuild_qemu.sh device     # 只重编 qemu-system-x86_64(设备模型)
#   ./scripts/rebuild_qemu.sh all        # 两个都(默认)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
SO="$ROOT/build/bridge/libcosim_bridge.so"
QEMU_BUILD="$ROOT/third_party/qemu/build"
QEMU_BIN="$QEMU_BUILD/qemu-system-x86_64"

mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

rebuild_bridge() {
  echo "[rebuild_qemu] bridge 库: make bridge"
  local before; before="$(mtime "$SO")"
  ( cd "$ROOT" && make bridge )
  local after; after="$(mtime "$SO")"
  if [ ! -f "$SO" ]; then echo "[错误] .so 未生成: $SO"; exit 1; fi
  if [ "$after" -gt "$before" ]; then
    echo "[OK] libcosim_bridge.so 已更新 ($(date -d @"$after" +%H:%M:%S))"
  else
    echo "[注意] .so mtime 未变 —— 可能无改动或 make 判定无需重编"
  fi
  echo "      $SO"
}

rebuild_device() {
  [ -f "$QEMU_BUILD/build.ninja" ] || { echo "[错误] 无 qemu build: $QEMU_BUILD"; exit 1; }
  echo "[rebuild_qemu] 设备模型: ninja qemu-system-x86_64"
  local before; before="$(mtime "$QEMU_BIN")"
  # 触碰设备源确保重编(bridge_qemu.h 变化等依赖)
  touch "$ROOT/third_party/qemu/hw/net/cosim_pcie_rc.c" \
        "$ROOT/third_party/qemu/hw/net/cosim_pcie_pf.c" \
        "$ROOT/third_party/qemu/hw/net/cosim_pcie_vf.c" 2>/dev/null || true
  ninja -C "$QEMU_BUILD" qemu-system-x86_64
  local after; after="$(mtime "$QEMU_BIN")"
  [ "$after" -gt "$before" ] && echo "[OK] qemu-system-x86_64 已更新 ($(date -d @"$after" +%H:%M:%S))" \
                             || echo "[注意] qemu binary mtime 未变"
  echo "      $QEMU_BIN"
}

case "${1:-all}" in
  bridge) rebuild_bridge ;;
  device) rebuild_device ;;
  all)    rebuild_bridge; echo; rebuild_device ;;
  *) echo "usage: $0 [bridge|device|all]"; exit 1 ;;
esac
echo
echo "[提示] QEMU 通过 rpath 链 $SO —— 重建 .so 后直接重启 QEMU 即加载新库(无需 relink QEMU)。"
