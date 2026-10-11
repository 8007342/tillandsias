# Runtime testing performance: research handoff

Date: 2026-10-11. Operator-requested research on Macuahuitl.
Branch: `research/litmus-lua-performance-20261011`.
Audit source frame: `cdba630cee433fa52366d29b3d5888a5d6177825`.
Integration refresh before handoff: `f07e77e19`. Audit claims below retain their
original `cdba630ce` frame; the profiled gate used `323098bc6`.
Disposition: proposals for coordinator review; no production gate changes.

## Recommendation

Build **one Rust-owned immutable source snapshot, exact search index and typed
relation store per gate**, and let small Lua predicates query it in batches.
Stop repeatedly enumerating, opening, parsing and searching the same files for
each assertion. Preserve behavior tests and real mutation controls. Measure
compilation, fixture setup and nested gates independently: optimizing text
search alone cannot deliver a whole-gate 10x improvement when rebuilding
artifacts dominates.

Four parallel research agents audited test inventories, Lua/index/runtime
implementation, gate costs, and fleet infrastructure. This harness exposes
`general` agents but no model-selection argument; Astra/Sol worker models
could not be selected or verified. The primary integrated their reports.

## Research artifacts

| Report | Evidence and scope |
| --- | --- |
| [Scan inventory](research-litmus-scan-inventory-2026-10-11.md) | Reproducible exhaustive lexical census of 1,269 tracked test/check/Lua/litmus files; individual hot algorithms, gate registrations, policy/evasion review; nine bounded timing runs. |
| [Lua and index runtime](research-lua-index-runtime-2026-10-11.md) | Rust/Lua execution and provenance, existing reusable primitives, cache-identity gaps, Rust test repetition, snapshot/index/batch design and correctness matrix. |
| [Gate costs](research-gate-costs-2026-10-11.md) | Dispatch reachability, source invalidation, duplicate test executions, real nested gates, private cold builds, proposed metrics and safe rollout. |
| [Fleet infrastructure](research-fleet-runtime-infra-2026-10-11.md) | Current login/mirror/GPU/Nix/sccache implementation and folded plan statuses, live prerequisites, remaining scans outside the core test scope. |

The census is exhaustive for its declared tracked scope, **not exhaustive
semantic review of every file**, nor dynamic proof of every transitive runtime
cost. Each report names its gaps and evidence frame. Local expert capability
probes reported source/binary skew and degraded state; source findings were
verified through repository reads, rather than inferred from binary existence.

## Highest-confidence waste and first cuts

1. `scripts/lua/check-litmus-bindings.lua`, `file_named`: a name lookup rereads
   the litmus corpus per requested name. Build a parsed name map and binding
   adjacency relation once. Batch extractability using the actual runner parser.
2. `scripts/check-added-test-is-referenced.sh`, standing registration count,
   and `scripts/lua/audit-guard-activation.lua`, `find_invoker`: search the same
   registration surfaces per test/guard. One multi-pattern pass supplies all
   matches. Preserve current literal semantics before strengthening them.
3. `scripts/check-litmus-dead-inputs.sh`: 519 awk launches to discover 25
   annotated tests; 92 globs scan the tracked path population. Parse metadata
   once and match a shared path manifest with compatible glob semantics.
4. `scripts/lua/check-shell-ratchet.lua`, `history`, `at`, `check_descends`: historical
   floors can require 99 separate `git show` launches. Batch unique blob reads
   with `git cat-file --batch`; retain the all-history ratchet obligation.
5. `crates/tillandsias-plan/tests/lua_source_agreements.rs`,
   `explicit_manifest_cases_match_their_expected_guard_verdicts`: nine full
   evaluator runs where one captured outcome map suffices for the assertions.
   Keep independent expected-value parsing and production CLI controls.
6. `build.sh`: the production Lua integration is dispatched three times and
   land-queue fixtures twice on the successful full-check path. Coalesce only
   demonstrably identical instrument/input/regime/coverage; retain named IDs.
7. `_touch_gating_checkout` forces tracked-input recompilation to stop another
   worktree's compiled code producing a false green. Replace with independently
   tested content-qualified artifact ownership; do not remove the mitigation
   just to improve a timer.
8. Mutation fixtures perform private cold release builds or reenter actual
   gates. Separate pure decision tests from a small real front-door contract
   suite; use isolated mutable fixtures and reusable dependency artifacts.

## Measurement evidence

Safe static guards, same session, three runs each, all exit 0:

| Guard | Median | Initial target for equivalent indexed evaluation |
| --- | ---: | ---: |
| Dead inputs | 2,243.338 ms | <=224.334 ms |
| Line windows | 707.239 ms | <=70.724 ms |
| Steps can fail | 185.427 ms | <=18.543 ms |

