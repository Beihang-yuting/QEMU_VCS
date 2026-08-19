# Target-native table sideband validation

Date: 2026-08-19 (Asia/Shanghai)

## Scope and revisions

This report validates the optional table-sideband port described by
`docs/superpowers/specs/2026-08-18-table-sideband-target-port-design.md` and
`docs/superpowers/plans/2026-08-18-table-sideband-target-port.md`.

- Target base: `bca79aaa6a54ecb881bb0fdff73245216492bc93`
  (`origin/feature/qemu-vcs-isolated-tcp`).
- Validated implementation HEAD: `36a3ccc9d07186b6304c2d5f106b3dd0ee611b85`
  (`feature/table-backdoor-sideband-target`).
- The remote disposable source repository was an exact synchronization of the
  shared tracked tree and had local commit
  `5cb1c3a66510530eaab362135978d8f534670b91`. Its 505 tracked entries match the
  corresponding local entries; the local checkout additionally has 20
  unrelated tracked files under `third_party/dpu-debugutils/`. The different
  full-tree IDs are therefore not presented as identical commits.

The final task groups are represented by these implementation commits:

- Task 11, PF0 reads: `85e3663` and fallback fix `99f4bf6`.
- Task 12, default-off launch switch: `0f71037`, `cc0bbee`, `7574924`, and
  `cc0271c`.
- Task 13, transactional Guest overlay: `68cea8f`, `41e8229`, and `3c116ec`.
- Task 14, complete buffers and QID batches: `b246ea9`, `31e07de`, and
  `c4ed723`.
- Task 15, integration kit and multi-RAM example: `36a3ccc`.

All VCS compilation and simulation ran on `10.11.10.53` through `bash -lic`.
The synchronized source and out-of-tree build were:

```text
/home/ubuntu/test_cosim/builds/table-sideband-target-src
/home/ubuntu/test_cosim/builds/table-sideband-target-build
```

No credential, proxy setting, generated binary, QEMU source tree, or simulator
output was added to the repository.

## Full target regression

The final foreground run used:

```bash
cd /home/ubuntu/test_cosim/builds/table-sideband-target-build
/usr/bin/time -p ctest --output-on-failure -j1
```

Result: `73/73` passed, zero failures, including the retained 45-test target
baseline. CTest reported 433.11 seconds; the surrounding timer reported
433.18 seconds real, 101.05 seconds user, and 86.63 seconds system. The saved
log is `/tmp/task16-ctest-final.log`.

The first full run is discarded setup evidence, not a product failure. It
passed 72/73; `test_dpu_debugutils_build` failed with
`fatal: Needed a single revision` because the freshly synchronized disposable
Git repository had no `HEAD`. Committing that exact already-synchronized tree
created only the disposable remote commit named above. Targeted test 71 then
passed, and the final clean foreground run passed all 73 tests. An earlier
background wrapper also produced malformed status bookkeeping; its status is
discarded in favor of the foreground run and its direct exit code.

Seven focused binaries were then invoked independently so one failure could
not hide later results:

```text
tests/unit/test_table_protocol                  RC 0
tests/unit/test_dpu_table_policy                RC 0
tests/unit/test_table_ctrl_core                 RC 0
tests/unit/test_table_read_decode               RC 0
tests/unit/test_table_lifecycle                 RC 0
tests/integration/test_table_roundtrip          RC 0
tests/unit/test_table_vcs_core                  RC 0
AGGREGATE|TOTAL=7|FAILURES=0|RC=0
```

The durable log is
`/home/ubuntu/test_cosim/builds/task16-focused-evidence-36a3ccc9/table-sideband-focused-validation.log`
(SHA-256
`49b6a0576b33ae8aa1b66009f46578ee50e1ca3eaadb3fb6ce9e40acae871718`).
Its companion provenance manifest is `manifest.txt` in the same private
directory (SHA-256
`bdb70427059193959e689c768888b2cf144ec037ef8793810515e3554b6277f1`).

The focused tests cover controller slot ownership and contention, terminal
partial execution, timeout/protocol completion without replay, the exact
proven-no-commit replay cases, invalid route maps, target disappearance,
completion validation, per-RC activation/reassembly, publish-once concurrency,
strict RC checks, and cleanup/worker isolation.

