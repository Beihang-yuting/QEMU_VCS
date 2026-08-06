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

assert_not_contains() {
    local needle="$1" haystack="$2" description="$3"
    if grep -Fq -- "$needle" <<<"$haystack"; then
        fail "$description (unexpected: $needle)"
    fi
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

snapshot_optional_tree() {
    local root="$1"
    if [ -d "$root" ]; then
        printf 'present\n'
        snapshot_tree "$root"
    elif [ -e "$root" ] || [ -L "$root" ]; then
        printf 'other\t%s\n' "$(stat -c '%F' -- "$root")"
    else
        printf 'absent\n'
    fi
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

# The real Ubuntu Server builder must expose a complete, side-effect-free plan
# before Task 8 exercises the privileged/network build on the simulation host.
builder="$repo/scripts/build_rootfs_ubuntu_server.sh"
if [ ! -x "$builder" ]; then
    fail 'Ubuntu Server rootfs builder is missing or not executable'
else
    builder_fakebin="$work/builder-fakebin"
    mkdir -p "$builder_fakebin"
    printf '#!/usr/bin/env bash\n: > "$BLOCKED_SENTINEL"\nexit 97\n' \
        > "$builder_fakebin/blocked"
    chmod +x "$builder_fakebin/blocked"
    for command_name in \
        sudo mount umount debootstrap apt apt-get curl wget truncate \
        mkfs.ext4 chroot tar depmod e2fsck; do
        ln -s blocked "$builder_fakebin/$command_name"
    done

    snapshot_optional_tree "$repo/build/tmp" > "$work/builder-tree-before"
    builder_output_dir="$work/images/ubuntu-server"
    blocked_sentinel="$work/builder-blocked-command"
    if ! builder_output="$(COSIM_GUEST_SSH_PASSWORD=not-printed \
            BLOCKED_SENTINEL="$blocked_sentinel" \
            PATH="$builder_fakebin:$PATH" \
            "$builder" --dry-run "$builder_output_dir" 2>&1)"; then
        fail "Ubuntu Server builder dry-run failed: $builder_output"
    fi

    for expected in \
        'noble' '8G' '6.8.0-107-generic' \
        'ubuntu-minimal' 'ubuntu-standard' 'build-essential' \
        'linux-headers-6.8.0-107-generic' 'libreadline-dev' \
        '/opt/dpu-debugutils' \
        'apt-daily.timer' 'apt-daily-upgrade.timer' \
        'unattended-upgrades.service' \
        'debootstrap --variant=minbase' \
        'http://archive.ubuntu.com/ubuntu noble main universe' \
        'http://archive.ubuntu.com/ubuntu noble-updates main universe' \
        'http://security.ubuntu.com/ubuntu noble-security main universe' \
        'PasswordAuthentication yes' 'PermitRootLogin no' \
        'systemd-networkd.service' 'serial-getty@ttyS0.service' \
        'Driver=e1000e' 'depmod -b ROOT 6.8.0-107-generic' \
        '/lib/modules/6.8.0-107-generic/build/Makefile' \
        'stage_guest_debugutils.sh --include-source' \
        '/usr/local/bin/pci_debug' '/usr/local/bin/reg_display' \
        'Cleanup order: /dev/pts -> /dev -> /proc -> /sys -> root' \
        "Output directory: $builder_output_dir" \
        "Output rootfs: $builder_output_dir/rootfs.ext4" \
        "Output kernel: $builder_output_dir/vmlinuz"; do
        assert_contains "$expected" "$builder_output" \
            "Ubuntu Server builder dry-run omits $expected"
    done
    assert_not_contains 'not-printed' "$builder_output" \
        'Ubuntu Server builder dry-run disclosed the SSH password'
    [ ! -e "$builder_output_dir" ] || \
        fail 'Ubuntu Server builder dry-run created its output directory'
    [ ! -e "$blocked_sentinel" ] || \
        fail 'Ubuntu Server builder dry-run invoked a blocked privileged/network command'
    snapshot_optional_tree "$repo/build/tmp" > "$work/builder-tree-after"
    assert_same "$work/builder-tree-before" "$work/builder-tree-after" \
        'Ubuntu Server builder dry-run changed repo build/tmp'

    if COSIM_GUEST_SSH_PASSWORD=not-printed \
            BLOCKED_SENTINEL="$work/builder-blocked-unknown" \
            PATH="$builder_fakebin:$PATH" \
            "$builder" --unknown >/dev/null 2>&1; then
        fail 'Ubuntu Server builder accepted an unknown option'
    fi
    [ ! -e "$work/builder-blocked-unknown" ] || \
        fail 'builder unknown-option validation invoked a blocked command'
    if COSIM_GUEST_SSH_PASSWORD=not-printed \
            BLOCKED_SENTINEL="$work/builder-blocked-extra" \
            PATH="$builder_fakebin:$PATH" \
            "$builder" --dry-run "$builder_output_dir" extra >/dev/null 2>&1; then
        fail 'Ubuntu Server builder accepted an extra positional argument'
    fi
    [ ! -e "$work/builder-blocked-extra" ] || \
        fail 'builder extra-argument validation invoked a blocked command'

    builder_source="$(<"$builder")"
    assert_contains 'set -euo pipefail' "$builder_source" \
        'builder does not enable strict Bash mode'
    assert_contains '[[ "${EUID}" -eq 0 ]] || fail' "$builder_source" \
        'builder has no explicit root-only guard'
    assert_contains '${PROJECT_DIR}/build/tmp' "$builder_source" \
        'builder work path is not rooted in repo build/tmp'
    assert_contains 'mktemp -d "${BUILD_TMP}/ubuntu-server.XXXXXX"' "$builder_source" \
        'builder does not use a constrained mktemp work directory'
    assert_contains 'chmod 0700 "${WORK_DIR}"' "$builder_source" \
        'builder does not lock down its work directory'
    assert_contains 'truncate -s "${ROOTFS_SIZE}"' "$builder_source" \
        'builder does not create a sparse 8G image with truncate'
    assert_not_contains 'dd if=' "$builder_source" \
        'builder allocates the image with dd'
    assert_contains 'debootstrap --variant=minbase "${SUITE}" "${MOUNT_DIR}" "${ARCHIVE_MIRROR}"' \
        "$builder_source" 'builder debootstrap contract changed'
    assert_contains '"${PROJECT_DIR}/scripts/setup-ubuntu-kernel.sh" "${KVER}"' \
        "$builder_source" 'builder does not request the exact legacy Ubuntu kernel asset'
    assert_contains 'depmod -b "${MOUNT_DIR}" "${KVER}"' "$builder_source" \
        'builder does not regenerate metadata for the exact kernel version'
    assert_contains '[[ -f "${MODULE_DIR}/build/Makefile" ]]' "$builder_source" \
        'builder does not require the exact headers build Makefile'
    assert_contains '"${PROJECT_DIR}/scripts/stage_guest_debugutils.sh"' "$builder_source" \
        'builder does not reuse the debugutils staging helper'
    assert_contains '--include-source' "$builder_source" \
        'builder does not stage debugutils source'
    assert_contains 'cp --sparse=always' "$builder_source" \
        'builder publication can inflate the sparse rootfs'
    assert_contains 'systemctl mask cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service' \
        "$builder_source" 'builder does not mask cloud-init units'
    assert_contains 'systemctl mask apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service' \
        "$builder_source" 'builder does not mask apt background units'
    assert_contains 'mount -o loop,nosuid,nodev' "$builder_source" \
        'builder root mount lacks safe options or is not executable'
    assert_contains 'trap cleanup EXIT' "$builder_source" \
        'builder has no EXIT cleanup trap'
    assert_contains 'trap handle_int INT' "$builder_source" \
        'builder has no independent INT trap'
    assert_contains 'trap handle_term TERM' "$builder_source" \
        'builder has no independent TERM trap'
    assert_contains 'tracked_mount mounted_root "${MOUNT_DIR}" mount -o loop,nosuid,nodev' \
        "$builder_source" 'root mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_sys "${MOUNT_DIR}/sys" mount -t sysfs' \
        "$builder_source" 'sys mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_proc "${MOUNT_DIR}/proc" mount -t proc' \
        "$builder_source" 'proc mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_dev "${MOUNT_DIR}/dev" mount --bind /dev' \
        "$builder_source" 'dev mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_devpts "${MOUNT_DIR}/dev/pts" mount -t devpts' \
        "$builder_source" 'devpts mount is not signal-safe and tracked'
    expected_unmounts=$'unmount_if_mounted mounted_devpts "${MOUNT_DIR}/dev/pts"\nunmount_if_mounted mounted_dev "${MOUNT_DIR}/dev"\nunmount_if_mounted mounted_proc "${MOUNT_DIR}/proc"\nunmount_if_mounted mounted_sys "${MOUNT_DIR}/sys"\nunmount_if_mounted mounted_root "${MOUNT_DIR}"'
    assert_contains "$expected_unmounts" "$builder_source" \
        'builder cleanup does not use the required reverse unmount order'
    assert_not_contains 'cosim_nic' "$builder_source" \
        'builder installs or autoloads the custom cosim_nic driver'

    expected_packages=$'ubuntu-minimal\nubuntu-standard\nsystemd\nsystemd-sysv\nopenssh-server\nsudo\nbuild-essential\ngit\nbc\nflex\nbison\npkg-config\nlibelf-dev\nlibreadline-dev\nlinux-headers-6.8.0-107-generic\npciutils\nkmod\niproute2\niputils-ping\nethtool\ntcpdump\ncurl\nwget\nvim-tiny\nless\nfile\nca-certificates'
    builder_packages="$(awk '
        /^PACKAGES=\($/ { capturing = 1; next }
        capturing && /^\)$/ { exit }
        capturing {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            gsub(/^"|"$/, "")
            if (length) print
        }
    ' "$builder")"
    if [ "$builder_packages" != "$expected_packages" ]; then
        fail 'builder package list does not exactly match the Ubuntu Server contract'
    fi

    # Reproduce the mount-return signal window without privileges.  The fifth
    # fake mount records the target, signals its parent, then returns failure;
    # tracked_mount must use mountpoint to retain the state, defer TERM until
    # the flag is set, and let EXIT cleanup unmount all five targets in reverse.
    builder_library="$work/builder-library.sh"
    if awk '
        /^# === builder main ===$/ { found = 1; exit }
        { print }
        END { if (!found) exit 1 }
    ' "$builder" > "$builder_library"; then
        signal_fakebin="$work/signal-fakebin"
        signal_root="$work/signal-root"
        mkdir -p "$signal_fakebin" \
            "$signal_root/sys" "$signal_root/proc" \
            "$signal_root/dev/pts"
        printf '0\n' > "$work/mount-count"
        : > "$work/mounted-targets"
        : > "$work/unmount-log"
        cat > "$signal_fakebin/mount" <<'FAKE_MOUNT'
#!/usr/bin/env bash
count=$(( $(<"$MOUNT_COUNT") + 1 ))
printf '%s\n' "$count" > "$MOUNT_COUNT"
target=''
for target in "$@"; do :; done
printf '%s\n' "$target" >> "$MOUNTED_TARGETS"
if [ "$count" -eq 5 ]; then
    kill -TERM "$PPID"
    exit 32
fi
exit 0
FAKE_MOUNT
        cat > "$signal_fakebin/mountpoint" <<'FAKE_MOUNTPOINT'
#!/usr/bin/env bash
target="${!#}"
grep -Fxq -- "$target" "$MOUNTED_TARGETS"
FAKE_MOUNTPOINT
        cat > "$signal_fakebin/umount" <<'FAKE_UMOUNT'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$UNMOUNT_LOG"
exit 0
FAKE_UMOUNT
        chmod +x "$signal_fakebin/mount" \
            "$signal_fakebin/mountpoint" "$signal_fakebin/umount"

        signal_status=0
        (
            export MOUNT_COUNT="$work/mount-count"
            export MOUNTED_TARGETS="$work/mounted-targets"
            export UNMOUNT_LOG="$work/unmount-log"
            PATH="$signal_fakebin:$PATH"
            # shellcheck source=/dev/null
            source "$builder_library"
            MOUNT_DIR="$signal_root"
            trap cleanup EXIT
            trap handle_int INT
            trap handle_term TERM
            tracked_mount mounted_root "$signal_root" mount root-image "$signal_root"
            tracked_mount mounted_sys "$signal_root/sys" mount sysfs "$signal_root/sys"
            tracked_mount mounted_proc "$signal_root/proc" mount proc "$signal_root/proc"
            tracked_mount mounted_dev "$signal_root/dev" mount dev "$signal_root/dev"
            tracked_mount mounted_devpts "$signal_root/dev/pts" mount devpts "$signal_root/dev/pts"
        ) || signal_status=$?
        [ "$signal_status" -eq 143 ] ||
            fail "TERM during mount transition returned $signal_status instead of 143"
        cat > "$work/expected-unmount-log" <<EOF
$signal_root/dev/pts
$signal_root/dev
$signal_root/proc
$signal_root/sys
$signal_root
EOF
        assert_same "$work/expected-unmount-log" "$work/unmount-log" \
            'TERM mount cleanup did not unmount every tracked target in reverse order'

        # Reproduce the publication return-point window: the second mv has
        # installed the new output, then signals the parent before the next
        # shell statement can update transaction state.
        if grep -Fq 'publish_results() {' "$builder_library"; then
            publish_case="$work/publish-case"
            publish_parent="$publish_case/images"
            publish_output="$publish_parent/ubuntu-server"
            publish_inputs="$publish_case/inputs"
            publish_fakebin="$publish_case/fakebin"
            mkdir -p "$publish_output" "$publish_inputs" "$publish_fakebin"
            printf 'old-output\n' > "$publish_output/old-sentinel"
            printf 'new-rootfs\n' > "$publish_inputs/rootfs.ext4"
            printf 'new-kernel\n' > "$publish_inputs/vmlinuz"
            printf 'new-modules\n' > "$publish_inputs/modules.tar.gz"
            printf '0\n' > "$publish_case/mv-count"
            real_mv="$(command -v mv)"
            cat > "$publish_fakebin/mv" <<'FAKE_MV'
#!/usr/bin/env bash
count=$(( $(<"$MV_COUNT") + 1 ))
printf '%s\n' "$count" > "$MV_COUNT"
"$REAL_MV" "$@"
status=$?
if [ "$status" -eq 0 ] && [ "$count" -eq 2 ]; then
    kill -TERM "$PPID"
fi
exit "$status"
FAKE_MV
            chmod +x "$publish_fakebin/mv"

            publish_status=0
            (
                export MV_COUNT="$publish_case/mv-count"
                export REAL_MV="$real_mv"
                PATH="$publish_fakebin:$PATH"
                # shellcheck source=/dev/null
                source "$builder_library"
                OUTPUT_DIR="$publish_output"
                ROOTFS_IMAGE="$publish_inputs/rootfs.ext4"
                KERNEL_IMAGE="$publish_inputs/vmlinuz"
                KERNEL_MODULES="$publish_inputs/modules.tar.gz"
                trap cleanup EXIT
                trap handle_int INT
                trap handle_term TERM
                publish_results
            ) || publish_status=$?
            [ "$publish_status" -eq 143 ] ||
                fail "TERM after output mv returned $publish_status instead of 143"
            [ -f "$publish_output/old-sentinel" ] ||
                fail 'publication TERM did not restore the previous output'
            grep -Fxq 'old-output' "$publish_output/old-sentinel" ||
                fail 'publication TERM changed the previous output content'
            for uncommitted_artifact in rootfs.ext4 vmlinuz modules.tar.gz; do
                [ ! -e "$publish_output/$uncommitted_artifact" ] ||
                    fail "publication TERM left an uncommitted artifact: $uncommitted_artifact"
            done
            publish_leftover="$(find "$publish_parent" -mindepth 1 -maxdepth 1 \
                \( -name '.ubuntu-server.old.*' -o -name '.ubuntu-server.new.*' \) \
                -print -quit)"
            [ -z "$publish_leftover" ] ||
                fail "publication TERM left transaction state behind: $publish_leftover"
        else
            fail 'builder has no sourceable transactional publish_results function'
        fi
    else
        fail 'builder has no sourceable boundary for mount-transition behavior testing'
    fi
fi

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
