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

make_complete_qemu_tar() {
    local output="$1" source_root
    local subproject
    source_root=$(mktemp -d "$work/qemu-source.XXXXXX")
    for subproject in keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do
        mkdir -p "$source_root/qemu-9.2.0/subprojects/$subproject"
        printf 'project(%s)\n' "$subproject" > \
            "$source_root/qemu-9.2.0/subprojects/$subproject/meson.build"
    done
    tar -cJf "$output" -C "$source_root" qemu-9.2.0
    rm -rf "$source_root"
}

fixture_source="$work/original/source-tree"
fixture_archive_dir="$work/original/archive-dir"
relocated_dir="$work/relocated/archive-dir"
test_project="$work/import-target/project"
mkdir -p "$fixture_source/guest/ubuntu" "$fixture_source/qemu-src" \
    "$fixture_source/guest/ubuntu-server" "$fixture_archive_dir" \
    "$relocated_dir" "$test_project/scripts"
cp "$repo/setup.sh" "$test_project/setup.sh"
ln -s "$repo/scripts/validate-qemu-source-closure.py" \
    "$test_project/scripts/validate-qemu-source-closure.py"
chmod +x "$test_project/setup.sh"

make_complete_qemu_tar "$fixture_source/qemu-src/qemu-9.2.0.tar.xz"

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
[ "$(stat -c '%a' "$test_project/build/tmp")" = 700 ] || \
    fail 'setup did not enforce mode 0700 on build/tmp'
[ "$(stat -c '%u' "$test_project/build/tmp")" = "$(id -u)" ] || \
    fail 'setup build/tmp is not owned by the invoking user'

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

# An incomplete nested QEMU tar must be rejected before any import transaction
# copy or existing project artifact mutation.
incomplete_qemu_source="$work/incomplete-qemu/source"
mkdir -p "$incomplete_qemu_source"
cp -a "$fixture_source/." "$incomplete_qemu_source/"
printf 'not-a-qemu-tar\n' > \
    "$incomplete_qemu_source/qemu-src/qemu-9.2.0.tar.xz"
