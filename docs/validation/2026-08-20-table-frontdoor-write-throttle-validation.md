# Table frontdoor write throttle validation

Date: 2026-08-20 (Asia/Shanghai)

## Scope and revisions

This report validates the Guest-driver table-frontdoor write throttle described
by `docs/superpowers/specs/2026-08-20-table-frontdoor-write-throttle-design.md`
and `docs/superpowers/plans/2026-08-20-table-frontdoor-write-throttle.md`.

- Remote branch base: `bca79aaa6a54ecb881bb0fdff73245216492bc93`
  (`origin/feature/qemu-vcs-isolated-tcp`).
- Table-sideband state targeted by the throttle design:
  `a1ed632f513d38a9feff6f073a200979e6635693`.
- Task 1 starting point, after the design and plan commits:
  `358162f30c285b52878680a4858af03ee508b3fe`.
- Validated implementation HEAD:
  `67b657f1bebfd79df46cb0f96b2a65079b66d426`
  on `feature/qemu-vcs-isolated-tcp`.

The implementation and validation-fix chain is:

```text
f3286249d81422e3d499f660d299a5f7663f7354  test(driver): define table frontdoor throttle boundary
4d91eb2f8c9bf2c13d53cda4f65caba0b6a18bf5  feat(driver): pace table frontdoor writes
4a975e8d2b7ca25e82a7eed4806d4738865274cd  docs(driver): integrate frontdoor write pacing
83b95317efad4ba2705a14ac66049c57024e2b2a  fix(driver): harden overlay patch state audit
3447f1eb21089dc42fa7ff6d1266873b21a80e29  fix(test): allow full overlay audit matrix
6f0c772999ad0f1d3febf08f5698c50be97800a1  test(driver): cover concurrent frontdoor pacing
67b657f1bebfd79df46cb0f96b2a65079b66d426  fix(driver): serialize frontdoor pacing boundary
```

Commits `e60c832` and `9fffaeb` are intermediate, report-only evidence
commits, not implementation revisions. This report is finalized by a later
report-only commit whose identity cannot be embedded in its own contents
without creating a self-reference; the validated implementation chain
therefore ends at `67b657f` above.

Before publication, the unpublished plan history was rewritten to remove a
credential literal. The rewritten commit identities above replace their
pre-sanitization counterparts; no code or test behavior changed.

All target compilation, CTest, VCS, and Guest-module work ran on
`ubuntu@10.11.10.53` through `bash -lic`. The disposable project paths were:

```text
source: /home/ubuntu/test_cosim/builds/table-sideband-target-src
build:  /home/ubuntu/test_cosim/builds/table-sideband-target-build
```

The sanitized tracked controlled set contains 190 paths including this report.
The report was excluded to avoid a self-referential manifest, and the remaining
189 implementation inputs were synchronized with `rsync -aR --checksum`. They
were hashed independently on the local worktree and host 53; the manifests
compared byte-for-byte equal. The host-53 manifest is
`/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/evidence/validation-controlled-inputs.sha256`
and its SHA-256 is
`83ba5db953f9efd241ff06c0b615795fdb2ce0261301a1e4c7d0541f6f1be304`.

## RED and GREEN sequence

The implementation plan and commit chain record the following test-first
sequence:

1. Before the portable predicate existed, building
   `test_dpu_table_frontdoor_throttle` failed on the missing
   `cosim_table_frontdoor_throttle_core.h`. Adding the predicate made the same
   target and executable exit zero.
2. `bash tests/integration/test_dpu_table_frontdoor_throttle_patch.sh` first
   failed with `missing throttle patch`. After patch 0004 and its immutable
   getter were added, that harness, the complete-buffer contract, and the QID
   batch contract exited zero.
3. `bash tests/integration/test_dpu_table_overlay_apply.sh` first failed
   because the installer did not manage
   `cosim_table_frontdoor_throttle_core.h`. Adding it to the transactional
   source list made the overlay and documentation contracts pass.

Task 5 also exposed and retained a validation RED rather than treating a
timeout as success. At `83b9531`, the fresh focused command was:

