#!/usr/bin/env bash
# Verify default QEMU management-NIC arguments without starting QEMU.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "[qemu-management-nic] FAIL: $*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$1" <<<"$2" || fail "missing: $1"
}

assert_not_contains() {
    ! grep -Fq -- "$1" <<<"$2" || fail "unexpected: $1"
}

run_login() {
    make -s -C "$repo" run-qemu CONSOLE=login QEMU=/bin/echo KERNEL=/bin/true ROOTFS=/bin/true \
        LOG_DIR="$tmp/logs-login" RUN_DIR="$tmp/run-login" "$@"
}

for console in login-multi file; do
    logs="$tmp/logs-$console"
    make -s -C "$repo" run-qemu CONSOLE="$console" NUM_RC=2 QEMU=/bin/echo KERNEL=/bin/true ROOTFS=/bin/true \
        LOG_DIR="$logs" RUN_DIR="$tmp/run-$console"
    rc0="$(<"$logs/qemu_rc0.boot")"
    rc1="$(<"$logs/qemu_rc1.boot")"
    assert_contains 'id=mgmtnet0,hostfwd=tcp:127.0.0.1:2222-:22' "$rc0"
    assert_contains 'e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01' "$rc0"
    assert_contains 'id=mgmtnet1,hostfwd=tcp:127.0.0.1:2223-:22' "$rc1"
    assert_contains 'e1000e,netdev=mgmtnet1,mac=52:54:00:53:00:02' "$rc1"
done

login="$(run_login)"
assert_contains 'id=mgmtnet0,hostfwd=tcp:127.0.0.1:2222-:22' "$login"
assert_contains 'e1000e,netdev=mgmtnet0,mac=52:54:00:53:00:01' "$login"

disabled="$(run_login MGMT_NET=0)"
assert_not_contains 'mgmtnet' "$disabled"

make -s -C "$repo" validate-mgmt-net MGMT_NET=0
make -s -C "$repo" validate-mgmt-net MGMT_NET=1 MGMT_SSH_PORT_BASE=65535
if make -s -C "$repo" validate-mgmt-net MGMT_NET=2 >/dev/null 2>&1; then
    fail "MGMT_NET=2 accepted"
fi
if make -s -C "$repo" validate-mgmt-net MGMT_SSH_PORT_BASE=0 >/dev/null 2>&1; then
    fail "port 0 accepted"
fi
if make -s -C "$repo" validate-mgmt-net MGMT_SSH_PORT_BASE=65536 >/dev/null 2>&1; then
    fail "port 65536 accepted"
fi
if injected_output="$(make -s -C "$repo" validate-mgmt-net \
        'MGMT_NET=1; echo MGMT_NET_INJECTED' 2>&1)"; then
    fail "shell-injected MGMT_NET was accepted"
fi
if [[ "$injected_output" == *MGMT_NET_INJECTED* ]]; then
    fail "MGMT_NET executed injected shell content"
fi
if injected_output="$(make -s -C "$repo" validate-mgmt-net \
        'MGMT_SSH_PORT_BASE=2222; echo MGMT_PORT_INJECTED' 2>&1)"; then
    fail "shell-injected MGMT_SSH_PORT_BASE was accepted"
fi
if [[ "$injected_output" == *MGMT_PORT_INJECTED* ]]; then
    fail "MGMT_SSH_PORT_BASE executed injected shell content"
fi

echo "[qemu-management-nic] PASS"