incomplete_qemu_archive="$work/incomplete-qemu/archive.zip"
(cd "$incomplete_qemu_source" && zip -qr "$incomplete_qemu_archive" .)
incomplete_qemu_expected="$work/incomplete-qemu/existing-qemu.tar.xz"
cp "$test_project/third_party/qemu-9.2.0.tar.xz" "$incomplete_qemu_expected"
incomplete_qemu_fakebin="$work/incomplete-qemu/fakebin"
incomplete_qemu_copy_marker="$work/incomplete-qemu/transaction-copy-called"
incomplete_qemu_transaction_marker="$work/incomplete-qemu/transaction-created"
mkdir -p "$incomplete_qemu_fakebin"
cat > "$incomplete_qemu_fakebin/cp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
destination="${@: -1}"
case "$destination" in
    */offline-transaction.*/*)
        : > "$OFFLINE_TEST_TRANSACTION_COPY_CALLED" ;;
esac
exec /usr/bin/cp "$@"
EOF
cat > "$incomplete_qemu_fakebin/mktemp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *offline-transaction.*)
        : > "$OFFLINE_TEST_TRANSACTION_CREATED" ;;
esac
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$incomplete_qemu_fakebin/cp" "$incomplete_qemu_fakebin/mktemp"
incomplete_qemu_log="$work/incomplete-qemu/import.log"
if PATH="$incomplete_qemu_fakebin:$PATH" \
        OFFLINE_TEST_TRANSACTION_COPY_CALLED="$incomplete_qemu_copy_marker" \
        OFFLINE_TEST_TRANSACTION_CREATED="$incomplete_qemu_transaction_marker" \
        "$test_project/setup.sh" --import "$incomplete_qemu_archive" --import-only \
        >"$incomplete_qemu_log" 2>&1; then
    fail 'setup accepted an incomplete nested QEMU tar'
fi
grep -Fq 'QEMU source closure' "$incomplete_qemu_log" || \
    fail 'nested QEMU rejection did not identify source closure'
[ ! -e "$incomplete_qemu_copy_marker" ] || \
    fail 'nested QEMU rejection copied into an import transaction'
[ ! -e "$incomplete_qemu_transaction_marker" ] || \
    fail 'nested QEMU rejection created an import transaction'
cmp -s "$incomplete_qemu_expected" \
    "$test_project/third_party/qemu-9.2.0.tar.xz" || \
    fail 'nested QEMU rejection changed the existing project tar'
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'nested QEMU rejection left import temporary state'
fi

assert_nested_qemu_name_rejected() {
    local case_name="$1" variant_source="$2"
    local variant_archive variant_log copy_marker transaction_marker
    variant_archive="$work/qemu-name-$case_name/archive.zip"
    variant_log="$work/qemu-name-$case_name/import.log"
    copy_marker="$work/qemu-name-$case_name/transaction-copy-called"
    transaction_marker="$work/qemu-name-$case_name/transaction-created"
    mkdir -p "$(dirname "$variant_archive")"
    (cd "$variant_source" && zip -qr "$variant_archive" .)
    if PATH="$incomplete_qemu_fakebin:$PATH" \
            OFFLINE_TEST_TRANSACTION_COPY_CALLED="$copy_marker" \
            OFFLINE_TEST_TRANSACTION_CREATED="$transaction_marker" \
            "$test_project/setup.sh" --import "$variant_archive" --import-only \
            >"$variant_log" 2>&1; then
        fail "setup accepted invalid nested QEMU archive names: $case_name"
    fi
    grep -Fq 'QEMU 源码包名称或数量' "$variant_log" || {
        cat "$variant_log" >&2
        fail "nested QEMU name rejection was unclear: $case_name"
    }
    [ ! -e "$copy_marker" ] || \
        fail "nested QEMU name rejection copied into a transaction: $case_name"
    [ ! -e "$transaction_marker" ] || \
        fail "nested QEMU name rejection created a transaction: $case_name"
    cmp -s "$incomplete_qemu_expected" \
        "$test_project/third_party/qemu-9.2.0.tar.xz" || \
        fail "nested QEMU name rejection changed the existing tar: $case_name"
}

wrong_qemu_name_source="$work/qemu-name-wrong/source"
mkdir -p "$(dirname "$wrong_qemu_name_source")"
cp -a "$fixture_source" "$wrong_qemu_name_source"
mv "$wrong_qemu_name_source/qemu-src/qemu-9.2.0.tar.xz" \
    "$wrong_qemu_name_source/qemu-src/qemu-9.2.0-source.tar.xz"

dual_qemu_name_source="$work/qemu-name-dual/source"
mkdir -p "$(dirname "$dual_qemu_name_source")"
cp -a "$fixture_source" "$dual_qemu_name_source"
cp "$dual_qemu_name_source/qemu-src/qemu-9.2.0.tar.xz" \
    "$dual_qemu_name_source/qemu-src/qemu-9.2.0.tar.gz"

extra_qemu_name_source="$work/qemu-name-extra/source"
mkdir -p "$(dirname "$extra_qemu_name_source")"
cp -a "$fixture_source" "$extra_qemu_name_source"
cp "$extra_qemu_name_source/qemu-src/qemu-9.2.0.tar.xz" \
    "$extra_qemu_name_source/qemu-src/qemu-unexpected.tar.xz"

missing_v3_qemu_source="$work/qemu-name-missing-v3/source"
mkdir -p "$(dirname "$missing_v3_qemu_source")"
cp -a "$fixture_source" "$missing_v3_qemu_source"
rm -f "$missing_v3_qemu_source/qemu-src/qemu-9.2.0.tar.xz"
assert_nested_qemu_name_rejected dual "$dual_qemu_name_source"
assert_nested_qemu_name_rejected wrong "$wrong_qemu_name_source"
assert_nested_qemu_name_rejected extra "$extra_qemu_name_source"
assert_nested_qemu_name_rejected missing-v3 "$missing_v3_qemu_source"

missing_python_bin="$work/missing-python/bin"
missing_python_log="$work/missing-python/import.log"
missing_python_transaction_marker="$work/missing-python/transaction-created"
mkdir -p "$missing_python_bin"
for required_command in awk basename bash cat chmod cmp cp cut dirname du find \
        grep head id md5sum mkdir readlink realpath rm sha256sum sort stat tar \
        uniq unzip wc zipinfo; do
    ln -s "$(command -v "$required_command")" \
        "$missing_python_bin/$required_command"
done
cat > "$missing_python_bin/mktemp" <<'EOF'
#!/bin/bash
set -euo pipefail
case "$*" in
    *offline-transaction.*)
        : > "$OFFLINE_TEST_TRANSACTION_CREATED" ;;
esac
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$missing_python_bin/mktemp"
set +e
PATH="$missing_python_bin" \
    OFFLINE_TEST_TRANSACTION_CREATED="$missing_python_transaction_marker" \
    /bin/bash "$test_project/setup.sh" --import "$archive" --import-only \
    >"$missing_python_log" 2>&1
missing_python_status=$?
set -e
[ "$missing_python_status" -ne 0 ] || \
    fail 'setup accepted a nested QEMU tar without python3 available'
grep -Fq '缺少 QEMU source closure 校验依赖: python3' \
    "$missing_python_log" || {
    cat "$missing_python_log" >&2
    fail 'missing python3 rejection did not identify the validator dependency'
}
[ ! -e "$missing_python_transaction_marker" ] || \
    fail 'missing python3 rejection created an import transaction'
cmp -s "$incomplete_qemu_expected" \
    "$test_project/third_party/qemu-9.2.0.tar.xz" || \
    fail 'missing python3 rejection changed the existing QEMU tar'

artifact_preflight_expected="$work/artifact-preflight-expected"
mkdir -p "$artifact_preflight_expected"
/usr/bin/cp -a "$test_project/guest/images/ubuntu" \
    "$artifact_preflight_expected/ubuntu"
/usr/bin/cp -a "$test_project/guest/images/ubuntu-server" \
    "$artifact_preflight_expected/ubuntu-server"
for missing_artifact in \
    guest/ubuntu/vmlinuz \
    guest/ubuntu/rootfs.ext4 \
    guest/ubuntu-server/vmlinuz \
    guest/ubuntu-server/modules.tar.gz \
    guest/ubuntu-server/rootfs.ext4; do
    variant_name=${missing_artifact//\//-}
    variant_source="$work/artifact-preflight/$variant_name/source"
    mkdir -p "$(dirname "$variant_source")"
    /usr/bin/cp -a "$fixture_source" "$variant_source"
    rm -f "$variant_source/$missing_artifact"
    variant_archive="$work/artifact-preflight/$variant_name/archive.zip"
    (cd "$variant_source" && zip -qr "$variant_archive" .)
    variant_log="$work/artifact-preflight/$variant_name/import.log"
    if "$test_project/setup.sh" --import "$variant_archive" --import-only \
            >"$variant_log" 2>&1; then
        fail "v3 Ubuntu Server import accepted missing $missing_artifact"
    fi
    grep -Fq "$missing_artifact" "$variant_log" || \
        fail "v3 artifact rejection did not identify $missing_artifact"
    for artifact in vmlinuz rootfs.ext4; do
        cmp -s "$artifact_preflight_expected/ubuntu/$artifact" \
            "$test_project/guest/images/ubuntu/$artifact" || \
            fail "missing $missing_artifact changed compact $artifact"
    done
    for artifact in vmlinuz modules.tar.gz rootfs.ext4; do
        cmp -s "$artifact_preflight_expected/ubuntu-server/$artifact" \
            "$test_project/guest/images/ubuntu-server/$artifact" || \
            fail "missing $missing_artifact changed server $artifact"
    done
    if find "$test_project/build" -maxdepth 2 -type d \
            \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
            -print -quit | grep -q .; then
        fail "missing $missing_artifact left import transaction state"
    fi
done

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
cp "$fixture_source/qemu-src/qemu-9.2.0.tar.xz" \
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

missing_zipinfo_bin="$work/rollback/missing-zipinfo-bin"
mkdir -p "$missing_zipinfo_bin"
for required_command in bash dirname du cut wc awk grep sort uniq mkdir mktemp \
        rm find basename cp cmp stat tar sha256sum mv readlink realpath; do
    ln -s "$(command -v "$required_command")" \
        "$missing_zipinfo_bin/$required_command"
done
cat > "$missing_zipinfo_bin/unzip" <<'EOF'
#!/bin/bash
set -euo pipefail
: > "$OFFLINE_TEST_UNZIP_CALLED"
exec /usr/bin/unzip "$@"
EOF
chmod +x "$missing_zipinfo_bin/unzip"
missing_zipinfo_log="$work/rollback/missing-zipinfo.log"
missing_zipinfo_unzip_called="$work/rollback/missing-zipinfo-unzip-called"
set +e
PATH="$missing_zipinfo_bin" \
    OFFLINE_TEST_UNZIP_CALLED="$missing_zipinfo_unzip_called" \
    /bin/bash "$test_project/setup.sh" --import "$rollback_archive" --import-only \
    >"$missing_zipinfo_log" 2>&1
missing_zipinfo_status=$?
set -e
[ "$missing_zipinfo_status" -ne 0 ] || \
    fail 'setup accepted an archive without zipinfo available'
[ ! -e "$missing_zipinfo_unzip_called" ] || \
    fail 'zipinfo dependency failure invoked unzip before rejection'
grep -Fq 'zipinfo' "$missing_zipinfo_log" || \
    fail 'missing zipinfo rejection did not identify the dependency'
for artifact in vmlinuz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu/$artifact" \
        "$test_project/guest/images/ubuntu/$artifact" || \
        fail "missing zipinfo changed compact $artifact"
done
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'missing zipinfo left import transaction state'
fi

partial_zipinfo_bin="$work/rollback/partial-zipinfo-bin"
mkdir -p "$partial_zipinfo_bin"
cat > "$partial_zipinfo_bin/zipinfo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
    -1)
        printf 'offline-meta.env\n'
        exit 82
        ;;
    -l)
        printf '%s\n' '-rw-r--r--  3.0 unx       10 tx       10 stor 26-Aug-06 00:00 offline-meta.env'
        exit 83
        ;;
esac
exit 84
EOF
cat > "$partial_zipinfo_bin/unzip" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: > "$OFFLINE_TEST_UNZIP_CALLED"
exec /usr/bin/unzip "$@"
EOF
chmod +x "$partial_zipinfo_bin/zipinfo" "$partial_zipinfo_bin/unzip"
partial_zipinfo_log="$work/rollback/partial-zipinfo.log"
partial_zipinfo_unzip_called="$work/rollback/partial-zipinfo-unzip-called"
set +e
PATH="$partial_zipinfo_bin:$PATH" \
    OFFLINE_TEST_UNZIP_CALLED="$partial_zipinfo_unzip_called" \
    "$test_project/setup.sh" --import "$rollback_archive" --import-only \
    >"$partial_zipinfo_log" 2>&1
partial_zipinfo_status=$?
set -e
[ "$partial_zipinfo_status" -ne 0 ] || \
    fail 'setup accepted partial zipinfo output with a nonzero status'
[ ! -e "$partial_zipinfo_unzip_called" ] || \
    fail 'partial zipinfo failure invoked unzip before rejection'
grep -Fq 'zipinfo' "$partial_zipinfo_log" || \
    fail 'partial zipinfo failure did not identify archive listing validation'
for artifact in vmlinuz rootfs.ext4; do
    cmp -s "$rollback_expected/ubuntu/$artifact" \
        "$test_project/guest/images/ubuntu/$artifact" || \
        fail "partial zipinfo failure changed compact $artifact"
done
if find "$test_project/build" -maxdepth 2 -type d \
        \( -name 'offline-import*' -o -name 'offline-transaction*' \) \
        -print -quit | grep -q .; then
    fail 'partial zipinfo failure left import transaction state'
fi

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
set +e
PATH="$rollback_fakebin:$PATH" \
    OFFLINE_TEST_FAIL_DEST="$test_project/guest/images/ubuntu-server" \
    OFFLINE_TEST_FAIL_ONCE="$work/rollback/fail-once" \
    "$test_project/setup.sh" --import "$rollback_archive" --import-only \
    >"$rollback_log" 2>&1
rollback_status=$?
set -e
[ "$rollback_status" -eq 73 ] || \
    fail "controlled mid-import install rename returned $rollback_status instead of 73"
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

restore_failure_fakebin="$work/rollback/restore-failure-fakebin"
mkdir -p "$restore_failure_fakebin"
cat > "$restore_failure_fakebin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source_path="${@: -2:1}"
destination="${@: -1}"
if [ "$destination" = "$OFFLINE_TEST_RESTORE_DEST" ]; then
    case "$source_path" in
        */offline-transaction.*/new/*)
            if [ ! -e "$OFFLINE_TEST_INSTALL_ONCE" ]; then
                : > "$OFFLINE_TEST_INSTALL_ONCE"
                /usr/bin/mv "$@"
                exit 75
            fi
            ;;
        */offline-transaction.*/backup/*)
            echo 'controlled restore failure' >&2
            exit 76
            ;;
    esac
fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$restore_failure_fakebin/mv"
for profile_artifact in \
    ubuntu/vmlinuz \
    ubuntu/rootfs.ext4 \
    ubuntu-server/vmlinuz \
    ubuntu-server/modules.tar.gz \
    ubuntu-server/rootfs.ext4; do
    printf 'restore76-stale:%s\n' "$profile_artifact" > \
        "$test_project/guest/images/$profile_artifact"
done
restore_failure_log="$work/rollback/restore-failure.log"
set +e
PATH="$restore_failure_fakebin:$PATH" \
    OFFLINE_TEST_RESTORE_DEST="$test_project/guest/images/ubuntu" \
    OFFLINE_TEST_INSTALL_ONCE="$work/rollback/restore-install-once" \
    "$test_project/setup.sh" --import "$rollback_archive" --import-only \
    >"$restore_failure_log" 2>&1
restore_failure_status=$?
set -e
[ "$restore_failure_status" -eq 75 ] || \
    fail "restore mv failure replaced original status 75 with $restore_failure_status"
if [ -f "$test_project/guest/images/ubuntu/vmlinuz" ] && \
        grep -Fxq 'new-compact-kernel' \
        "$test_project/guest/images/ubuntu/vmlinuz"; then
    fail 'restore mv failure left the imported compact tree as a false success'
fi
restore_failure_backup=$(find "$test_project/build/tmp" -type f \
    -path '*/offline-transaction.*/backup/guest/images/ubuntu/vmlinuz' \
    -print -quit)
