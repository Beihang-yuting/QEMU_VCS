#!/bin/bash
# run_cosim_vcs.sh — VCS 侧读 QEMU 吐的 cosim-conn.json,连过去跑 2-RC cosim。
# 与 setup_qemu_env.sh 完全解耦:只认描述符里的 host/port_base/num_rc/device。
#
# 用法:
#   # 描述符已在本地(同机 or 已 scp 过来):
#   CONN_JSON=/path/to/cosim-conn.json ./scripts/run_cosim_vcs.sh
#
#   # 跨机自动拉描述符(QEMU 在 53):
#   CONN_FROM=ubuntu@10.11.10.53:/home/ubuntu/ryan/software/cosim-platform/run/cosim-conn.json \
#     ./scripts/run_cosim_vcs.sh
#
# 库路径给 build_cosim_multirc.sh(见其头注),用 AXIS_VIP/PCIE_TL/HOST_MEM/XILINX 覆盖。
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
CONN_JSON="${CONN_JSON:-$ROOT/run/cosim-conn.json}"

# 跨机:先把描述符 scp 过来
if [ -n "$CONN_FROM" ]; then
  mkdir -p "$(dirname "$CONN_JSON")"
  echo "[run_vcs] fetch descriptor: $CONN_FROM -> $CONN_JSON"
  scp ${SCP_OPTS:-} "$CONN_FROM" "$CONN_JSON"
fi
[ -f "$CONN_JSON" ] || { echo "[错误] 描述符不存在: $CONN_JSON (设 CONN_JSON= 或 CONN_FROM=)"; exit 1; }

echo "[run_vcs] descriptor: $CONN_JSON"; cat "$CONN_JSON"

# 用 python3 解析(避免依赖 jq)
read HOST PORT_BASE NUM_RC DEV_VENDOR DEV_DEVICE DEV_BAR0 <<EOF
$(python3 - "$CONN_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
dev = d.get("device", {})
print(d["host"], d["port_base"], d["num_rc"],
      dev.get("vendor","0x1af4"), dev.get("device","0x1041"), dev.get("bar0_size","0x10000"))
PY
)
EOF

echo "[run_vcs] host=$HOST port_base=$PORT_BASE num_rc=$NUM_RC dev=$DEV_VENDOR:$DEV_DEVICE bar0=$DEV_BAR0"

# 喂给 build_cosim_multirc.sh run(它认这些 env)。device.* 一并透传(前向兼容,
# 当前 test 不消费未知 plusarg;后续 config_proxy 对齐时用)。
export REMOTE_HOST="$HOST" PORT_BASE NUM_RC
export EXTRA_PLUSARGS="+DEV_VENDOR=$DEV_VENDOR +DEV_DEVICE=$DEV_DEVICE +DEV_BAR0_SIZE=$DEV_BAR0"

exec "$SCRIPT_DIR/build_cosim_multirc.sh" run