These are baselines and proposed targets, **not demonstrated speedups**.
Compare matched cold, shared-index warm and verdict-memo regimes; include
snapshot validation, index preparation and reporting in end-to-end totals.
Collect child execution counts, file opens/bytes, parser/VM creations, compile
units and lock wait. Existing phase/step JSONL should gain run/span/parent
identity, monotonic timing, failure/cleanup outcomes and telemetry health.
Do not add another shell loop that scans the whole tree to collect each metric.

### Primary gate attempts

Command: `TILLANDSIAS_GATE_PROFILE=1 /usr/bin/time -v ./build.sh --check`.

- Attempt 1: 16.34 s, exit 1, before normal test execution. Toolbox dispatch
  could not resolve a `script run` binary. The guard honestly printed
  `could-not-run:lua-decider:check-unique-bin-names.lua:no-script-runner`, but
  the build's generic error then claimed duplicate bin names. That is a
  diagnostic-classification problem, not evidence of duplicate bins.
- Built the required runner inside the existing builder:
  `toolbox run --container tillandsias-builder cargo build --release -p tillandsias-plan`.
  Cargo reported 1m01s. This is prerequisite preparation, not a test baseline.
- Attempt 2: 4.91 s, exit 1 at the citation convention guard. Research reports
  initially used moving source-line citations. Workers changed general claims
  to stable symbols and explicitly justified pinned audit spans. Scoped citation
  guards passed. This is a research-document correction, not a bypass.
- Attempt 3, refreshed base `323098bc67510215c71165433caeb4b8de5f1609`:
  the tool's 1,200,000 ms deadline terminated the gate before completion.
  Last banner: litmus selection parity with/without jq/yq. The dispatcher
  printed that it was propagating termination to its marked process tree.
  Post-run status contained only the pre-existing `opencode.json` edit and
  the five research documents; no tracked production mutation remained.
  A targeted process listing found no surviving gate/selection runner from
  this checkout. Another agent's gate in `/home/tlatoani/claudia/tillandsias`
  was running on the same host at inspection, so this is **not a quiescent-host
  benchmark**; no processes belonging to that agent were stopped.
- Attempt 4 after the final integration refresh: `./build.sh --check`,
  bounded to 120 s as a pre-push recheck, was also deadline-incomplete.
  Formatting, fast refusals, both strict clippy regimes and ledger integrity
  passed before termination during the fleet-activity fixture. The two clippy
  commands reported 3.84 s and 4.82 s. This deliberately bounded recheck is
  **not** a second 20-minute benchmark or a full validation pass.

Research-only persistence uses the repository's existing issue-capture hook
lane, which validates outgoing prose without requiring a full-build stamp.
The actual hook result is reported by the primary after pushing; no stamp or
full-gate success was manufactured for this branch.

The captured transcript contains 107 Cargo test-summary lines, totaling 3,922
passing executions and zero failed executions. Those are **execution counts,
not unique tests**, and do not cover unfinished fixtures. Compiler messages
reported 17.80 s and 13.05 s for dev-profile invocations, then 40.75 s,
41.63 s, 19.75 s and 0.12 s for test-profile invocations. They are individual
Cargo elapsed messages, not summed exclusive root phase timings. The transcript
has no final phase table or gate success stamp from this invocation.

Raw relevant existing JSONL records (paths/identities abbreviated only in this
presentation; durations and exits unchanged):

```json
{"ts":"2026-10-11T20:27:13Z","step":"build-preamble","phase":"check","duration_ms":141,"exit":0}
{"ts":"2026-10-11T20:35:47Z","step":"archiver-check-miss","phase":"check","duration_ms":69677,"exit":0}
{"ts":"2026-10-11T20:36:42Z","step":"terminology-check-miss","phase":"check","duration_ms":110,"exit":0}
```

These supply a fresh **69.677 s archiver-check miss** versus **110 ms
terminology-check miss**: do not optimize terminology based on its historical
14–33 s comments. The log still has no terminal `build-check` record for the
deadline-killed third invocation when inspected. It also contains synthetic
fixture litmus passes/fails, so an unqualified sum of matching records would
misattribute fixture work as live gate evidence. Run/span IDs, terminal records
on timeout, and fixture-to-root joins are concrete instrumentation needs.

The external time wrapper observes toolbox dispatch, not all child CPU/RSS;
wall time is usable but its CPU and RSS fields must not be presented as the
whole container workload. No complete full-gate baseline is claimed here.

## Architecture proposal and implementation sequence