[ -n "$restore_failure_backup" ] || \
    fail 'restore mv failure discarded the only compact backup'
grep -Fxq 'restore76-stale:ubuntu/vmlinuz' "$restore_failure_backup" || \
    fail 'restore mv failure preserved the wrong backup content'
grep -Fq 'recovery' "$restore_failure_log" || \
    fail 'restore mv failure did not report a recovery path'
restore_failure_transaction="${restore_failure_backup%%/backup/*}"
mkdir -p "$test_project/guest/images"
/usr/bin/cp -a "$(dirname "$restore_failure_backup")" \
    "$test_project/guest/images/ubuntu"
find "$restore_failure_transaction" -depth -delete

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
ln -s "$repo/scripts/validate-qemu-source-closure.py" \
    "$package_project/scripts/validate-qemu-source-closure.py"
chmod +x "$package_project/scripts/prepare-offline.sh"
make_complete_qemu_tar "$package_project/third_party/qemu-9.2.0.tar.xz"
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
: > "$target/.offline-test-mounted"
if [ -n "${OFFLINE_TEST_MOUNT_SIGNAL_NAME:-}" ] &&
        [ ! -e "$OFFLINE_TEST_MOUNT_SIGNAL_ONCE" ]; then
    : > "$OFFLINE_TEST_MOUNT_SIGNAL_ONCE"
    kill -s "$OFFLINE_TEST_MOUNT_SIGNAL_NAME" "$PPID"
    if [ "${OFFLINE_TEST_MOUNT_INACTIVE_AFTER_SIGNAL:-false}" = true ]; then
        find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    fi
