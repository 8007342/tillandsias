# Managed Lua terminal trace: bounded first slice

@trace order:1539-dt84, order:1384-aixy

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
measurement. Full candidate gating and landing remain pending. The rebuilt
pre-trace binary's SHA-256 is
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

Next action: parent runs and archives independent controls, gates the frozen
candidate, opens a partial-slice PR, and checkpoints via serialized landing;
then releases the unfinished row with the exact remaining coverage above.
