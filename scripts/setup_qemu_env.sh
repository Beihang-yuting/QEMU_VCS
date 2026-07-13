#!/bin/bash
# setup_qemu_env.sh — QEMU 侧隔离环境。只管起 QEMU + guest,吐连接描述符。
# 不碰 VCS / RTL —— VCS 环境读 cosim-conn.json 自行连接。
#
# 每个 RC = 一个 QEMU 实例(cosim-pcie-rc, transport=tcp, 同 port_base, instance_id=r)。
# QEMU 是 TCP server(先起、listen);VCS 后连。端口 = port_base + instance_id*3。
#
# 用法:
#   ./scripts/setup_qemu_env.sh up            # 起 NUM_RC 个 QEMU + 写 cosim-conn.json,前台守着
#   ./scripts/setup_qemu_env.sh descriptor    # 只写 cosim-conn.json(QEMU 你自己另起时用)
#   NUM_RC=2 PORT_BASE=9100 ADVERTISE_HOST=10.11.10.53 ./scripts/setup_qemu_env.sh up
#
# 关键环境变量:
#   NUM_RC(1) PORT_BASE(9100) TRANSPORT(tcp)
#   ADVERTISE_HOST(本机首个 IP)  —— 写进描述符给 VCS 连
#   GUEST_TYPE(ubuntu) QEMU KERNEL ROOTFS GUEST_MEMORY(256M)
#   DEV_VENDOR(0x1af4) DEV_DEVICE(0x1041) DEV_BAR0_SIZE(0x10000)  —— 描述符里给 VCS config_proxy 对齐
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
RUN_DIR="${RUN_DIR:-$ROOT/run}"
LOG_DIR="${LOG_DIR:-$RUN_DIR/log}"
CONN_JSON="${CONN_JSON:-$RUN_DIR/cosim-conn.json}"

NUM_RC="${NUM_RC:-1}"
PORT_BASE="${PORT_BASE:-9100}"
TRANSPORT="${TRANSPORT:-tcp}"
ADVERTISE_HOST="${ADVERTISE_HOST:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
GUEST_TYPE="${GUEST_TYPE:-ubuntu}"
GUEST_MEMORY="${GUEST_MEMORY:-256M}"
DEV_VENDOR="${DEV_VENDOR:-0x1af4}"
DEV_DEVICE="${DEV_DEVICE:-0x1041}"
DEV_BAR0_SIZE="${DEV_BAR0_SIZE:-0x10000}"

# QEMU / 镜像 自动定位(与 Makefile 一致的默认)
QEMU="${QEMU:-$(ls $ROOT/third_party/qemu/build/qemu-system-x86_64 $HOME/workspace/qemu-9.2.0/build/qemu-system-x86_64 2>/dev/null | head -1)}"
KERNEL="${KERNEL:-$(ls $ROOT/guest/images/$GUEST_TYPE/bzImage $ROOT/guest/images/$GUEST_TYPE/vmlinuz 2>/dev/null | head -1)}"
ROOTFS="${ROOTFS:-$(ls $ROOT/guest/images/$GUEST_TYPE/rootfs.ext4 2>/dev/null | head -1)}"

QEMU_PIDS=()
cleanup() {
  echo "[setup_qemu] stopping ${#QEMU_PIDS[@]} QEMU instance(s)..."
  for p in "${QEMU_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}

write_descriptor() {
  mkdir -p "$(dirname "$CONN_JSON")"
  {
    echo "{"
    echo "  \"transport\": \"$TRANSPORT\","
    echo "  \"host\": \"$ADVERTISE_HOST\","
    echo "  \"port_base\": $PORT_BASE,"
    echo "  \"num_rc\": $NUM_RC,"
    echo "  \"port_formula\": \"port = port_base + instance_id*3\","
    echo -n "  \"rcs\": ["
    for r in $(seq 0 $((NUM_RC-1))); do
      [ "$r" -gt 0 ] && echo -n ","
      echo -n " {\"rc\": $r, \"instance_id\": $r, \"port\": $((PORT_BASE + r*3))}"
    done
    echo " ],"
    echo "  \"device\": { \"vendor\": \"$DEV_VENDOR\", \"device\": \"$DEV_DEVICE\", \"bar0_size\": \"$DEV_BAR0_SIZE\" }"
    echo "}"
  } > "$CONN_JSON"
  echo "[setup_qemu] descriptor written: $CONN_JSON"
  cat "$CONN_JSON"
}

launch_one() {
  local r="$1"
  local dev="cosim-pcie-rc,transport=$TRANSPORT,port_base=$PORT_BASE,instance_id=$r"
  local guest_args append
  if [ -n "$ROOTFS" ]; then
    guest_args="-drive file=$ROOTFS,format=raw,if=none,id=rootdisk$r -device virtio-blk-pci,drive=rootdisk$r,addr=0x10"
    append="console=ttyS0 root=/dev/vda rw guest_ip=10.0.0.$((10+r))"
  else
    guest_args=""
    append="console=ttyS0 guest_ip=10.0.0.$((10+r))"
  fi
  echo "[setup_qemu] RC$r: QEMU listen $TRANSPORT port_base=$PORT_BASE inst=$r (port $((PORT_BASE+r*3)))"
  # -snapshot: 多实例共享只读 rootfs 基,写走临时 overlay
  "$QEMU" -M q35 -m "$GUEST_MEMORY" -smp 1 -snapshot \
     -kernel "$KERNEL" $guest_args \
     -append "$append" \
     -device "$dev" \
     -nographic -serial "file:$LOG_DIR/qemu_rc$r.log" \
     -monitor "unix:$RUN_DIR/qemu_rc$r.monitor,server,nowait" &
  QEMU_PIDS+=($!)
}

do_up() {
  [ -n "$QEMU" ]   && [ -x "$QEMU" ]   || { echo "[错误] QEMU 未找到,设 QEMU=/path/to/qemu-system-x86_64"; exit 1; }
  [ -n "$KERNEL" ] && [ -f "$KERNEL" ] || { echo "[错误] KERNEL 未找到(GUEST_TYPE=$GUEST_TYPE),设 KERNEL="; exit 1; }
  [ -n "$ROOTFS" ] || echo "[警告] 无 rootfs,仅 kernel 启动"
  mkdir -p "$RUN_DIR" "$LOG_DIR"
  trap cleanup EXIT INT TERM
  for r in $(seq 0 $((NUM_RC-1))); do launch_one "$r"; done
  write_descriptor
  echo "[setup_qemu] $NUM_RC QEMU 已起(server listen)。VCS 侧读 $CONN_JSON 连接。Ctrl-C 停。"
  wait
}

case "${1:-up}" in
  up)         do_up ;;
  descriptor) write_descriptor ;;
  *) echo "usage: $0 [up|descriptor]"; exit 1 ;;
esac