fi
EOF
cat > "$fakebin/umount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${@: -1}"
printf '%s\n' "$target" >> "$OFFLINE_TEST_UMOUNT_LOG"
if [ "${OFFLINE_TEST_UMOUNT_FAIL:-false}" = true ]; then
    exit 77
fi
find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
EOF
cat > "$fakebin/mountpoint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${@: -1}"
if [ "${OFFLINE_TEST_MOUNTPOINT_ERROR:-false}" = true ]; then
    exit 65
fi
if [ -f "$target/.offline-test-mounted" ]; then
    exit 0
fi
inactive_status=${OFFLINE_TEST_MOUNTPOINT_INACTIVE_STATUS:-32}
if [ "${1:-}" != -q ] && [ "$inactive_status" -eq 1 ]; then
    [ "${LC_ALL:-}" = C ] || exit 97
    case "${OFFLINE_TEST_MOUNTPOINT_DIAGNOSTIC_KIND:-not-mounted}" in
        not-mounted) printf '%s is not a mountpoint\n' "$target" ;;
        missing) printf 'mountpoint: %s: No such file or directory\n' "$target" >&2 ;;
        permission) printf 'mountpoint: %s: Permission denied\n' "$target" >&2 ;;
        system) printf 'mountpoint: failed to read mount table: Input/output error\n' >&2 ;;
        unexpected) printf 'warning: %s is not a mountpoint\n' "$target" >&2 ;;
        *) exit 96 ;;
    esac
