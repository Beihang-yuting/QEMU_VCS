#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp_root="$repo/build/tmp"
mkdir -p "$tmp_root"
work=$(mktemp -d "$tmp_root/offline-ubuntu-server-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

fixture_source="$work/original/source-tree"
fixture_archive_dir="$work/original/archive-dir"
relocated_dir="$work/relocated/archive-dir"
test_project="$work/import-target/project"
mkdir -p "$fixture_source/guest/ubuntu" \
    "$fixture_source/guest/ubuntu-server" "$fixture_archive_dir" \
    "$relocated_dir" "$test_project"
cp "$repo/setup.sh" "$test_project/setup.sh"
chmod +x "$test_project/setup.sh"

printf 'compact-kernel\n' > "$fixture_source/guest/ubuntu/vmlinuz"
printf 'compact-rootfs\n' > "$fixture_source/guest/ubuntu/rootfs.ext4"
printf 'server-kernel\n' > "$fixture_source/guest/ubuntu-server/vmlinuz"
printf 'server-modules\n' > "$fixture_source/guest/ubuntu-server/modules.tar.gz"
printf 'server-rootfs\n' > "$fixture_source/guest/ubuntu-server/rootfs.ext4"
cat > "$fixture_source/offline-meta.env" <<'EOF'
OFFLINE_VERSION=3
OFFLINE_GUEST_TYPE=ubuntu-server
OFFLINE_KVER=6.8.0-107-generic
OFFLINE_HAS_UBUNTU_ROOTFS=true
OFFLINE_HAS_UBUNTU_SERVER_ROOTFS=true
OFFLINE_UBUNTU_SERVER_HAS_HEADERS=true
OFFLINE_DPU_DEBUGUTILS_SHA256=1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab
EOF

archive="$fixture_archive_dir/offline-ubuntu-server.zip"
(cd "$fixture_source" && zip -qr "$archive" .)
(cd "$fixture_archive_dir" && md5sum "$(basename "$archive")" > "$(basename "$archive").md5")
mv "$archive" "${archive}.md5" "$relocated_dir/"
archive="$relocated_dir/$(basename "$archive")"

mkdir -p "$test_project/guest/images/ubuntu" \
    "$test_project/guest/images/ubuntu-server"
printf 'stale-compact-kernel\n' > "$test_project/guest/images/ubuntu/vmlinuz"
printf 'stale-compact-rootfs\n' > "$test_project/guest/images/ubuntu/rootfs.ext4"
printf 'stale-server-kernel\n' > "$test_project/guest/images/ubuntu-server/vmlinuz"
printf 'stale-server-modules\n' > "$test_project/guest/images/ubuntu-server/modules.tar.gz"
printf 'stale-server-rootfs\n' > "$test_project/guest/images/ubuntu-server/rootfs.ext4"

import_log="$work/import.log"
if ! "$test_project/setup.sh" --import "$archive" --import-only >"$import_log" 2>&1; then
    cat "$import_log" >&2
    fail 'relocated Ubuntu Server offline archive import failed'
fi

grep -Fq '离线包版本: 3' "$import_log" || \
    fail 'OFFLINE_VERSION=3 metadata is not supported by setup import'

for relative_path in \
    guest/ubuntu/vmlinuz \
    guest/ubuntu/rootfs.ext4 \
    guest/ubuntu-server/vmlinuz \
    guest/ubuntu-server/modules.tar.gz \
    guest/ubuntu-server/rootfs.ext4; do
    cmp "$fixture_source/$relative_path" \
        "$test_project/guest/images/${relative_path#guest/}" || \
        fail "imported artifact differs: $relative_path"
done

if grep -R -a -F -q -- "$fixture_source" "$test_project"; then
    fail 'imported project leaks the original absolute fixture path'
fi
if find "$test_project" -type f -name '*.ko' -print -quit | grep -q .; then
    fail 'default offline import unexpectedly installed a kernel module'
fi
if find "$test_project" -path '*/custom-driver*' -print -quit | grep -q .; then
    fail 'default offline import unexpectedly installed custom-driver content'
fi
if grep -R -I -E -q 'autoload|modules-load' "$test_project/guest/images"; then
    fail 'default offline import enabled driver autoloading'
fi

# Reject traversal before extraction or destination mutation.
printf 'stale-before-slip\n' > "$test_project/guest/images/ubuntu/vmlinuz"
slip_work="$work/zip-slip"
mkdir -p "$slip_work/source"
printf 'escape-attempt\n' > "$slip_work/escape.txt"
slip_archive="$slip_work/traversal.zip"
(cd "$slip_work/source" && zip -q "$slip_archive" ../escape.txt)
zipinfo -1 "$slip_archive" | grep -Fxq '../escape.txt' || \
    fail 'zip-slip fixture does not contain its traversal entry'
slip_log="$work/zip-slip.log"
if "$test_project/setup.sh" --import "$slip_archive" --import-only \
        >"$slip_log" 2>&1; then
    fail 'setup accepted a zip-slip offline archive'
fi
grep -Fq '不安全的离线包条目' "$slip_log" || \
    fail 'zip-slip archive was not rejected by entry preflight'
grep -Fxq 'stale-before-slip' "$test_project/guest/images/ubuntu/vmlinuz" || \
    fail 'zip-slip rejection changed an existing Guest artifact'
[ ! -e "$test_project/build/escape.txt" ] || \
    fail 'zip-slip archive escaped the import staging directory'
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'zip-slip rejection left import temporary state'
fi

# ZIP symlinks (and all other non-regular entry types) must be rejected before
# they can dereference data outside the archive or create links in the project.
symlink_source="$work/symlink/source"
mkdir -p "$symlink_source/guest/ubuntu"
printf 'outside-secret\n' > "$work/symlink/outside-secret"
ln -s "$work/symlink/outside-secret" "$symlink_source/guest/ubuntu/vmlinuz"
printf 'symlink-rootfs\n' > "$symlink_source/guest/ubuntu/rootfs.ext4"
printf 'OFFLINE_VERSION=3\n' > "$symlink_source/offline-meta.env"
symlink_archive="$work/symlink/archive.zip"
(cd "$symlink_source" && zip -qry "$symlink_archive" .)
printf 'stale-before-symlink\n' > "$test_project/guest/images/ubuntu/vmlinuz"
symlink_log="$work/symlink.log"
if "$test_project/setup.sh" --import "$symlink_archive" --import-only \
        >"$symlink_log" 2>&1; then
    fail 'setup accepted a symlink entry in an offline archive'
fi
grep -Fq '不安全的离线包条目类型' "$symlink_log" || \
    fail 'symlink archive was not rejected by entry-type preflight'
grep -Fxq 'stale-before-symlink' "$test_project/guest/images/ubuntu/vmlinuz" || \
    fail 'symlink rejection changed an existing Guest artifact'
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'symlink rejection left import temporary state'
fi

# Force an install-rename failure after the compact profile has been committed. Import
# must restore every old artifact, including files already overwritten.
rollback_source="$work/rollback/source"
mkdir -p "$rollback_source/guest/ubuntu" \
    "$rollback_source/guest/ubuntu-server" "$rollback_source/qemu-src"
printf 'rollback-qemu-source\n' > \
    "$rollback_source/qemu-src/qemu-9.2.0.tar.xz"
printf 'new-compact-kernel\n' > "$rollback_source/guest/ubuntu/vmlinuz"
printf 'new-compact-rootfs\n' > "$rollback_source/guest/ubuntu/rootfs.ext4"
printf 'new-server-kernel\n' > "$rollback_source/guest/ubuntu-server/vmlinuz"
printf 'new-server-modules\n' > "$rollback_source/guest/ubuntu-server/modules.tar.gz"
printf 'new-server-rootfs\n' > "$rollback_source/guest/ubuntu-server/rootfs.ext4"
cat > "$rollback_source/offline-meta.env" <<'EOF'
OFFLINE_VERSION=3
OFFLINE_GUEST_TYPE=ubuntu-server
OFFLINE_KVER=6.8.0-107-generic
OFFLINE_HAS_UBUNTU_ROOTFS=true
OFFLINE_HAS_UBUNTU_SERVER_ROOTFS=true
OFFLINE_UBUNTU_SERVER_HAS_HEADERS=true
OFFLINE_DPU_DEBUGUTILS_SHA256=1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab
EOF
rollback_archive="$work/rollback/archive.zip"
(cd "$rollback_source" && zip -qr "$rollback_archive" .)

for profile_artifact in \
    ubuntu/vmlinuz \
    ubuntu/rootfs.ext4 \
    ubuntu-server/vmlinuz \
    ubuntu-server/modules.tar.gz \
    ubuntu-server/rootfs.ext4; do
    printf 'stale:%s\n' "$profile_artifact" > \
        "$test_project/guest/images/$profile_artifact"
done
rollback_expected="$work/rollback/expected"
mkdir -p "$rollback_expected"
cp -a "$test_project/guest/images/ubuntu" "$rollback_expected/ubuntu"
cp -a "$test_project/guest/images/ubuntu-server" "$rollback_expected/ubuntu-server"

stage_copy_fakebin="$work/rollback/stage-copy-fakebin"
mkdir -p "$stage_copy_fakebin"
cat > "$stage_copy_fakebin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
case "$destination" in
    */offline-transaction.*/new/guest/images/ubuntu/vmlinuz)
        /usr/bin/cp "$@"
        exit 73
        ;;
