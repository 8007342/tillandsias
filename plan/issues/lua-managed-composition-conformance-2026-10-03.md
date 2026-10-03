# Managed Lua composition: implementation and parent controls

@trace order:1538-pwdr, order:1539-dt84, order:1384-aixy

## Scope and provenance

The operator approved a 24-hour continuation, with composition first and a
separately claimed bounded tracing slice after it lands. Astra audited source
`d3ffda692`; Sol implemented in an isolated worktree based on `247db6e54`,
and Terra authored disjoint CLI conformance tests. The parent owns review,
integration, verification, commits and pushes. The original dirty checkout
remains untouched. MCP tools were not exposed; the local plan CLI and cited
source spans are the unavailable-read-path fallback.

This is scoped script-runtime composition, not new cacheable capabilities,
shell-string execution, a pipe operator, filesystem widening, default-deny
activation, UX, a release, or closure of the parent migration. Existing
8 MiB per-fd prefix capture remains authoritative; original 1 MiB-tail prose
is still recorded contract drift, not an implemented capture policy.

## Pinned API behavior

- `proc.select{p1,p2,timeout_ms=...}` returns the original authentic handle,
  non-consumingly, in ordered stream-completion receipt order. It preserves
  that order across result-publication races, already-completed handles and
  repeated calls. The default deadline is 300000 ms; explicit zero disables
  only this deadline. Expiry returns `nil,"timed_out"`, leaves children
  running and invents no child result. The outer script deadline wins.
- `proc.all{...}` returns full result tables in argument order and pumps
  every owned producer, including nonmembers. Empty all returns `{}`;
  empty select is an error. Sparse, duplicate, forged, foreign or unexpected
  list entries are programmer errors. Private weak-key host-bound identities
  validate handles and copied-method receivers without retaining Lua tables.
- `proc.chain{{argv=...},...}` validates and snapshots all requests,
  nested argv/env/stdin/options and effective absolute cwd before launch or
  consent consumption. Only stage one may specify stdin. Empty chains and
  managed `group=false` are errors; existing single-run legacy group=false
  is unchanged. Each actual stage authorizes once immediately before launch.
  Ordinary nonzero, signal, timeout, capture clipping, policy/consent refusal
  and spawn failure remain data: later stages still run. Preceding retained
  stdout bytes flow in memory, or empty bytes when unavailable. The aggregate
  retains `stages`, conjunction `ok` and one-based `first_failure` or nil.
- `p:on_exit(fn)` has one replaceable slot before dispatch and refuses new
  registration after dispatch starts. It runs once on the Lua thread, after
  preceding fd lines and before wait/select/all observe completion. Each
  observer gets fresh result tables; mutation cannot alter Rust-owned output.
  `wall_ms` freezes at host processing of the Finished receipt, not the OS
  exit instant; no precise executor completion timestamp is claimed.
- All new asynchronous doors check synchronously before yielding. Callback
  and whole-chain-getter reentrancy closes the scope permanently even when
  Lua catches the error. Programmer validation errors remain recoverable.
  Scope teardown and terminal advisory/emit latches remain runner-owned.

## Parent verification and a refuted boundary

At local candidate `dab7017143d6a04d3eeac4739df7080d09a1e5ce`, independent
checks passed 42 lua_proc tests, 9 dispatcher units, executor tests and
package-only Clippy. All 16 new CLI tests failed against preserved pre-fix
binary SHA-256 `ab68d0b685d87f0ddbd19d85902bb2cd3a7ae8345b04a52b3137c8ba0ccd067f`.
These are targeted Linux results, not a forced gate or landing receipt.

Parent test review corrected false-positive negatives and invalid fixtures
before accepting evidence: trailing nil was not a sparse Lua list; callback
entry must be proven; acknowledged completion order cannot depend on sleeps;
captured READY lines cannot be omitted from expected output; a snapshot
mutator needs an actual file acknowledgement.

A further parent probe found that 1048577 newline-free bytes passed proc.run
but failed proc.chain with `proc-line-too-long`. Chain requested unused full
line streaming and therefore inherited its 1 MiB line bound. The parent
authorized a narrow completion-only managed seam in pushed ledger correction
`050f4fb21`. Actual proc.spawn line bounds and default capture must not change.
The preserved pre-repair candidate binary is SHA-256
`6e05156d5892b778bb8b8490e84a3546940301e6489eb8e49e60bd6c48eb40a9`.

