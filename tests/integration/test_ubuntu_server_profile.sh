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
    dry_project="$work/dry-project"
    dry_builder="$dry_project/scripts/build_rootfs_ubuntu_server.sh"
    mkdir -p "$dry_project/scripts"
    cp "$builder" "$dry_builder"
    chmod +x "$dry_builder"

    builder_fakebin="$work/builder-fakebin"
    mkdir -p "$builder_fakebin"
    real_dirname="$(command -v dirname)"
    cat > "$builder_fakebin/dirname" <<'EARLY_DIRNAME'
#!/usr/bin/env bash
if [[ -v COSIM_GUEST_SSH_PASSWORD || -v GUEST_PASSWORD ]]; then
    : > "$EARLY_PASSWORD_LEAK"
fi
exec "$REAL_DIRNAME" "$@"
EARLY_DIRNAME
    export EARLY_PASSWORD_LEAK="$work/early-password-leak"
    export REAL_DIRNAME="$real_dirname"
    printf '#!/usr/bin/env bash\n: > "$BLOCKED_SENTINEL"\nexit 97\n' \
        > "$builder_fakebin/blocked"
    chmod +x "$builder_fakebin/dirname" "$builder_fakebin/blocked"
    for command_name in \
        sudo mount umount debootstrap apt apt-get curl wget truncate \
        mkfs.ext4 chroot tar depmod e2fsck; do
        ln -s blocked "$builder_fakebin/$command_name"
    done

    if ! snapshot_tree "$dry_project" > "$work/builder-tree-before"; then
        fail 'could not snapshot the isolated builder project before dry-run'
    fi
    builder_output_dir="$dry_project/guest/images/ubuntu-server"
    blocked_sentinel="$work/builder-blocked-command"
    if ! builder_output="$(COSIM_GUEST_SSH_PASSWORD=not-printed \
            GUEST_PASSWORD=attacker-exported-value \
            BLOCKED_SENTINEL="$blocked_sentinel" \
            PATH="$builder_fakebin:$PATH" \
            "$dry_builder" --dry-run "$builder_output_dir" 2>&1)"; then
        fail "Ubuntu Server builder dry-run failed: $builder_output"
    fi
    [ ! -e "$work/early-password-leak" ] ||
        fail 'Guest password leaked into the builder earliest child process'
    dry_mount_line="$(grep -F 'Mounts:' <<<"$builder_output")"
    expected_dry_mount_line='Mounts: root loop,nosuid (exec); sys/proc nosuid,nodev,noexec; dev/devpts nosuid'
    [ "$dry_mount_line" = "$expected_dry_mount_line" ] ||
        fail 'Ubuntu Server dry-run does not report the exact writable root mount options'
    dry_root_mount="${dry_mount_line%%;*}"
    case "$dry_root_mount" in
        *nodev*|*noexec*)
            fail 'Ubuntu Server dry-run claims the writable root uses nodev/noexec'
            ;;
    esac

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
    if ! dry_without_password="$(
            unset COSIM_GUEST_SSH_PASSWORD
            BLOCKED_SENTINEL="$work/builder-blocked-no-password" \
                PATH="$builder_fakebin:$PATH" \
                "$dry_builder" --dry-run "$builder_output_dir" 2>&1
        )"; then
        fail "Ubuntu Server dry-run required a Guest password: $dry_without_password"
    fi
    [ ! -e "$work/builder-blocked-no-password" ] ||
        fail 'passwordless dry-run invoked a blocked privileged/network command'
    if COSIM_GUEST_SSH_PASSWORD=not-printed \
            BLOCKED_SENTINEL="$work/builder-blocked-unknown" \
            PATH="$builder_fakebin:$PATH" \
            "$dry_builder" --unknown >/dev/null 2>&1; then
        fail 'Ubuntu Server builder accepted an unknown option'
    fi
    [ ! -e "$work/builder-blocked-unknown" ] || \
        fail 'builder unknown-option validation invoked a blocked command'
    if COSIM_GUEST_SSH_PASSWORD=not-printed \
            BLOCKED_SENTINEL="$work/builder-blocked-extra" \
            PATH="$builder_fakebin:$PATH" \
            "$dry_builder" --dry-run "$builder_output_dir" extra >/dev/null 2>&1; then
        fail 'Ubuntu Server builder accepted an extra positional argument'
    fi
    [ ! -e "$work/builder-blocked-extra" ] || \
        fail 'builder extra-argument validation invoked a blocked command'
    if ! snapshot_tree "$dry_project" > "$work/builder-tree-after"; then
        fail 'could not snapshot the isolated builder project after dry-run'
    fi
    assert_same "$work/builder-tree-before" "$work/builder-tree-after" \
        'Ubuntu Server builder dry-run changed the isolated project tree'

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
    assert_contains 'trap cleanup EXIT' "$builder_source" \
        'builder has no EXIT cleanup trap'
    assert_contains 'trap handle_int INT' "$builder_source" \
        'builder has no independent INT trap'
    assert_contains 'trap handle_term TERM' "$builder_source" \
        'builder has no independent TERM trap'
    expected_cleanup_traps=$'trap - EXIT\n    trap \'\' INT TERM'
    assert_contains "$expected_cleanup_traps" "$builder_source" \
        'builder cleanup does not ignore secondary INT/TERM signals'
    assert_contains 'capture_guest_password' "$builder_source" \
        'builder does not capture the Guest password before child processes'
    assert_contains 'unset COSIM_GUEST_SSH_PASSWORD' "$builder_source" \
        'builder does not remove the Guest password from the inherited environment'
    assert_contains 'mv -T --' "$builder_source" \
        'builder publication does not use no-target-directory renames'
    assert_contains '${BUILD_TMP}/ubuntu-server-output.' "$builder_source" \
        'builder output lock is not rooted in repo build/tmp'
    expected_root_mount=$'tracked_mount mounted_root "${MOUNT_DIR}" mount -o loop,nosuid \\\n    "${ROOTFS_IMAGE}" "${MOUNT_DIR}"'
    assert_contains "$expected_root_mount" "$builder_source" \
        'writable root mount is not loop,nosuid and signal-safe'
    assert_contains 'tracked_mount mounted_sys "${MOUNT_DIR}/sys" mount -t sysfs' \
        "$builder_source" 'sys mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_proc "${MOUNT_DIR}/proc" mount -t proc' \
        "$builder_source" 'proc mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_dev "${MOUNT_DIR}/dev" mount --bind /dev' \
        "$builder_source" 'dev mount is not signal-safe and tracked'
    assert_contains 'tracked_mount mounted_devpts "${MOUNT_DIR}/dev/pts" mount -t devpts' \
        "$builder_source" 'devpts mount is not signal-safe and tracked'
    prepare_offline_source="$(<"$repo/scripts/prepare-offline.sh")"
    assert_contains 'sudo mount -o loop,ro,nosuid,nodev -- "$image" "$mount_dir"' \
        "$prepare_offline_source" \
        'prepare-offline readonly rootfs mount lost ro,nosuid,nodev'
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
        root_mount_case="$work/root-mount-case"
        root_mount_fakebin="$root_mount_case/fakebin"
        root_mount_snippet="$root_mount_case/root-mount-snippet.sh"
        mkdir -p "$root_mount_fakebin" "$root_mount_case/root"
        if ! awk '
            /^tracked_mount mounted_root "\$\{MOUNT_DIR\}" mount -o / {
                capturing = 1
            }
            capturing { print }
            capturing && /^debootstrap --variant=minbase / {
                found = 1
                exit
            }
            END { if (!found) exit 1 }
        ' "$builder" > "$root_mount_snippet"; then
            fail 'could not extract the builder root-mount/debootstrap sequence'
        fi
        cat > "$root_mount_fakebin/mount" <<'ROOT_MOUNT'