## QEMU build, registration, and launch behavior

The injected QEMU build was generated under the repository-ignored
`third_party/qemu` work area only. The copied environment initially contained
absolute paths plus stale Task 10 table sources. Environment staging therefore:

- moved the old build to `build-stale-task16`;
- configured a fresh `third_party/qemu/build` against the current source and
  build paths;
- moved obsolete copied table headers to `stale-task16-hw-net`; and
- removed obsolete copied Meson registrations before `make qemu-device`
  injected only the current sources.

This cleanup changed no tracked file and is not evidence of a product-source
defect. `make qemu-device` returned 0 and produced QEMU 9.2.0. Fresh queries
returned 0:

```bash
third_party/qemu/build/qemu-system-x86_64 -device cosim-pcie-rc,help
third_party/qemu/build/qemu-system-x86_64 -device cosim-table-ctrl,help
```

The retained `cosim-pcie-rc` help includes `instance_id`, `mmio_timeout_ms`,
`num_pfs`, `port_base`, `remote_host`, `transport`, `vf_dma_base`,
`vf_dma_size`, and `vf_iommu`. The new table-controller help includes:

```text
device_instance=<uint32>  default 0
instance_id=<uint32>      default 0
listen_addr=<str>
rc_id=<uint32>            default 0
table_port_base=<uint32>  default 10100
timeout_ms=<uint32>       default 3000
```

`test_qemu_table_setup_smoke.sh` and `test_table_launch_switch.sh` both passed.
The default-off launch contract stayed normalized to the target baseline; port
zero, overflowing base-plus-instance values, and oversized ports are rejected.

## Live QEMU fallback evidence

Both live cases used real QEMU devices: the root port at
`bus=pcie.0,addr=0x3`, the main `cosim-pcie-rc` behind it, and
`cosim-table-ctrl` at `bus=pcie.0,addr=0x6`. The main bridge completed the real
v2 three-connection TCP handshake, a topology request/response, and one QEMU
CFGRD/completion. It stayed realized before and after each table-sideband case.

No-client case
(`/home/ubuntu/test_cosim/builds/task16-live-noclient.YtMX9P`):

- QMP remained responsive in `prelaunch`, and PCI enumeration included
  `1af4:10f0`.
- qtest assigned table BAR0 at `0xe0000000` and read magic `0x4c425443`.
- `READY` was 0 before and after; there was no route activation or false
  `READY=1`.
- The main bridge helper returned 0 and remained realized.

Invalid-map case
(`/home/ubuntu/test_cosim/builds/task16-live-invalid.XxKiYi`):

- The table transport completed a protocol-valid handshake and received a
  complete `BEGIN`, two `ENTRY`, `END` generation.
- The generation was rejected for a duplicate route ID, not for disconnect or
  an incomplete protocol exchange.
- Markers were `TABLE_HANDSHAKE_VALID=1`,
  `INVALID_FULL_GENERATION_SENT=1`,
  `INVALID_REASON=duplicate_route_id`, and `INVALID_HELPER_RC=0`.
- qtest read `READY=0` before and after; QEMU logged
  `cosim-table[0]: READY=0`; QMP and the main bridge remained responsive.

These cases prove table configuration failure falls back without breaking the
original main bridge. They do not claim a real Guest/DUT table deposit.

## VCS and filelist validation

The standalone VCS runners used the synchronized source on host 53:

```text
run_test_cosim_table_unit.sh          RC 0  COSIM_TABLE_UNIT: ALL PASS
run_test_cosim_table_service.sh       RC 0  ALL PASS
run_test_cosim_table_runtime.sh       RC 0  ALL PASS
run_test_cosim_table_multiram.sh      RC 0  ALL PASS
run_test_runtime_bdf_utils.sh         RC 0
run_test_dpu_501x_profile.sh          RC 0
run_test_cosim_cpl_payload_codec.sh   RC 0
```

