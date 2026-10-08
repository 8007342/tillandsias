# Managed Lua terminal trace: bounded first slice

@trace order:1539-dt84, order:1384-aixy

## Outcome

PR [213](https://github.com/8007342/tillandsias/pull/213) merged at
`1630531e5d7f58b2b72adfdc80e54b93679b7f7f` on2026-10-04T00:26:45Z.
The parent independently verified published work head
`cbafa30a1fd1992a7456b3d55c03e7f1be96bcab` as an ancestor of refreshed
origin/linux-next. The serialized queue actually exited0 in1091021ms and
reported `landed=1 evicted=0 requeued=0 skipped=0`; PR state/merge identity and
ancestry, not queue success alone, establish integration. This completes only
the approved first slice. The unfinished1539 claim is released to ready;
parent1384, preflight1520, OpenSpec4.2 and native obligations remain open.

## Scope and authority

This is a partial slice of `lua-script-run-trace-records-every-managed-process-terminal-outcome`,
not closure of that packet, parent1384, or OpenSpec4.2. The existing packet
already specifies correlated fields, stderr-only `--trace`, host-measured
duration, and `command_policy::redact`; the earlier ASK was unnecessarily
treated as a first-slice design gate. The operator-approved window ends
2026-10-04T15:46:14Z. Existing exclusions remain: no UX/default-deny activation,
destructive E2E, release, build/landing rewrite, or unsupported native claim.

The source baseline is `e889a1c0ef94c8a1fba0c3b8623d6e07964613fd`; the claim is
`fa913d2a9` on linux-next, confirmed by `check-claim-confirmed.sh`. Research
used Astra, regular implementation used Terra, and the parent owns review,
CLI tests, compiler serialization, gates, and integration. MCP handshake was
healthy but tools were unexposed, so the named fallback is **unavailable**.

## Contract delivered by the candidate

- Script `proc.run` records only an actual successful executor `Output`, using
  one host duration measurement shared with its returned Lua result.
- Dispatcher completions record a real published output before `on_exit`.
  `Finished` receipt is not output publication: the pending/empty-queue retry
  and completion barrier remain intact, with the original frozen duration.
- An ordered collection shared by Host clones deduplicates real `Output.run`
  identities. Repeated waits, callback-visible table mutation, and callback
  failure do not rewrite or duplicate an observed record. Callback release
  does not destroy already collected records.
- Normal `--trace` rendering writes one `trace:proc:` JSON line per record on
  stderr, then preserves the existing script summary. Fields are `kind`, actual
  `run_id`, redacted executed `argv` array, host `wall_ms`, actual `status`,
  explicit `code` (null unless exited), `truncated`, and signal when available.
- Existing redaction is applied per argument before serialization, not to the
  returned argv. No stdin, environment values, or child fd payloads are retained
  in trace records; no persistent sink is added. Arbitrary-secret removal is
  not claimed.
- Denial, missing consent, failed start, and executor errors without intact
  output invent no child exit code, terminal status, or executor identity.

Parent review added explicit real-RunId deduplication and removed an unnecessary
clone of the full captured output during the completion transition. Existing
8MiB per-fd prefix capture, streaming limits, policy authorization, scope
latches, and callback delivery order are unchanged. The Mac observer file
`tests/lua_proc.rs` is not edited; new controls live in `tests/lua_proc_trace.rs`.

## Verification status

Parent independently compiled and measured585 distinct tests, all passing:
12 new trace controls,428 plan-library tests (including10 dispatcher units),
46 CLI tests,45 existing Lua proc controls,22 predicate-class tests, and32
executor tests. There were no cfg-skipped native selections in this Linux
measurement. The forced candidate gate actually exited0 in1010755ms on
`cbafa30a1fd1992a7456b3d55c03e7f1be96bcab`; its workspace baseline measured
2921 tests, zero new reds, zero tolerated failures and zero stale entries.
A separately forced landing gate passed on the actual merged candidate with
the same2921/0/0/0 workspace result. Native stubs/zero-test selections do not
count as native conformance. The rebuilt pre-trace binary's SHA-256 is
`7c147a5d86c7320caea4dc9f525575f98038fd6ab09ab38ea61f3a306c3143c1`.
A real baseline probe returned successful proc.run and waited-spawn results,
but stderr contained only the old script summary and no process records.

Parent commands (run serially inside the existing builder toolbox):

```text
cargo test -p tillandsias-plan --test lua_proc_trace
cargo test -p tillandsias-plan --lib
cargo test -p tillandsias-plan --test lua_proc
cargo test -p tillandsias-plan --test lua_predicate_classes
cargo test -p tillandsias-exec
TILLANDSIAS_SKIP_VERSION_BUMP=1 TILLANDSIAS_FORCE_CHECK=1 ./build.sh --check
```

The identical named CLI controls were measured against the preserved pre-slice
artifact:10 positive record controls FAILED and two existing-behavior negative
controls PASSED (no-child identity/code absence and outer-timeout stdout/status
invariance). After the slice, all12 PASSED. The pre-fix launcher actually
exited101; this is the expected regression red, not an absent result or a
tolerated production failure. Raw before/after logs and typed receipts live
under `plan/evidence/lua-terminal-trace-20261003/` and
`plan/issues/evidence/lua-terminal-trace-20261003/`.

The combined targeted launcher actually exited101 after all585 tests passed:
its final strict Clippy command hit the pre-existing `async_trait` expansion's
`double_must_use` lint in `tillandsias-core/src/image_builder.rs` under
rustc/clippy1.99. The existing gate in `build.sh` already names the
coordinator-approved allowance in its strict Clippy phase. The parent retry
uses that exact existing policy (`-D warnings -A clippy::double_must_use`),
not a new lint waiver or
source edit. The corrected Clippy+format launcher actually exited0 in5379ms.
The genuine exited101 receipt and original diagnostic are archived; the whole
first launcher is not labeled green. No new gate/lint waiver is introduced.

The first preflight actually exited1: its issue-citation guard caught the
parent's newly added line-number code citation. That citation is corrected to
the strict Clippy phase by name. The corrected preflight actually exited0 in
56060ms, with partial coverage:206 ran, eight declared skips, ten deadline
skips, zero could-not-run and zero refusals. Skipped checks are not vouched for.
The original preflight log was accidentally overwritten during retry; its
original typed exited1 receipt survives, but byte-exact original diagnostics
are unavailable. A direct citation control reproduced the same known bad
citation and actual exited1; that separately identified control and its
corrected green are retained, not relabeled as the original log.
Separately, the parent mistakenly ran the fast affordance scanner beside
preflight fixtures. Its enumerated temporary `.znbn-prefix-runner` vanished
while being scanned, producing repeated sed read errors followed by an `ok` token.
That overlapping observation is NOT accepted as gate evidence. The raw output
is archived, and the parent now serializes the whole verification phase,
including fast deciders, not only compiler invocations. No scanner contract or
fixture assertion is changed; deterministic vanished-input hardening remains
an explicit follow-up audit1549-i4va rather than an inferred closure from this race.

The evidence archive is byte-exact plaintext. Raw logs contain original trailing
whitespace and final blank lines, so a whole-archive `git diff --check` reports
those diagnostic bytes; runtime/test source whitespace is checked separately.
No diagnostic bytes are stripped and no tracked-binary guard waiver is added.
The first full candidate gate actually exited1 in4625ms: the new investigation
packet lacked an explicit scorable/unscoreable obligation. Its audit-only
deliverable now names an honest unscoreable reason and the future contract
test path, rather than claiming a nonexistent litmus test. Preserve that gate
receipt and log before retry; no runtime source or gate contract is changed.

## Launcher correction and provenance

The first claim-gate launcher omitted explicit `XDG_RUNTIME_DIR` at the bounded
agent door. It actually exited1 after toolbox entry failed; it was neither a
green nor an absent status. A harmless paired `toolbox run ... gcc --version`
probe reproduced exit1 without context and exit0 with only
`--env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR`. The corrected gate actually exited0
in949951ms. This is a launcher correction, not a production environment-policy
change or permission to widen the inherited environment.

The failed entry created two empty toolbox lock files in an already-existing
empty checkout directory. Their birth times matched this launch, and they were
moved by exact filename into external scratch; no pre-existing file, directory,
or warm-target symlink was removed. Only meaningful candidate artifacts will
be committed. Raw launcher receipts are retained for the evidence archive.

## Remaining work and next action

Keep1539 ready after this slice's claim is released. Remaining terminal
collection includes outstanding/dropped handles and script-scope cleanup on
verdict, error, and outer timeout; outer timeout still exits before normal
trace rendering. Comprehensive chain/select/all and legacy/standalone doors
remain separately unmeasured, even though common dispatcher completion can
incidentally observe pumped children. Some executor errors bypass Finished and
carry no intact output identity: do not fabricate outcomes to fill that gap.
Any executor observation API requires a coordinated ownership decision.

Native1543-ffhg/1544-cnae and Mac observer1543-f44v remain native-host packets,
ready/dependency-unblocked but not measured by Linux.1547-ynn5 and1545-qdb5,
native preflight, remaining capture-contract reconciliation, parent1384 and
preflight1520 remain open. No unattended scheduler was armed.

## Unmeasured follow-on design

Astra's second read-only audit proposes a <=2h registered-async-handle slice:
collect authentic published successful outputs after `Scope::cleanup` and
before `Host::release_callbacks`, without pumping the closed dispatcher or
invoking callbacks, then expose those records in the outer-timeout trace
branch. Preserve `Completed`/pending receipt durations; otherwise report
launch-request-to-host-collection elapsed time, not exact OS lifetime. Reuse
actual RunId deduplication and redaction, and serialize collector/release.
`Err`/`None` must not become fabricated terminal records.

Public `Process::result` is non-consuming, and retained handlers cover dropped
Lua handles. However, successful host registration can follow executor setup;
blocking `Scope::run` has its own post-result recording race; and job assignment,
reader/stdin/wait, final reap and setup-handshake failures may leave no intact
Output identity or public process enumeration. These remain explicit gaps.
No follow-on implementation or test coverage is asserted by this research;
any executor observation/identity/registration API needs coordinated ownership.
The complete research handoff is preserved as
`plan/evidence/lua-terminal-trace-20261003/follow-on-trace-research.md.txt`.

The cycle used three completed delegates (two Astra research, one Terra
implementation); parent verification is independent. Token instrumentation
reported `source=absent`, meaning unknown spend rather than zero. UTC rollover
maintenance is recorded separately with cache/peer-runtime GC deferred, not
silently performed during this scoped pass.

Next action: claim another bounded registered-async cleanup/timeout trace
slice under1539's existing contract, preserve the remaining registration,
identity, legacy/native gaps, and checkpoint through a separately verified PR.
Do not close the whole trace or parent from this partial Linux evidence.

## Second slice (2026-10-08)

Delivered on `work/1539-dt84` (Linux only, macuahuitl): the registered
async-handle slice proposed under "Unmeasured follow-on design".

- `Host::collect_terminals` (backed by `Host::collect_locked`) runs after
  `Scope::cleanup`. For each handler still registered in `Dispatch`, it records
  the authentic published `Ok(Output)`. It never pumps the closed dispatcher,
  invokes a callback, sets `delivered`, or waits on a supervisor.
  `Err` and `None` publications produce no record.
- `Host::release_callbacks` now collects under the same dispatch lock before
  it clears handlers. A second collection is therefore serialized with release,
  and `push_terminal` de-duplicates on the actual `Output.run`. Redaction still
  goes through `terminal_record`.
- Duration: a `Completed` or pending `Finished` receipt keeps its frozen
  `wall_ms` and is labelled `wall_basis: finished_receipt`. Otherwise
  `wall_ms` is the time from the launch request to host collection, labelled
  `wall_basis: launch_request_to_host_collection`. That figure is not the OS
  lifetime. Records produced by the normal dispatcher path carry no
  `wall_basis` and keep their shape unchanged.
- In `cli_run`, the outer-timeout branch now renders `trace:proc:` records and
  the `[script-run]` summary to stderr when `--trace` is given. It does this
  after `Scope::cleanup` and the collection. Stdout, the refusal line and
  exit 124 are unchanged.

Red/green: these controls failed against the unfixed trunk:
`trace_outer_timeout_renders_collected_outstanding_async_terminals`,
`trace_dropped_unwaited_handle_is_collected_on_verdict_and_on_error` and the
strengthened `trace_outer_timeout_preserves_stdout_and_exit_and_renders_held_records`.
On the unfixed trunk the outer timeout printed zero records and the dropped
handle was absent. The other 12 trace controls stayed green, including the new
`trace_already_delivered_handle_is_not_duplicated_or_relabelled_by_collection`.
After the fix, all 15 trace controls, 49 `lua_proc` tests and 11
`script_process` unit tests pass. The new unit test
`cleanup_collection_keeps_receipts_labels_fallback_and_never_fabricates`
covers Err and None absence, the preserved pending-receipt duration and
callback-free collection. A mutation that ignored pending receipts made it
fail (31 ms against 1 ms).

A child that was still running at the outer timeout is recorded only with
the completion the executor actually published when cleanup ended it
(`timed_out` or `signaled`, with a null code). The collector never relabels it.

Still open: handles whose registration follows executor setup; the blocking
`proc.run` post-result-recording race under the outer timeout; executor errors
without an intact Output identity; chain/select/all comprehensiveness and the
legacy/standalone doors; and native Mac/Windows conformance. None of these
needs, or received, an executor API change in this slice. The row stays open.
