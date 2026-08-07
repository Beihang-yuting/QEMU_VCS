#!/usr/bin/env python3
"""Validate that a QEMU source tar contains its offline Meson subprojects."""

from __future__ import annotations

import os
import posixpath
import resource
import signal
import subprocess
import sys
import tarfile
from pathlib import Path


REQUIRED_MEMBERS = (
    "subprojects/keycodemapdb/meson.build",
    "subprojects/berkeley-softfloat-3/meson.build",
    "subprojects/berkeley-testfloat-3/meson.build",
)
EXPECTED_TOP = "qemu-9.2.0"
OFFICIAL_ABSOLUTE_SYMLINK = (
    "qemu-9.2.0/roms/edk2/EmulatorPkg/Unix/Host/X11IncludeHack",
    "/opt/X11/include",
)
MIB = 1024 * 1024
MAX_ARCHIVE_BYTES = 256 * MIB
MAX_MEMBERS = 200_000
MAX_TOTAL_NAME_BYTES = 32 * MIB
MAX_MEMBER_PATH_BYTES = 4095
MAX_PATH_COMPONENT_BYTES = 255
MAX_LINK_TARGET_BYTES = 4095
MAX_TOTAL_REGULAR_BYTES = 2 * 1024 * MIB
MAX_PAX_FIELD_BYTES = 1 * MIB
MAX_TOTAL_PAX_BYTES = 8 * MIB
WORKER_ADDRESS_SPACE_BYTES = 256 * MIB
WORKER_CPU_SECONDS = 60
WORKER_WALL_SECONDS = 90


def fail(message: str) -> int:
    print(f"QEMU source closure validation failed: {message}", file=sys.stderr)
    return 1


def validate(archive: Path, expected_top: str = EXPECTED_TOP) -> int:
    required_paths = {
        f"{expected_top}/{required}": required for required in REQUIRED_MEMBERS
    }
    entries: dict[str, tuple[str, str]] = {}
    member_count = 0
    total_name_bytes = 0
    total_regular_bytes = 0
    total_pax_bytes = 0

    try:
        with tarfile.open(archive, mode="r:*") as source_tar:
            for member in source_tar:
                name = member.name
                member_count += 1
                if member_count > MAX_MEMBERS:
                    return fail("member count exceeds resource limit")
                name_bytes = len(os.fsencode(name))
                total_name_bytes += name_bytes
                if total_name_bytes > MAX_TOTAL_NAME_BYTES:
                    return fail("cumulative member names exceed resource limit")
                if member.isreg():
                    if member.size < 0:
                        return fail(f"negative regular member size: {name}")
                    total_regular_bytes += member.size
                    if total_regular_bytes > MAX_TOTAL_REGULAR_BYTES:
                        return fail("declared regular payload exceeds resource limit")
                for pax_key, pax_value in member.pax_headers.items():
                    key_bytes = len(
                        str(pax_key).encode("utf-8", errors="surrogatepass")
                    )
                    value_bytes = len(
                        str(pax_value).encode("utf-8", errors="surrogatepass")
                    )
                    if (
                        key_bytes > MAX_PAX_FIELD_BYTES
                        or value_bytes > MAX_PAX_FIELD_BYTES
                    ):
                        return fail("PAX field exceeds resource limit")
                    total_pax_bytes += key_bytes + value_bytes
                    if total_pax_bytes > MAX_TOTAL_PAX_BYTES:
                        return fail("cumulative PAX fields exceed resource limit")
                logical_name = (
                    name[:-1] if member.isdir() and name.endswith("/") else name
                )
                components = logical_name.split("/")
                if (
                    not logical_name
                    or name.startswith("/")
                    or any(component in ("", ".", "..") for component in components)
                ):
                    return fail(f"unsafe member path: {name!r}")
                if len(os.fsencode(logical_name)) > MAX_MEMBER_PATH_BYTES:
                    return fail("member path exceeds filesystem limit")
                if any(
                    len(os.fsencode(component)) > MAX_PATH_COMPONENT_BYTES
                    for component in components
                ):
                    return fail("member path component exceeds filesystem limit")
                if components[0] != expected_top:
                    return fail(
                        f"member is outside expected top-level {expected_top}: {name}"
                    )

                if member.isreg():
                    kind = "regular"
                elif member.isdir():
                    kind = "directory"
                elif member.issym():
                    kind = "symlink"
                elif member.islnk():
                    kind = "hardlink"
                else:
                    return fail(f"unsupported member type: {name}")

                if logical_name in entries:
                    if logical_name in required_paths:
                        return fail(
                            f"required member must appear exactly once: {logical_name}"
                        )
                    return fail(f"duplicate logical member path: {logical_name}")
                entries[logical_name] = (kind, member.linkname)
    except MemoryError:
        return fail("worker memory resource limit exceeded")
    except Exception as error:  # Non-memory listing errors must fail closed.
        return fail(f"cannot read tar listing for {archive}: {error}")

    for logical_name in entries:
        components = logical_name.split("/")
        for component_count in range(1, len(components)):
            ancestor = "/".join(components[:component_count])
            ancestor_entry = entries.get(ancestor)
            if ancestor_entry is not None and ancestor_entry[0] != "directory":
                return fail(
                    f"explicit non-directory ancestor: {ancestor} -> {logical_name}"
                )

    resolved_hardlinks: dict[str, str] = {}
    for logical_name, (kind, linkname) in entries.items():
        if kind in ("symlink", "hardlink") and (
            len(os.fsencode(linkname)) > MAX_LINK_TARGET_BYTES
        ):
            return fail("link target exceeds filesystem limit")
        if kind == "symlink":
            if (logical_name, linkname) == OFFICIAL_ABSOLUTE_SYMLINK:
                continue
            if not linkname or linkname.startswith("/"):
                return fail(f"unsafe symlink target: {logical_name} -> {linkname!r}")
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(logical_name), linkname)
            )
            if resolved != expected_top and not resolved.startswith(
                f"{expected_top}/"
            ):
                return fail(
                    f"unsafe symlink target: {logical_name} -> {linkname!r}"
                )
        elif kind == "hardlink":
            target_components = linkname.split("/")
            if (
                not linkname
                or linkname.startswith("/")
                or any(
                    component in ("", ".", "..")
                    for component in target_components
                )
                or posixpath.normpath(linkname) != linkname
            ):
                return fail(
                    f"non-canonical hardlink target: "
                    f"{logical_name} -> {linkname!r}"
                )
            if any(
                len(os.fsencode(component)) > MAX_PATH_COMPONENT_BYTES
                for component in target_components
            ):
                return fail("hardlink target component exceeds filesystem limit")
            if linkname != expected_top and not linkname.startswith(
                f"{expected_top}/"
            ):
                return fail(
                    f"unsafe hardlink target: {logical_name} -> {linkname!r}"
                )
            resolved_hardlinks[logical_name] = linkname

    for logical_name, target in resolved_hardlinks.items():
        visited = {logical_name}
        while True:
            if target in visited:
                return fail(
                    f"hardlink target is not a unique regular member: {logical_name}"
                )
            visited.add(target)
            target_entry = entries.get(target)
            if target_entry is None:
                return fail(
                    f"hardlink target is not a unique regular member: {logical_name}"
                )
            if target_entry[0] == "regular":
                break
            if target_entry[0] != "hardlink":
                return fail(
                    f"hardlink target is not a unique regular member: {logical_name}"
                )
            target = resolved_hardlinks[target]

    for required_path in required_paths:
        required_entry = entries.get(required_path)
        if required_entry is None:
            return fail(f"missing required member: {required_path}")
        if required_entry[0] != "regular":
            return fail(f"required member is not a regular member: {required_path}")

    print(f"QEMU source closure: PASS top-level={expected_top}")
    return 0


