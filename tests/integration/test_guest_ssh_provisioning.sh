#!/usr/bin/env bash
# Contract test for the rootfs SSH/SCP provisioning command.  It deliberately
# uses --dry-run so it is safe to run without root privileges or an image.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo/scripts/provision_guest_ssh.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    echo "[guest-ssh-provisioning] FAIL: $*" >&2
    exit 1
}

assert_contains() {
    grep -Fq -- "$1" <<<"$2" || fail "missing: $1"
}

help="$($script --help)"
assert_contains 'COSIM_GUEST_SSH_PASSWORD' "$help"
assert_contains '--rootfs' "$help"
assert_contains '--user' "$help"

if "$script" --dry-run --rootfs "$tmp/rootfs.ext4" --user ryan >/dev/null 2>&1; then
    fail 'missing password was accepted'
fi

if COSIM_GUEST_SSH_PASSWORD='not-to-be-printed' \
        "$script" --dry-run --rootfs "$tmp/rootfs.ext4" --user 'bad/user' >/dev/null 2>&1; then
    fail 'unsafe user name was accepted'
fi

output="$(COSIM_GUEST_SSH_PASSWORD='not-to-be-printed' \
    "$script" --dry-run --rootfs "$tmp/rootfs.ext4" --user ryan)"
assert_contains 'openssh-server sudo build-essential' "$output"
assert_contains 'Driver=e1000e' "$output"
assert_contains 'PasswordAuthentication yes' "$output"
[[ "$output" != *not-to-be-printed* ]] || fail 'password leaked to output'

echo '[guest-ssh-provisioning] PASS'