Parent-added controls cover a newline-free NUL/non-UTF8 payload above the
line bound, default 8 MiB prefix clipping followed by a successful stage,
and caught exit-callback advisory/emit during an active chain with byte-exact
verdicts and acknowledged owned-group cleanup. Independent re-verification
passed 44 CLI tests, 9 dispatcher units and 32 executor tests. All 18 new
CLI cases fail against pre-composition; the long-capture case also fails
against the preserved pre-repair candidate and passes after repair. Exact
typed receipts and named-test logs are archived with the evidence.

`Scope::spawn_completion` uses the existing supervisor and real Finished
receipt, after fd draining and child reaping and before ordinary result
publication. It omits only unused line assembly/events. Public streaming
and silent legacy spawn keep their original modes, deadlines and bounds.
The forced integration/landing receipts are still pending; do not infer
them from targeted verification.

The first gate preflight refused raw diagnostic source-line references in
the evidence logs. Gzip packaging preserved those streams but a subsequent
gate correctly refused the tracked binaries. Raw diagnostic streams now
live as byte-exact plain text in the existing `plan/evidence/` area, separate
from prose audit citations, with SHA-256 hashes. Neither diagnostic rewrite,
citation waiver nor binary allowlist change was used.
The forced gate at `04b015eb06359ca37cabdf166883ff4f50e89228`
reached the workspace suite, ran2891 tests, and reported2 new reds,0 tolerated
and0 stale. The failed `lua_predicate_classes` target reproduced the same
external-target fixture assumption in its memo-input and observing-list
cases. Pushed ownership correction `25559544b` authorizes only their
repository-local fixture repair. The actual gate-failure receipt, diagnostic
stream and source identity are retained. This gate remains red until repaired
fixtures and a complete forced retry pass; the diagnostic archive is evidence
of the failure, not a substitute for a green gate.

Terra's bounded fixture repair reproduced20 passes and2 failures before,
then22 passes after; parent reviewed its unique repository-local tempfile
and tempdir lifetimes. The old memo cache-hit/stale-verdict, byte-order,
symlink-exclusion and outside-root assertions remain unchanged. Parent
independent22-test execution and the full-gate retry still decide readiness.

Parent independently passed the22-test target after the fixture repair. The
forced retry at `02562a619807576d275b7571298f89e6d5506868` passed strict Clippy
and all2891 workspace tests (0 new reds,0 tolerated,0 stale), then refused
the compressed diagnostic artifacts. This partial green is not a full gate.
The binary-packaging failure and its source identity are retained; the
plain-text-only candidate must complete a new forced gate before pushing.

The next forced gate at `7dfb53f511cfed85c304ddd989af9043137195a9` passed
workspace and evidence checks, then reproduced11/14 in the existing OOM
postmortem fixture. Its three journal reads also used the external target
link and were correctly refused as unreadable seams. Ownership correction
`612b16410` permits only a repository-local unique scratch directory for
that fixture. Parent independent typed controls measured11/14 before and
14/14 after; related OOM, unrelated victim, quiet journal, unreadable input,
actual memory refusal and wiring assertions all remain unchanged. No memory,
OOM, read-env-root, gate-step or landing policy was altered. Eight delegates
were already invoked; this mechanical integration correction stayed with
the parent rather than creating a ninth worker. Native execution of the
fixture-location correction and a complete forced retry remain unmeasured.

The complete forced gate at `46ff10f0ef721518750c242cd4b41c75a6ef1136`
then passed: actual run `0f15b0dc-d176-45c7-9150-9e06f19bbe4a` exited0,
ok=true,1007450ms including targeted preparation; phases totalled951s.
All2891 workspace tests passed with0 new-red/0 tolerated/0 stale. Only
plan fragments were subsequently merged; prepush check confirmed gate-fresh
and the startup boundary was preserved. First published source checkpoint
`09fc59740d047d5179488cb74131f6719ddf5451` is draft PR212, not READY.

