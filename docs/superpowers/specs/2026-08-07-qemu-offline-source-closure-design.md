# QEMU Offline Source-Closure Design

## Goal

Make every newly produced or imported offline package contain a QEMU 9.2.0
source archive that can configure without downloading the three subprojects
required by QEMU's Meson build.

## Architecture

Add one tracked, listing-only validator at
`scripts/validate-qemu-source-closure.py`. A small parent checks the physical
archive size, then runs the tar parser in a resource-limited worker with CPU,
address-space, wall-clock, member-count, path-byte, PAX-byte, and declared-file
size bounds. It opens gzip or xz tar archives without extracting them and
requires every logical path to be unique and rooted exactly at `qemu-9.2.0`.

The worker accepts only regular files, directories, symlinks, and hardlinks.
Every explicitly listed ancestor must be a directory. Symlinks must be leaf
members whose relative target remains within `qemu-9.2.0`; the only absolute
target exception is the authentic QEMU 9.2.0 leaf
`roms/edk2/EmulatorPkg/Unix/Host/X11IncludeHack -> /opt/X11/include`.
Hardlinks must be leaves and resolve to one unique regular archive member.
FIFO, device, socket, unknown, duplicate, conflicting, or escaping entries are
rejected. The three required subproject `meson.build` paths must each be the
single regular member at their exact `qemu-9.2.0/...` path.

`scripts/prepare-offline.sh` obtains QEMU from an existing local xz archive, a
local source directory, or the official QEMU 9.2.0 release URL. Only the
official download must match the pinned official SHA-256. All three sources
must pass the shared closure validator immediately before ZIP publication.

`setup.sh --import` requires a version-3 package to contain exactly one nested
QEMU tar after safe outer-ZIP extraction. Legacy driver-only packages with no
QEMU candidate remain compatible. If any package contains a `qemu-*.tar.*`,
there must be exactly one and its basename must be `qemu-9.2.0.tar.xz` or
`qemu-9.2.0.tar.gz`; arbitrary names and dual-format packages fail before an
import transaction is created. Setup verifies `python3` exists only when it
will invoke the shared validator, then passes the expected top explicitly. A
failed preflight removes only its project-local `build/tmp` import workspace
and leaves existing project artifacts unchanged.

## Compatibility

Import continues accepting both `.tar.xz` and `.tar.gz`. Version-3 metadata and
the default no-driver profile remain unchanged; closure is established from
the archive content rather than a trustable metadata claim. Manual download
instructions point to the official `.tar.xz` release.

The authentic release contains 81,379 unique members: 75,465 regular files,
5,849 directories, and 65 symlinks. It has no hardlinks, special members, or
PAX headers. Its one absolute symlink is the exact leaf exception above; none
of its links is an archive-member ancestor.

## Resource limits

The parent rejects archives larger than 256 MiB before parsing. The worker has
a 256 MiB address-space limit, a 60-second CPU limit, and a 90-second wall
timeout. It rejects more than 200,000 members, more than 32 MiB of cumulative
member-name bytes, a single name longer than 4 KiB, more than 2 GiB of declared
regular payload, a PAX key or value larger than 1 MiB, or more than 8 MiB of
cumulative PAX key/value bytes. The 135,188,800-byte authentic archive uses
81,379 members, 5,883,359 name bytes, a 158-byte longest name, 647,679,574
declared regular bytes, and zero PAX bytes; its measured unbounded baseline was
79,648 KiB maximum RSS and 15.67 seconds locally.

## Tests

Direct helper tests cover complete gzip/xz archives, exact-top enforcement,
each missing required member, non-regular and special members, duplicate and
conflicting logical paths, non-directory explicit ancestors, safe and escaping
links, regular headers with trailing-slash names, unreadable listings, and a
large-PAX compressed fixture. Integration tests prove incomplete local
packaging input fails, a valid local tar succeeds, a non-official download
fails the pinned hash after requesting the official URL, and missing, wrongly
named, duplicate, or invalid nested QEMU inputs are rejected before transaction
creation or target mutation.

Authentic release coverage is explicitly opt-in and never downloads during the
ordinary focused test. Place the official file under project `build/tmp`, then
run:

```bash
QEMU_OFFICIAL_RELEASE_TAR="$PWD/build/tmp/qemu-9.2.0.tar.xz" \
  bash tests/integration/test_offline_qemu_archive.sh
```

This mode requires an absolute regular-file path, exact size `135188800`, exact
SHA-256 `f859f0bc65e1f533d040bbe8c92bcfecee5af2c921a6687c652fb44d089bd894`,
and a successful invocation of the same source-closure helper. Its output is
the retained size/hash/helper evidence for a real official tar.