esac
exec /usr/bin/cp "$@"
EOF
chmod +x "$stage_copy_fakebin/cp"
stage_copy_log="$work/rollback/stage-copy.log"
if PATH="$stage_copy_fakebin:$PATH" \
        "$test_project/setup.sh" --import "$rollback_archive" --import-only \
        >"$stage_copy_log" 2>&1; then
    fail 'staging copy content-then-return73 unexpectedly succeeded'
fi
for artifact in vmlinuz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu/$artifact" \
        "$test_project/guest/images/ubuntu/$artifact" || \
        fail "staging copy failure changed compact $artifact"
done
for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu-server/$artifact" \
        "$test_project/guest/images/ubuntu-server/$artifact" || \
        fail "staging copy failure changed server $artifact"
done
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'staging copy failure left import transaction state'
fi

qemu_copy_fakebin="$work/rollback/qemu-copy-fakebin"
mkdir -p "$qemu_copy_fakebin"
cat > "$qemu_copy_fakebin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
case "$destination" in
    */offline-transaction.*/sources/qemu/)
        /usr/bin/cp "$@"
        exit 74
        ;;
esac
exec /usr/bin/cp "$@"
EOF
chmod +x "$qemu_copy_fakebin/cp"
qemu_copy_log="$work/rollback/qemu-copy.log"
set +e
PATH="$qemu_copy_fakebin:$PATH" \
    "$test_project/setup.sh" --import "$rollback_archive" --import-only \
    >"$qemu_copy_log" 2>&1