Independent adjacent controls also found the if-not-pipeline fixture red
and pilot-lua-ports at4/5 because their scratch inputs traverse the same
external target link. Those controls are outside the default full gate;
its green is not all-litmus proof. Pushed ownership correction `288b37249`
permits only unique repository-local scratch for these two fixtures. Source
was not edited while gated. Parent measured the original failures, then
if-not at3/3 and pilot at5/5 after their data-location changes, retaining
all parser, byte-agreement,200k-writer, sandbox-env, stale-runner and
retirement checks. Builder-context re-verification and the final integrated
forced retry remain pending before READY/landing.

The production if-not decider itself separately emits ok for an unreadable
selected violating file. Its directly measured false-green receipt and
exact outside fixture are retained; `1547-ynn5` awaits contract review.
Moving the fixture does not repair that guard behavior or close its packet.

## Landing observer refutation and bounded test correction

The first serialized landing attempt gated merged candidate
`21eb9f88c5cf13cdc3d5f9de252c8c4473f099e5` at base `c78493e4a`, then evicted
PR212 on one existing callback-cleanup control: workspace2891/new-red1/
tolerated0/stale0. The queue wrapper exited0 because it completed its queue,
not because composition landed. PR212 returned to DRAFT, READY was withdrawn,
and no status closure or test ownership release followed. The queue deletes
its temporary full gate log; the full workspace transcript and retained PR
diagnostic tail were copied byte-for-byte before rerunning, not reconstructed.

Parent failure-only instrumentation kept the immediate-live assertion intact.
With8 concurrent Rust test processes,64 trials returned62 real exited0 and2
exited101. One failed first read observed an acknowledged grandchild in R,
then the same start identity in Z after3.955us. The other first read observed
Linux X (dead), then ENOENT after1.681us. Both original assertions still
FAILED; their exact diagnostics and test-binary hash are retained. A concurrent
44-test target passed. Independent Python sampling of256 actual cleanup runs
found0 immediate-live/0 live-at100ms/0 unexpected statuses; those negatives
alone did not reproduce or refute the landing red. The Python source is kept
byte-for-byte as `measure-callback-cleanup.py.source.txt` without a dependency,
source-injection or guard waiver. A measurement-script JSON parser initially
refused the builder's stdout banner; its failure is retained too.

The correction is confined to the Linux test observer: parse proc stat state
and start identity, recognize Z/X as not executing, and poll up to100ms for
the acknowledged killed identity to stop or disappear. Non-ENOENT read errors
now fail instead of counting as death. This does not claim a precise OS exit
instant or grandchild waitpid. Existing1.1s delayed-marker checks and their
long-deadline positive control stay unchanged. The new
`cleanup_observer_rejects_acknowledged_live_group_before_accepting_its_stop`
control starts a real acknowledged child+grandchild group held alive until
this fixture kills it; it must reject each live identity for the full bound,
then accept actual kill/direct-child-wait cleanup. Production supervisors,
groupkill, reap, callbacks, process APIs and policy are untouched.

The8-delegate cycle limit is exhausted, so the parent owns this mechanically
bounded integration correction rather than invoking a ninth agent. After-change
stress/known-live controls, targeted verification, full forced gate, preflight
and serialized target+candidate landing still decide readiness. Neither a
green retry nor queue execution success substitutes for remote ancestry.

After the observer correction, the same64-trial/8-process stress returned64
real exited0,0 exited101 and0 absent/other statuses. The independently executed
known-live control passed1/1, checking live child and grandchild rejection
before kill and stopped-identity acceptance after actual cleanup. All64 before
and64 after typed receipts and the after binary hash are retained separately;
no failing stream was overwritten. This is observer conformance evidence,
not a substitute for the forced integrated/landing gates still pending.

The corrected source then passed the complete parent forced gate at
`402dbd1e7d7b77eb827ee2aa97bcc2ee1023457a`: actual run
`a0b6a642-95e9-4994-a6f8-87ce4e3ebbef` exited0/ok=true,1079307ms including
targeted preparation; phases1007s, workspace2892/new-red0/tolerated0/stale0.
The45-test CLI target and all previous targeted controls passed. Only a plan
fragment was subsequently merged; source checkpoint
`a992d8e08e53df189a5d521d6276f290d6d8552e` was pushed and remote-verified.
Fresh required preflight actual `f48e5611-254a-46bb-b649-5404a54ed7ad` exited0
in57924ms, explicitly PARTIAL:ran207/declared-skip8/deadline-skip9/
could-not-run0/refused0/sum224/session-isolation/wall54s. It does not vouch
for the9 deadline-skipped guards. READY was renewed for this corrected source;
actual serialized landing and remote ancestry still decide closure.

