#!/usr/bin/env python3
"""Validate that a QEMU source tar contains its offline Meson subprojects."""

from __future__ import annotations

import sys
import tarfile
from pathlib import Path


REQUIRED_MEMBERS = (
    "subprojects/keycodemapdb/meson.build",
    "subprojects/berkeley-softfloat-3/meson.build",
    "subprojects/berkeley-testfloat-3/meson.build",
)


def fail(message: str) -> int:
    print(f"QEMU source closure validation failed: {message}", file=sys.stderr)
    return 1


def validate(archive: Path) -> int:
    matches: dict[str, list[tuple[str, bool]]] = {
        required: [] for required in REQUIRED_MEMBERS
    }

    try:
        with tarfile.open(archive, mode="r:*") as source_tar:
            for member in source_tar:
                name = member.name
                safety_name = name[:-1] if member.isdir() and name.endswith("/") else name
                components = safety_name.split("/")
                if (
                    not safety_name
                    or name.startswith("/")
                    or any(component in ("", ".", "..") for component in components)
                ):
                    return fail(f"unsafe member path: {name!r}")

                for required in REQUIRED_MEMBERS:
                    required_suffix = f"/{required}"
                    if not name.endswith(required_suffix):
                        continue
                    top_level = name[: -len(required_suffix)]
                    if not top_level or "/" in top_level:
                        return fail(
                            f"required member lacks one QEMU top-level: {name}"
                        )
                    matches[required].append((top_level, member.isreg()))
    except Exception as error:  # Listing errors must always fail closed.
        return fail(f"cannot read tar listing for {archive}: {error}")

    for required, found in matches.items():
        if not found:
            return fail(f"missing required member: <qemu-top>/{required}")
        if len(found) != 1:
            return fail(
                f"required member must appear exactly once: <qemu-top>/{required}"
            )
        if not found[0][1]:
            return fail(f"required member is not a regular member: {found[0][0]}/{required}")

    top_levels = {found[0][0] for found in matches.values()}
    if len(top_levels) != 1:
        return fail("required members do not share a common top-level")

    print(f"QEMU source closure: PASS top-level={next(iter(top_levels))}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return fail(f"usage: {Path(argv[0]).name} <qemu-source.tar.xz|tar.gz>")
    archive = Path(argv[1])
    if not archive.is_file():
        return fail(f"archive is not a regular file: {archive}")
    return validate(archive)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