qemu_copy_status=$?
set -e
[ "$qemu_copy_status" -ne 0 ] || \
    fail 'QEMU staging copy return74 unexpectedly succeeded'
for artifact in vmlinuz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu/$artifact" \
        "$test_project/guest/images/ubuntu/$artifact" || \
        fail "QEMU staging copy failure changed compact $artifact"
done
for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu-server/$artifact" \
        "$test_project/guest/images/ubuntu-server/$artifact" || \
        fail "QEMU staging copy failure changed server $artifact"
done
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'QEMU staging copy failure left import transaction state'
fi

rollback_fakebin="$work/rollback/fakebin"
mkdir -p "$rollback_fakebin"
cat > "$rollback_fakebin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
case "$destination" in
    "$OFFLINE_TEST_FAIL_DEST"|"$OFFLINE_TEST_FAIL_DEST"/*)
        if [ ! -e "$OFFLINE_TEST_FAIL_ONCE" ]; then
            : > "$OFFLINE_TEST_FAIL_ONCE"
            echo 'controlled import commit failure' >&2
            exit 73
        fi
        ;;
esac
exec /usr/bin/mv "$@"
EOF
chmod +x "$rollback_fakebin/mv"
rollback_log="$work/rollback/import.log"
if PATH="$rollback_fakebin:$PATH" \
        OFFLINE_TEST_FAIL_DEST="$test_project/guest/images/ubuntu-server" \
        OFFLINE_TEST_FAIL_ONCE="$work/rollback/fail-once" \
        "$test_project/setup.sh" --import "$rollback_archive" --import-only \
        >"$rollback_log" 2>&1; then
    fail 'controlled mid-import install rename failure unexpectedly succeeded'
fi
cmp -s "$rollback_expected/ubuntu/vmlinuz" \
    "$test_project/guest/images/ubuntu/vmlinuz" || \
    fail 'failed import did not restore the compact kernel'
cmp -s "$rollback_expected/ubuntu/rootfs.ext4" \
    "$test_project/guest/images/ubuntu/rootfs.ext4" || \
    fail 'failed import did not restore the compact rootfs'
for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu-server/$artifact" \
        "$test_project/guest/images/ubuntu-server/$artifact" || \
        fail "failed import did not restore Ubuntu Server $artifact"
done
grep -Fq '回滚' "$rollback_log" || \
    fail 'failed import did not report transaction rollback'
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'failed import left transaction temporary state'
fi

move_nonzero_fakebin="$work/rollback/move-nonzero-fakebin"
mkdir -p "$move_nonzero_fakebin"
cat > "$move_nonzero_fakebin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
if [ "$destination" = "$OFFLINE_TEST_MOVE_NONZERO_DEST" ] && \
        [ ! -e "$OFFLINE_TEST_MOVE_NONZERO_ONCE" ]; then
    : > "$OFFLINE_TEST_MOVE_NONZERO_ONCE"
    /usr/bin/mv "$@"
    exit 75
fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$move_nonzero_fakebin/mv"
for profile_artifact in \
    ubuntu/vmlinuz \
    ubuntu/rootfs.ext4 \
    ubuntu-server/vmlinuz \
    ubuntu-server/modules.tar.gz \
    ubuntu-server/rootfs.ext4; do
    printf 'move75-stale:%s\n' "$profile_artifact" > \
        "$test_project/guest/images/$profile_artifact"
done
move_nonzero_expected="$work/rollback/move-nonzero-expected"
mkdir -p "$move_nonzero_expected"
/usr/bin/cp -a "$test_project/guest/images/ubuntu" \
    "$move_nonzero_expected/ubuntu"
/usr/bin/cp -a "$test_project/guest/images/ubuntu-server" \
    "$move_nonzero_expected/ubuntu-server"
move_nonzero_log="$work/rollback/move-nonzero.log"
set +e
PATH="$move_nonzero_fakebin:$PATH" \
    OFFLINE_TEST_MOVE_NONZERO_DEST="$test_project/guest/images/ubuntu" \
    OFFLINE_TEST_MOVE_NONZERO_ONCE="$work/rollback/move-nonzero-once" \
    "$test_project/setup.sh" --import "$rollback_archive" --import-only \
    >"$move_nonzero_log" 2>&1
move_nonzero_status=$?
set -e
[ "$move_nonzero_status" -ne 0 ] || \
    fail 'install move completed then return75 unexpectedly succeeded'
for artifact in vmlinuz rootfs.ext4; do
    cmp -s "$move_nonzero_expected/ubuntu/$artifact" \
        "$test_project/guest/images/ubuntu/$artifact" || \
        fail "move return75 did not restore compact $artifact"
done
for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
    cmp -s "$move_nonzero_expected/ubuntu-server/$artifact" \
        "$test_project/guest/images/ubuntu-server/$artifact" || \
        fail "move return75 changed server $artifact"
done
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'move return75 left import transaction state'
fi

# Signals on either side of the backup rename must observe a complete state
# transition: before-rename keeps the original in place; after-rename restores
# it from backup.  Exercise both INT and TERM independently.
signal_fakebin="$work/rollback/signal-fakebin"
mkdir -p "$signal_fakebin"
cat > "$signal_fakebin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
trigger=false
case "$OFFLINE_TEST_SIGNAL_PHASE:$destination" in
    backup:*/offline-transaction.*/backup/guest/images/ubuntu)
        trigger=true ;;
    install:"$OFFLINE_TEST_INSTALL_DEST")
        trigger=true ;;
