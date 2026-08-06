#!/usr/bin/env bash
# Contract test for the Ubuntu Server guest profile.  All executable probes are
# metadata-only, import-only, or dry-run operations: no image build or network
# access is permitted here.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-server-profile-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

failures=0

fail() {
    echo "[ubuntu-server-profile] FAIL: $*" >&2
    failures=$((failures + 1))
}

assert_contains() {
    local needle="$1" haystack="$2" description="$3"
    grep -Fq -- "$needle" <<<"$haystack" || fail "$description (missing: $needle)"
}

assert_file() {
    [ -f "$1" ] || fail "$2 (missing: $1)"
}

assert_same() {
    cmp -s -- "$1" "$2" || fail "$3 (different: $1, $2)"
}

snapshot_tree() {
    local root="$1"
    (
        cd "$root"
        find . -mindepth 1 -printf '%P\0' | LC_ALL=C sort -z |
            while IFS= read -r -d '' path; do
                if [ -L "$path" ]; then
                    printf 'symlink\t%s\t%s\n' "$path" "$(readlink -- "$path")"
                elif [ -f "$path" ]; then
                    printf 'file\t%s\t%s\n' "$path" \
                        "$(sha256sum -- "$path" | awk '{print $1}')"
                elif [ -d "$path" ]; then
                    printf 'directory\t%s\n' "$path"
                else
                    printf 'other\t%s\t%s\n' "$path" "$(stat -c '%F' -- "$path")"
                fi
            done
    )
}

# Public selectors and Make defaults.
help="$(bash "$repo/setup.sh" --help)" || fail 'setup --help failed'
assert_contains 'ubuntu-server' "$help" 'setup help omits ubuntu-server'

make_help="$(make -s -C "$repo" help)" || fail 'make help failed'
assert_contains 'GUEST_TYPE=ubuntu|ubuntu-server|debian' "$make_help" \
    'Make help omits ubuntu-server'

make_info="$(make -s -C "$repo" info GUEST_TYPE=ubuntu-server \
    KERNEL=/bin/true ROOTFS=/bin/true)" || fail 'make info failed for ubuntu-server'
assert_contains 'ubuntu-server' "$make_info" 'make info does not show the resolved guest type'

make_db_default="$(make -s -pn -C "$repo" 2>/dev/null)" || fail 'make database dump failed for defaults'
grep -Eq '^GUEST_TYPE[[:space:]]*[:?]?=[[:space:]]*ubuntu$' <<<"$make_db_default" || \
    fail 'default GUEST_TYPE is not ubuntu'
grep -Eq '^GUEST_MEMORY[[:space:]]*[:?]?=[[:space:]]*256M$' <<<"$make_db_default" || \
    fail 'default compact Ubuntu memory is not 256M'

make_db_ubuntu="$(make -s -pn -C "$repo" GUEST_TYPE=ubuntu 2>/dev/null)" || \
    fail 'make database dump failed for ubuntu'
grep -Eq '^GUEST_MEMORY[[:space:]]*[:?]?=[[:space:]]*256M$' <<<"$make_db_ubuntu" || \
    fail 'Ubuntu compact profile memory is not 256M'

make_db_server="$(make -s -pn -C "$repo" GUEST_TYPE=ubuntu-server 2>/dev/null)" || \
    fail 'make database dump failed for ubuntu-server'
grep -Eq '^GUEST_MEMORY[[:space:]]*[:?]?=[[:space:]]*2G$' <<<"$make_db_server" || \
    fail 'Ubuntu Server profile memory is not 2G'

make_db_debian="$(make -s -pn -C "$repo" GUEST_TYPE=debian 2>/dev/null)" || \
    fail 'make database dump failed for debian'
grep -Eq '^GUEST_MEMORY[[:space:]]*[:?]?=[[:space:]]*512M$' <<<"$make_db_debian" || \
    fail 'Debian profile memory is not 512M'

# setup.sh must keep every selected profile in its own image directory.
grep -Fq 'ubuntu|ubuntu-server|debian|skip)' "$repo/setup.sh" || \
    fail 'setup validation does not accept ubuntu-server'
grep -Fq 'IMAGES_DIR="${PROJECT_DIR}/guest/images/${GUEST_TYPE}"' "$repo/setup.sh" || \
    fail 'setup image directory is not profile-relative'
grep -Fq 'guest/images/ubuntu' "$repo/setup.sh" || \
    fail 'legacy Ubuntu image path was removed'

grep -Fq 'ubuntu|ubuntu-server)' "$repo/scripts/build_cosim_nic.sh" || \
    fail 'cosim_nic does not share Ubuntu kernel/header selection with ubuntu-server'