```bash
cd /home/ubuntu/test_cosim/builds/table-sideband-target-build
ctest --output-on-failure \
  -R 'dpu_table_frontdoor_throttle|dpu_table_overlay|dpu_complete_buffer|dpu_qid|table_launch|workflow_command|pcie_launch'
```

It returned CTest RC 8 with 8/9 passing because
`test_dpu_table_overlay_apply` hit its 30-second CTest timeout at 30.03
seconds. A traced direct run then completed every assertion, printed `PASS`,
and returned zero in 49.38 seconds. The trace showed the enlarged audit matrix
only entering its later cases after 30 seconds. The root cause was therefore
the stale test timeout, not an overlay assertion failure.

Commit `3447f1e` changed only that test's timeout from 30 to 90 seconds. After
resynchronizing and reconfiguring from that HEAD, a preliminary focused run
passed 9/9 in 58.52 seconds; the overlay test itself passed in 49.52 seconds.
Its corresponding preliminary full regression passed 75/75. Concurrency review
then extended the patched-driver harness at `6f0c772`, so those two successful
logs are pre-concurrency-review history and are not authoritative for the final
implementation. They are archived under
`/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820-pre-serialization/evidence`
as:

```text
a91638c63e5835d83a6b61bfc5cbbbdaf849573dccfff15f81be9c7367b26df8  focused-ctest-pre-concurrency-review.log
3e6490f85752649462ac1970ad0b9f1b0354621110afcf95686a07cb1340e28c  full-ctest-pre-concurrency-review.log
```

At `6f0c772`, the concurrent test proved independent counters and readbacks for
two separate `dpu_hw` instances, and its then-canonical focused and full runs
passed 9/9 and 75/75. Spinlock review subsequently identified a same-device
ordering gap: an atomic sequence selects a unique boundary writer, but by
itself does not prevent a later write from passing that writer's drain. Those
successful runs are therefore pre-spinlock-review evidence and are not
authoritative for the production fix. They are preserved as:

```text
6f6b61d44ed4e9f93295b6603d2ee6b33adf9239ee5d6cae0426c97b9a091761  evidence/focused-ctest-pre-spinlock-review.log
ce463d49b0f86822b9b2ca57357b42e68a49fc3d5393fb981122cc5ec97b2d76  evidence/full-ctest-pre-spinlock-review.log
```

Commit `67b657f` added an IRQ-safe per-`dpu_hw` pacing lock and deterministic
same-device boundary coverage. Its authoritative GREEN is the fresh run below.

The RED and diagnostic logs remain separate from both the archived preliminary
GREEN and the post-review canonical logs:

```text
evidence/focused-ctest-timeout30-red.log
evidence/overlay-timeout-diagnostic.log
```

An initial CTest capability probe using `--test-dir` was also retained as
`focused-ctest-unsupported-cli.log`. The host's older CTest ignored that
option and searched `/home/ubuntu`, so its zero-test result is not validation
evidence; all reported focused and full results were run after changing into
the build directory.

## Final reconfigure, incremental project build, and regression

The final CMake reconfigure reused the existing disposable build directory and
pointed its release-fixture test at the clean reference archive explicitly:

```bash
cmake -S "$src" -B "$build" -DCMAKE_BUILD_TYPE=Debug \
  -DDPU_TABLE_REFERENCE_ARCHIVE=/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810/source/host-driver-net-skipeth.tar.gz
cmake --build "$build" -j8
```

Configuration and the incremental project build both returned zero. This was
not a clean CMake build tree. Their logs are
`evidence/validation-configure.log` and `evidence/validation-build.log`; the
corresponding exit files record `CONFIGURE_RC=0` and `BUILD_RC=0` from
`PIPESTATUS[0]`. “Clean” in this report refers to the immutable reference
archive and the Guest-driver source provenance described below, not to the
reused project build directory.

The final fresh post-spinlock-review focused run used verbose CTest output so
the concurrent and same-device contracts were captured in the canonical log.
It passed as follows:

```text
9/9 passed
0 failures
Total Test time (real) = 59.67 seconds
FOCUSED_CTEST_RC=0
```

The overlay test took 50.09 seconds and the patched-driver frontdoor test took
0.33 seconds. The latter executes the deterministic same-`dpu_hw` boundary
gate, and the log contains all three required markers:

```text
53: frontdoor throttle source contract passed
53: concurrent harness source contract passed
53: frontdoor throttle runtime contract passed
```

The final fresh post-spinlock-review serial full regression used:

```bash
cd /home/ubuntu/test_cosim/builds/table-sideband-target-build
/usr/bin/time -p ctest --output-on-failure -j1
```

It passed exactly 75/75 with zero failures. CTest reported 488.39 seconds;
the surrounding timer reported 488.54 seconds real, 122.38 seconds user, and
116.61 seconds system. `FULL_CTEST_RC=0` was captured from the timed CTest
pipeline. A separate `ctest -N` returned zero and reported exactly
`Total Tests: 75`.

The durable final logs and SHA-256 values are:

```text
6f52bb5915412201f86ff11b0eed5e22fee731a909fd45f221c872ea93489937  evidence/focused-ctest.log
09603ca7d1d39a16927ad110d61205b5c9d5d09090c6d17403aa341567a1e509  evidence/full-ctest.log
d3a266b014d824f4f0a98b8a3da1d463beedfea34574fb3436c8f3ae2225ce72  evidence/validation-configure.log
a0380c0041acfe2fdcf01c28ba38111e0d4c710c395b014f9bb191e7f337bbdc  evidence/validation-build.log
a7247ad10363d7f77543084d928edef6db60647f83d0de1ffefb9cb8fb5a8cac  evidence/ctest-list.log
7e011fa8f342e41353607b12698074b8c266abf7b2fc3eaacf1b5efb8022f01d  evidence/validation-summary.txt
4516e2754ac2d69c625fcfed192b9827cd59958f560d8bede3e30a8e143f2650  evidence/validation-reproduce.txt
```

All `evidence/` paths in this report are relative to:

```text
/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820
```

## Driver delivery and hashes

The generated delivery paths are:

```text
driver source: /home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net
module:        /home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net/dpu_snd1.ko
```

Fresh on-host hashing produced:

```text
validation controlled-input manifest (189 implementation inputs):
  83ba5db953f9efd241ff06c0b615795fdb2ce0261301a1e4c7d0541f6f1be304
Task 4 r2 delivery source-input manifest (12 overlay inputs):
  9d2a06c895761f5333cc92eda00ccfb78c62c0a33704f729ae4d15093a3abfed
Task 4 r2 synchronized-input manifest (190 tracked inputs):
  146b5c464e61dff85a16fd9e1da49c3727e1a783ce44cc72ee96fb574478a800
portable throttle source:
  425764c1c1fa642d572452124c17ce3b7747640a9da25e1e7d511170ff06bd77
module:
  0cba6823475aa9ca6111094d0625fb20745ac5a3564ab93d50cb4155ddcc6f5b
reference archive:
  6807536b08663c82a40b2e37b065a4e6f2e910cc2137433c9df4c54a1750018c
patched-source tree manifest:
  8db8d1fe256376fb20d22d88a91234333ca0ecdd88bef45924af8b9ae77419c5
```

The last value is the live SHA-256 of `evidence/tree-first.sha256`, not the
hash of the small pointer file `patched-tree-manifest.sha256`. The reference
archive's before/after hashes are identical. The release directory was never
used as a build or patch target.

The reference release requires:

```bash
make -C /home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820/host-driver-net \
  CFLAGS=-UDPU_LACP modules
```

Task 4 r2 atomically preserved the previous delivery, generated the production
driver from the clean reference archive, applied the overlay twice, and built
the new delivery with the command above. The following three files are the
authoritative final module-build evidence; the transcript captures
`PIPESTATUS[0]` as `build_rc=0`, and `module-build.exit` contains `0`:

```text
94769d9c918aa79b6718739a7bc142bc5dedf9e322bbaae0bf64b77342d7c464  evidence/module-build.log
4896d7a9eff0159654e150ec9810b57aaaa4d8953272e9671743ebb2eae87e8c  evidence/module-build-transcript.log
9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa  evidence/module-build.exit
```

That build produced the final module SHA-256
`0cba6823475aa9ca6111094d0625fb20745ac5a3564ab93d50cb4155ddcc6f5b`.
The pre-serialization delivery remains intact at
`/home/ubuntu/test_cosim/builds/dpu-table-frontdoor-flush-20260820-pre-serialization`;
its superseded module SHA-256 is
`a002d711d7b512c7247ab6c8978277385423585dbee8d1cd5a3a61684c800bc7`.
It is retained for provenance but is not the production module. The Task 4 r2
`summary.txt` and `reproduce.txt` were kept byte-identical while this final run
added separate `validation-summary.txt` and `validation-reproduce.txt` files.

The final module's `modinfo` reports version 2.1.0,
vermagic `5.15.0-101-generic`, build metadata containing `-UDPU_LACP`, and:

```text
parm: table_frontdoor_flush_interval:Flush table frontdoor writes after this many DWORDs (0 disables) (uint)
```

The generated `main.c` proves the numeric default is 100 and the parameter is
read-only (`0444`). Thus `insmod dpu_snd1.ko` paces by default, while
`table_frontdoor_flush_interval=0` restores the original unpaced fallback.

Both overlay invocations returned zero. `tree-first.sha256` and
`tree-second.sha256` compare equal, and the delivered tree contains no
`*.orig` or `*.rej` files. Both apply logs state that the delivery is up to
date, as expected for the already-overlaid reference archive.

## Throttle scope and behavior

Inspection of the actual generated driver, not only the repository patch,
confirmed:

- `struct dpu_hw` owns one `atomic64_t table_frontdoor_write_sequence` and one
  `spinlock_t table_frontdoor_write_lock`. Probe initializes both, so the
  counter and IRQ-safe pacing lock are independent per `dpu_hw`/DUT context.
- The generated `common.h` has one helper definition and exactly two helper
  call sites. Those calls replace only the fallback loops in
  `wr32_for_each()` and `wr32_for_high_order()`; the generic `wr32()` macro and
  other register paths are unchanged.
- Each wrapper returns on both `DPU_TABLE_SUCCESS` and `DPU_TABLE_ERROR`
  before entering its fallback loop. Successful semantic writes and hard
  errors therefore perform neither frontdoor MMIO nor a throttle increment.
- When the interval is zero, the helper writes the DWORD and returns without
  touching either the atomic counter or the pacing lock. For a nonzero
  interval, `spin_lock_irqsave()` serializes the complete write, atomic
  increment, optional boundary `readl()` through `rd32()`, and
  `spin_unlock_irqrestore()` sequence. A later write on that same device cannot
  pass its boundary read, while distinct `dpu_hw` instances remain parallel.
- The portable predicate rejects interval zero and sequence zero and selects
  exact multiples with `sequence % interval == 0`. Unit and patched-wrapper
  tests cover intervals 0, 1, and 100, triggering-address selection,
  low-to-high and high-to-low loops, terminal results, and independent device
  sequences.
- The patched-wrapper harness models the kernel counter with C11
  `_Atomic uint64_t` storage and `atomic_fetch_add_explicit()`. A pthread
  barrier/start gate launches two independent `dpu_hw` instances concurrently,
  while a synchronized MMIO event log records the resulting accesses. Each
  device performs 100 writes and exactly one readback at its own 100th write,
  at that triggering write's exact address.
- The same-device test starts from sequence 99, holds boundary write A after
  its `writel()` while still inside the pacing lock, and makes follower B
  attempt that same lock. No follower MMIO is permitted until A is released;
  the synchronized event log then proves deterministic `W_A, R_A, W_B` order
  and a final sequence of 101.
- The canonical focused log records the frontdoor source, concurrent harness
  source, and frontdoor runtime contracts as passed.