esac
if [ "$trigger" = true ]; then
        if [ ! -e "$OFFLINE_TEST_SIGNAL_ONCE" ]; then
            : > "$OFFLINE_TEST_SIGNAL_ONCE"
            if [ "$OFFLINE_TEST_SIGNAL_DIRECTION" = after ]; then
                /usr/bin/mv "$@"
            fi
            kill -s "$OFFLINE_TEST_SIGNAL_NAME" "$PPID"
            [ "$OFFLINE_TEST_SIGNAL_DIRECTION" = after ] && exit 0
            exit 73
        fi
fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$signal_fakebin/mv"
for signal_phase in backup install; do
    for signal_direction in before after; do
        for signal_name in INT TERM; do
        for profile_artifact in \
            ubuntu/vmlinuz \
            ubuntu/rootfs.ext4 \
            ubuntu-server/vmlinuz \
            ubuntu-server/modules.tar.gz \
            ubuntu-server/rootfs.ext4; do
            printf 'signal-stale:%s\n' "$profile_artifact" > \
                "$test_project/guest/images/$profile_artifact"
        done
        signal_expected="$work/rollback/signal-expected-$signal_phase-$signal_direction-$signal_name"
        mkdir -p "$signal_expected"
        /usr/bin/cp -a "$test_project/guest/images/ubuntu" "$signal_expected/ubuntu"
        /usr/bin/cp -a "$test_project/guest/images/ubuntu-server" \
            "$signal_expected/ubuntu-server"
        signal_once="$work/rollback/signal-once-$signal_phase-$signal_direction-$signal_name"
        signal_log="$work/rollback/signal-$signal_phase-$signal_direction-$signal_name.log"
        set +e
        PATH="$signal_fakebin:$PATH" \
            OFFLINE_TEST_SIGNAL_ONCE="$signal_once" \
            OFFLINE_TEST_SIGNAL_PHASE="$signal_phase" \
            OFFLINE_TEST_INSTALL_DEST="$test_project/guest/images/ubuntu" \
            OFFLINE_TEST_SIGNAL_DIRECTION="$signal_direction" \
            OFFLINE_TEST_SIGNAL_NAME="$signal_name" \
            "$test_project/setup.sh" --import "$rollback_archive" --import-only \
            >"$signal_log" 2>&1
        signal_status=$?
        set -e
        expected_status=130
        [ "$signal_name" = TERM ] && expected_status=143
        [ "$signal_status" -eq "$expected_status" ] || \
            fail "$signal_name during $signal_phase $signal_direction rename returned $signal_status"
        for artifact in vmlinuz rootfs.ext4; do
            cmp -s "$signal_expected/ubuntu/$artifact" \
                "$test_project/guest/images/ubuntu/$artifact" || \
                fail "$signal_name during $signal_phase $signal_direction rename lost compact $artifact"
        done
        for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
            cmp -s "$signal_expected/ubuntu-server/$artifact" \
                "$test_project/guest/images/ubuntu-server/$artifact" || \
                fail "$signal_name during $signal_phase $signal_direction rename changed server $artifact"
        done
        if find "$test_project/build" -maxdepth 2 -type d \
                \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
                -print -quit | grep -q .; then
            fail "$signal_name during $signal_phase $signal_direction rename left transaction state"
        fi
        done
    done
