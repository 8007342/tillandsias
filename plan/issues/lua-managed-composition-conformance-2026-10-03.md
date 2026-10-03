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