1. **Counters and identities.** Complete the behavioral-input manifest for
   cache/build freshness (including fold code, dependencies and Lua policies).
   Diagnose setup/compile/execute/cleanup and nested costs using existing seams.
2. **Rust snapshot and exact index.** Enumerate each scoped population once;
   retain bytes, line offsets, parsed metadata, literal/regex candidate postings
   and structural relationships. A token-only full-text index cannot reproduce
   arbitrary substrings/regexes: verify candidates against exact bytes, and
   perform one bounded shared scan for patterns without a safe indexed filter.
3. **Typed relations.** Names/bindings/requirements/order declarations, scoped
   Rust items/calls and shell command/effect facts replace comment-satisfiable
   checkbox checks. Macros/cfg/dynamic dataflow remain explicit unknowns where
   the parser cannot establish the requested property.
4. **Batch Lua execution.** Reuse Rust data and compiled worker-local functions,
   but isolate environments, verdict/output/read logs and cancellation per
   check. Refactor CLI process-exit and global read-root ownership first.
5. **Pilot and differential verification.** Convert binding/reference/metadata
   families first. Compare every verdict, count and diagnostic to direct scans
   on immutable snapshots and meaningful planted defects. Then broaden.
6. **Build/fixture acceleration.** Prove worktree artifact ownership; deduplicate
   identical dispatch; evaluate signed Nix outputs and compiler/dependency
   caches for private mutation builds, with independent red/restored-green
   evidence. Avoid a fleet-shared mutable Cargo target directory.

Key validity inputs include dirty/untracked bytes, membership/deletes/renames,
modes/symlinks, canonical worktree, frozen base, checker/parser/binary identity,
Lua bundle/override, feature/toolchain/env and negative dependencies. Cache
errors, clipping, empty selections, malformed data or unknown freshness cannot
become a passing empty population. Live process/host observations execute fresh.

Acceptance: **>=10x end-to-end reduction for the selected static subsystem**,
zero seeded defects missed, no wrong-worktree/stale-input pass, and measured
cold/warm memory/CPU costs. Whole-gate >=10x remains the operator goal; profile
and remove compile/fixture amplification as well before claiming it achieved.

## Provenance and policy findings

Vendored Lua's interpreter is compiled, but normal gate Lua sources currently
load from the checkout at runtime. An artifact-bound shipped policy bundle and
explicit development override identities improve tamper detection. Compilation
alone authenticates neither authorship nor honest execution: authorized builders,
signed content-bound artifacts and independently trusted expected identities
remain necessary. Do not relax text-only loads or accept arbitrary Lua bytecode
in the name of speed.

The no-Python checker is already Rust-backed; optimize its repeated dispatch
and actual policy scan, rather than rebuilding a filename-only substitute.
Base64 guard inspection found fail-open error paths and a same-file heuristic,
plus a guest fixture that encodes visible scripts and decodes/executes them.
The scan report names the exact transport for policy disposition. Legitimate
encoded credentials/OTP data are separate from encoded executable payloads.
Indexed execution/dataflow facts need positive, negative and error controls;
do not silently change policy during a performance port.

## Fleet readiness and coordinator follow-up

- Cloudflare OAuth implementation is ledger-completed. The default client ID
  is a placeholder; registered OAuth/Mesh/Worker setup is a live prerequisite,
  not evidence supplied by fake-server gates.
- Macuahuitl GPU capability is recorded, but this audit did not measure live
  GPU/model residency or fleet inference. Use models for research/retrieval,
  not deterministic gate verdicts or probabilistic skipping.
- Reuse immutable local index publication and mirror ref durability; frame
  fleet indexes by exact ref/commit/content and authenticated publisher.
- Per-host signed Nix caching exists; fleet builders/shared cache remain open.
  The current Nix wrapper refuses transparent full `build.sh` execution despite
  an older design's integration claim. Reconcile before promising acceleration.
- Existing shared-expert, fleet-mirror, builder/cache and sccache packets are
  enumerated with dependencies in the fleet report; avoid duplicate initiatives.
- Latest integration refresh adds `1614-5x7m`, a Darwin front-door budget defect:
  another current performance symptom to include in cross-platform acceptance.
- The later pre-push refresh also includes more runtime manifest-dir cleanup,
  including subject-root discovery in `lua_source_agreements.rs`. That repairs
  the root-location issue named by the audit; the nine-evaluation duplication
  remains an independent finding at the original frame.

Coordinator: review this branch later for a PR into `linux-next`; allocate
bounded implementation packets from the sequence above, keeping measurements
and exact coverage attached. The operator asked for research and proposals;
these reports do not declare their proposed runtime implemented or approved.