done

# Atomic install requires transaction/new and the final parent to share a
# device.  A mismatch must fail before the first backup rename.
cross_device_fakebin="$work/rollback/cross-device-fakebin"
mkdir -p "$cross_device_fakebin"
cat > "$cross_device_fakebin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate="${@: -1}"
case "$candidate" in
    */offline-transaction.*/new/guest/images/ubuntu)
        [ "${OFFLINE_TEST_STAT_ERROR:-false}" = false ] || exit 88
        printf '111\n'; exit 0 ;;
    "$OFFLINE_TEST_FINAL_PARENT")
        printf '222\n'; exit 0 ;;
esac
exec /usr/bin/stat "$@"
EOF
cat > "$cross_device_fakebin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${@: -1}" in
    */offline-transaction.*/backup/*)
        : > "$OFFLINE_TEST_BACKUP_RENAME_SEEN" ;;
esac
exec /usr/bin/mv "$@"
EOF
chmod +x "$cross_device_fakebin/stat" "$cross_device_fakebin/mv"
printf 'cross-device-stale\n' > "$test_project/guest/images/ubuntu/vmlinuz"
cross_device_log="$work/rollback/cross-device.log"
backup_rename_seen="$work/rollback/backup-rename-seen"
if PATH="$cross_device_fakebin:$PATH" \
        OFFLINE_TEST_FINAL_PARENT="$test_project/guest/images" \
        OFFLINE_TEST_BACKUP_RENAME_SEEN="$backup_rename_seen" \
        "$test_project/setup.sh" --import "$rollback_archive" --import-only \
        >"$cross_device_log" 2>&1; then
    fail 'cross-device transaction unexpectedly succeeded'
fi
grep -Fq '不同文件系统' "$cross_device_log" || \
    fail 'cross-device rejection did not explain the device mismatch'
grep -Fxq 'cross-device-stale' "$test_project/guest/images/ubuntu/vmlinuz" || \
    fail 'cross-device rejection changed the old compact kernel'
[ ! -e "$backup_rename_seen" ] || \
    fail 'cross-device rejection occurred after a backup rename'

printf 'stat-error-stale\n' > "$test_project/guest/images/ubuntu/vmlinuz"
stat_error_log="$work/rollback/stat-error.log"
if PATH="$cross_device_fakebin:$PATH" \
        OFFLINE_TEST_STAT_ERROR=true \
        OFFLINE_TEST_FINAL_PARENT="$test_project/guest/images" \
        OFFLINE_TEST_BACKUP_RENAME_SEEN="$backup_rename_seen" \
        "$test_project/setup.sh" --import "$rollback_archive" --import-only \
        >"$stat_error_log" 2>&1; then
    fail 'transaction continued after stat failed'
fi
grep -Fxq 'stat-error-stale' "$test_project/guest/images/ubuntu/vmlinuz" || \
    fail 'stat failure changed the old compact kernel'
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'stat failure left import transaction state'
fi

# If another actor creates/replaces the final tree after backup, rollback must
# preserve both the third-party final and the original backup for recovery.
for profile_artifact in \
    ubuntu/vmlinuz \
    ubuntu/rootfs.ext4 \
    ubuntu-server/vmlinuz \
    ubuntu-server/modules.tar.gz \
    ubuntu-server/rootfs.ext4; do
    printf 'conflict-stale:%s\n' "$profile_artifact" > \
        "$test_project/guest/images/$profile_artifact"
done
conflict_fakebin="$work/rollback/conflict-fakebin"
mkdir -p "$conflict_fakebin"
cat > "$conflict_fakebin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
if [ "$destination" = "$OFFLINE_TEST_CONFLICT_DEST" ]; then
    mkdir -p "$destination"
    printf 'third-party-tree\n' > "$destination/concurrent-marker"
    exit 74
fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$conflict_fakebin/mv"
conflict_log="$work/rollback/conflict.log"
if PATH="$conflict_fakebin:$PATH" \
        OFFLINE_TEST_CONFLICT_DEST="$test_project/guest/images/ubuntu-server" \
        "$test_project/setup.sh" --import "$rollback_archive" --import-only \
        >"$conflict_log" 2>&1; then
    fail 'concurrent replacement import unexpectedly succeeded'
fi
grep -Fxq 'third-party-tree' \
    "$test_project/guest/images/ubuntu-server/concurrent-marker" || \
    fail 'rollback deleted a concurrent replacement tree'
conflict_backup=$(find "$test_project/build/tmp" -type f \
    -path '*/offline-transaction.*/backup/guest/images/ubuntu-server/vmlinuz' \
    -print -quit)
[ -n "$conflict_backup" ] || fail 'rollback discarded the original conflict backup'
grep -Fxq 'conflict-stale:ubuntu-server/vmlinuz' "$conflict_backup" || \
    fail 'preserved conflict backup does not contain the original tree'