# Import an offline fixture into an isolated project and verify both the new
# profile-relative destination and the unchanged legacy destinations.
test_project="$work/project"
payload="$work/payload"
mkdir -p "$test_project" \
    "$payload/guest/ubuntu-server" "$payload/guest/ubuntu" "$payload/guest/debian"
cp "$repo/setup.sh" "$test_project/setup.sh"
chmod +x "$test_project/setup.sh"
mkdir -p "$test_project/scripts"
cp "$repo/scripts/setup-ubuntu-kernel.sh" "$test_project/scripts/setup-ubuntu-kernel.sh"
chmod +x "$test_project/scripts/setup-ubuntu-kernel.sh"

# Load setup.sh's real functions without entering its main install flow.  This
# exercises the actual interactive selector and Ubuntu Server builder route,
# while keeping the test isolated from network, compilation, and sudo.
setup_library="$work/setup-library.sh"
if ! awk '
    /^# === setup.sh main flow ===$/ { found = 1; exit }
    { print }
    END { if (!found) exit 1 }
' "$test_project/setup.sh" > "$setup_library"; then
    fail 'setup.sh main-flow boundary was not found'
fi

menu_project="$work/menu-project"
menu_cwd="$work/menu-cwd"
menu_result="$work/menu-result"
mkdir -p "$menu_project" "$menu_cwd"
if ! (
    # shellcheck source=/dev/null
    source "$setup_library"
    PROJECT_DIR="$menu_project"
    cd "$menu_cwd"
    interactive_menu > "$work/menu-output" <<'MENU_INPUT'
n
1
2

3
MENU_INPUT
    printf '%s\n' "$GUEST_TYPE" > "$menu_result"
); then
    fail 'interactive setup selector failed'
fi
grep -Fxq 'ubuntu-server' "$menu_result" || \
    fail 'interactive setup selector did not resolve ubuntu-server'

server_output="$test_project/guest/images/ubuntu-server"
missing_builder_output="$work/missing-builder-output"
if (
    # shellcheck source=/dev/null
    source "$setup_library"
    PROJECT_DIR="$test_project"
    build_ubuntu_server_guest "$server_output"
) > "$missing_builder_output" 2>&1; then
    fail 'Ubuntu Server build route accepted a missing builder'
fi
missing_builder_text="$(<"$missing_builder_output")"
assert_contains "$test_project/scripts/build_rootfs_ubuntu_server.sh" \
    "$missing_builder_text" 'missing-builder error omits the resolved builder path'
assert_contains 'Task 4' "$missing_builder_text" \
    'missing-builder error omits the Task 4/import guidance'

builder_log="$work/builder-log"
printf '%s\n' '#!/usr/bin/env bash' \
    'printf "%s\n" "$#" > "${BUILDER_LOG}.count"' \
    'printf "%s\n" "$@" > "${BUILDER_LOG}.args"' \
    'output_dir="$1"' \
    'case "${BUILDER_FIXTURE_MODE:-complete}" in' \
    '    empty) ;;' \
    '    no-kernel) mkdir -p "$output_dir"; printf "rootfs\n" > "$output_dir/rootfs.ext4" ;;' \
    '    no-rootfs) mkdir -p "$output_dir"; printf "kernel\n" > "$output_dir/vmlinuz" ;;' \
    '    complete) mkdir -p "$output_dir"; printf "rootfs\n" > "$output_dir/rootfs.ext4"; printf "kernel\n" > "$output_dir/vmlinuz" ;;' \
    'esac' \
    > "$test_project/scripts/build_rootfs_ubuntu_server.sh"
chmod +x "$test_project/scripts/build_rootfs_ubuntu_server.sh"

rm -rf "$server_output"
empty_output="$work/empty-builder-output"
if (
    # shellcheck source=/dev/null
    source "$setup_library"
    PROJECT_DIR="$test_project"
    export BUILDER_LOG="$builder_log" BUILDER_FIXTURE_MODE=empty
    build_ubuntu_server_guest "$server_output"
) > "$empty_output" 2>&1; then
    fail 'Ubuntu Server build route accepted a successful builder with no artifacts'
fi
empty_text="$(<"$empty_output")"
assert_contains 'rootfs' "$empty_text" 'empty-builder error omits the missing rootfs'
assert_contains 'kernel' "$empty_text" 'empty-builder error omits the missing kernel'

rm -rf "$server_output"
no_kernel_output="$work/no-kernel-builder-output"
if (
    # shellcheck source=/dev/null
    source "$setup_library"
    PROJECT_DIR="$test_project"
    export BUILDER_LOG="$builder_log" BUILDER_FIXTURE_MODE=no-kernel
    build_ubuntu_server_guest "$server_output"
) > "$no_kernel_output" 2>&1; then
    fail 'Ubuntu Server build route accepted a missing kernel artifact'
