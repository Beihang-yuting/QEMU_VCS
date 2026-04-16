#!/usr/bin/env bash
# launch_dual.py smoke test — uses stub `sleep` command so it doesn't need QEMU.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCHER="$REPO_ROOT/scripts/launch_dual.py"

echo "[launch-smoke] LAUNCHER: $LAUNCHER"

OUTPUT=$(python3 "$LAUNCHER" --launcher-cmd "sleep 10" --smoke 2>&1)
RC=$?
echo "--- launcher output ---"
echo "$OUTPUT"
echo "--- end output ---"

if [ $RC -ne 0 ]; then
    echo "[launch-smoke] FAIL: launcher exit rc=$RC" >&2
    exit 1
fi

echo "$OUTPUT" | grep -q "\[A\] local: sleep 10"       || { echo "[launch-smoke] FAIL: no A start"; exit 1; }
echo "$OUTPUT" | grep -q "\[B\] local: sleep 10"       || { echo "[launch-smoke] FAIL: no B start"; exit 1; }
echo "$OUTPUT" | grep -q "nodes alive=True"            || { echo "[launch-smoke] FAIL: nodes not alive at deadline"; exit 1; }

echo "[launch-smoke] PASS"
exit 0