grep -Fq '并发冲突' "$conflict_log" || \
    fail 'rollback did not report its concurrent replacement conflict'

# Exercise the real packager with controlled rootfs mount and package-download
# boundaries.  The generated ZIP and all metadata remain production outputs;
# only privileged/image operations are replaced by deterministic fixtures.
package_project="$work/package-project"
mkdir -p "$package_project/scripts" "$package_project/third_party" \
    "$package_project/guest/images/debian" \
    "$package_project/guest/images/ubuntu" \
    "$package_project/guest/images/ubuntu-server" \
    "$package_project/guest/driver/prebuilt" "$package_project/build/tmp"
cp "$repo/scripts/prepare-offline.sh" "$package_project/scripts/prepare-offline.sh"
chmod +x "$package_project/scripts/prepare-offline.sh"
printf 'qemu-source-fixture\n' > "$package_project/third_party/qemu-9.2.0.tar.xz"
printf 'debian-kernel\n' > "$package_project/guest/images/debian/bzImage"
printf 'debian-rootfs\n' > "$package_project/guest/images/debian/rootfs.ext4"
printf 'compact-kernel\n' > "$package_project/guest/images/ubuntu/vmlinuz"
printf 'compact-modules\n' > "$package_project/guest/images/ubuntu/modules.tar.gz"
printf 'compact-rootfs\n' > "$package_project/guest/images/ubuntu/rootfs.ext4"
printf 'server-kernel\n' > "$package_project/guest/images/ubuntu-server/vmlinuz"
printf 'server-modules\n' > "$package_project/guest/images/ubuntu-server/modules.tar.gz"
printf 'server-rootfs\n' > "$package_project/guest/images/ubuntu-server/rootfs.ext4"
printf 'prebuilt-module\n' > \
    "$package_project/guest/driver/prebuilt/cosim_nic_6.8.0-107-generic.ko"

compact_root="$work/mount-fixtures/compact"
server_root="$work/mount-fixtures/server"
bad_server_root="$work/mount-fixtures/server-missing-make"
for root in "$compact_root" "$server_root"; do
    mkdir -p "$root/usr/local/bin"
    printf '#!/bin/sh\nexit 0\n' > "$root/usr/local/bin/pci_debug"
    printf '#!/bin/sh\nexit 0\n' > "$root/usr/local/bin/reg_display"
    chmod 0755 "$root/usr/local/bin/pci_debug" "$root/usr/local/bin/reg_display"
done
mkdir -p "$server_root/etc" "$server_root/usr/bin" \
    "$server_root/usr/src/linux-headers-6.8.0-107-generic" \
    "$server_root/lib/modules/6.8.0-107-generic" \
    "$server_root/opt/dpu-debugutils"
cat > "$server_root/etc/os-release" <<'EOF'
NAME="Ubuntu"
ID=ubuntu
VERSION_ID="24.04"
EOF
for tool in gcc make; do
    printf '#!/bin/sh\nexit 0\n' > "$server_root/usr/bin/$tool"
    chmod 0755 "$server_root/usr/bin/$tool"
done
printf 'headers-fixture\n' > \
    "$server_root/usr/src/linux-headers-6.8.0-107-generic/Makefile"
ln -s /usr/src/linux-headers-6.8.0-107-generic \
    "$server_root/lib/modules/6.8.0-107-generic/build"
printf 'debug-source-fixture\n' > "$server_root/opt/dpu-debugutils/Makefile"
cp -a "$server_root" "$bad_server_root"
rm -f "$bad_server_root/usr/bin/make"

fakebin="$work/fakebin"
mount_log="$work/mount.log"
umount_log="$work/umount.log"
mkdir -p "$fakebin"
cat > "$fakebin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = '-n' ] && [ "$#" -eq 1 ]; then
    exit 0
fi
exec "$@"
EOF
cat > "$fakebin/apt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = download ] || exit 70
printf 'header package fixture\n' > "${2}_1_amd64.deb"
EOF
cat > "$fakebin/mount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_image="${@: -2:1}"
target="${@: -1}"
printf '%s\t%s\t%s\n' "$*" "$source_image" "$target" >> "$OFFLINE_TEST_MOUNT_LOG"
case "$source_image" in
    */guest/images/ubuntu-server/rootfs.ext4)
        fixture_root="$OFFLINE_TEST_SERVER_ROOT" ;;
    */guest/images/ubuntu/rootfs.ext4)
        fixture_root="$OFFLINE_TEST_COMPACT_ROOT" ;;
    */guest/images/debian/rootfs.ext4)
        fixture_root="$OFFLINE_TEST_DEBIAN_ROOT" ;;
    *) exit 71 ;;
esac
mkdir -p "$target"
cp -a "$fixture_root/." "$target/"
EOF
cat > "$fakebin/umount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${@: -1}"
printf '%s\n' "$target" >> "$OFFLINE_TEST_UMOUNT_LOG"
find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
EOF
chmod +x "$fakebin/sudo" "$fakebin/apt" "$fakebin/mount" "$fakebin/umount"