fi
assert_contains 'kernel' "$(<"$no_kernel_output")" \
    'missing-kernel error does not identify the kernel artifact'

rm -rf "$server_output"
no_rootfs_output="$work/no-rootfs-builder-output"
if (
    # shellcheck source=/dev/null
    source "$setup_library"
    PROJECT_DIR="$test_project"
    export BUILDER_LOG="$builder_log" BUILDER_FIXTURE_MODE=no-rootfs
    build_ubuntu_server_guest "$server_output"
) > "$no_rootfs_output" 2>&1; then
    fail 'Ubuntu Server build route accepted a missing rootfs artifact'
fi
assert_contains 'rootfs' "$(<"$no_rootfs_output")" \
    'missing-rootfs error does not identify the rootfs artifact'

rm -rf "$server_output"
if ! (
    # shellcheck source=/dev/null
    source "$setup_library"
    PROJECT_DIR="$test_project"
    export BUILDER_LOG="$builder_log" BUILDER_FIXTURE_MODE=complete
    build_ubuntu_server_guest "$server_output"
); then
    fail 'Ubuntu Server build route failed with an executable builder'
fi
grep -Fxq '1' "${builder_log}.count" || \
    fail 'Ubuntu Server builder did not receive exactly one argument'
printf '%s\n' "$server_output" > "$work/expected-builder-args"
assert_same "$work/expected-builder-args" "${builder_log}.args" \
    'Ubuntu Server builder received the wrong output directory'
grep -Fq 'build_ubuntu_server_guest "$IMAGES_DIR"' "$repo/setup.sh" || \
    fail 'main Guest flow does not call the tested Ubuntu Server build route'

# Kernel extraction dry-run must leave the complete isolated project tree
# byte-for-byte and topology-equivalent, and must not invoke privileged,
# package-manager, or network commands.
fakebin="$work/fakebin"
mkdir -p "$fakebin"
printf '#!/usr/bin/env bash\ntouch "$BLOCKED_SENTINEL"\nexit 97\n' > "$fakebin/blocked"
chmod +x "$fakebin/blocked"
for command_name in sudo apt apt-get curl wget; do
    ln -s blocked "$fakebin/$command_name"
done

snapshot_tree "$test_project" > "$work/tree-before-dry-run"
dry_output_dir="$test_project/dry-run-output"
dry_output="$(BLOCKED_SENTINEL="$work/blocked-command" PATH="$fakebin:$PATH" \
    "$test_project/scripts/setup-ubuntu-kernel.sh" --dry-run \
    6.8.0-107-generic "$dry_output_dir" 2>&1)" || \
    fail "kernel setup dry-run failed: $dry_output"
assert_contains '6.8.0-107-generic' "$dry_output" 'dry-run omits resolved kernel version'
assert_contains "$dry_output_dir" "$dry_output" 'dry-run omits resolved output directory'
[ ! -e "$dry_output_dir" ] || fail 'dry-run created the requested output directory'
[ ! -e "$test_project/build/ubuntu-kernel" ] || fail 'dry-run created its kernel work directory'
[ ! -e "$work/blocked-command" ] || fail 'dry-run invoked sudo, apt, or a network client'

default_dry_output="$(BLOCKED_SENTINEL="$work/blocked-command-default" PATH="$fakebin:$PATH" \
    "$test_project/scripts/setup-ubuntu-kernel.sh" --dry-run 2>&1)" || \
    fail "default kernel setup dry-run failed: $default_dry_output"
assert_contains "$test_project/guest/images/ubuntu" "$default_dry_output" \
    'legacy default Ubuntu kernel output path changed'
[ ! -e "$test_project/guest/images/ubuntu" ] || \
    fail 'default dry-run created the legacy Ubuntu output directory'
[ ! -e "$test_project/build/ubuntu-kernel" ] || \
    fail 'default dry-run created its kernel work directory'
[ ! -e "$work/blocked-command-default" ] || \
    fail 'default dry-run invoked sudo, apt, or a network client'

if BLOCKED_SENTINEL="$work/blocked-command-unknown" PATH="$fakebin:$PATH" \
        "$test_project/scripts/setup-ubuntu-kernel.sh" --unknown >/dev/null 2>&1; then
    fail 'kernel setup accepted an unknown option'
fi
[ ! -e "$work/blocked-command-unknown" ] || \
    fail 'unknown-option validation invoked sudo, apt, or a network client'
