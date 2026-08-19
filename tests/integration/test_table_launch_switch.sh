#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
baseline="$repo/tests/fixtures/table_default_off_qemu_args.txt"
fixture_parent="$repo/build/tmp"
mkdir -p "$fixture_parent"
work=$(mktemp -d "$fixture_parent/test-table-launch-switch.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

fail() {
    echo "[table-launch-switch] FAIL: $*" >&2
    exit 1
}

dry_run() {
    local console=$1
    shift
    make -s -n -C "$repo" run-qemu \
        "CONSOLE=$console" NUM_RC=2 \
        "QEMU=$repo/.table-launch-fixture/qemu" \
        "KERNEL=$repo/.table-launch-fixture/bzImage" \
        "ROOTFS=$repo/.table-launch-fixture/rootfs.ext4" \
        ADVERTISE_HOST=192.0.2.1 "$@"
}

extract_qemu_recipe() {
    local console=$1

    awk -v console="$console" '
        index($0, "LD_LIBRARY_PATH=") { active = 1 }
        active {
            print
            if ((console == "login" &&
                 index($0, "-mon chardev=cons0,mode=readline")) ||
                (console != "login" && $0 ~ /> .*2>&1 & \\$/))
                exit
        }
    '
}

capture_qemu_recipes() {
    local console

    for console in login login-multi file; do
        printf '[%s]\n' "$console"
        dry_run "$console" "$@" | extract_qemu_recipe "$console" |
            sed "s|$repo|<PROJECT>|g"
    done
}

assert_count() {
    local expected=$1
    local count=$2
    local context=$3

    [[ "$count" -eq "$expected" ]] ||
        fail "$context: expected $expected, got $count"
}

capture_qemu_recipes >"$work/default.txt"
if ! cmp -s "$baseline" "$work/default.txt"; then
    diff -u "$baseline" "$work/default.txt" >&2 || true
    fail "default QEMU recipes changed from the captured baseline"
fi
capture_qemu_recipes TABLE_BACKDOOR=off >"$work/off.txt"
if ! cmp -s "$baseline" "$work/off.txt"; then
    diff -u "$baseline" "$work/off.txt" >&2 || true
    fail "explicit off QEMU recipes differ from the default-off baseline"
fi
capture_qemu_recipes TABLE_PORT_BASE=0 >"$work/default-invalid-port.txt"
if ! cmp -s "$baseline" "$work/default-invalid-port.txt"; then
    diff -u "$baseline" "$work/default-invalid-port.txt" >&2 || true
    fail "default-off QEMU recipes depend on dormant TABLE_PORT_BASE"
fi
capture_qemu_recipes TABLE_BACKDOOR=off TABLE_PORT_BASE=not-a-port \
    >"$work/off-invalid-port.txt"
if ! cmp -s "$baseline" "$work/off-invalid-port.txt"; then
    diff -u "$baseline" "$work/off-invalid-port.txt" >&2 || true
    fail "explicit-off QEMU recipes depend on dormant TABLE_PORT_BASE"
fi

for console in login login-multi file; do
    enabled=$(dry_run "$console" TABLE_BACKDOOR=on TABLE_PORT_BASE=10100)
    recipe=$(printf '%s\n' "$enabled" | extract_qemu_recipe "$console")
    if [[ "$console" == login ]]; then
        controller='-device "cosim-table-ctrl,bus=pcie.0,addr=0x6,table_port_base=10100,instance_id=0,rc_id=0,device_instance=0"'
    else
        controller='-device "cosim-table-ctrl,bus=pcie.0,addr=0x6,table_port_base=10100,instance_id=$r,rc_id=$r,device_instance=0"'
    fi
    count=$(printf '%s\n' "$recipe" | grep -Fo -- "$controller" | wc -l || true)
    assert_count 1 "$count" "$console controller count"
    count=$(printf '%s\n' "$recipe" |
        grep -Fo -- 'dpu_snd1.table_backdoor=1' | wc -l || true)
    assert_count 1 "$count" "$console Guest table argument count"
    count=$(printf '%s\n' "$recipe" |
        grep -Fo -- '-device "pcie-root-port' | wc -l || true)
    assert_count 1 "$count" "$console root-port count"
    if [[ "$recipe" == *'cosim-table-ctrl,bus=cosim_rp'* ]]; then
        fail "$console places the table controller behind the DUT root port"
    fi
    if grep -Eiq 'route[-_]?map' <<<"$recipe"; then
        fail "$console passes a route-map option to QEMU"
    fi
done

run_descriptor() {
    local console=$1
    local mode=$2
    local descriptor=$3
    local -a table_args=()

    if [[ "$mode" != default ]]; then
        table_args+=("TABLE_BACKDOOR=$mode")
    fi
    make -s -C "$repo" run-qemu \
        "CONSOLE=$console" NUM_RC=2 QEMU=/bin/true KERNEL=/bin/true \
        ROOTFS=/bin/true MGMT_NET=0 QEMU_TIME_MODE=realtime \
        LOG_DIR="$work/log-$console-$mode" \
        RUN_DIR="$work/run-$console-$mode" CONN_JSON="$descriptor" \
        ADVERTISE_HOST=192.0.2.1 TABLE_PORT_BASE=10100 \
        "${table_args[@]}" >/dev/null
}

for console in login login-multi file; do
    for mode in default off; do
        descriptor="$work/conn-$console-$mode.json"
        run_descriptor "$console" "$mode" "$descriptor"
        python3 -m json.tool "$descriptor" >/dev/null ||
            fail "$console/$mode descriptor is not valid JSON"
        if grep -q '"table_' "$descriptor"; then
            fail "$console/$mode descriptor contains dormant table fields"
        fi
    done
    cmp -s "$work/conn-$console-default.json" \
        "$work/conn-$console-off.json" ||
        fail "$console default and explicit-off descriptors differ"
    descriptor="$work/conn-$console-on.json"
    run_descriptor "$console" on "$descriptor"
    python3 -m json.tool "$descriptor" >/dev/null ||
        fail "$console enabled descriptor is not valid JSON"
    grep -Fq '"table_backdoor": true' "$descriptor" ||
        fail "$console enabled descriptor lacks table_backdoor"
    grep -Fq '"table_port_base": 10100' "$descriptor" ||
        fail "$console enabled descriptor lacks table_port_base"
    grep -Fq '"table_port_formula": "port = table_port_base + instance_id"' \
        "$descriptor" ||
        fail "$console enabled descriptor lacks table port formula"
    grep -Fq '"table_port": 10100' "$descriptor" ||
        fail "$console enabled descriptor lacks RC0 table port"
    if [[ "$console" != login ]]; then
        grep -Fq '"table_port": 10101' "$descriptor" ||
            fail "$console enabled descriptor lacks RC1 table port"
    fi
done

marker="$work/qemu-launched"
invalid_descriptor="$work/invalid.json"
fake_qemu="$work/qemu-marker"
printf '#!/usr/bin/env bash\ntouch "$TABLE_LAUNCH_MARKER"\n' >"$fake_qemu"
chmod +x "$fake_qemu"
export TABLE_LAUNCH_MARKER="$marker"

expect_invalid_before_launch() {
    local label=$1
    local accepted=0
    shift

    rm -f "$marker" "$invalid_descriptor"
    if make -s -C "$repo" run-qemu CONSOLE=login NUM_RC=1 \
            QEMU="$fake_qemu" KERNEL=/bin/true ROOTFS=/bin/true \
            MGMT_NET=0 QEMU_TIME_MODE=realtime \
            LOG_DIR="$work/invalid-log" RUN_DIR="$work/invalid-run" \
            CONN_JSON="$invalid_descriptor" "$@" >/dev/null 2>&1; then
        accepted=1
    fi
    [[ ! -e "$invalid_descriptor" ]] ||
        fail "$label created a descriptor before rejection"
    [[ ! -e "$marker" ]] || fail "$label reached QEMU before rejection"
    ((accepted == 0)) || fail "$label was accepted"
}

expect_literal_rejected_without_evaluation() {
    local variable=$1
    local eval_marker="$work/${variable,,}-evaluated"

    rm -f "$eval_marker"
    expect_invalid_before_launch "literal $variable Make function" \
        TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 \
        "$variable=\$(shell touch $eval_marker)invalid"
    [[ ! -e "$eval_marker" ]] || fail "$variable evaluated a Make function"
}

expect_valid_launch() {
    local label=$1
    shift

    rm -f "$marker"
    make -s -C "$repo" run-qemu CONSOLE=login NUM_RC=1 \
        QEMU="$fake_qemu" KERNEL=/bin/true ROOTFS=/bin/true \
        MGMT_NET=0 QEMU_TIME_MODE=realtime \
        LOG_DIR="$work/valid-log" RUN_DIR="$work/valid-run" \
        CONN_JSON="$work/valid.json" "$@" >/dev/null 2>&1 ||
        fail "$label was rejected"
    [[ -e "$marker" ]] || fail "$label did not reach QEMU"
}

expect_valid_launch "default-off with zero dormant table port" \
    TABLE_PORT_BASE=0
expect_valid_launch "explicit off with nonnumeric dormant table port" \
    TABLE_BACKDOOR=off TABLE_PORT_BASE=not-a-port
expect_invalid_before_launch "unknown TABLE_BACKDOOR" \
    TABLE_BACKDOOR=maybe TABLE_PORT_BASE=10100
expect_invalid_before_launch "zero TABLE_PORT_BASE" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=0
expect_invalid_before_launch "TABLE_PORT_BASE above TCP range" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=65536
expect_invalid_before_launch "extremely long TABLE_PORT_BASE" \
    TABLE_BACKDOOR=on \
    TABLE_PORT_BASE=999999999999999999999999999999999999
expect_invalid_before_launch "TABLE_PORT_BASE above signed shell range" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=9223372036854775808
expect_invalid_before_launch "extremely long NUM_RC" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 \
    NUM_RC=999999999999999999999999999999999999
expect_invalid_before_launch "extremely long PORT_BASE" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 \
    PORT_BASE=999999999999999999999999999999999999
expect_invalid_before_launch "table port range overflow" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=65535 NUM_RC=2
expect_invalid_before_launch "zero main transport base" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 PORT_BASE=0 NUM_RC=1
expect_invalid_before_launch "effective default transport collision" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=9100 PORT_BASE=0 NUM_RC=1
expect_invalid_before_launch "main transport port range overflow" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=10100 PORT_BASE=65535 NUM_RC=1
expect_literal_rejected_without_evaluation NUM_RC
expect_literal_rejected_without_evaluation PORT_BASE
for collision in 9100 9101 9102; do
    expect_invalid_before_launch "RC0 transport collision at $collision" \
        TABLE_BACKDOOR=on "TABLE_PORT_BASE=$collision" PORT_BASE=9100
done
for collision in 9103 9104 9105; do
    expect_invalid_before_launch "RC1 transport collision at $collision" \
        TABLE_BACKDOOR=on "TABLE_PORT_BASE=$collision" PORT_BASE=9100 NUM_RC=2
done
expect_invalid_before_launch "cross-instance transport collision" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=9099 PORT_BASE=9100 NUM_RC=2
expect_valid_launch "maximum single-RC table port" \
    TABLE_BACKDOOR=on TABLE_PORT_BASE=65535 PORT_BASE=9100 NUM_RC=1

echo "PASS: default-off and enabled table launch switch"