#!/usr/bin/env bash
mount_options=''
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        shift
        mount_options="$1"
        break
    fi
    shift
done
printf '%s\n' "$mount_options" > "$ROOT_MOUNT_OPTIONS"
ROOT_MOUNT
        cat > "$root_mount_fakebin/debootstrap" <<'ROOT_DEBOOTSTRAP'
#!/usr/bin/env bash
mount_options="$(<"$ROOT_MOUNT_OPTIONS")"
case ",$mount_options," in
    *,nodev,*|*,noexec,*)
        echo 'Cannot install into target mounted with noexec or nodev' >&2
        exit 86
        ;;
esac
case ",$mount_options," in
    *,loop,*) ;;
    *)
        echo 'rootfs image was not mounted through a loop device' >&2
        exit 87
        ;;
esac
: > "$ROOT_DEBOOTSTRAP_OK"
ROOT_DEBOOTSTRAP
        chmod +x "$root_mount_fakebin/mount" \
            "$root_mount_fakebin/debootstrap"

        root_mount_status=0
        (
            export ROOT_MOUNT_OPTIONS="$root_mount_case/mount-options"
            export ROOT_DEBOOTSTRAP_OK="$root_mount_case/debootstrap-ok"
            PATH="$root_mount_fakebin:$PATH"
            # shellcheck source=/dev/null
            source "$builder_library"
            MOUNT_DIR="$root_mount_case/root"
            ROOTFS_IMAGE="$root_mount_case/rootfs.ext4"
            # shellcheck source=/dev/null
            source "$root_mount_snippet"
        ) > "$root_mount_case/output" 2>&1 || root_mount_status=$?
        [ "$root_mount_status" -eq 0 ] ||
            fail "writable rootfs mount blocked debootstrap with status $root_mount_status"
        [ -e "$root_mount_case/debootstrap-ok" ] ||
            fail 'debootstrap fixture did not accept the writable rootfs mount'

        password_case="$work/password-case"
        password_fakebin="$password_case/fakebin"
        mkdir -p "$password_fakebin"
        cat > "$password_fakebin/password-env-probe" <<'PASSWORD_ENV_PROBE'
