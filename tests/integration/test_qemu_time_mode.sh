#!/usr/bin/env bash
# Verify the opt-in QEMU iCount command line without starting QEMU.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
make_cmd=(make -s -n -C "$repo" run-qemu QEMU=/bin/true KERNEL=/bin/true ROOTFS=/bin/true)

fail() {
    echo "[qemu-time-mode] FAIL: $*" >&2
    exit 1
}

assert_exactly_once() {
    local needle="$1"
    local haystack="$2"
    local count

    count="$( { grep -Fo -- "$needle" <<<"$haystack" || true; } | wc -l | tr -d '[:space:]')"
    [[ "$count" == "1" ]] || fail "expected exactly one '$needle', got $count"
}

for console in login login-multi file; do
    realtime="$("${make_cmd[@]}" CONSOLE="$console" QEMU_TIME_MODE=realtime)"
    if grep -Fq -- '-icount ' <<<"$realtime"; then
        fail "realtime command unexpectedly enables iCount for CONSOLE=$console"
    fi
    assert_exactly_once '/bin/true -M q35' "$realtime"

    icount="$("${make_cmd[@]}" CONSOLE="$console" QEMU_TIME_MODE=icount)"
    assert_exactly_once '-accel tcg' "$icount"
    assert_exactly_once '-icount shift=auto,align=off,sleep=on' "$icount"
    if grep -Fq -- '-icount shift=auto,align=off,sleep=off' <<<"$icount"; then
        fail "legacy global sleep=off mode remains enabled for CONSOLE=$console"
    fi
done

make -s -C "$repo" validate-qemu-time-mode QEMU_TIME_MODE=realtime
make -s -C "$repo" validate-qemu-time-mode QEMU_TIME_MODE=icount
if make -s -C "$repo" validate-qemu-time-mode QEMU_TIME_MODE=invalid >/dev/null 2>&1; then
    fail "invalid QEMU_TIME_MODE was accepted"
fi

if injected_output="$(make -s -C "$repo" validate-qemu-time-mode \
        'QEMU_TIME_MODE=icount; echo QEMU_TIME_MODE_INJECTED' 2>&1)"; then
    fail "shell-injected QEMU_TIME_MODE was accepted"
fi
if [[ "$injected_output" == *QEMU_TIME_MODE_INJECTED* ]]; then
    fail "QEMU_TIME_MODE executed injected shell content"
fi

if make_function_output="$(make -s -C "$repo" validate-qemu-time-mode \
        'QEMU_TIME_MODE=$(shell printf QEMU_TIME_MODE_MAKE_FUNCTION_INJECTED >&2)' 2>&1)"; then
    fail "Make-function QEMU_TIME_MODE was accepted"
fi
if [[ "$make_function_output" == *QEMU_TIME_MODE_MAKE_FUNCTION_INJECTED* ]]; then
    fail "QEMU_TIME_MODE evaluated an injected Make function"
fi

echo "[qemu-time-mode] PASS"
