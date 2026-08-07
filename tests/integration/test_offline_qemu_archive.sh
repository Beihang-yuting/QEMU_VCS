#!/usr/bin/env bash
# Exercise the reusable offline QEMU source-closure contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
PREPARE="$REPO_ROOT/scripts/prepare-offline.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-qemu-source-closure.py"
TMP_ROOT="$REPO_ROOT/build/tmp"
mkdir -p "$TMP_ROOT"
work=$(mktemp -d "$TMP_ROOT/offline-qemu-archive-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_complete_tree() {
    local root="$1" subproject
    for subproject in keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do
        mkdir -p "$root/qemu-9.2.0/subprojects/$subproject"
        printf 'project(%s)\n' "$subproject" > \
            "$root/qemu-9.2.0/subprojects/$subproject/meson.build"
    done
}

make_tar() {
    local compression="$1" source_root="$2" output="$3"
    case "$compression" in
        xz) tar -cJf "$output" -C "$source_root" qemu-9.2.0 ;;
        gz) tar -czf "$output" -C "$source_root" qemu-9.2.0 ;;
        *) fail "unsupported fixture compression: $compression" ;;
    esac
}

assert_rejected() {
    local archive="$1" expected="$2" log
    log="$work/rejected-$(basename "$archive").log"
    if "$VALIDATOR" "$archive" >"$log" 2>&1; then
        fail "validator accepted invalid archive: $(basename "$archive")"
    fi
    grep -Fq "$expected" "$log" || {
        cat "$log" >&2
        fail "rejection did not identify $expected"
    }
}

bash -n "$SETUP"
bash -n "$PREPARE"
[ -x "$VALIDATOR" ] || fail 'QEMU source-closure validator is missing or not executable'

complete_source="$work/complete-source"
make_complete_tree "$complete_source"
for compression in xz gz; do
    complete_archive="$work/complete.tar.$compression"
    make_tar "$compression" "$complete_source" "$complete_archive"
    "$VALIDATOR" "$complete_archive" >"$work/complete-$compression.log" 2>&1 || {
        cat "$work/complete-$compression.log" >&2
        fail "validator rejected complete tar.$compression fixture"
    }
done

for missing in keycodemapdb berkeley-softfloat-3 berkeley-testfloat-3; do
    missing_source="$work/missing-$missing-source"
    cp -a "$complete_source" "$missing_source"
    rm -f "$missing_source/qemu-9.2.0/subprojects/$missing/meson.build"
    missing_archive="$work/missing-$missing.tar.xz"
    make_tar xz "$missing_source" "$missing_archive"
    assert_rejected "$missing_archive" "subprojects/$missing/meson.build"
done

nonregular_source="$work/nonregular-source"
cp -a "$complete_source" "$nonregular_source"
rm -f "$nonregular_source/qemu-9.2.0/subprojects/keycodemapdb/meson.build"
ln -s ../berkeley-softfloat-3/meson.build \
    "$nonregular_source/qemu-9.2.0/subprojects/keycodemapdb/meson.build"
make_tar xz "$nonregular_source" "$work/nonregular.tar.xz"
assert_rejected "$work/nonregular.tar.xz" 'regular member'

duplicate_archive="$work/duplicate.tar.xz"
tar -cJf "$duplicate_archive" -C "$complete_source" \
    qemu-9.2.0/subprojects/keycodemapdb/meson.build \
    qemu-9.2.0/subprojects/keycodemapdb/meson.build \
    qemu-9.2.0/subprojects/berkeley-softfloat-3/meson.build \
    qemu-9.2.0/subprojects/berkeley-testfloat-3/meson.build
assert_rejected "$duplicate_archive" 'exactly once'

mixed_source="$work/mixed-source"
mkdir -p "$mixed_source/top-a/subprojects/keycodemapdb" \
    "$mixed_source/top-b/subprojects/berkeley-softfloat-3" \
    "$mixed_source/top-a/subprojects/berkeley-testfloat-3"
printf 'keycodes\n' > "$mixed_source/top-a/subprojects/keycodemapdb/meson.build"
printf 'softfloat\n' > "$mixed_source/top-b/subprojects/berkeley-softfloat-3/meson.build"
printf 'testfloat\n' > "$mixed_source/top-a/subprojects/berkeley-testfloat-3/meson.build"
tar -cJf "$work/mixed-top.tar.xz" -C "$mixed_source" top-a top-b
assert_rejected "$work/mixed-top.tar.xz" 'common top-level'

tar -cJf "$work/unsafe-path.tar.xz" \
    --transform='s,^,../,' -C "$complete_source" qemu-9.2.0
assert_rejected "$work/unsafe-path.tar.xz" 'unsafe member path'

printf 'not a tar archive\n' > "$work/corrupt.tar.xz"
assert_rejected "$work/corrupt.tar.xz" 'cannot read tar listing'

grep -Fq 'qemu-9.2.0.tar.xz' "$SETUP" || \
    fail 'xz offline QEMU archive input is unsupported'
grep -Fq 'qemu-9.2.0.tar.gz' "$SETUP" || \
    fail 'gzip offline QEMU archive input is unsupported'
grep -Fq 'https://download.qemu.org/qemu-9.2.0.tar.xz' "$PREPARE" || \
    fail 'packager does not use the official QEMU 9.2.0 release URL'
grep -Fq 'f859f0bc65e1f533d040bbe8c92bcfecee5af2c921a6687c652fb44d089bd894' \
    "$PREPARE" || fail 'packager does not pin the official QEMU release SHA-256'
grep -Fq 'https://download.qemu.org/qemu-9.2.0.tar.xz' "$SETUP" || \
    fail 'setup manual download guidance does not use the official release URL'

echo 'PASS: offline QEMU source closure and archive formats'
