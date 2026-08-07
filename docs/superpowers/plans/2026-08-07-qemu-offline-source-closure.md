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