package_archive="$work/output/offline-ubuntu-server.zip"
mkdir -p "$(dirname "$package_archive")"
: > "$mount_log"
: > "$umount_log"
if ! PATH="$fakebin:$PATH" \
    OFFLINE_TEST_MOUNT_LOG="$mount_log" \
    OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
    OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
    OFFLINE_TEST_SERVER_ROOT="$server_root" \
    "$package_project/scripts/prepare-offline.sh" \
        --guest ubuntu-server --output "$package_archive" >"$work/package.log" 2>&1; then
    cat "$work/package.log" >&2
    fail 'Ubuntu Server offline packaging failed'
fi

for entry in \
    guest/ubuntu/vmlinuz \
    guest/ubuntu/rootfs.ext4 \
    guest/ubuntu-server/vmlinuz \
    guest/ubuntu-server/modules.tar.gz \
    guest/ubuntu-server/rootfs.ext4; do
    zipinfo -1 "$package_archive" | grep -Fxq "$entry" || \
        fail "offline package is missing $entry"
done
metadata=$(unzip -p "$package_archive" offline-meta.env)
for field in \
    OFFLINE_VERSION=3 \
    OFFLINE_GUEST_TYPE=ubuntu-server \
    OFFLINE_KVER=6.8.0-107-generic \
    OFFLINE_HAS_UBUNTU_ROOTFS=true \
    OFFLINE_HAS_UBUNTU_SERVER_ROOTFS=true \
    OFFLINE_UBUNTU_SERVER_HAS_HEADERS=true \
    OFFLINE_DPU_DEBUGUTILS_SHA256=1da850673e19b04a239456ae119527a7937cf13bfefdc7236c7570ffdd3d11ab; do
    grep -Fxq "$field" <<<"$metadata" || fail "offline metadata is missing $field"
done
if zipinfo -1 "$package_archive" | grep -Eq '(^|/)custom-driver(/|$)'; then
    fail 'default offline package unexpectedly contains a custom driver'
fi
if zipinfo -1 "$package_archive" | grep -E '\.ko$' >/dev/null; then
    fail 'default Ubuntu Server offline package unexpectedly contains a direct .ko'
fi
if zipinfo -1 "$package_archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    fail 'offline package contains an unsafe or absolute entry path'
fi

package_import_project="$work/package-import-project"
mkdir -p "$package_import_project"
cp "$repo/setup.sh" "$package_import_project/setup.sh"
chmod +x "$package_import_project/setup.sh"
if ! "$package_import_project/setup.sh" --import "$package_archive" --import-only \
        >"$work/package-import.log" 2>&1; then
    cat "$work/package-import.log" >&2
    fail 'generated Ubuntu Server archive could not be imported'
fi
if find "$package_import_project" -type f -name '*.ko' -print -quit | grep -q .; then
    fail 'generated Ubuntu Server import tree contains a direct .ko'
fi

direct_ko_source="$work/direct-ko/source"
mkdir -p "$direct_ko_source/driver"
printf 'unexpected-direct-module\n' > \
    "$direct_ko_source/driver/cosim_nic_6.8.0-107-generic.ko"
direct_ko_archive="$work/direct-ko/archive.zip"
cp "$package_archive" "$direct_ko_archive"
(cd "$direct_ko_source" && zip -q "$direct_ko_archive" \
    driver/cosim_nic_6.8.0-107-generic.ko)
printf 'preflight-sentinel\n' > "$package_import_project/import-sentinel"
direct_ko_log="$work/direct-ko/import.log"
if "$package_import_project/setup.sh" --import "$direct_ko_archive" --import-only \
        >"$direct_ko_log" 2>&1; then
    fail 'setup accepted a direct .ko in a v3 Ubuntu Server archive'
fi
grep -Fq 'direct .ko' "$direct_ko_log" || \
    fail 'direct .ko preflight rejection did not explain the policy'
grep -Fxq 'preflight-sentinel' "$package_import_project/import-sentinel" || \
    fail 'direct .ko preflight rejection changed the target project'
if find "$package_import_project" -type f -name '*.ko' -print -quit | grep -q .; then
    fail 'direct .ko preflight rejection imported a kernel module'
fi
test "$(wc -l < "$mount_log")" -eq 2 || \
    fail 'packager did not validate both selected Ubuntu rootfs images'
test "$(wc -l < "$umount_log")" -eq 2 || \
    fail 'packager did not unmount both validated rootfs images'