fi
exit "$inactive_status"
EOF
chmod +x "$fakebin/sudo" "$fakebin/apt" "$fakebin/mount" "$fakebin/umount" \
    "$fakebin/mountpoint"

# A user-supplied local tar is not required to match the official digest, but
# it must satisfy the same source-closure contract before a ZIP is published.
incomplete_package_project="$work/incomplete-package-project"
/usr/bin/cp -a "$package_project" "$incomplete_package_project"
printf 'plaintext-incomplete-qemu\n' > \
    "$incomplete_package_project/third_party/qemu-9.2.0.tar.xz"
incomplete_package_archive="$work/output/incomplete-qemu.zip"
if PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$incomplete_package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$incomplete_package_archive" \
            >"$work/incomplete-package.log" 2>&1; then
    fail 'packager accepted an incomplete local QEMU tar'
fi
grep -Fq 'QEMU source closure' "$work/incomplete-package.log" || \
    fail 'incomplete local QEMU rejection did not identify source closure'
[ ! -e "$incomplete_package_archive" ] || \
    fail 'incomplete local QEMU input published a ZIP'

# The default download must use the official URL and reject even a structurally
# complete tar when it does not match the pinned official release digest.
download_package_project="$work/download-package-project"
/usr/bin/cp -a "$package_project" "$download_package_project"
rm -f "$download_package_project/third_party/qemu-9.2.0.tar.xz"
download_fakebin="$work/download-fakebin"
download_url_log="$work/download-url.log"
mkdir -p "$download_fakebin"
cat > "$download_fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
printf '%s\n' "$url" >> "$OFFLINE_TEST_DOWNLOAD_URL_LOG"
cp "$OFFLINE_TEST_DOWNLOAD_FIXTURE" "$output"
EOF
chmod +x "$download_fakebin/curl"
wrong_hash_archive="$work/output/wrong-official-hash.zip"
if PATH="$download_fakebin:$fakebin:$PATH" \
        OFFLINE_TEST_DOWNLOAD_URL_LOG="$download_url_log" \
        OFFLINE_TEST_DOWNLOAD_FIXTURE="$package_project/third_party/qemu-9.2.0.tar.xz" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$download_package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$wrong_hash_archive" \
            >"$work/wrong-official-hash.log" 2>&1; then
    fail 'packager accepted a wrong-hash official QEMU download'
fi
grep -Fxq 'https://download.qemu.org/qemu-9.2.0.tar.xz' "$download_url_log" || \
    fail 'packager did not request the official QEMU release URL'
grep -Fq 'SHA-256' "$work/wrong-official-hash.log" || \
    fail 'wrong official QEMU digest did not report SHA-256 failure'
[ ! -e "$wrong_hash_archive" ] || \
    fail 'wrong-hash official QEMU download published a ZIP'

# Neither offline entry point may create temporary state through a symlink in
# the project-local build/tmp path.  Cover both possible linked components and
# collect all failures so both scripts are exercised in the initial RED run.
unsafe_tmp_failures=0
for unsafe_component in build tmp; do
    unsafe_setup_project="$work/unsafe-tmp/setup-$unsafe_component"
    unsafe_setup_outside="$work/unsafe-tmp/setup-$unsafe_component-outside"
    mkdir -p "$unsafe_setup_project" "$unsafe_setup_outside"
    printf 'keep\n' > "$unsafe_setup_outside/sentinel"
    cp "$repo/setup.sh" "$unsafe_setup_project/setup.sh"
    chmod +x "$unsafe_setup_project/setup.sh"
    if [ "$unsafe_component" = build ]; then
        ln -s "$unsafe_setup_outside" "$unsafe_setup_project/build"
    else
        mkdir -p "$unsafe_setup_project/build"
        ln -s "$unsafe_setup_outside" "$unsafe_setup_project/build/tmp"
    fi
    if "$unsafe_setup_project/setup.sh" --import "$archive" --import-only \
            >"$work/unsafe-tmp/setup-$unsafe_component.log" 2>&1; then
        echo "setup accepted symlinked $unsafe_component in build/tmp" >&2
        unsafe_tmp_failures=$((unsafe_tmp_failures + 1))
    fi
    if find "$unsafe_setup_outside" -mindepth 1 ! -name sentinel \
            -print -quit | grep -q .; then
        echo "setup mutated outside symlink target for $unsafe_component" >&2
        unsafe_tmp_failures=$((unsafe_tmp_failures + 1))
    fi

    unsafe_package_project="$work/unsafe-tmp/package-$unsafe_component"
    unsafe_package_outside="$work/unsafe-tmp/package-$unsafe_component-outside"
    /usr/bin/cp -a "$package_project" "$unsafe_package_project"
    find "$unsafe_package_project/build" -depth -delete
    mkdir -p "$unsafe_package_outside"
    printf 'keep\n' > "$unsafe_package_outside/sentinel"
    if [ "$unsafe_component" = build ]; then
        ln -s "$unsafe_package_outside" "$unsafe_package_project/build"
    else
        mkdir -p "$unsafe_package_project/build"
        ln -s "$unsafe_package_outside" "$unsafe_package_project/build/tmp"
    fi
    unsafe_package_archive="$work/output/unsafe-tmp-$unsafe_component.zip"
    : > "$mount_log"
    : > "$umount_log"
    if PATH="$fakebin:$PATH" \
            OFFLINE_TEST_MOUNT_LOG="$mount_log" \
            OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
            OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
            OFFLINE_TEST_SERVER_ROOT="$server_root" \
            "$unsafe_package_project/scripts/prepare-offline.sh" \
                --guest ubuntu-server --output "$unsafe_package_archive" \
                >"$work/unsafe-tmp/package-$unsafe_component.log" 2>&1; then
        echo "packager accepted symlinked $unsafe_component in build/tmp" >&2
        unsafe_tmp_failures=$((unsafe_tmp_failures + 1))
    fi
    if find "$unsafe_package_outside" -mindepth 1 ! -name sentinel \
            -print -quit | grep -q .; then
        echo "packager mutated outside symlink target for $unsafe_component" >&2
        unsafe_tmp_failures=$((unsafe_tmp_failures + 1))
    fi