## Parent launcher timeout: absent result, owned recovery

The next landing launcher was accidentally given a120000ms harness timeout,
despite the run door's explicit5400000ms bound. The harness stopped its
launcher at two minutes and left an EMPTY status file, not a typed gate
result. The queue and toolbox gate survived in owned process groups1530562
and1532937, UID1000, this exact checkout. Candidate
`190c952fa16aaf5c57e82f7dbff983ad08b4b3cc` was still unlanded at base1eefbeb19.
Parent froze the queue before killing only those verified owned groups,
retained the partial gate stream/source/process snapshot/empty status, and
verified no named owners or cargo/rustc/plan binaries remained. The clean
tree returned normally to linux-next, without resetting/restoring user files;
the unrelated old Claude watcher was untouched. The checkout lock read free
after cleanup and was reacquired on the same harnessPID6538; this alone does
not establish a lock defect.

This absence is parent launcher misuse and measurable overhead, not a
production queue/runtime defect or a completed red/green gate. The partial
stream stops during source-agreement compilation. No code, gate or landing
policy repair followed. The next retry uses background harness timeout0 and
the door's explicit90-minute bound, after confirming no survivor. Wrapper
success is not landing evidence: its post-queue check must prove actual
candidate ancestry on origin/linux-next. Native, tracing and parent obligations
remain open until their separate receipts exist.

## Bounded landing and closure

PR212 landed on linux-next as `f4f106c73400197364f1a6e17723bbdd439d3e99`
on2026-10-03T20:32:39Z. The serialized queue read base14a5db889 and exact
published head `10d2890ed708e144cd7aa194425338246bedd1ea`, forced tier=full,
reported gate=green and landed1/evicted0/requeued0/skipped0. Actual typed
run `552a1054-eb79-43ee-833f-0172ba659164` exited0/ok=true in1073429ms;
the launching wrapper itself fetched trunk and verified candidate ancestry.
Parent independently fetched origin, rechecked that exact ancestry and PR's
MERGED state, then fast-forwarded its primary linux-next checkout. The current
plan binary's content guard and startup worktree boundary both passed.

This closes only1538's managed composition and preserved Linux streaming/
lifetime conformance. Test ownership is released so the Mac observer packet
1543-f44v can take the old outer Unix test, and native composition children
1543-ffhg/1544-cnae can claim their disjoint native files after pulling this
source. Native green, whole1539 trace, parent1384 closure, composite OpenSpec
4.2, capture-contract reconciliation, preflight1520, and1547's unreadable-scan
contract correction are NOT established by this landing. The complete queue
gate's temporary log is removed by the queue; its genuine summary/typed
receipt and complete workspace transcript are retained, not an invented full
log. All prior raw diagnostics/negative controls remain byte-exact evidence.

Broader plan-library verification initially passed425 tests and failed two
legacy read/memo fixtures because they wrote under the worktree's `target`
symlink, outside its repository root. The filesystem refusal was correct.
Those fixtures now use automatically cleaned repository-local temporary
inputs, preserving their memo/read-log assertions and containment. No cache
link, production filesystem rule or sandbox bypass was changed. The aborted
pre-gate receipt and failure log are retained; verification must pass before
the forced gate starts.

## Remaining boundaries

Native Mac/Windows measurements are not supplied by Linux runs. The CLI
managed-script module is Linux-gated; reporting its zero selected tests on a
native host is not conformance evidence. Unix dispatcher units also need
native verification; their utility names now resolve through PATH instead
of assuming the Linux `/bin/true` layout. Dedicated disjoint native packets
1543-ffhg (Mac) and1544-cnae (Windows) depend on composition landing.

The Mac peer is active on1375-amye and1519-6rcp. Its native Rust1.96 Clippy
report on trunk050f4fb21 identified a nonminimal whitelist expression in
lua_predicate.rs. The owning Linux checkpoint applies equivalent De Morgan
simplification; native re-verification of that repair remains the Mac's work.
This report is not a native composition green.

Trace coverage, parent contract reconciliation, native obligations and
dependent preflight1520 stay open. No composite OpenSpec task is closed by
this child alone.