The last three were invoked with `bash`. Two retained scripts are tracked mode
`100644`; direct execution therefore returned the expected shell RC 126 before
they were rerun with `bash`, matching their CTest invocation. File modes were
not changed to hide that plan-command mismatch.

The retained target filelist was also linked without adding a production DUT
top:

```text
archive: /home/ubuntu/test_cosim/builds/table-sideband-target-build/lib/libcosim_bridge.a
output:  /home/ubuntu/test_cosim/builds/table-sideband-target-build/vcs-cosim/simv_cosim
FILELIST_LINK_RC=0
```

The executable retained `bridge_vcs_init_ex_rc`,
`bridge_vcs_poll_tlp_scalar_rc`, and `bridge_vcs_send_cpl_scalar_rc`, plus the
table symbols `table_vcs_init_rc`, `table_vcs_activate_routes_rc`, and
`table_vcs_cleanup_rc`.

## Deterministic completion and two-RC evidence

A disposable C wrapper included production
`bridge/table/cosim_table_protocol.h` bytes independently matched to local
commit `36a3ccc9`, compiled with
`-std=c11 -Wall -Wextra -Werror`, and invoked
`cosim_table_status_may_frontdoor` for every defined status. Compile and run
both returned 0:

```text
SUCCESS       0
NOT_READY     1
NO_ROUTE      1
UNSUPPORTED   1
SLOT_BUSY     1
EXEC_ERROR    0
TIMEOUT       0
UNKNOWN       0
TARGET_GONE   0
PROTOCOL      0
STATUS_MATRIX_SUMMARY|defined=10|safe=4|failures=0
STATUS_MATRIX_ALL_PASS
```

Artifacts are in
`/home/ubuntu/test_cosim/builds/task16-status-matrix-36a3ccc9`; compile and run
log hashes are
`9d1bc1dde301a60c6b55cafae30bce8fe8a10c44f0d4a6ff1253c3a4d37497a8`
and
`2e9efa3b4b8111f159e15b7e99042e2a1cc8d83d8baa92d1776fc2a6dd7acd79`.
Only the four proven-no-commit outcomes permit frontdoor replay. In particular,
partial `EXEC_ERROR`, timeout, disappearance, malformed completion, and success
are terminal.

A second disposable VCS harness copied/adapted the retained runtime test and
runner. It compiled production `cosim_table_pkg`, runtime, and service bytes
independently matched to local commit `36a3ccc9`, together with the retained
lifecycle DPI stub. Compile and run both returned 0:

```text
RC0: stub effective_port=10100 transaction=0x100 index=7 offset=0x70 raw_data[0]=0x00 calls=1
RC1: stub effective_port=10101 transaction=0x101 index=7 offset=0x70 raw_data[0]=0x01 calls=1
```

For each RC, load/register/init/activate/interrupt/cleanup and handler-call
counts were exactly one. The run ended with `TWORC_ISOLATION_ALL_PASS`.
Artifacts are in `/home/ubuntu/test_cosim/builds/task16-tworc-36a3ccc9`;
compile and run log hashes are
`7a8b3412953818dcb1a068e014cc63a64e25b49a801a44b3450024f00a8d7fcf`
and
`4916f5901509026316ec7877cac5383cc6f79c36c5aae6b2469818c091494aa7`.
This proves that production SV passes RC0/RC1 separately through initialization
and dispatch, passes base 10100 with instance IDs 0/1, routes stub-generated
RC-specific requests to the correct handlers, and completes one ordered
lifecycle per RC. The effective-port values are calculated by the DPI stub.
The harness opens no socket and does not exercise production C transport,
production route parsing, real port binding, two-host network isolation, or a
production-DUT deposit.

## Guest overlay and module

Validation used release
`/home/ubuntu/test_cosim/releases/dpu-qid128-pf0only-vnetcache-skipeth-20260810`
and `source/host-driver-net-skipeth.tar.gz`, extracting only into
`/home/ubuntu/test_cosim/builds/task16-guest.YChDbQ`.

- Archive before/after SHA-256:
  `6807536b08663c82a40b2e37b065a4e6f2e910cc2137433c9df4c54a1750018c`.