if BLOCKED_SENTINEL="$work/blocked-command-extra" PATH="$fakebin:$PATH" \
        "$test_project/scripts/setup-ubuntu-kernel.sh" --dry-run 6.8.0-107-generic \
        "$dry_output_dir" extra >/dev/null 2>&1; then
    fail 'kernel setup accepted an extra positional argument'
fi
[ ! -e "$work/blocked-command-extra" ] || \
    fail 'extra-argument validation invoked sudo, apt, or a network client'
snapshot_tree "$test_project" > "$work/tree-after-dry-run"
assert_same "$work/tree-before-dry-run" "$work/tree-after-dry-run" \
    'kernel setup dry-run changed the isolated project tree'

printf 'server-kernel\n' > "$payload/guest/ubuntu-server/vmlinuz"
printf 'server-modules\n' > "$payload/guest/ubuntu-server/modules.tar.gz"
printf 'server-rootfs\n' > "$payload/guest/ubuntu-server/rootfs.ext4"
printf 'ubuntu-kernel\n' > "$payload/guest/ubuntu/vmlinuz"
printf 'ubuntu-rootfs\n' > "$payload/guest/ubuntu/rootfs.ext4"
printf 'debian-kernel\n' > "$payload/guest/debian/bzImage"
printf 'debian-rootfs\n' > "$payload/guest/debian/rootfs.ext4"
archive="$work/offline.zip"
(cd "$payload" && zip -qr "$archive" .) || fail 'failed to create offline import fixture'
mkdir -p "$test_project/guest/images/ubuntu-server" \
    "$test_project/guest/images/ubuntu" "$test_project/guest/images/debian"
for stale_path in \
    "$test_project/guest/images/ubuntu-server/vmlinuz" \
    "$test_project/guest/images/ubuntu-server/modules.tar.gz" \
    "$test_project/guest/images/ubuntu-server/rootfs.ext4" \
    "$test_project/guest/images/ubuntu/vmlinuz" \
    "$test_project/guest/images/ubuntu/rootfs.ext4" \
    "$test_project/guest/images/debian/bzImage" \
    "$test_project/guest/images/debian/rootfs.ext4"; do
    printf 'stale:%s\n' "$stale_path" > "$stale_path"
done
import_output="$(bash "$test_project/setup.sh" --import "$archive" --import-only 2>&1)" || \
    fail "offline import failed: $import_output"
assert_file "$test_project/guest/images/ubuntu-server/vmlinuz" \
    'Ubuntu Server kernel was not imported profile-relatively'
assert_file "$test_project/guest/images/ubuntu-server/modules.tar.gz" \
    'Ubuntu Server modules were not imported profile-relatively'
assert_file "$test_project/guest/images/ubuntu-server/rootfs.ext4" \
    'Ubuntu Server rootfs was not imported profile-relatively'
assert_file "$test_project/guest/images/ubuntu/vmlinuz" \
    'legacy Ubuntu import path regressed'
assert_file "$test_project/guest/images/ubuntu/rootfs.ext4" \
    'legacy Ubuntu rootfs import regressed'
assert_file "$test_project/guest/images/debian/bzImage" \
    'legacy Debian import path regressed'
assert_file "$test_project/guest/images/debian/rootfs.ext4" \
    'legacy Debian rootfs import regressed'
assert_same "$payload/guest/ubuntu-server/vmlinuz" \
    "$test_project/guest/images/ubuntu-server/vmlinuz" \
    'Ubuntu Server kernel import content changed'
assert_same "$payload/guest/ubuntu-server/modules.tar.gz" \
    "$test_project/guest/images/ubuntu-server/modules.tar.gz" \
    'Ubuntu Server modules import content changed'
assert_same "$payload/guest/ubuntu-server/rootfs.ext4" \
    "$test_project/guest/images/ubuntu-server/rootfs.ext4" \
    'Ubuntu Server rootfs import content changed'
assert_same "$payload/guest/ubuntu/vmlinuz" \
    "$test_project/guest/images/ubuntu/vmlinuz" \
    'legacy Ubuntu kernel import content changed'
assert_same "$payload/guest/ubuntu/rootfs.ext4" \
    "$test_project/guest/images/ubuntu/rootfs.ext4" \
    'legacy Ubuntu rootfs import content changed'
assert_same "$payload/guest/debian/bzImage" \
    "$test_project/guest/images/debian/bzImage" \
    'legacy Debian kernel import content changed'
assert_same "$payload/guest/debian/rootfs.ext4" \
    "$test_project/guest/images/debian/rootfs.ext4" \
    'legacy Debian rootfs import content changed'

if [ "$failures" -ne 0 ]; then
    echo "[ubuntu-server-profile] $failures contract check(s) failed" >&2
    exit 1
fi

echo '[ubuntu-server-profile] PASS'
