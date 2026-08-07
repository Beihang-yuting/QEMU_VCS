# QEMU Offline Source-Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject QEMU tar archives that cannot configure fully offline and use the hash-pinned official QEMU 9.2.0 release as the packager default.

**Architecture:** A Python listing-only validator owns the tar contract. Both shell entry points invoke it before publishing or transactionally importing a QEMU tar, while the packager separately authenticates an official network download.

**Tech Stack:** Bash, Python 3 standard-library `tarfile`, GNU tar/zip test fixtures, CTest.

---

### Task 1: Define the closure contract in tests

**Files:**
- Modify: `tests/integration/test_offline_qemu_archive.sh`
- Modify: `tests/integration/test_offline_ubuntu_server.sh`

- [ ] Create real gzip/xz fixtures with the three required regular members.
- [ ] Assert each missing member, duplicate/non-regular member, regular trailing-slash filename, inconsistent top level, unsafe path, and corrupt listing is rejected.
- [ ] Assert incomplete local packaging input and wrong-hash official-download content are rejected.
- [ ] Assert incomplete nested imports fail before transaction copy and leave target sentinels unchanged.
- [ ] Run `QEMU_OFFICIAL_RELEASE_TAR="$PWD/build/tmp/qemu-9.2.0.tar.xz" bash tests/integration/test_offline_qemu_archive.sh`; retain the exact size, SHA-256, and helper-PASS output as authentic-release evidence.
- [ ] Run both focused tests on exact `7179e66`; record the expected missing-validator and accepted-incomplete-archive RED failures.

### Task 2: Implement and connect the shared validator

**Files:**
- Create: `scripts/validate-qemu-source-closure.py`
- Modify: `scripts/prepare-offline.sh`
- Modify: `setup.sh`

- [ ] Implement a `tarfile.open(..., mode="r:*")` listing pass that never extracts.
- [ ] Reject unreadable archives, absolute or dot-dot member paths, non-regular/duplicate required members, and differing required-member top levels.
- [ ] Download `https://download.qemu.org/qemu-9.2.0.tar.xz` and compare its digest with `f859f0bc65e1f533d040bbe8c92bcfecee5af2c921a6687c652fb44d089bd894`.
- [ ] Validate local/downloaded/repacked QEMU archives immediately before ZIP publication.
- [ ] Validate an imported nested QEMU tar before creating the offline transaction.
- [ ] Update manual download guidance to the official `.tar.xz` URL while retaining gzip import discovery.

### Task 3: Verify and commit

**Files:**
- Verify all files above.

- [ ] Run focused integration tests and `bash -n`/Python compilation checks locally.
- [ ] Run the related CTest/diff checks locally.
- [ ] Run focused tests and the full 41+ integration set on `ubuntu@10.11.10.53` through a bash login shell.
- [ ] Inspect `git diff --check`, the complete diff, and final status.
- [ ] Create one new commit without amend or push and report its SHA plus RED/GREEN evidence.

### Task 4: Bind the producer, validator, and importer to QEMU 9.2.0

**Files:**
- Modify: `tests/integration/test_offline_qemu_archive.sh`
- Modify: `tests/integration/test_offline_ubuntu_server.sh`
- Modify: `scripts/validate-qemu-source-closure.py`
- Modify: `scripts/prepare-offline.sh`
- Modify: `setup.sh`

- [ ] Add a complete `foo/...` fixture and run the current helper; record RED
  because it prints `PASS top-level=foo`.
- [ ] Add wrong-basename and dual `.tar.xz`/`.tar.gz` nested packages. Wrap
  `mktemp` to record any `offline-transaction.*` request and assert rejection,
  no marker, and unchanged target sentinel.
- [ ] Require every tar member to start with exact logical top
  `qemu-9.2.0`, and invoke the validator with that expected top explicitly
  from producer and importer.
- [ ] Replace first-match `qemu-*.tar.*` discovery with a complete candidate
  enumeration. If any candidate exists, require count one and one of the two
  exact names; require a candidate for version 3 while retaining zero-candidate
  legacy driver-only imports. Check `command -v python3` before the helper and
  emit a dependency-specific error.
- [ ] Run both focused tests; expect the `foo` and nested-package cases to pass
  only after the production checks are present.

### Task 5: Validate the complete tar member graph

**Files:**
- Modify: `tests/integration/test_offline_qemu_archive.sh`
- Modify: `scripts/validate-qemu-source-closure.py`

- [ ] Add TarInfo fixtures for a top-level symlink followed by required regular
  descendants, a required ancestor symlink, FIFO, character device, escaping
  symlink, duplicate logical path, regular/directory conflict, safe symlink,
  valid hardlink, and hardlink to a non-regular or absent target.
- [ ] Run the current helper and record RED for each malicious archive it
  accepts because it only records the three required leaf members.
- [ ] Build a unique logical-path map. Permit only regular, directory, symlink,
  and hardlink members; require any explicit ancestor to be a directory;
  validate link targets and leaf status; then require the three exact regular
  closure paths.
- [ ] Permit only the authentic leaf
  `qemu-9.2.0/roms/edk2/EmulatorPkg/Unix/Host/X11IncludeHack` with exact target
  `/opt/X11/include` as an absolute-link exception.
- [ ] Run synthetic tests and the SHA-pinned authentic release. Expect all
  malicious fixtures rejected and the authentic archive accepted.

### Task 6: Isolate tar parsing behind hard resource limits

**Files:**
- Modify: `tests/integration/test_offline_qemu_archive.sh`
- Modify: `scripts/validate-qemu-source-closure.py`

- [ ] Create a small compressed archive whose first accepted member carries a
  64 MiB PAX value, followed by the three exact closure members. Run the old
  helper under `/usr/bin/time -v`; record that it returns PASS and its peak RSS.
- [ ] Make the public invocation a parent that rejects physical archives over
  256 MiB and launches a hidden worker with RLIMIT_AS=256 MiB,
  RLIMIT_CPU=60 seconds, and a 90-second subprocess timeout.
- [ ] In the worker enforce 200,000 members, 32 MiB cumulative names, 4 KiB per
  name, 2 GiB declared regular bytes, 1 MiB per PAX key/value, and 8 MiB
  cumulative PAX bytes. Report memory, signal, timeout, or listing failures with
  distinct nonzero diagnostics.
- [ ] Run the large-PAX fixture. Expect a PAX resource-limit rejection while
  the calling parent remains alive, then re-run a normal fixture to prove the
  parent path still works.

### Task 7: Reverify the hardened contract

**Files:**
- Verify all files above and the existing design document.

- [ ] Run Python AST parsing, Bash syntax, the five related local scripts, and
  `git diff --check`.
- [ ] On `ubuntu@10.11.10.53` through `bash -lic`, run the SHA-pinned authentic
  focused mode and full CTest from `build/tmp`; expect `41/41`.
- [ ] Retain threshold, old/new large-PAX peak/rejection, authentic member-type,
  size/hash/helper, and host-53 results under the existing Task10 artifact.
- [ ] Audit zero scoped processes and mounts, remove exact local/remote
  temporary trees, stage only intended files, and append one commit without
  amend or push.
