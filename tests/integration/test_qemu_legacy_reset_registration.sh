#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
qemu_build=${1:-}

if [[ -z "$qemu_build" || ! -f "$qemu_build/build.ninja" ]]; then
    echo "usage: $0 QEMU_BUILD_DIR" >&2
    exit 2
fi

python3 - "$repo" "$qemu_build" <<'PY'
import pathlib
import shlex
import subprocess
import sys
import tempfile

repo = pathlib.Path(sys.argv[1])
build = pathlib.Path(sys.argv[2]).resolve()
source = (repo / "qemu-plugin/cosim_pcie_rc.c").read_text()
probe_source = repo / "tests/integration/qemu_legacy_reset_probe.c"
target = "tests/unit/test-qdev-global-props"

direct = "dc->legacy_reset = cosim_pcie_rc_reset;" in source
helper = (
    "device_class_set_legacy_reset(dc, cosim_pcie_rc_reset);" in source
)
if direct == helper:
    raise SystemExit(
        "cosim reset registration must use exactly one direct/helper pattern"
    )
registration = "helper" if helper else "direct"

subprocess.run(
    ["ninja", "-C", str(build), target],
    check=True,
    stdout=subprocess.DEVNULL,
)
commands = subprocess.check_output(
    ["ninja", "-C", str(build), "-t", "commands", target],
    text=True,
).splitlines()
compile_line = next(
    line for line in commands
    if "test-qdev-global-props.c.o" in line and " -c " in line
)
link_line = next(
    line for line in commands
    if " -o tests/unit/test-qdev-global-props " in line
)

with tempfile.TemporaryDirectory(prefix="cosim-qom-reset-") as temp:
    temp_path = pathlib.Path(temp)
    probe_object = temp_path / "qemu_legacy_reset_probe.o"
    probe_binary = temp_path / "qemu_legacy_reset_probe"

    compile_args = shlex.split(compile_line)
    rewritten = []
    index = 0
    while index < len(compile_args):
        arg = compile_args[index]
        if arg == "-MD":
            index += 1
            continue
        if arg in ("-MQ", "-MF"):
            index += 2
            continue
        if arg == "-o":
            rewritten.extend((arg, str(probe_object)))
            index += 2
            continue
        if arg == "-c":
            rewritten.extend((arg, str(probe_source)))
            index += 2
            continue
        rewritten.append(arg)
        index += 1
    subprocess.run(rewritten, cwd=build, check=True)

    link_args = shlex.split(link_line)
    for index, arg in enumerate(link_args):
        if arg == "-o":
            link_args[index + 1] = str(probe_binary)
        elif arg.endswith("test-qdev-global-props.c.o"):
            link_args[index] = str(probe_object)
    subprocess.run(link_args, cwd=build, check=True)
    subprocess.run([str(probe_binary), registration], check=True)

print("[qemu-legacy-reset] PASS: real QOM device_cold_reset invokes callback")
PY