#!/usr/bin/env bash
if [[ -v COSIM_GUEST_SSH_PASSWORD || -v GUEST_PASSWORD ]]; then
    : > "$PASSWORD_ENV_LEAK"
fi
PASSWORD_ENV_PROBE
        cat > "$password_fakebin/chroot" <<'PASSWORD_CHROOT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CHPASSWD_ARGS"
if [[ -v COSIM_GUEST_SSH_PASSWORD || -v GUEST_PASSWORD ]]; then
    : > "$PASSWORD_ENV_LEAK"
fi
cat > "$CHPASSWD_INPUT"
PASSWORD_CHROOT
        chmod +x "$password_fakebin/password-env-probe" \
            "$password_fakebin/chroot"

        if grep -Fq 'capture_guest_password() {' "$builder_library" &&
                grep -Fq 'validate_guest_password() {' "$builder_library" &&
                grep -Fq 'install_guest_password() {' "$builder_library"; then
            password_status=0
            (
                export COSIM_GUEST_SSH_PASSWORD='safe password:42'
                export GUEST_PASSWORD='attacker-exported-value'
                export PASSWORD_ENV_LEAK="$password_case/environment-leak"
                export CHPASSWD_ARGS="$password_case/chpasswd-args"
                export CHPASSWD_INPUT="$password_case/chpasswd-input"
                PATH="$password_fakebin:$PATH"
                # shellcheck source=/dev/null
                source "$builder_library"
                validate_guest_password
                [[ ! -v COSIM_GUEST_SSH_PASSWORD ]]
                password-env-probe
                install_guest_password /guest-root
            ) || password_status=$?
            [ "$password_status" -eq 0 ] ||
                fail "valid Guest password handling failed with status $password_status"
            [ ! -e "$password_case/environment-leak" ] ||
                fail 'Guest password variable leaked into a child process'
            printf '%s\n' '/guest-root' 'chpasswd' > "$password_case/expected-args"
            assert_same "$password_case/expected-args" "$password_case/chpasswd-args" \
                'Guest password helper invoked the wrong chroot command'
            printf '%s\n' 'ryan:safe password:42' > "$password_case/expected-input"
            assert_same "$password_case/expected-input" "$password_case/chpasswd-input" \
                'chpasswd did not receive exactly one controlled user/password record'

            bad_passwords=($'bad\rroot:injected' $'bad\nroot:injected' '')
            for bad_password in "${bad_passwords[@]}"; do
                bad_password_status=0
                (
                    export COSIM_GUEST_SSH_PASSWORD="$bad_password"
                    # shellcheck source=/dev/null
                    source "$builder_library"
                    validate_guest_password
                ) > "$password_case/rejected-output" 2>&1 ||
                    bad_password_status=$?
                [ "$bad_password_status" -ne 0 ] ||
                    fail 'builder accepted an empty or CR/LF Guest password'
            done
            missing_password_status=0
            (
                unset COSIM_GUEST_SSH_PASSWORD
                # shellcheck source=/dev/null
                source "$builder_library"
                validate_guest_password
            ) > "$password_case/missing-output" 2>&1 ||
                missing_password_status=$?
            [ "$missing_password_status" -ne 0 ] ||
                fail 'builder accepted a missing Guest password'
        else
            fail 'builder has no sourceable secure Guest password helpers'
        fi

        lock_claim_case="$work/lock-claim-case"
        lock_claim_fakebin="$lock_claim_case/fakebin"
        mkdir -p "$lock_claim_fakebin"
        real_mv="$(command -v mv)"
        cat > "$lock_claim_fakebin/mv" <<'LOCK_CLAIM_MV'
