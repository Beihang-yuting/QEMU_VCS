#!/usr/bin/env bash
# Guard the offline QEMU source formats emitted by prepare-offline.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

bash -n "$SETUP"

if ! grep -Fq 'qemu-9.2.0.tar.xz' "$SETUP"; then
    echo "FAIL: xz offline QEMU archive input is unsupported" >&2
    exit 1
fi

if ! grep -Fq 'qemu-9.2.0.tar.gz' "$SETUP"; then
    echo "FAIL: gzip offline QEMU archive input is unsupported" >&2
    exit 1
fi

echo "PASS: setup.sh accepts gzip and xz offline QEMU archives"