while IFS=$'\t' read -r mount_args _source mount_target; do
    case ",$mount_args," in
        *ro*) ;;
        *) fail 'packager did not mount a selected rootfs read-only' ;;
    esac
    case "$mount_target" in
        "$package_project/build/tmp"/*) ;;
        *) fail "packager mount path escaped project build/tmp: $mount_target" ;;
    esac
    [ ! -e "$mount_target" ] || fail "packager left mount workspace: $mount_target"
done < "$mount_log"
[ ! -e "$package_project/build/offline-staging" ] || \
    fail 'packager used the legacy production temporary path outside build/tmp'

# The direct cosim_nic artifact remains part of legacy ubuntu/debian packages.
for legacy_guest in ubuntu debian; do
    legacy_archive="$work/output/legacy-$legacy_guest.zip"
    : > "$mount_log"
    : > "$umount_log"
    if ! PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_DEBIAN_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest "$legacy_guest" --output "$legacy_archive" \
            >"$work/package-legacy-$legacy_guest.log" 2>&1; then
        cat "$work/package-legacy-$legacy_guest.log" >&2
        fail "legacy $legacy_guest offline packaging failed"
    fi
    zipinfo -1 "$legacy_archive" | \
        grep -Eq '^driver/cosim_nic_.*\.ko$' || \
        fail "legacy $legacy_guest package lost direct cosim_nic.ko"
done

# A relative build link resolving inside the mounted rootfs is valid.
relative_server_root="$work/mount-fixtures/server-relative-link"
cp -a "$server_root" "$relative_server_root"
rm -f "$relative_server_root/lib/modules/6.8.0-107-generic/build"
ln -s ../../../usr/src/linux-headers-6.8.0-107-generic \
    "$relative_server_root/lib/modules/6.8.0-107-generic/build"
relative_archive="$work/output/relative-build-link.zip"
: > "$mount_log"
: > "$umount_log"
if ! PATH="$fakebin:$PATH" \
    OFFLINE_TEST_MOUNT_LOG="$mount_log" \
    OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
    OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
    OFFLINE_TEST_SERVER_ROOT="$relative_server_root" \
    "$package_project/scripts/prepare-offline.sh" \
        --guest ubuntu-server --output "$relative_archive" \
        >"$work/package-relative-link.log" 2>&1; then
    cat "$work/package-relative-link.log" >&2
    fail 'packager rejected a rootfs-scoped relative kernel build link'
fi
test "$(wc -l < "$umount_log")" -eq 2 || \
    fail 'relative build-link validation did not unmount both rootfs images'

# A relative link escaping MOUNT_ROOT, and an absolute target that exists only
# on the host, must not satisfy the in-rootfs build-link requirement.
for unsafe_link_case in escape host-only; do
    unsafe_server_root="$work/mount-fixtures/server-$unsafe_link_case"
    cp -a "$server_root" "$unsafe_server_root"
    rm -f "$unsafe_server_root/lib/modules/6.8.0-107-generic/build"
    if [ "$unsafe_link_case" = escape ]; then
        ln -s ../../../../../../../../bin \
            "$unsafe_server_root/lib/modules/6.8.0-107-generic/build"
    else
        ln -s /bin "$unsafe_server_root/lib/modules/6.8.0-107-generic/build"
    fi
    unsafe_archive="$work/output/unsafe-$unsafe_link_case.zip"
    : > "$mount_log"
    : > "$umount_log"
    if PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$unsafe_server_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$unsafe_archive" \
            >"$work/package-unsafe-$unsafe_link_case.log" 2>&1; then
        fail "packager accepted the $unsafe_link_case kernel build link"
    fi
    grep -Fq "/lib/modules/6.8.0-107-generic/build" \
        "$work/package-unsafe-$unsafe_link_case.log" || \
        fail "$unsafe_link_case failure does not identify the kernel build link"
    test "$(wc -l < "$umount_log")" -eq 2 || \
        fail "$unsafe_link_case validation did not unmount both rootfs images"
    [ ! -e "$unsafe_archive" ] || \
        fail "$unsafe_link_case validation published a partial ZIP"
done

# A rootfs contract failure must abort packaging, unmount the image, remove the
# temporary staging tree, and avoid publishing even a partial ZIP.
failed_archive="$work/output/invalid-server.zip"
: > "$mount_log"
: > "$umount_log"
if PATH="$fakebin:$PATH" \
    OFFLINE_TEST_MOUNT_LOG="$mount_log" \
    OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
    OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
    OFFLINE_TEST_SERVER_ROOT="$bad_server_root" \
    "$package_project/scripts/prepare-offline.sh" \
        --guest ubuntu-server --output "$failed_archive" >"$work/package-failure.log" 2>&1; then
    fail 'packager accepted an Ubuntu Server rootfs without make'
fi
grep -Fq '/usr/bin/make' "$work/package-failure.log" || \
    fail 'rootfs validation failure does not identify /usr/bin/make'
test "$(wc -l < "$umount_log")" -eq 2 || \
    fail 'rootfs validation failure did not unmount all mounted images'
[ ! -e "$failed_archive" ] || fail 'failed packaging published a partial ZIP'
while IFS=$'\t' read -r _mount_args _source mount_target; do
    [ ! -e "$mount_target" ] || \
        fail "failed packaging left mount workspace: $mount_target"
done < "$mount_log"

echo 'PASS: relocated import and Ubuntu Server offline packaging'
