#!/usr/bin/env bash
# Exercise the reusable offline QEMU source-closure contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"
PREPARE="$REPO_ROOT/scripts/prepare-offline.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-qemu-source-closure.py"
CMAKE_TESTS="$REPO_ROOT/tests/integration/CMakeLists.txt"
TMP_ROOT="$REPO_ROOT/build/tmp"
OFFICIAL_RELEASE_SIZE=135188800
OFFICIAL_RELEASE_SHA256=f859f0bc65e1f533d040bbe8c92bcfecee5af2c921a6687c652fb44d089bd894
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

assert_accepted() {
    local archive="$1" description="$2" log
    log="$work/accepted-$(basename "$archive").log"
    "$VALIDATOR" "$archive" >"$log" 2>&1 || {
        cat "$log" >&2
        fail "validator rejected valid archive: $description"
    }
}

bash -n "$SETUP"
bash -n "$PREPARE"
[ -x "$VALIDATOR" ] || fail 'QEMU source-closure validator is missing or not executable'

if [ -n "${QEMU_OFFICIAL_RELEASE_TAR:-}" ]; then
    case "$QEMU_OFFICIAL_RELEASE_TAR" in
        /*) ;;
        *) fail 'QEMU_OFFICIAL_RELEASE_TAR must be an absolute path' ;;
    esac
    [ -f "$QEMU_OFFICIAL_RELEASE_TAR" ] && \
        [ ! -L "$QEMU_OFFICIAL_RELEASE_TAR" ] || \
        fail 'QEMU_OFFICIAL_RELEASE_TAR is not a regular file'
    official_size=$(stat -c '%s' -- "$QEMU_OFFICIAL_RELEASE_TAR")
    [ "$official_size" -eq "$OFFICIAL_RELEASE_SIZE" ] || \
        fail "official QEMU release size mismatch: $official_size"
    official_sha256=$(sha256sum -- "$QEMU_OFFICIAL_RELEASE_TAR" | awk '{print $1}')
    [ "$official_sha256" = "$OFFICIAL_RELEASE_SHA256" ] || \
        fail "official QEMU release SHA-256 mismatch: $official_sha256"
    "$VALIDATOR" "$QEMU_OFFICIAL_RELEASE_TAR" \
        >"$work/official-release-validator.log" 2>&1 || {
        cat "$work/official-release-validator.log" >&2
        fail 'validator rejected the authentic official QEMU release tar'
    }
    printf 'official_release_size=%s\n' "$official_size"
    printf 'official_release_sha256=%s\n' "$official_sha256"
    cat "$work/official-release-validator.log"
fi

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

wrong_top_source="$work/wrong-top-source"
mkdir -p "$wrong_top_source"
cp -a "$complete_source/qemu-9.2.0" "$wrong_top_source/foo"
tar -cJf "$work/wrong-top.tar.xz" -C "$wrong_top_source" foo
assert_rejected "$work/wrong-top.tar.xz" 'expected top-level qemu-9.2.0'

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

python3 - "$work" <<'PY'
import io
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
required = (
    "subprojects/keycodemapdb/meson.build",
    "subprojects/berkeley-softfloat-3/meson.build",
    "subprojects/berkeley-testfloat-3/meson.build",
)


def regular(archive, name, payload=b"fixture\n"):
    member = tarfile.TarInfo(name)
    member.type = tarfile.REGTYPE
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))


def special(archive, name, kind, linkname=""):
    member = tarfile.TarInfo(name)
    member.type = kind
    member.linkname = linkname
    if kind == tarfile.CHRTYPE:
        member.devmajor = 1
        member.devminor = 3
    archive.addfile(member)


def fixture(name, extras):
    with tarfile.open(root / name, mode="w:xz") as archive:
        extras(archive)
        for suffix in required:
            regular(archive, f"qemu-9.2.0/{suffix}")


fixture(
    "top-symlink.tar.xz",
    lambda archive: special(
        archive, "qemu-9.2.0", tarfile.SYMTYPE, "qemu-real"
    ),
)
fixture(
    "required-ancestor-symlink.tar.xz",
    lambda archive: special(
        archive,
        "qemu-9.2.0/subprojects/keycodemapdb",
        tarfile.SYMTYPE,
        "../berkeley-softfloat-3",
    ),
)
fixture(
    "required-ancestor-regular.tar.xz",
    lambda archive: regular(
        archive, "qemu-9.2.0/subprojects/keycodemapdb"
    ),
)
fixture(
    "fifo.tar.xz",
    lambda archive: special(
        archive, "qemu-9.2.0/unsafe-fifo", tarfile.FIFOTYPE
    ),
)
fixture(
    "device.tar.xz",
    lambda archive: special(
        archive, "qemu-9.2.0/unsafe-device", tarfile.CHRTYPE
    ),
)
fixture(
    "escape-symlink.tar.xz",
    lambda archive: special(
        archive,
        "qemu-9.2.0/links/escape",
        tarfile.SYMTYPE,
        "../../../outside",
    ),
)


def duplicate(archive):
    regular(archive, "qemu-9.2.0/duplicate")
    regular(archive, "qemu-9.2.0/duplicate")


fixture("duplicate-logical-path.tar.xz", duplicate)


def conflicting(archive):
    special(archive, "qemu-9.2.0/conflict/", tarfile.DIRTYPE)
    regular(archive, "qemu-9.2.0/conflict")


fixture("conflicting-logical-path.tar.xz", conflicting)
fixture(
    "missing-hardlink-target.tar.xz",
    lambda archive: special(
        archive,
        "qemu-9.2.0/links/missing-hardlink",
        tarfile.LNKTYPE,
        "qemu-9.2.0/missing-target",
    ),
)


def hardlink_to_directory(archive):
    special(archive, "qemu-9.2.0/directory-target/", tarfile.DIRTYPE)
    special(
        archive,
        "qemu-9.2.0/links/directory-hardlink",
        tarfile.LNKTYPE,
        "qemu-9.2.0/directory-target",
    )


fixture("directory-hardlink-target.tar.xz", hardlink_to_directory)


def compensated_hardlink_target(archive):
    regular(archive, "qemu-9.2.0/target")
    special(
        archive,
        "qemu-9.2.0/hard",
        tarfile.LNKTYPE,
        "qemu-9.2.0/missing/../target",
    )


fixture("compensated-hardlink-target.tar.xz", compensated_hardlink_target)
fixture(
    "overlong-member-component.tar.xz",
    lambda archive: regular(archive, f"qemu-9.2.0/{'m' * 300}"),
)
fixture(
    "overlong-symlink-target.tar.xz",
    lambda archive: special(
        archive,
        "qemu-9.2.0/links/overlong-symlink",
        tarfile.SYMTYPE,
        "s" * 5000,
    ),
)


def safe_symlink(archive):
    regular(archive, "qemu-9.2.0/targets/regular")
    special(
        archive,
        "qemu-9.2.0/links/safe-symlink",
        tarfile.SYMTYPE,
        "../targets/regular",
    )


fixture("safe-symlink.tar.xz", safe_symlink)


def valid_hardlink(archive):
    regular(archive, "qemu-9.2.0/targets/hardlink-regular")
    special(
        archive,
        "qemu-9.2.0/links/valid-hardlink",
        tarfile.LNKTYPE,
        "qemu-9.2.0/targets/hardlink-regular",
    )


fixture("valid-hardlink.tar.xz", valid_hardlink)


def official_absolute_leaf(archive):
    special(
        archive,
        "qemu-9.2.0/roms/edk2/EmulatorPkg/Unix/Host/X11IncludeHack",
        tarfile.SYMTYPE,
        "/opt/X11/include",
    )


fixture("official-absolute-leaf.tar.xz", official_absolute_leaf)
PY

i2_rejection_failures=0
while IFS='|' read -r archive_name expected; do
    rejection_log="$work/i2-rejected-$archive_name.log"
    if "$VALIDATOR" "$work/$archive_name" >"$rejection_log" 2>&1; then
        printf 'I2_RED_ACCEPTED=%s\n' "$archive_name" >&2
        i2_rejection_failures=$((i2_rejection_failures + 1))
    elif ! grep -Fq "$expected" "$rejection_log"; then
        cat "$rejection_log" >&2
        fail "I2 rejection did not identify $expected: $archive_name"
    fi
done <<'EOF'
top-symlink.tar.xz|non-directory ancestor
required-ancestor-symlink.tar.xz|non-directory ancestor
required-ancestor-regular.tar.xz|non-directory ancestor
fifo.tar.xz|unsupported member type
device.tar.xz|unsupported member type
escape-symlink.tar.xz|unsafe symlink target
duplicate-logical-path.tar.xz|duplicate logical member path
conflicting-logical-path.tar.xz|duplicate logical member path
missing-hardlink-target.tar.xz|hardlink target is not a unique regular member
directory-hardlink-target.tar.xz|hardlink target is not a unique regular member
compensated-hardlink-target.tar.xz|non-canonical hardlink target
overlong-member-component.tar.xz|member path component exceeds filesystem limit
overlong-symlink-target.tar.xz|link target exceeds filesystem limit
EOF
[ "$i2_rejection_failures" -eq 0 ] || \
    fail "validator accepted $i2_rejection_failures unsafe member-graph fixtures"

assert_accepted "$work/safe-symlink.tar.xz" 'safe in-tree symlink leaf'
assert_accepted "$work/valid-hardlink.tar.xz" 'hardlink to a unique regular member'
assert_accepted "$work/official-absolute-leaf.tar.xz" \
    'official QEMU 9.2.0 absolute leaf exception'

safe_symlink_extract="$work/safe-symlink-extract"
valid_hardlink_extract="$work/valid-hardlink-extract"
mkdir -p "$safe_symlink_extract" "$valid_hardlink_extract"
tar -xJf "$work/safe-symlink.tar.xz" -C "$safe_symlink_extract"
[ -L "$safe_symlink_extract/qemu-9.2.0/links/safe-symlink" ] || \
    fail 'safe symlink fixture did not extract as a symlink'
cmp "$safe_symlink_extract/qemu-9.2.0/targets/regular" \
    "$safe_symlink_extract/qemu-9.2.0/links/safe-symlink" || \
    fail 'safe symlink fixture did not resolve to the expected payload'
tar -xJf "$work/valid-hardlink.tar.xz" -C "$valid_hardlink_extract"
cmp "$valid_hardlink_extract/qemu-9.2.0/targets/hardlink-regular" \
    "$valid_hardlink_extract/qemu-9.2.0/links/valid-hardlink" || \
    fail 'valid hardlink fixture did not extract the expected payload'

large_pax_archive="$work/large-pax.tar.xz"
python3 - "$large_pax_archive" <<'PY'
import io
import sys
import tarfile

required = (
    "subprojects/keycodemapdb/meson.build",
    "subprojects/berkeley-softfloat-3/meson.build",
    "subprojects/berkeley-testfloat-3/meson.build",
)
with tarfile.open(sys.argv[1], mode="w:xz", format=tarfile.PAX_FORMAT) as archive:
    probe = tarfile.TarInfo("qemu-9.2.0/pax-resource-probe")
    probe.pax_headers = {"comment": "P" * (64 * 1024 * 1024)}
    payload = b"resource probe\n"
    probe.size = len(payload)
    archive.addfile(probe, io.BytesIO(payload))
    for suffix in required:
        member = tarfile.TarInfo(f"qemu-9.2.0/{suffix}")
        payload = b"project('resource-limit')\n"
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
PY

oversized_archive="$work/oversized-physical.tar.xz"
truncate -s $((256 * 1024 * 1024 + 1)) "$oversized_archive"
i3_rejection_failures=0
large_pax_log="$work/large-pax-rejected.log"
if "$VALIDATOR" "$large_pax_archive" >"$large_pax_log" 2>&1; then
    echo 'I3_RED_ACCEPTED=large-pax.tar.xz' >&2
    i3_rejection_failures=$((i3_rejection_failures + 1))
elif ! grep -Eq '(PAX field|memory) resource limit' "$large_pax_log"; then
    cat "$large_pax_log" >&2
    echo 'I3_RED_MISSING_BOUND=large-pax.tar.xz' >&2
    i3_rejection_failures=$((i3_rejection_failures + 1))
fi
oversized_log="$work/oversized-physical-rejected.log"
if "$VALIDATOR" "$oversized_archive" >"$oversized_log" 2>&1; then
    echo 'I3_RED_ACCEPTED=oversized-physical.tar.xz' >&2
    i3_rejection_failures=$((i3_rejection_failures + 1))
elif ! grep -Fq 'archive exceeds physical size limit' "$oversized_log"; then
    cat "$oversized_log" >&2
    echo 'I3_RED_MISSING_BOUND=oversized-physical.tar.xz' >&2
    i3_rejection_failures=$((i3_rejection_failures + 1))
fi
[ "$i3_rejection_failures" -eq 0 ] || \
    fail "validator missed $i3_rejection_failures resource boundaries"
assert_accepted "$work/complete.tar.xz" \
    'normal archive after resource-limit rejection'

# A regular tar header whose raw name ends in '/' is not the required source
# file. Tar consumers may materialize such an entry as a directory or reject
# the contradictory header, so matching a stripped name would incorrectly
# declare source closure.
trailing_slash_archive="$work/trailing-slash-regular.tar.xz"
python3 - "$trailing_slash_archive" <<'PY'
import io
import sys
import tarfile

required = (
    "subprojects/keycodemapdb/meson.build",
    "subprojects/berkeley-softfloat-3/meson.build",
    "subprojects/berkeley-testfloat-3/meson.build",
)
with tarfile.open(sys.argv[1], mode="w:xz") as archive:
    for suffix in required:
        payload = b"project('invalid-trailing-slash')\n"
        member = tarfile.TarInfo(f"qemu-9.2.0/{suffix}/")
        member.type = tarfile.REGTYPE
        member.size = len(payload)
        archive.addfile(member, io.BytesIO(payload))
PY
assert_rejected "$trailing_slash_archive" 'unsafe member path'

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
assert_rejected "$work/mixed-top.tar.xz" 'expected top-level qemu-9.2.0'

tar -cJf "$work/unsafe-path.tar.xz" \
    --transform='s,^,../,' -C "$complete_source" qemu-9.2.0
assert_rejected "$work/unsafe-path.tar.xz" 'unsafe member path'

printf 'not a tar archive\n' > "$work/corrupt.tar.xz"
assert_rejected "$work/corrupt.tar.xz" 'cannot read tar listing'

grep -Fq 'qemu-9.2.0.tar.xz' "$SETUP" || \
    fail 'xz offline QEMU archive input is unsupported'
grep -Fq 'qemu-9.2.0.tar.gz' "$SETUP" || \
    fail 'gzip offline QEMU archive input is unsupported'
grep -Fq -- '--expected-top qemu-9.2.0' "$SETUP" || \
    fail 'setup import does not explicitly require the QEMU 9.2.0 top-level'
grep -Fq -- '--expected-top qemu-9.2.0' "$PREPARE" || \
    fail 'packager does not explicitly require the QEMU 9.2.0 top-level'
grep -Fq 'set_tests_properties(test_offline_qemu_archive PROPERTIES TIMEOUT 30)' \
    "$CMAKE_TESTS" || fail 'offline QEMU focused CTest timeout is below 30 seconds'
grep -Fq 'https://download.qemu.org/qemu-9.2.0.tar.xz' "$PREPARE" || \
    fail 'packager does not use the official QEMU 9.2.0 release URL'
grep -Fq 'f859f0bc65e1f533d040bbe8c92bcfecee5af2c921a6687c652fb44d089bd894' \
    "$PREPARE" || fail 'packager does not pin the official QEMU release SHA-256'
grep -Fq 'https://download.qemu.org/qemu-9.2.0.tar.xz' "$SETUP" || \
    fail 'setup manual download guidance does not use the official release URL'

echo 'PASS: offline QEMU source closure and archive formats'
