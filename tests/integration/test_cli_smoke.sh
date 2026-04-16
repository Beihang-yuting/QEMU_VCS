#!/usr/bin/env bash
# cosim_cli smoke test
#
# 验证：
#   1. Python 解释器能加载 libcosim_bridge.so（ctypes 绑定完整）
#   2. bridge_init() 成功创建 SHM + socket
#   3. REPL 接受 stdin 上的 `quit` 并干净退出
#   4. bridge_destroy() 清理 SHM + socket
#
# 通过 --no-wait 跳过 bridge_connect()，所以不依赖 VCS。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/scripts/cosim_cli.py"
LIB="$REPO_ROOT/build/bridge/libcosim_bridge.so"

SHM_NAME="/cosim-cli-smoke-$$"
SOCK_PATH="/tmp/cosim-cli-smoke-$$.sock"

cleanup() {
    rm -f "$SOCK_PATH" || true
    rm -f "/dev/shm${SHM_NAME}" || true
}
trap cleanup EXIT

echo "[cli-smoke] CLI   : $CLI"
echo "[cli-smoke] LIB   : $LIB"
echo "[cli-smoke] SHM   : $SHM_NAME"
echo "[cli-smoke] SOCK  : $SOCK_PATH"

if [ ! -f "$LIB" ]; then
    echo "[cli-smoke] FAIL: library not built yet: $LIB" >&2
    echo "[cli-smoke]       run 'make bridge' first" >&2
    exit 1
fi

# Feed 'status\nquit' on stdin, capture both streams.
OUTPUT=$(printf "status\nquit\n" | \
    python3 "$CLI" --no-wait --lib "$LIB" --shm "$SHM_NAME" --sock "$SOCK_PATH" 2>&1)
RC=$?

echo "--- cli output ---"
echo "$OUTPUT"
echo "--- end output ---"

if [ $RC -ne 0 ]; then
    echo "[cli-smoke] FAIL: cosim_cli exited with rc=$RC" >&2
    exit 1
fi

# Expect init / ready / status / destroy banners
echo "$OUTPUT" | grep -q "init bridge"       || { echo "[cli-smoke] FAIL: no init banner";    exit 1; }
echo "$OUTPUT" | grep -q "cosim_cli ready"   || { echo "[cli-smoke] FAIL: no ready banner";   exit 1; }
echo "$OUTPUT" | grep -q "mode  : fast"      || { echo "[cli-smoke] FAIL: status did not report mode"; exit 1; }
echo "$OUTPUT" | grep -q "destroying bridge" || { echo "[cli-smoke] FAIL: no destroy banner"; exit 1; }

echo "[cli-smoke] PASS"
exit 0