done
[ "$unsafe_tmp_failures" -eq 0 ] || \
    fail "$unsafe_tmp_failures build/tmp symlink-hardening contract(s) failed"

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
[ "$(stat -c '%a' "$package_project/build/tmp")" = 700 ] || \
    fail 'packager did not enforce mode 0700 on build/tmp'
[ "$(stat -c '%u' "$package_project/build/tmp")" = "$(id -u)" ] || \
    fail 'packager build/tmp is not owned by the invoking user'

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
mkdir -p "$package_import_project/scripts"
cp "$repo/setup.sh" "$package_import_project/setup.sh"
ln -s "$repo/scripts/validate-qemu-source-closure.py" \
    "$package_import_project/scripts/validate-qemu-source-closure.py"
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
    mount_options=""
    read -r -a mount_words <<< "$mount_args"
    for ((mount_word_index=0; mount_word_index<${#mount_words[@]}; mount_word_index++)); do
        if [ "${mount_words[$mount_word_index]}" = -o ] &&
                [ "$((mount_word_index + 1))" -lt "${#mount_words[@]}" ]; then
            mount_options=${mount_words[$((mount_word_index + 1))]}
            break
        fi
    done
    for required_mount_option in ro nosuid nodev; do
        case ",$mount_options," in
            *,"$required_mount_option",*) ;;
            *) fail "packager mount options lack exact $required_mount_option token" ;;
        esac
    done
    case "$mount_target" in
        "$package_project/build/tmp"/*) ;;
        *) fail "packager mount path escaped project build/tmp: $mount_target" ;;
    esac
    [ ! -e "$mount_target" ] || fail "packager left mount workspace: $mount_target"
done < "$mount_log"
[ ! -e "$package_project/build/offline-staging" ] || \
    fail 'packager used the legacy production temporary path outside build/tmp'

# A signal delivered after mount has taken effect but before the mount command
# returns must be deferred until the parent records the live mount.  Cleanup
# then unmounts it exactly once and preserves unrelated build/tmp content.
for mount_signal_case in HUP:129 INT:130 TERM:143; do
    mount_signal_name=${mount_signal_case%%:*}
    mount_signal_expected=${mount_signal_case#*:}
    mount_signal_log="$work/mount-signal-$mount_signal_name.log"
    mount_signal_once="$work/mount-signal-$mount_signal_name.once"
    mount_signal_archive="$work/output/mount-signal-$mount_signal_name.zip"
    mount_signal_keep="$package_project/build/tmp/mount-signal-keep-$mount_signal_name"
    printf 'keep\n' > "$mount_signal_keep"
    : > "$mount_log"
    : > "$umount_log"
    set +e
    PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_MOUNT_SIGNAL_NAME="$mount_signal_name" \
        OFFLINE_TEST_MOUNT_SIGNAL_ONCE="$mount_signal_once" \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$mount_signal_archive" \
            >"$mount_signal_log" 2>&1
    mount_signal_status=$?
    set -e
    [ "$mount_signal_status" -eq "$mount_signal_expected" ] || \
        fail "$mount_signal_name after mount returned $mount_signal_status"
    test "$(wc -l < "$mount_log")" -eq 1 || \
        fail "$mount_signal_name after mount did not stop after the first mount"
    test "$(wc -l < "$umount_log")" -eq 1 || \
        fail "$mount_signal_name after mount did not unmount exactly once"
    mount_signal_target=$(cut -f3 "$mount_log")
    [ ! -e "$mount_signal_target" ] || \
        fail "$mount_signal_name after mount left its mount directory"
    grep -Fxq keep "$mount_signal_keep" || \
        fail "$mount_signal_name cleanup removed unrelated build/tmp content"
    [ ! -e "$mount_signal_archive" ] || \
        fail "$mount_signal_name after mount published an archive"
done

: > "$mount_log"
: > "$umount_log"
mount_signal_failed_archive="$work/output/mount-signal-failed.zip"
set +e
PATH="$fakebin:$PATH" \
    OFFLINE_TEST_MOUNT_LOG="$mount_log" \
    OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
    OFFLINE_TEST_MOUNT_SIGNAL_NAME=HUP \
    OFFLINE_TEST_MOUNT_SIGNAL_ONCE="$work/mount-signal-failed.once" \
    OFFLINE_TEST_MOUNT_INACTIVE_AFTER_SIGNAL=true \
    OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
    OFFLINE_TEST_SERVER_ROOT="$server_root" \
    "$package_project/scripts/prepare-offline.sh" \
        --guest ubuntu-server --output "$mount_signal_failed_archive" \
        >"$work/mount-signal-failed.log" 2>&1
mount_signal_failed_status=$?
set -e
[ "$mount_signal_failed_status" -eq 129 ] || \
    fail "HUP during inactive mount transition returned $mount_signal_failed_status"
mount_signal_failed_target=$(cut -f3 "$mount_log")
[ ! -e "$mount_signal_failed_target" ] || \
    fail 'HUP during inactive mount transition left its mount directory'
test "$(wc -l < "$umount_log")" -eq 0 || \
    fail 'HUP during inactive mount transition attempted an unmount'

# util-linux 2.34 reports an ordinary existing directory as status 1.  Accept
# that ambiguous status only after the exact C-locale diagnostic; other status
# 1 diagnostics and state-probe failures must preserve the directory.
status_one_archive="$work/output/mountpoint-status-one.zip"
: > "$mount_log"
: > "$umount_log"
if ! PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_MOUNTPOINT_INACTIVE_STATUS=1 \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$status_one_archive" \
            >"$work/mountpoint-status-one.log" 2>&1; then
    fail 'packager rejected exact status-1 non-mountpoint diagnostics'
fi
while IFS=$'\t' read -r _mount_args _source mount_target; do
    [ ! -e "$mount_target" ] || \
        fail "status-1 compatibility left mount workspace: $mount_target"
done < "$mount_log"

for diagnostic_kind in missing permission system unexpected; do
    : > "$mount_log"
    : > "$umount_log"
    diagnostic_archive="$work/output/mountpoint-$diagnostic_kind.zip"
    if PATH="$fakebin:$PATH" \
            OFFLINE_TEST_MOUNT_LOG="$mount_log" \
            OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
            OFFLINE_TEST_MOUNTPOINT_INACTIVE_STATUS=1 \
            OFFLINE_TEST_MOUNTPOINT_DIAGNOSTIC_KIND="$diagnostic_kind" \
            OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
            OFFLINE_TEST_SERVER_ROOT="$server_root" \
            "$package_project/scripts/prepare-offline.sh" \
                --guest ubuntu-server --output "$diagnostic_archive" \
                >"$work/mountpoint-$diagnostic_kind.log" 2>&1; then
        fail "packager accepted status-1 $diagnostic_kind diagnostics"
    fi
    diagnostic_target=$(cut -f3 "$mount_log" | head -1)
    [ -d "$diagnostic_target" ] || \
        fail "status-1 $diagnostic_kind failure removed the uncertain directory"
    [ ! -e "$diagnostic_archive" ] || \
        fail "status-1 $diagnostic_kind failure published an archive"
done

: > "$mount_log"
: > "$umount_log"
umount_failure_archive="$work/output/umount-failure.zip"
if PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_UMOUNT_FAIL=true \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$umount_failure_archive" \
            >"$work/umount-failure.log" 2>&1; then
    fail 'packager succeeded after rootfs unmount failed'
fi
umount_failure_target=$(cut -f3 "$mount_log" | head -1)
[ -d "$umount_failure_target" ] || \
    fail 'failed rootfs unmount did not preserve its directory'
[ ! -e "$umount_failure_archive" ] || \
    fail 'failed rootfs unmount published an archive'

: > "$mount_log"
: > "$umount_log"
unknown_mount_archive="$work/output/mountpoint-unknown.zip"
if PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_MOUNTPOINT_ERROR=true \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$server_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$unknown_mount_archive" \
            >"$work/mountpoint-unknown.log" 2>&1; then
    fail 'packager succeeded with an unknown rootfs mount state'
fi
unknown_mount_target=$(cut -f3 "$mount_log" | head -1)
[ -d "$unknown_mount_target" ] || \
    fail 'unknown rootfs mount state did not preserve its directory'
test "$(wc -l < "$umount_log")" -eq 0 || \
    fail 'unknown rootfs mount state attempted an unsafe unmount'
[ ! -e "$unknown_mount_archive" ] || \
    fail 'unknown rootfs mount state published an archive'

# Resolve every path component inside MOUNT_ROOT.  Valid absolute and
# multi-hop links remain rootfs-scoped; escape, loop, and host-only chains fail.
symlink_roots="$work/mount-fixtures/symlink-chains"
absolute_parent_root="$symlink_roots/absolute-parent"
multihop_root="$symlink_roots/multihop"
loop_root="$symlink_roots/loop"
host_only_root="$symlink_roots/host-only"
relative_escape_root="$symlink_roots/relative-escape"
forty_hop_root="$symlink_roots/forty-hop"
forty_one_hop_root="$symlink_roots/forty-one-hop"
intermediate_file_root="$symlink_roots/intermediate-file"
final_executable_root="$symlink_roots/final-executable-type"
final_regular_root="$symlink_roots/final-regular-type"
final_directory_root="$symlink_roots/final-directory-type"
outside_usr="$work/rootfs-host-only/usr"
mkdir -p "$symlink_roots" "$(dirname "$outside_usr")"
/usr/bin/cp -a "$server_root/usr" "$outside_usr"

for chain_root in "$absolute_parent_root" "$multihop_root" "$loop_root" \
        "$host_only_root" "$relative_escape_root" "$forty_hop_root" \
        "$forty_one_hop_root" "$intermediate_file_root" \
        "$final_executable_root" "$final_regular_root" \
        "$final_directory_root"; do
    /usr/bin/cp -a "$server_root" "$chain_root"
done
mv "$absolute_parent_root/usr" "$absolute_parent_root/root-usr"
ln -s /root-usr "$absolute_parent_root/usr"

mv "$multihop_root/usr" "$multihop_root/root-usr"
ln -s usr-hop "$multihop_root/usr"
ln -s root-usr "$multihop_root/usr-hop"

mv "$loop_root/usr" "$loop_root/root-usr"
ln -s usr-hop "$loop_root/usr"
ln -s usr "$loop_root/usr-hop"

rm -rf "$host_only_root/usr"
ln -s "$outside_usr" "$host_only_root/usr"
rm -f "$host_only_root/lib/modules/6.8.0-107-generic/build"
mkdir -p "$host_only_root/lib/modules/6.8.0-107-generic/build"

rm -rf "$relative_escape_root/usr"
outside_usr_without_root=${outside_usr#/}
ln -s "../../../../../../../../../../../../$outside_usr_without_root" \
    "$relative_escape_root/usr"
rm -f "$relative_escape_root/lib/modules/6.8.0-107-generic/build"
mkdir -p "$relative_escape_root/lib/modules/6.8.0-107-generic/build"

for hop_case in forty-hop:39 forty-one-hop:40; do
    hop_name=${hop_case%%:*}
    hop_count=${hop_case#*:}
    hop_root="$symlink_roots/$hop_name"
    mv "$hop_root/usr" "$hop_root/root-usr"
    hop_link=usr
    for ((hop_index=1; hop_index<=hop_count; hop_index++)); do
        next_hop="usr-hop-$hop_index"
        ln -s "$next_hop" "$hop_root/$hop_link"
        hop_link=$next_hop
    done
    ln -s root-usr "$hop_root/$hop_link"
    rm -f "$hop_root/lib/modules/6.8.0-107-generic/build"
    /usr/bin/cp -a \
        "$hop_root/root-usr/src/linux-headers-6.8.0-107-generic" \
        "$hop_root/lib/modules/6.8.0-107-generic/build"
done

rm -rf "$intermediate_file_root/usr/local"
printf 'not-a-directory\n' > "$intermediate_file_root/usr/local"
rm -f "$final_executable_root/usr/bin/gcc"
mkdir "$final_executable_root/usr/bin/gcc"
rm -f "$final_regular_root/usr/src/linux-headers-6.8.0-107-generic/Makefile"
mkdir "$final_regular_root/usr/src/linux-headers-6.8.0-107-generic/Makefile"
rm -f "$final_directory_root/lib/modules/6.8.0-107-generic/build"
printf 'not-a-directory\n' > \
    "$final_directory_root/lib/modules/6.8.0-107-generic/build"

symlink_case_failures=0
for chain_case in \
    absolute-parent:accept \
    multihop:accept \
    loop:reject \
    host-only:reject \
    relative-escape:reject \
    forty-hop:accept \
    forty-one-hop:reject \
    intermediate-file:reject \
    final-executable-type:reject \
    final-regular-type:reject \
    final-directory-type:reject; do
    chain_name=${chain_case%%:*}
    chain_expectation=${chain_case#*:}
    chain_root="$symlink_roots/$chain_name"
    chain_archive="$work/output/symlink-chain-$chain_name.zip"
    : > "$mount_log"
    : > "$umount_log"
    set +e
    PATH="$fakebin:$PATH" \
        OFFLINE_TEST_MOUNT_LOG="$mount_log" \
        OFFLINE_TEST_UMOUNT_LOG="$umount_log" \
        OFFLINE_TEST_COMPACT_ROOT="$compact_root" \
        OFFLINE_TEST_DEBIAN_ROOT="$compact_root" \
        OFFLINE_TEST_SERVER_ROOT="$chain_root" \
        "$package_project/scripts/prepare-offline.sh" \
            --guest ubuntu-server --output "$chain_archive" \
            >"$work/package-symlink-chain-$chain_name.log" 2>&1
    chain_status=$?
    set -e
    if [ "$chain_expectation" = accept ] && [ "$chain_status" -ne 0 ]; then
        echo "symlink-chain $chain_name was rejected" >&2
        symlink_case_failures=$((symlink_case_failures + 1))
    elif [ "$chain_expectation" = reject ] && [ "$chain_status" -eq 0 ]; then
        echo "symlink-chain $chain_name was accepted" >&2
        symlink_case_failures=$((symlink_case_failures + 1))
    fi
    test "$(wc -l < "$umount_log")" -eq 2 || \
        fail "symlink-chain $chain_name did not unmount both rootfs images"
done
[ "$symlink_case_failures" -eq 0 ] || \
    fail "$symlink_case_failures rootfs symlink-chain contract(s) failed"

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
        grep -E '^driver/cosim_nic_.*\.ko$' >/dev/null || \
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
