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
  `6f0c772999ad0f1d3febf08f5698c50be97800a1`
  on `feature/qemu-vcs-isolated-tcp`.

The implementation and validation-fix chain is:

```text
f3286249d81422e3d499f660d299a5f7663f7354  test(driver): define table frontdoor throttle boundary
4d91eb2f8c9bf2c13d53cda4f65caba0b6a18bf5  feat(driver): pace table frontdoor writes
4a975e8d2b7ca25e82a7eed4806d4738865274cd  docs(driver): integrate frontdoor write pacing
83b95317efad4ba2705a14ac66049c57024e2b2a  fix(driver): harden overlay patch state audit
3447f1eb21089dc42fa7ff6d1266873b21a80e29  fix(test): allow full overlay audit matrix
6f0c772999ad0f1d3febf08f5698c50be97800a1  test(driver): cover concurrent frontdoor pacing
```

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
`31ad32d1ac2738e3254895111e1530f0a11cdcea7f8d70232a71ee79d8ea9f77`.

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
implementation. They are archived as:

```text
a91638c63e5835d83a6b61bfc5cbbbdaf849573dccfff15f81be9c7367b26df8  evidence/focused-ctest-pre-concurrency-review.log
3e6490f85752649462ac1970ad0b9f1b0354621110afcf95686a07cb1340e28c  evidence/full-ctest-pre-concurrency-review.log
```

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

The final fresh post-review focused run used verbose CTest output so the
concurrent harness contracts were captured in the canonical log. It passed as
follows:

```text
9/9 passed
0 failures
Total Test time (real) = 61.07 seconds
FOCUSED_CTEST_RC=0
```

The overlay test took 51.73 seconds and the patched-driver frontdoor test took
0.31 seconds. The log contains both required markers:

```text
53: concurrent harness source contract passed
53: frontdoor throttle runtime contract passed
```

The final fresh post-review serial full regression used:

```bash
cd /home/ubuntu/test_cosim/builds/table-sideband-target-build
/usr/bin/time -p ctest --output-on-failure -j1
```

It passed exactly 75/75 with zero failures. CTest reported 476.23 seconds;
the surrounding timer reported 476.25 seconds real, 120.43 seconds user, and
117.18 seconds system. `FULL_CTEST_RC=0` was captured from the timed CTest
pipeline. A separate `ctest -N` returned zero and reported exactly
`Total Tests: 75`.

The durable final logs and SHA-256 values are:

```text
6f6b61d44ed4e9f93295b6603d2ee6b33adf9239ee5d6cae0426c97b9a091761  evidence/focused-ctest.log
ce463d49b0f86822b9b2ca57357b42e68a49fc3d5393fb981122cc5ec97b2d76  evidence/full-ctest.log
d3a266b014d824f4f0a98b8a3da1d463beedfea34574fb3436c8f3ae2225ce72  evidence/validation-configure.log
00d6219633a17310238a9f049fc17761fa253b1fc6eba0a66cddf35c7065f7d2  evidence/validation-build.log
a7247ad10363d7f77543084d928edef6db60647f83d0de1ffefb9cb8fb5a8cac  evidence/ctest-list.log
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
source input manifest:
  31ad32d1ac2738e3254895111e1530f0a11cdcea7f8d70232a71ee79d8ea9f77
portable throttle source:
  425764c1c1fa642d572452124c17ce3b7747640a9da25e1e7d511170ff06bd77
module:
  a002d711d7b512c7247ab6c8978277385423585dbee8d1cd5a3a61684c800bc7
reference archive:
  6807536b08663c82a40b2e37b065a4e6f2e910cc2137433c9df4c54a1750018c
patched-source tree manifest:
  4e7d2f725c9156d602e3d05c6bc5d1c2cdd0babfdba2398208e89acb9187fa5d
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

The Guest driver was initially generated from the clean reference archive and
built in the delivery tree. The authoritative verification build then reran
the same command on that same delivery tree. The following three files are the
authoritative final module-build evidence; the transcript captures
`PIPESTATUS[0]` as `build_rc=0`, and `module-build.exit` contains `0`:

```text
138fb6f0aa42e712f7e76534fb32e9cadead4298e974c28ea47fc507420ed070  evidence/module-build-verification.log
44b0f8e6fde54404f735a97c840dd2fc90fd2531b6012c1d918a41a4b1dda1c0  evidence/module-build-verification-transcript.log
9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa  evidence/module-build.exit
```

That successful verification build produced the final module SHA-256
`a002d711d7b512c7247ab6c8978277385423585dbee8d1cd5a3a61684c800bc7`.
The earlier `evidence/module-build.log` belongs only to the initial build and
is not the final authoritative build record. Likewise,
`evidence/module-before-verification.sha256` (file SHA-256
`d291e54529667a2591a73dae82f70695a5d56b482df49bc91468f35aa20bd8f3`)
records the superseded pre-verification module SHA-256
`d7f2cc584523003cda5e04b67b4ca170458124b6ee9692c73545217716b9dd6c`.

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

- `struct dpu_hw` owns one `atomic64_t table_frontdoor_write_sequence`, and
  probe initializes it with `atomic64_set(..., 0)`. Counters are therefore
  independent per `dpu_hw`/DUT context.
- The generated `common.h` has one helper definition and exactly two helper
  call sites. Those calls replace only the fallback loops in
  `wr32_for_each()` and `wr32_for_high_order()`; the generic `wr32()` macro and
  other register paths are unchanged.
- Each wrapper returns on both `DPU_TABLE_SUCCESS` and `DPU_TABLE_ERROR`
  before entering its fallback loop. Successful semantic writes and hard
  errors therefore perform neither frontdoor MMIO nor a throttle increment.
- The helper writes the actual DWORD first. When the interval is zero it
  returns before the atomic increment. Otherwise the exact interval boundary
  performs `readl()` through `rd32()` at the triggering DWORD address.
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
- The canonical focused log records both the concurrent harness source
  contract and the frontdoor throttle runtime contract as passed.

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
- Multi-RAM specifically passed as test 67/75 in 45.80 seconds. The existing
  report also records the standalone `run_test_cosim_table_multiram.sh` pass
  and the retained filelist link evidence.

## Hygiene

The assigned worktree was clean before this report refresh. The final range
relative to the remote base contains 106 paths (87 added and 19 modified), all
accounted for by the retained table-sideband work and this throttle chain. The
range after `358162f` through `6f0c772` contains 15 paths including this report
and 14 implementation paths when the report is excluded.

`git diff --check 358162f..6f0c772` returns 2 only because
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
sanitized before push, and the final branch-range added-line secret scan found
no matches for GitHub tokens, password-plus-numeric literals, literal
`SSHPASS` assignments, or literal `sshpass -p` usage. Existing documentation
still demonstrates an interactive password-variable prompt; that is not a
persisted credential. Validation credentials were supplied out of band. No
remote URL or credential helper was changed.

## Limitations

The pacing `readl()` deliberately discards its data. It is a posted-write
drain, not a table-data correctness check, and Linux `readl()` supplies no
separate completion status to this helper. Existing QEMU/VCS completion and
timeout behavior remains authoritative.

The unit, patched-driver, module-build, QEMU, VCS, Guest, and multi-RAM results
validate integration and bounded write pacing. They do not determine the
capacity or preferred interval of the user's production DUT. The default of
100 must still be exercised with the user's real table layout, production DUT
hierarchy, and representative workload; tune or disable the interval only
from that workload evidence.