#!/usr/bin/env bash
if [ "$CLAIM_MUTATION" = replaced-directory ]; then
    lock_mv_count=$(( $(<"$LOCK_MV_COUNT") + 1 ))
    printf '%s\n' "$lock_mv_count" > "$LOCK_MV_COUNT"
    if [ "$lock_mv_count" -gt 1 ]; then
        : > "$STALE_CLEANUP_ATTEMPT"
    fi
fi
"$REAL_MV" "$@" || exit $?
lock_target=''
for lock_target in "$@"; do :; done
case "$CLAIM_MUTATION" in
    missing) rm -f -- "$lock_target/owner" ;;
    replaced) printf '%s\n' '999999999:third-party' > "$lock_target/owner" ;;
    replaced-directory)
        "$REAL_MV" -T -- "$lock_target" "$DISPLACED_LOCK"
        mkdir "$lock_target"
        printf '%s\n' '999999999:replacement' > "$lock_target/owner"
        stat -c '%d:%i' "$lock_target" > "$REPLACEMENT_ID"
        ;;
esac
LOCK_CLAIM_MV
        chmod +x "$lock_claim_fakebin/mv"

        for claim_mutation in missing replaced; do
            claim_dir="$lock_claim_case/$claim_mutation"
            claim_build_tmp="$claim_dir/build/tmp"
            claim_result="$claim_dir/result"
            mkdir -p "$claim_build_tmp"
            claim_status=0
            (
                export REAL_MV="$real_mv"
                export CLAIM_MUTATION="$claim_mutation"
                PATH="$lock_claim_fakebin:$PATH"
                # shellcheck source=/dev/null
                source "$builder_library"
                BUILD_TMP="$claim_build_tmp"
                OUTPUT_LOCK_CANDIDATE="$claim_build_tmp/.ubuntu-server-lock-candidate.test"
                OUTPUT_LOCK_DIR="$claim_build_tmp/ubuntu-server-output.$(
                    printf '0%.0s' {1..64}
                ).lock"
                OUTPUT_LOCK_OWNER="${BASHPID}:test"
                mkdir "$OUTPUT_LOCK_CANDIDATE"
                printf '%s\n' "$OUTPUT_LOCK_OWNER" > "$OUTPUT_LOCK_CANDIDATE/owner"
                claim_status=0
                claim_output_lock_once || claim_status=$?
                printf '%s\n%s\n' "$claim_status" "$output_lock_held" > "$claim_result"
            ) || claim_status=$?
            [ "$claim_status" -eq 0 ] ||
                fail "could not exercise $claim_mutation lock-owner mutation"
            claim_function_status="$(sed -n '1p' "$claim_result")"
            claim_held="$(sed -n '2p' "$claim_result")"
            [ "$claim_function_status" -ne 0 ] ||
                fail "lock claim reported success after its owner was $claim_mutation"
            [ "$claim_held" = false ] ||
                fail "lock claim marked itself held after its owner was $claim_mutation"
            claim_lock="$(find "$claim_build_tmp" -mindepth 1 -maxdepth 1 \
                -name 'ubuntu-server-output.*.lock' -print -quit)"
            if [ "$claim_mutation" = missing ]; then
                [ -z "$claim_lock" ] ||
                    fail 'ownerless claimed lock was not safely removed'
            else
                [ -n "$claim_lock" ] &&
                        grep -Fxq '999999999:third-party' "$claim_lock/owner" ||
                    fail 'lock claim removed or changed a replacement owner'
            fi
        done

        acquire_case="$lock_claim_case/acquire-replaced"
        acquire_build_tmp="$acquire_case/build/tmp"
        mkdir -p "$acquire_build_tmp"
        acquire_status=0
        (
            export REAL_MV="$real_mv"
            export CLAIM_MUTATION=replaced
            PATH="$lock_claim_fakebin:$PATH"
            # shellcheck source=/dev/null
            source "$builder_library"
            BUILD_TMP="$acquire_build_tmp"
            OUTPUT_DIR="$acquire_case/output"
            acquire_output_lock
            : > "$acquire_case/publication-continued"
        ) > "$acquire_case/acquire-output" 2>&1 || acquire_status=$?
        [ "$acquire_status" -ne 0 ] ||
            fail 'acquire continued after its claimed owner was replaced'
        [ ! -e "$acquire_case/publication-continued" ] ||
            fail 'publication continued without a verified output lock owner'
        acquire_lock="$(find "$acquire_build_tmp" -mindepth 1 -maxdepth 1 \
            -name 'ubuntu-server-output.*.lock' -print -quit)"
        [ -n "$acquire_lock" ] &&
                grep -Fxq '999999999:third-party' "$acquire_lock/owner" ||
            fail 'failed acquire removed or changed a replacement lock owner'

        directory_case="$lock_claim_case/acquire-directory-replaced"
        directory_build_tmp="$directory_case/build/tmp"
        directory_displaced="$directory_case/displaced-claim.lock"
        directory_replacement_id="$directory_case/replacement-id"
        directory_mv_count="$directory_case/mv-count"
        directory_stale_attempt="$directory_case/stale-cleanup-attempt"
        mkdir -p "$directory_build_tmp"
        printf '0\n' > "$directory_mv_count"
        directory_status=0
        (
            export REAL_MV="$real_mv"
            export CLAIM_MUTATION=replaced-directory
            export DISPLACED_LOCK="$directory_displaced"
            export REPLACEMENT_ID="$directory_replacement_id"
            export LOCK_MV_COUNT="$directory_mv_count"
            export STALE_CLEANUP_ATTEMPT="$directory_stale_attempt"
            PATH="$lock_claim_fakebin:$PATH"
            # shellcheck source=/dev/null
            source "$builder_library"
            BUILD_TMP="$directory_build_tmp"
            OUTPUT_DIR="$directory_case/output"
            acquire_output_lock
            : > "$directory_case/publication-continued"
        ) > "$directory_case/acquire-output" 2>&1 || directory_status=$?
        [ "$directory_status" -ne 0 ] ||
            fail 'acquire continued after its whole lock directory was replaced'
        [ ! -e "$directory_case/publication-continued" ] ||
            fail 'publication continued after an uncertain lock claim'
        directory_lock="$(find "$directory_build_tmp" -mindepth 1 -maxdepth 1 \
            -name 'ubuntu-server-output.*.lock' -print -quit)"
        directory_expected_id="$(<"$directory_replacement_id")"
        directory_current_id="$(stat -c '%d:%i' "$directory_lock" 2>/dev/null || true)"
        [ -n "$directory_lock" ] &&
                [ "$directory_current_id" = "$directory_expected_id" ] &&
                grep -Fxq '999999999:replacement' "$directory_lock/owner" ||
            fail 'acquire deleted or changed the replacement lock directory'
        [ -d "$directory_displaced" ] && [ ! -L "$directory_displaced" ] &&
                grep -Eq '^[1-9][0-9]*:[[:alnum:]]+$' \
                    "$directory_displaced/owner" ||
            fail 'acquire did not preserve the displaced original claim'
        [ ! -e "$directory_stale_attempt" ] &&
                [ "$(<"$directory_mv_count")" -eq 1 ] ||
            fail 'uncertain claim entered stale-lock cleanup or retried its candidate'

        signal_fakebin="$work/signal-fakebin"
        signal_build_tmp="$work/signal-build/tmp"
        signal_work_dir="$signal_build_tmp/ubuntu-server.signal-test"
        signal_root="$signal_work_dir/root"
        mkdir -p "$signal_fakebin" \
            "$signal_root/sys" "$signal_root/proc" \
            "$signal_root/dev/pts"
        printf '0\n' > "$work/mount-count"
        printf '0\n' > "$work/umount-count"
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
count=$(( $(<"$UMOUNT_COUNT") + 1 ))
printf '%s\n' "$count" > "$UMOUNT_COUNT"
if [ "$count" -eq 1 ]; then
    kill -TERM "$PPID"