`docs/COSIM-C-BUILD.md` and `docs/VCS-INTEGRATION-GUIDE.md` now use fixed host-53
source and module paths and give the exact `CFLAGS=-UDPU_LACP` module-build
command. They also document the performance tradeoff: a smaller interval
causes more drains and slower, more conservative pacing; a larger interval
causes fewer drains and faster operation with more DUT burst pressure; zero
disables pacing; and the default of 100 still requires real-workload
validation.

## Retained integration coverage

The final 75-test log retains the earlier target coverage documented in
`docs/validation/2026-08-18-table-sideband-target-validation.md`:

- Default/off and launch behavior: `test_table_launch_switch` and the existing
  report's “QEMU build, registration, and launch behavior” section retain the
  default-off contract and invalid-port rejection.
- QEMU: `test_qemu_integration`, the table target closure tests, and
  `test_qemu_table_setup_smoke` passed; the existing report retains live QEMU
  no-client and invalid-map fallback evidence.
- Guest: the transactional overlay, complete-buffer release fixture, QID
  batch, throttle patched-wrapper, and batch source contracts all passed. The
  final module build and `modinfo` evidence are recorded above.
- VCS: `test_runtime_bdf_utils`, `test_dpu_501x_profile`, the completion codec,
  table unit/service/runtime, and multi-RAM simulations all passed on host 53.
- Multi-RAM specifically passed as test 67/75 in 46.55 seconds. The existing
  report also records the standalone `run_test_cosim_table_multiram.sh` pass
  and the retained filelist link evidence.

## Hygiene

The assigned worktree was clean before this report refresh. The final range
relative to the remote base contains 106 paths (87 added and 19 modified), all
accounted for by the retained table-sideband work and this throttle chain. The
range after `358162f` through `67b657f` contains 17 paths including this report
and 16 implementation paths when the report is excluded.

`git diff --check 358162f..67b657f` returns 2 only because
`guest/dpu-table-sideband/0004-dpu-table-frontdoor-throttle.patch` is a nested
vendor-driver patch that intentionally preserves the reference driver's CRLF
bytes and whitespace. Every diagnostic is confined to that payload; it is
listed rather than normalized. The validation report itself is checked
separately and has no whitespace error.

The requested `bridge/common/cosim_protocol.h` path is absent in both the
remote base and this HEAD. The actual common protocol/transport/shm files —
`bridge/common/cosim_transport.h`, `transport_tcp.[ch]`, `transport_shm.c`,
and `shm_layout.[ch]` — have no branch-range diff. The table-specific protocol
headers were synchronized and independently hash-matched as intended.

No extracted `host-driver-net` tree, `.ko`, build directory, credential file,
token, or proxy configuration is tracked. The unpublished plan history was
sanitized before push, and the final implementation added-line secret-literal
scan, excluding this self-describing validation report, found no matches for
GitHub tokens, password-plus-numeric literals, literal `SSHPASS` assignments,
or literal `sshpass -p` usage. Existing documentation still demonstrates an
interactive password-variable prompt; that is not a persisted credential.
Validation credentials were supplied out of band. No remote URL or credential
helper was changed.

## Limitations

The pacing `readl()` deliberately discards its data. It is a posted-write
drain, not a table-data correctness check, and Linux `readl()` supplies no
separate completion status to this helper. Existing QEMU/VCS completion and
timeout behavior remains authoritative.

The per-device `atomic64_t` sequence is observed as a `u64` and theoretically
wraps after 2^64 nonzero-interval frontdoor DWORD writes. At wrap, sequence
zero is deliberately rejected by the portable predicate; the pacing phase then
restarts from one and may contain one nonstandard boundary gap. This lifetime
edge is documented rather than claimed as exercised by the finite regression.

The unit, patched-driver, module-build, QEMU, VCS, Guest, and multi-RAM results
validate integration and bounded write pacing. They do not determine the
capacity or preferred interval of the user's production DUT. The default of
100 must still be exercised with the user's real table layout, production DUT
hierarchy, and representative workload; tune or disable the interval only
from that workload evidence.
