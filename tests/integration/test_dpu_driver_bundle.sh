#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
builder="${project_dir}/scripts/build_dpu_driver_bundle.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/dpu-bundle-test.XXXXXX")
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

mkdir -p "$work/safe/host-driver-net"
printf 'obj-m += dpu_snd1.o\n' > "$work/safe/host-driver-net/Makefile"
tar -C "$work/safe" -czf "$work/safe.tar.gz" host-driver-net

tar -C "$work/safe" --transform='s,^host-driver-net/,../,' \
    -czf "$work/traversal.tar.gz" host-driver-net

"$builder" --validate-only --archive "$work/safe.tar.gz"
"$builder" --validate-only --use-system-bonding --archive "$work/safe.tar.gz"
if ! grep -Fq "dependencies=''" "$builder"; then
    echo 'FAIL: the no-LACP build must not declare a bonding dependency' >&2
    exit 1
fi
if ! grep -Fq "dependencies='bonding.ko'" "$builder"; then
    echo 'FAIL: the bundled-bonding build must retain its ordered dependency' >&2
    exit 1
fi
if "$builder" --validate-only --archive "$work/traversal.tar.gz"; then
    echo 'FAIL: traversal archive was accepted' >&2
    exit 1
fi

mkdir -p "$work/fake-headers/include/generated"
touch "$work/fake-headers/Makefile"
printf '#define UTS_RELEASE "6.8.0-test"\n' > "$work/fake-headers/include/generated/utsrelease.h"
if "$builder" --archive "$work/safe.tar.gz" \
        --kernel-build "$work/fake-headers" --output "$work/bundle" \
        --compat-runtime-deb "$work/missing-libc6.deb" >"$work/compat.err" 2>&1; then
    echo 'FAIL: missing compatibility runtime was accepted' >&2
    exit 1
fi
grep -Fq 'compatibility runtime archive not found' "$work/compat.err" || {
    echo 'FAIL: missing compatibility runtime did not produce a clear error' >&2
    exit 1
}

grep -Fq 'CUSTOM_DRIVER_COMPAT_RUNTIME_DEB' "$project_dir/setup.sh" || {
    echo 'FAIL: setup does not pass the optional compatibility runtime to the DPU builder' >&2
    exit 1
}

if ! grep -Fq "output directory is not empty" "$builder"; then
    echo "FAIL: DPU builder does not accept setup.sh empty mktemp output directories" >&2
    exit 1
fi

# Ubuntu 20.04's gcc-9 cannot parse several hardening options emitted by
# 6.8 kernel headers.  The builder must interpose a compiler wrapper even
# without the optional compatibility libc runtime.  Fake make exercises the
# exact CC= handoff while fake gcc-9 rejects an unfiltered option.
mkdir -p "$work/gcc9-tools" "$work/gcc9-driver/host-driver-net" \
    "$work/gcc9-headers/include/generated"
printf 'obj-m += dpu_snd1.o\n' > "$work/gcc9-driver/host-driver-net/Makefile"
tar -C "$work/gcc9-driver" -czf "$work/gcc9-driver.tar.gz" host-driver-net
touch "$work/gcc9-headers/Makefile"
printf '#define UTS_RELEASE "6.8.0-test"\n' \
    > "$work/gcc9-headers/include/generated/utsrelease.h"

cat > "$work/gcc9-tools/gcc-9" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
next_is_output=false
for arg in "$@"; do
    if "$next_is_output"; then
        output="$arg"
        next_is_output=false
        continue
    fi
    case "$arg" in
        -mharden-sls=all|-ftrivial-auto-var-init=zero|-fzero-call-used-regs=used-gpr)
            echo "gcc-9: error: unrecognized command line option '$arg'" >&2
            exit 2
            ;;
        -o) next_is_output=true ;;
    esac
done
[ -n "$output" ] && printf 'fake gcc-9 object\n' > "$output"
EOF

cat > "$work/gcc9-tools/make" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=''
compiler=''
target=''
next_is_dir=false
for arg in "$@"; do
    if "$next_is_dir"; then
        dir="$arg"
        next_is_dir=false
        continue
    fi
    case "$arg" in
        -C) next_is_dir=true ;;
        CC=*) compiler=${arg#CC=} ;;
        clean|modules) target="$arg" ;;
    esac
done
[ -n "$dir" ] && [ -n "$compiler" ]
if [ "$target" = modules ]; then
    printf 'int dpu_bundle_test;\n' > "$dir/.gcc9-test.c"
    "$compiler" -mharden-sls=all -ftrivial-auto-var-init=zero \
        -fzero-call-used-regs=used-gpr -c "$dir/.gcc9-test.c" \
        -o "$dir/dpu_snd1.ko"
fi
EOF

cat > "$work/gcc9-tools/modinfo" <<'EOF'
#!/usr/bin/env sh
if [ "$1" = '-F' ] && [ "$2" = 'vermagic' ]; then
    echo '6.8.0-test SMP'
    exit 0
fi
exit 1
EOF
cat > "$work/gcc9-tools/file" <<'EOF'
#!/usr/bin/env sh
echo "$1: ELF 64-bit LSB relocatable, x86-64"
EOF
chmod +x "$work/gcc9-tools/gcc-9" "$work/gcc9-tools/make" \
    "$work/gcc9-tools/modinfo" "$work/gcc9-tools/file"

PATH="$work/gcc9-tools:$PATH" CC=gcc-9 "$builder" \
    --use-system-bonding --archive "$work/gcc9-driver.tar.gz" \
    --kernel-build "$work/gcc9-headers" --output "$work/gcc9-bundle"
test -f "$work/gcc9-bundle/dpu_snd1.ko"

# The driver builder must keep its private source tree under the project
# build directory.  An imported project can be used by an unprivileged user
# whose system TMPDIR is unavailable, so the build must not depend on it.
PATH="$work/gcc9-tools:$PATH" CC=gcc-9 TMPDIR="$work/missing-system-tmp" \
    "$builder" --use-system-bonding --archive "$work/gcc9-driver.tar.gz" \
    --kernel-build "$work/gcc9-headers" --output "$work/gcc9-project-tmp-bundle"
test -f "$work/gcc9-project-tmp-bundle/dpu_snd1.ko"
test -d "$project_dir/build/tmp"
echo 'PASS: DPU driver archive validation'
