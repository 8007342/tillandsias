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