fi
exit 0
FAKE_UMOUNT
        chmod +x "$signal_fakebin/mount" \
            "$signal_fakebin/mountpoint" "$signal_fakebin/umount"

        signal_status=0
        (
            export MOUNT_COUNT="$work/mount-count"
            export UMOUNT_COUNT="$work/umount-count"
            export MOUNTED_TARGETS="$work/mounted-targets"
            export UNMOUNT_LOG="$work/unmount-log"
            PATH="$signal_fakebin:$PATH"
            # shellcheck source=/dev/null
            source "$builder_library"
            BUILD_TMP="$signal_build_tmp"
            WORK_DIR="$signal_work_dir"
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
        [ ! -e "$signal_work_dir" ] ||
            fail 'secondary TERM interrupted temporary work cleanup'

        # Reproduce the publication return-point window: the second mv has
        # installed the new output, then signals the parent before the next
        # shell statement can update transaction state.
        if grep -Fq 'publish_results() {' "$builder_library"; then
            publish_case="$work/publish-case"
            publish_parent="$publish_case/images"
            publish_output="$publish_parent/ubuntu-server"
            publish_inputs="$publish_case/inputs"
            publish_fakebin="$publish_case/fakebin"
            publish_build_tmp="$publish_case/build/tmp"
            mkdir -p "$publish_output" "$publish_inputs" \
                "$publish_fakebin" "$publish_build_tmp"
            printf 'old-output\n' > "$publish_output/old-sentinel"
            printf 'new-rootfs\n' > "$publish_inputs/rootfs.ext4"
            printf 'new-kernel\n' > "$publish_inputs/vmlinuz"
            printf 'new-modules\n' > "$publish_inputs/modules.tar.gz"
            printf '0\n' > "$publish_case/mv-count"
            real_mv="$(command -v mv)"
            cat > "$publish_fakebin/mv" <<'FAKE_MV'
#!/usr/bin/env bash
tracked=false
for argument in "$@"; do
    if [ "$argument" = "$PUBLISH_OUTPUT" ]; then tracked=true; fi
done
if [ "$tracked" != true ]; then
    exec "$REAL_MV" "$@"
fi
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
                export PUBLISH_OUTPUT="$publish_output"
                PATH="$publish_fakebin:$PATH"
                # shellcheck source=/dev/null
                source "$builder_library"
                BUILD_TMP="$publish_build_tmp"
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
            publish_lock_leftover="$(find "$publish_build_tmp" -mindepth 1 -maxdepth 1 \
                -name 'ubuntu-server-output.*.lock' -print -quit)"
            [ -z "$publish_lock_leftover" ] ||
                fail "publication TERM left its output lock behind: $publish_lock_leftover"

            # A non-cooperating writer creates OUTPUT_DIR just before the new
            # stage rename.  Publication must fail without nesting the stage,
            # deleting that directory, or discarding the displaced old output.
            concurrent_case="$work/publish-concurrent-case"
            concurrent_parent="$concurrent_case/images"
            concurrent_output="$concurrent_parent/ubuntu-server"
            concurrent_inputs="$concurrent_case/inputs"
            concurrent_fakebin="$concurrent_case/fakebin"
            concurrent_build_tmp="$concurrent_case/build/tmp"
            mkdir -p "$concurrent_output" "$concurrent_inputs" \
                "$concurrent_fakebin" "$concurrent_build_tmp"
            printf 'old-output\n' > "$concurrent_output/old-sentinel"
            printf 'new-rootfs\n' > "$concurrent_inputs/rootfs.ext4"
            printf 'new-kernel\n' > "$concurrent_inputs/vmlinuz"
            printf 'new-modules\n' > "$concurrent_inputs/modules.tar.gz"
            printf '0\n' > "$concurrent_case/mv-count"
            cat > "$concurrent_fakebin/mv" <<'CONCURRENT_MV'
#!/usr/bin/env bash
tracked=false
for argument in "$@"; do
    if [ "$argument" = "$PUBLISH_OUTPUT" ]; then tracked=true; fi
done
if [ "$tracked" != true ]; then
    exec "$REAL_MV" "$@"
fi
count=$(( $(<"$MV_COUNT") + 1 ))
printf '%s\n' "$count" > "$MV_COUNT"
if [ "$count" -eq 2 ]; then
    mkdir -p "$CONCURRENT_OUTPUT"
    printf 'third-party\n' > "$CONCURRENT_OUTPUT/third-party-sentinel"
fi
"$REAL_MV" "$@"
CONCURRENT_MV
            chmod +x "$concurrent_fakebin/mv"

            concurrent_status=0
            (
                export MV_COUNT="$concurrent_case/mv-count"
                export REAL_MV="$real_mv"
                export CONCURRENT_OUTPUT="$concurrent_output"
                export PUBLISH_OUTPUT="$concurrent_output"
                PATH="$concurrent_fakebin:$PATH"
                # shellcheck source=/dev/null
                source "$builder_library"
                BUILD_TMP="$concurrent_build_tmp"
                OUTPUT_DIR="$concurrent_output"
                ROOTFS_IMAGE="$concurrent_inputs/rootfs.ext4"
                KERNEL_IMAGE="$concurrent_inputs/vmlinuz"
                KERNEL_MODULES="$concurrent_inputs/modules.tar.gz"
                trap cleanup EXIT
                trap handle_int INT
                trap handle_term TERM
                publish_results
            ) > "$concurrent_case/publish-output" 2>&1 || concurrent_status=$?
            [ "$concurrent_status" -ne 0 ] ||
                fail 'publication reported success after a concurrent target appeared'
            grep -Fxq 'third-party' "$concurrent_output/third-party-sentinel" ||
                fail 'publication deleted or changed the concurrent target directory'
            nested_stage="$(find "$concurrent_output" -mindepth 1 \
                -name '.ubuntu-server.new.*' -print -quit)"
            [ -z "$nested_stage" ] ||
                fail "publication nested its stage inside the concurrent target: $nested_stage"
            concurrent_new_leftover="$(find "$concurrent_parent" -mindepth 1 -maxdepth 1 \
                -name '.ubuntu-server.new.*' -print -quit)"
            [ -z "$concurrent_new_leftover" ] ||
                fail "publication left its new stage behind: $concurrent_new_leftover"
            recovery_dir="$(find "$concurrent_parent" -mindepth 1 -maxdepth 1 \
                -type d -name '.ubuntu-server.old.*' -print -quit)"
            [ -n "$recovery_dir" ] && [ -f "$recovery_dir/old-sentinel" ] ||
                fail 'publication did not preserve the displaced old output for recovery'
            concurrent_lock_leftover="$(find "$concurrent_build_tmp" \
                -mindepth 1 -maxdepth 1 -name 'ubuntu-server-output.*.lock' \
                -print -quit)"
            [ -z "$concurrent_lock_leftover" ] ||
                fail "failed publication left its output lock behind: $concurrent_lock_leftover"

            # GNU mv -T replaces an empty destination directory.  A writer
            # racing in an empty placeholder must retain that exact directory,
            # not merely leave some directory at OUTPUT_DIR after publication.
            empty_case="$work/publish-empty-concurrent-case"
            empty_parent="$empty_case/images"
            empty_output="$empty_parent/ubuntu-server"
            empty_inputs="$empty_case/inputs"
            empty_fakebin="$empty_case/fakebin"
            empty_build_tmp="$empty_case/build/tmp"
            mkdir -p "$empty_output" "$empty_inputs" \
                "$empty_fakebin" "$empty_build_tmp"
            printf 'old-output\n' > "$empty_output/old-sentinel"
            printf 'new-rootfs\n' > "$empty_inputs/rootfs.ext4"
            printf 'new-kernel\n' > "$empty_inputs/vmlinuz"
            printf 'new-modules\n' > "$empty_inputs/modules.tar.gz"
            printf '0\n' > "$empty_case/mv-count"
            cat > "$empty_fakebin/mv" <<'EMPTY_CONCURRENT_MV'
#!/usr/bin/env bash
tracked=false
for argument in "$@"; do
    if [ "$argument" = "$PUBLISH_OUTPUT" ]; then tracked=true; fi
done
if [ "$tracked" != true ]; then
    exec "$REAL_MV" "$@"
fi
count=$(( $(<"$MV_COUNT") + 1 ))
printf '%s\n' "$count" > "$MV_COUNT"
if [ "$count" -eq 2 ]; then
    mkdir -p "$CONCURRENT_OUTPUT"
    stat -c '%d:%i' "$CONCURRENT_OUTPUT" > "$PLACEHOLDER_ID"
fi
"$REAL_MV" "$@"
EMPTY_CONCURRENT_MV
            chmod +x "$empty_fakebin/mv"

            empty_status=0
            (
                export MV_COUNT="$empty_case/mv-count"
                export REAL_MV="$real_mv"
                export CONCURRENT_OUTPUT="$empty_output"
                export PLACEHOLDER_ID="$empty_case/placeholder-id"
                export PUBLISH_OUTPUT="$empty_output"
                PATH="$empty_fakebin:$PATH"
                # shellcheck source=/dev/null
                source "$builder_library"
                BUILD_TMP="$empty_build_tmp"
                OUTPUT_DIR="$empty_output"
                ROOTFS_IMAGE="$empty_inputs/rootfs.ext4"
                KERNEL_IMAGE="$empty_inputs/vmlinuz"
                KERNEL_MODULES="$empty_inputs/modules.tar.gz"
                trap cleanup EXIT
                trap handle_int INT
                trap handle_term TERM
                publish_results
            ) > "$empty_case/publish-output" 2>&1 || empty_status=$?
            [ "$empty_status" -ne 0 ] ||
                fail 'publication reported success after an empty concurrent target appeared'
            [ -d "$empty_output" ] && [ ! -L "$empty_output" ] ||
                fail 'publication removed the empty concurrent target directory'
            empty_placeholder_id="$(<"$empty_case/placeholder-id")"
            empty_current_id="$(stat -c '%d:%i' "$empty_output" 2>/dev/null || true)"
            [ "$empty_current_id" = "$empty_placeholder_id" ] ||
                fail 'publication replaced the empty concurrent target directory inode'
            empty_nested_entry="$(find "$empty_output" -mindepth 1 -print -quit)"
            [ -z "$empty_nested_entry" ] ||
                fail "publication populated the empty concurrent target: $empty_nested_entry"
            empty_new_leftover="$(find "$empty_parent" -mindepth 1 -maxdepth 1 \
                -name '.ubuntu-server.new.*' -print -quit)"
            [ -z "$empty_new_leftover" ] ||
                fail "empty-target failure left its new stage behind: $empty_new_leftover"
            empty_recovery_list="$empty_case/recovery-list"
            find "$empty_parent" -mindepth 1 -maxdepth 1 -type d \
                -name '.ubuntu-server.old.*' -print > "$empty_recovery_list"
            empty_recovery_count="$(wc -l < "$empty_recovery_list")"
            empty_recovery_dir="$(head -n 1 "$empty_recovery_list")"
            [ "$empty_recovery_count" -eq 1 ] &&
                    [ -f "$empty_recovery_dir/old-sentinel" ] &&
                    grep -Fxq 'old-output' "$empty_recovery_dir/old-sentinel" ||
                fail 'empty-target failure did not retain exactly one old-output recovery directory'
            empty_lock_leftover="$(find "$empty_build_tmp" \
                -mindepth 1 -maxdepth 1 -name 'ubuntu-server-output.*.lock' \
                -print -quit)"
            [ -z "$empty_lock_leftover" ] ||
                fail "empty-target failure left its output lock behind: $empty_lock_leftover"
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
