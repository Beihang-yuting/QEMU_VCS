# QEMU Offline Source-Closure Design

## Goal

Make every newly produced or imported offline package contain a QEMU 9.2.0
source archive that can configure without downloading the three subprojects
required by QEMU's Meson build.

## Architecture

Add one tracked, listing-only validator at
`scripts/validate-qemu-source-closure.py`. It opens gzip or xz tar archives
without extracting them, rejects unreadable or unsafe member names, and
requires exactly one regular `meson.build` for each of `keycodemapdb`,
`berkeley-softfloat-3`, and `berkeley-testfloat-3` below one common top-level
directory.

`scripts/prepare-offline.sh` obtains QEMU from an existing local xz archive, a
local source directory, or the official QEMU 9.2.0 release URL. Only the
official download must match the pinned official SHA-256. All three sources
must pass the shared closure validator immediately before ZIP publication.

`setup.sh --import` locates a nested QEMU tar after safe outer-ZIP extraction
and validates it before creating or copying into an import transaction. A
failed preflight removes only its project-local `build/tmp` import workspace
and leaves existing project artifacts unchanged.

## Compatibility

Import continues accepting both `.tar.xz` and `.tar.gz`. Version-3 metadata and
the default no-driver profile remain unchanged; closure is established from
the archive content rather than a trustable metadata claim. Manual download
instructions point to the official `.tar.xz` release.

## Tests

Direct helper tests cover complete gzip/xz archives, each missing required
member, non-regular members, inconsistent top levels, duplicates, unsafe paths,
regular headers with trailing-slash names, and unreadable listings. Integration
tests prove incomplete local packaging input fails, a valid local tar succeeds,
a non-official download fails the pinned hash after requesting the official URL,
and an incomplete nested import is rejected before transaction copying or
target mutation.

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