def set_worker_resource_limits() -> int:
    try:
        resource.setrlimit(
            resource.RLIMIT_AS,
            (WORKER_ADDRESS_SPACE_BYTES, WORKER_ADDRESS_SPACE_BYTES),
        )
        resource.setrlimit(
            resource.RLIMIT_CPU,
            (WORKER_CPU_SECONDS, WORKER_CPU_SECONDS + 1),
        )
    except (OSError, ValueError) as error:
        return fail(f"cannot establish worker resource limits: {error}")
    return 0


def run_worker(archive: Path, expected_top: str) -> int:
    try:
        archive_size = archive.stat().st_size
    except OSError as error:
        return fail(f"cannot stat archive: {archive}: {error}")
    if archive_size > MAX_ARCHIVE_BYTES:
        return fail(
            f"archive exceeds physical size limit: {archive_size} > "
            f"{MAX_ARCHIVE_BYTES}"
        )

    command = [
        sys.executable,
        str(Path(__file__).resolve()),
        "--worker",
        "--expected-top",
        expected_top,
        str(archive),
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=WORKER_WALL_SECONDS,
            check=False,
            shell=False,
        )
    except subprocess.TimeoutExpired:
        return fail(
            f"worker wall-clock resource limit exceeded: {WORKER_WALL_SECONDS}s"
        )
    except OSError as error:
        return fail(f"cannot start validation worker: {error}")

    if completed.stdout:
        print(completed.stdout, end="")
    if completed.stderr:
        print(completed.stderr, end="", file=sys.stderr)
    if completed.returncode < 0:
        signal_number = -completed.returncode
        try:
            signal_name = signal.Signals(signal_number).name
        except ValueError:
            signal_name = str(signal_number)
        return fail(f"validation worker killed by resource signal: {signal_name}")
    return completed.returncode


def main(argv: list[str]) -> int:
    worker = False
    arguments = argv[1:]
    if arguments and arguments[0] == "--worker":
        worker = True
        arguments = arguments[1:]

    if len(arguments) == 1:
        expected_top = EXPECTED_TOP
        archive = Path(arguments[0])
    elif len(arguments) == 3 and arguments[0] == "--expected-top":
        expected_top = arguments[1]
        archive = Path(arguments[2])
    else:
        return fail(
            f"usage: {Path(argv[0]).name} "
            f"[--expected-top {EXPECTED_TOP}] <qemu-source.tar.xz|tar.gz>"
        )
    if expected_top != EXPECTED_TOP:
        return fail(f"unsupported expected top-level: {expected_top}")
    if not archive.is_file():
        return fail(f"archive is not a regular file: {archive}")
    if archive.is_symlink():
        return fail(f"archive is a symbolic link: {archive}")
    if worker:
        limit_status = set_worker_resource_limits()
        if limit_status != 0:
            return limit_status
        return validate(archive, expected_top)
    return run_worker(archive, expected_top)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