- Release-tree before/after SHA-256:
  `b9d94d690588f1aef22b49910c09206de9039e0d6ef9850d1fa96d656b9ed737`.
- Clean extracted-tree SHA-256:
  `c6aeab96971014046b31ac2f50046fd5fbde849df215ce36d3262d63dc92db84`.
- First and second applied-tree SHA-256:
  `a39130322212494c465a1f952c2077b05b5799d50cfe4ae7488f6612f6b3ad42`.
- `OVERLAY_IDEMPOTENT=1`; the release and archive remained untouched.

The archive already contains matching applied markers/content, so both apply
passes correctly reported that the overlay was up to date. Bare
`make modules` returned 2 at the retained baseline LACP dependency
`bonding/bond_alb.c:20:10: fatal error: net/ipx.h`. Building the same extracted
tree with `make CFLAGS=-UDPU_LACP modules` returned 0. This environment-specific
baseline workaround is recorded rather than attributed to the table overlay.

The resulting `dpu_snd1.ko` reports version 2.1.0, vermagic
`5.15.0-101-generic`, the `table_backdoor` parameter, and build metadata with
`-UDPU_LACP`. It exports/retains `dpu_table_submit` and
`dpu_table_submit_batch`.

Direct Guest tests passed: `test_dpu_table_policy`, `test_dpu_table_batch`,
`test_dpu_table_overlay_apply.sh`, `test_dpu_complete_buffer_patch.sh`,
`test_dpu_qid_batch_patch.sh`, and
`test_dpu_table_batch_source_contract.sh`. A command named
`test_dpu_complete_buffer_release_patch.sh` in an older scratch checklist does
not exist in this repository; its lookup stopped one composite wrapper, after
which every real remaining test was rerun and passed.

## Hygiene and retained evidence

The exact range check

```bash
git diff --check bca79aaa6a54ecb881bb0fdff73245216492bc93...36a3ccc9d07186b6304c2d5f106b3dd0ee611b85
```

returns 2 with 1,831 diagnostic lines confined to the three nested Guest
unified-patch payloads and the CRLF reference fixture
`tests/fixtures/dpu_qid_reference/af_mng.c`. Excluding `**/*.patch` leaves 890
lines, all in that byte-preserving CRLF fixture. Excluding the patch payloads
and reference fixture gives production-source RC 0 with no diagnostics. These
are classified nested-artifact warnings, not silently normalized.

Fresh scans found:

- no target-deleted `cosim.sh`, `cosim_pcie_pf.[ch]`, or
  `vcs-tb/cosim_xrc_test.sv` tracked;
- no tracked `third_party/qemu` dependency;
- no new build-product/archive candidate and no new SV production top;
- no change to the named common TLP/transport ABI headers;
- zero PAT or proxy persistence matches, zero added secret-pattern matches,
  and zero new paths among four pre-existing documentation examples that use a
  password variable with `sshpass`; and
- a clean assigned worktree before this report was created.

All Task 16 evidence directories and `/tmp/task16*` files were hashed into the
private manifest
`/home/ubuntu/test_cosim/builds/task16-validation-evidence-36a3ccc9/files.sha256`:

```text
FILE_COUNT=259
FILES_SHA256=4288817875f606f1e9401a4c2f53ba31656cd2a4fa89cce0864655a3833c8c22
summary.txt SHA256=d01eef2501bca1ef048abd48deb2e467a18256ac9e5663abc82ae58b6ca5d7e8
TASK16_PROCESS_COUNT=0
TABLE_PORT_10100_10103_LISTENER_COUNT=0
SOURCE_STATUS_COUNT=0
```

## Interpretation and limitation

The validation establishes ABI, routing, transport, failure ownership,
default-off compatibility, QEMU registration/lifecycle, Guest overlay behavior,
SV service dispatch, and deterministic per-RC isolation. The retained
`vio_notify_mock_handler` and runtime DPI harness validate integration and
packing only. They deliberately contain no production DUT hierarchy. A real
DUT table deposit still requires the user's production handler, matching Guest
image, table layout/protection codec, and DUT hierarchy. No mock result in this
report is presented as real-DUT semantic evidence.
