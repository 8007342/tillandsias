> Research snapshot (Codex, branch research/litmus-lua-performance-20261011, frame cdba630ce). Kept verbatim for provenance. Its claims were re-verified against trunk ed7a73185 and the measured 2026-10-11 gate in plan/issues/gate-performance-research-distillation-2026-10-11.md (order 1604-fsxu), which is the current verdict; where the two disagree, the distillation stands.

# Research: build and test gate costs, 2026-10-11

Status: research/proposal only; no production changes authorized by this report.
Evidence frame: `cdba630cee433fa52366d29b3d5888a5d6177825`, branch
`research/litmus-lua-performance-20261011`. Source citations below deliberately
include snapshot line numbers plus symbols so the primary researcher can locate
the exact dispatch in this revision. Re-verify symbols after source movement.

## Executive findings

1. Measure **whole invocation, compilation, execution, fixture setup, and nested
   invocations separately**. Existing telemetry is useful but cannot currently
   establish a current cold/warm baseline or reconstruct parent/child costs.
2. The forced check gate includes workspace tests, a serial tray/listen-vsock
   pass, and 161 data-wired steps, in addition to inline deciders. Older comments
   describing only plan-library tests are historical, not the executable scope.
3. The tracked-file touch protects against demonstrated cross-checkout Cargo
   false freshness, but deliberately invalidates warm workspace artifacts.
   Removing it without an independently proven replacement risks false passes.
4. The Lua source-agreement production test is executed three times on a full
   successful check path: dedicated integration target, workspace target, exact
   filtered integration target. This is precise duplicate-work evidence, not yet
   a measured wall-time ranking.
5. The release-gates litmus launches a fixture with several **real nested gate
   invocations**, including `--check --install`. The capability-manifest litmus
   copies large source trees and cold-builds a private release artifact before
   restoring its compile-time mutation and rebuilding. These are high-priority
   candidates for tracing, isolation, and cache-safe reuse.
6. No exponential runtime growth has been established. Nested calls and repeated
   work are real; a recursive cycle or an exponential recurrence needs measured
   parent/child evidence rather than inference from filenames.

## Scope and measurement honesty

- Read through project-info MCP first. Its broad searches cap results at 50;
  filesystem searches also capped at 100. **Fallback reason: unavailable** for
  the complete inventory; bounded `rg` searches then enumerated all literal
  gate-step bindings and compilation/copy/clone sites. MCP covered file reads.
- Counted 161 `STEP_SCRIPT`/`STEP_LUA` bindings across the complete data roster.
  The runner loads that roster dynamically; literal callsite inventory does not
  prove that every transitive command of every fixture has been executed.
- Ran no full gate, compiler experiment, mutation fixture, installation, or host
  reset. The primary researcher owns the full timing run. Research introduced
  only this report; pre-existing `opencode.json` dirt was observed.
- Existing `.cache/metrics/tillandsias-timing.jsonl` has **six records**, dated
  September 6–7: preamble 13,606 ms; failed `build-check` 225,817 ms; staging
  span 67 ms; trace span 617 ms; musl installation build 87,676 ms; portable
  launcher validation span 5,101 ms. Different host labels appear in these
  records. They are historical, mixed-dispatch evidence, not today's baseline.
- The discovered metrics directory exposes no litmus-step timing log. No current
  per-test timing distribution or current full-gate result was established here.
  Source comments' timings below are explicitly attributed historical reports.

## Executable reachability and scheduling

| Surface | Reachability and scheduling at the evidence frame |
| --- | --- |
| Check preamble | Wrappers/common setup, tracked-file touch, infrastructure/tool setup and sidecar staging precede check memo lookup. A memo hit can still pay setup cost. `build.sh` `_touch_gating_checkout` at 994–1001; `_stage_router_sidecar_if_compiling` at 1763–1780; memo at 2649–2732. | <!-- cite-ok: snapshot audit needs exact dispatch locations; symbols retained -->
| Forced/full check | Formatting and fast refusals precede strict default and listen-vsock clippy; then `cargo run` ledger validation; workspace and feature tests; inline guards; data-step loop; final stamp. `build.sh` check dispatch at 2606; clippy/ledger at 3037–3051; tests at 3894, 3966, 4038; data loop at 5247; final stamp/report at 5840–5849. | <!-- cite-ok: snapshot audit needs exact gate reachability -->
| Data-wired steps | `_run_gate_steps` loops serially over every `.step` glob, sources data, requires exactly one existing script/Lua runner, streams and captures output, checks metrics pollution, and handles explicitly nominated could-not-run codes. It does not apply the inline change-class selector inside this loop. `build.sh` at 1934–2050. | <!-- cite-ok: snapshot audit locates complete dynamic dispatch seam -->
| Preflight | Separate roster derived from fast refusals, data steps, hooks, inline Bash and Lua deciders. Bounded concurrent launcher with explicit serial declarations; default deadlines may yield named skips. It is not a full-audit pass. `_preflight_roster`, `_pf_predecide`, `_pf_launcher`, `_pf_run_guard` in `build.sh` at 411–659. | <!-- cite-ok: snapshot audit locates preflight scheduling machinery -->
| Pre-push | Installed `.git/hooks/pre-push` captures stdin once and serially invokes five fail-fast wrappers. Local gate rechecks preflight/deciders and verifies stamp, with explicit plan/issue lanes and warning/degraded lanes. It does not normally run the full build gate itself. Local-gate `gate-stamp.sh verify` call is at `scripts/hooks/pre-push-local-gate.sh:1856`; release preflight at 347. | <!-- cite-ok: snapshot audit distinguishes actual hook dispatch from instructions -->
| Test-only | `build.sh` at 2564 runs workspace `--no-fail-fast`, and 2590 runs the tray/listen-vsock pass. Combining flags can execute multiple dispatch blocks; measure dispatch identity, not just script name. | <!-- cite-ok: snapshot audit identifies separate test dispatch -->
| Local CI/release | `scripts/local-ci.sh` separately runs fmt, clippy default/all-features, workspace **library** tests, serial tray/listen-vsock bin tests, platform/signal tests, and litmus phases. Sites at 1206, 1224, 1244, 1312, 1353, 1382, 1394, 1970–2106. This is a different matrix from `--check`; larger feature sets do not necessarily subsume default-only tests. | <!-- cite-ok: snapshot audit needs exact independent matrix dispatches -->
| Litmus | `run-litmus-test.sh` runs specs serially at 3288–3297, tests serially through `run_tests_for_spec`, and each file's steps serially. Selection checks phase, retired status, host, size and declared diff inputs before execution at 2418–2508. Rust-query prechecks may call `cargo run` at 1506 if no runnable helper resolves. | <!-- cite-ok: snapshot audit locates scheduling and compilation fallback -->

Preflight concurrency is not a safe template for parallelizing the full gate.
Many fixtures mutate shared files, binaries, stamp state, environment, fixed
runtime paths, or metrics. Cargo compilation jobs, libtest threads, and shell
fixture jobs are three separate concurrency dimensions.

## Candidate costs and correctness constraints

The order below is an investigation priority, **not a measured current ranking**.

| Candidate | Mechanism, precise evidence, and next measurement |
| --- | --- |
| P0: cross-checkout freshness versus warm rebuild | `_touch_gating_checkout`, `build.sh:994–1001`, touches all tracked files on gating dispatches before memo lookup. Comments at 973–989 report wrong-checkout code executing with a shared target and older mtimes; reported yoga cost is +59 s for repeat gates and +10–18 s atop an approximately 180 s checkout switch. Measure dirty-unit count and reasons, not touch syscall duration alone. A content memo may hit after the touch, but a later Cargo invocation can still see those files as changed. | <!-- cite-ok: pinned audit of new correctness mitigation and its exact execution site -->
| P0: real nested gates in release litmus | `openspec/litmus-tests/litmus-release-gates-run-locally.yaml:212` invokes `test-gate-stamp-memoization.sh` (pre-build, quick). Fixture sites 370, 385, 403, 427 start memo, forced 90 s, combined install 40 s, and bad-format 300 s children. Fixture snapshots the real git-dir gate state at 243–300 and patches a real tracked Rust victim at 426. These are ceilings, not measured durations; child may exit early. Trace cleanup, source restoration, lock wait and child dispatches. A nested `--check` does not by itself imply another release litmus: their dispatch paths differ. | <!-- cite-ok: snapshot audit establishes actual parent/child edges and bounds -->
| P0: private cold release mutation build | `scripts/test-capability-manifest-guard.sh:15–21,53` copies manifests, all crates/assets/images, then builds a mutated plan release binary in fresh `$WORK/target`, restores manifest and builds again. Bound by `litmus-capability-manifest-guard.yaml` pre-build/quick, step at 58, timeout 300,000 ms. Every invocation discards the private target; warm production target does not warm it. Separate copy bytes, dependency compilation, mutated compilation, clean restoration build and assertions. Root release profile uses LTO and one codegen unit (`Cargo.toml` profile.release). | <!-- cite-ok: snapshot audit of expensive isolated mutation-build path -->
| P1: repeated production Lua integration | `build.sh:3894–3895` runs all `lua_source_agreements`; workspace at 3966 includes it again; 5124–5125 selects `production_script_run_preserves_pinned_exit_stdout_and_stderr_bytes` again. `crates/tillandsias-plan/tests/lua_source_agreements.rs:348–391` launches the production CLI once per manifest case and asserts exit/stdout/stderr bytes. Earlier `explicit_manifest_cases_match_their_expected_guard_verdicts` at 158–197 also recomputes all outcomes inside an eight-case loop. Measure per-case launch/evaluation and invocation multiplicity. Any future coalescing must preserve the uncached production-run contract, negative controls and nonempty coverage, with ledger approval before changing mandated dispatch. | <!-- cite-ok: snapshot audit establishes repeated execution and production-harness integration -->
| P1: live-ledger scaling | `fragments.rs` `compaction_on_the_real_ledger_preserves_every_comment_and_item` at 4754–4790 copies the live base/fragments, compacts and verifies preserved text and fold equivalence. Reachable in workspace tests. The old 117 s comment in `build.sh` is superseded by `Cargo.toml:131–145`: opt-level 2 plus an algorithm fix reportedly moved the live test to 15.5 s on one host. Measure current fragment count, base bytes, copy/fold/render/equivalence durations. Do not propose the already-fixed per-fragment refold as a new discovery. | <!-- cite-ok: pinned audit contrasts historical attribution with existing implementation optimization -->
| P1: feature matrix and serial execution | Default/all-targets clippy at `build.sh:3038`, listen-vsock clippy at 3042, workspace tests at 3966, serial tray/listen-vsock tests at 4038. Clippy and linked tests are different compiler work; feature variants need separate correctness coverage. Source reports cached feature compilation at 0.16 s and serial execution 46.1 s in September, but today's touch policy changes that assumption. Keep default-only tests and feature-only tests; instrument compile and execution separately before any concurrency experiment. | <!-- cite-ok: snapshot audit locates distinct mandatory matrices -->
| P1: data-step release re-entry | `scripts/gate-steps.d/375-1201-hsf9.step` binds `test-a-claim-names-a-workstation.sh`; script at 149 runs a filtered **release-profile** Cargo test. This is an extra profile/target build after the ordinary test-profile suite, even for one assertion. Measure units/link cost and selected/executed count. | <!-- cite-ok: exact data-step-to-Cargo edge in snapshot -->
| P1: helper compilation hidden in steps | Data step 155 binds `check-no-python-scripts.sh`, whose line 8 always issues `cargo build -p tillandsias-policy`. Data step 590 binds `test-litmus-self-match.sh`, whose line 41 builds the release helper if absent. Data step 417 binds `test-set-field-refuses-unknown-flags.sh`, whose 178/190 release rebuilds occur only when `TILLANDSIAS_SET_FIELD_MUTANT=1`. Record requested compile versus actual dirty units; do not charge an opt-in mutation to every gate. | <!-- cite-ok: snapshot audit separates unconditional, cold-only and opt-in compilation -->
| P2: source-mutation rebuild/restoration | Pre-build litmus `litmus-ssh-lane-refuses-when-unwired.yaml` invokes the SSH fixture at 24. `test-ssh-lane-refuses-when-unwired.sh:40,49–82` runs filtered tests, edits the real headless source, runs mutated tests, then restores source. Despite its description of a copy, compilation occurs against the real checkout. Next consumers can pay another rebuild; concurrent consumers can observe a mutant. Isolate before parallelizing, and distinguish expected semantic failure from an unrelated compilation failure. | <!-- cite-ok: snapshot audit locates real mutation and downstream invalidation -->
| P2: repeated Cargo startup and clones | Litmus fixtures `test-forge-config-trust-cross-platform-parity.sh:70–73` issue four filtered Cargo tests; `test-concurrent-forge-shared-stack.sh:44,122,215` builds/tests the headless target. Data step 286's `test-land-queue.sh:249,558,590` clones scratch remotes. `test-pending-capability-row-does-not-wedge.sh:84–87` hardlinks large plan/scripts trees with full-copy fallback. These are not automatically full production-repository clones. Count bytes/files/objects and target provenance before optimizing setup. Never mutate hardlinked existing files in place. | <!-- cite-ok: snapshot audit records repeated launch and setup candidates without asserting unmeasured size -->

The ten-round Cargo stress loop in `test-headless-env-lock-is-single.sh` exists,
but this audit found no literal binding in build.sh/data steps or a litmus command
for it. Do not list it as a proven mandatory-gate cost without another caller.
The nested forced gate in `test-gate-fast-refusals.sh` is data-step reachable
(175), but its behavioral arm at 133–155 is opt-in via
`TILLANDSIAS_GATE_FAST_REFUSAL_E2E=1`, not the default cost. <!-- cite-ok: exact snapshot separates possible re-entry from default reachability -->

## Existing telemetry: retain and extend, not replace blindly

- `build.sh` `_step`, `_run`, `_phase_close`, `_phase_report`,
  `_phase_emit_timing`: measured command work versus banner-to-banner span,
  gap reporting, slow threshold/profile output, batch emission. `_run` starts
  its timer after `_require_host_build_tools`; command work can therefore exclude
  setup that the phase span includes. Piped `_run` calls execute in subshells,
  losing parent phase accumulators and falling back to span attribution.
- Check EXIT trap emits whole check verdict, but phase flush/report normally
  occurs at successful completion. A refusal can lose accumulated fine-grained
  attribution; phase records use exit 0 by definition, not guard verdict.
  Preamble starts after initial wrapper/common/change-class setup, and the
  `build-check` timer starts after the preamble. Neither alone is total entry cost.
- `scripts/timing-log.sh` provides best-effort JSONL emission and clock resolution;
  durations are based on epoch time, not a monotonic span clock. Build's `_now_ms`
  has a coarser macOS fallback than the shared helper. Mark resolution and clock.
- `scripts/run-litmus-test.sh` `_lt_step_record` records test/step/budget/duration/
  exit at 109–121, called at 2096; per-test timings are batched; suite timing starts
  after discovery/setup at 3282–3285. Step timing is not total test cost. <!-- cite-ok: snapshot audit locates existing timing granularity and suite boundary -->
- `scripts/local-ci.sh` has phase and individual-check timing, including failed
  rerun reproduction. Fixed `/tmp/*-check.log` paths can be overwritten by other
  runs; join logs by unique run identity rather than filename or timestamp alone.
- **No-tests correctness edge:** human summary explicitly says
  NO-TESTS-EXECUTED, but `print_json_summary` still sets status PASS solely when
  failed==0 (`run-litmus-test.sh:2793–2794`). Consumers must check executed count; <!-- cite-ok: snapshot audit pins structured-versus-human summary discrepancy -->
  cached/skipped/advisory/could-not-run cannot become executed-pass evidence. <!-- cite-ok: snapshot audit pins structured-versus-human summary discrepancy -->

## Proposed metrics contract

Add a versioned side-channel alongside existing JSONL so existing consumers do
not silently reinterpret rows. Keep telemetry best-effort and preserve original
stdout/stderr/exit/signal. A missing record is unknown, never a zero duration or
proof that a check passed. Reject truncated/corrupt joins in analysis.

Each record should contain:

| Group | Required fields |
| --- | --- |
| Identity | `schema_version`, `run_id`, `span_id`, `parent_span_id`, `root_run_id`, `sequence`, stable `gate_id`/step-file ID/test full name, runner version |
| Evidence | source commit, tracked+untracked source/content manifest digest, executable mode/symlink identity, frozen diff-base SHA, canonical checkout root ID, effective target root ID, instrument/dependency digest |
| Regime | OS/arch/host ID, runtime/container lane, CPU/memory limits, effective Cargo jobs, libtest threads, shell jobs, toolchain versions, profile, target triple, features, lockfile/config/build-env digest, artifact provenance |
| Span | UTC start/end for joins; monotonic start/end/duration for elapsed time; clock resolution; phase kind (`setup`, `digest`, `lock_wait`, `compile`, `link`, `execute`, `restore`, `cleanup`); inclusive and exclusive duration |
| Verdict | original exit/signal, semantic verdict (`pass`, `fail`, `expected_mutant_failure`, `cached_pass`, `skip`, `advisory`, `could_not_run`, `timeout`, `incomplete`), selected/executed/failed/ignored counts, assertion-set digest |
| Work | compiler units dirty/fresh and fingerprint reason, artifact digest, Cargo launch count, child-gate count/max depth, files and bytes copied/hashed, Git objects/clone bytes, live ledger base bytes/fragment count |
| Cache | hit/miss/disabled with reason; cache key/version; producing run ID; validity horizon; full/scoped coverage and full-audit anchor; mutation ID plus expected failure identity; restoration digest |

Capture an invocation span **before** wrappers/re-exec and preserve run identity
across them. Use one span per Cargo invocation, then parse Cargo machine-readable
compiler artifacts/fresh flags where supported. Separate compilation/execution
in controlled experiments using `cargo test --no-run` then exact executable
invocation with the same environment; do not change the production harness merely
to obtain timings. Stable libtest transcripts do not supply every test duration;
do not rely on unsupported/nightly output. Dedicated harness timing or controlled
filtered runs can measure expensive tests without claiming suite-wide attribution.

Report inclusive root cost once, exclusive phase costs once; never sum parent
and child durations as if independent. Explain gaps. Record all refusals and
cleanup failures. Track telemetry overhead and dropped record count separately.

## Cache-safe optimization proposals

1. **Instrument first.** Add run/span identity, per-step outcomes on failure,
   Cargo lock/fingerprint attribution and setup/mutation/restoration spans.
   Surface telemetry health without making metrics failure a test verdict.
2. **Correct target ownership.** Evaluate checkout-isolated target roots or
   provenance-validated workspace artifacts with a globally coordinated writer
   protocol. Include bare Cargo users, not only build.sh markers. Content identity
   must cover embedded images/assets, build scripts, toolchain/config/env,
   modes/symlinks and runtime fixture input. Keep the current touch until negative
   controls prove the replacement. Test runtime `CARGO_MANIFEST_DIR` and
   compile-time `env!("CARGO_MANIFEST_DIR")`/`CARGO_BIN_EXE_*` separately: identical
   source bytes do not guarantee identical absolute paths in reused binaries.
3. **Mutation target reuse with isolation.** Keep private writable fixture
   sources/targets, but evaluate persistent content-addressed fixture targets or
   safe compiler/dependency cache reuse. Never hardlink mutable sources/artifacts
   into production. Cache outputs only after successful build/semantic assertions;
   prove mutant and restored binaries differ appropriately. Retain both red and
   green cases every time required by the approved gate contract.
4. **Coalesce identical same-run work only with proof.** First account for the
   three Lua target executions and duplicate filtered Cargo launches. Proposed
   reuse requires the same instrument, source/fixture bytes, env/profile/features,
   runner/artifact identity and assertion coverage, with no intervening mutation.
   The dedicated production integration is explicitly uncached; changing its
   dispatch needs plan approval, not a local performance shortcut.
5. **Incremental deciders in shadow mode.** Declare complete input closure,
   including negative dependencies (new/deleted files and directory membership),
   imports, bindings/specs/methodology and checker changes. Unknown input closure,
   unknown base, expired audit anchor, changed runner or runtime-sensitive input
   means run fully. Existing change-class/diff-scope controls already have
   fail-closed and full-anchor rules; extend the proven seam rather than inventing
   independent skip flags. Live-state/inference/host checks need their own regime
   and freshness contract, not a source-only key.
6. **Always-correct full audit.** Retain a forced, unscoped full matrix at release
   and the approved audit cadence, on every relevant platform, with mutation
   controls. A scoped run never renews full-audit freshness. Successful cache hits
   must name the evidence reused and scope; no zero-selection stamp. No bypass
   of mandated gates, no false full-scope stamp, no automatic removal of serial
   controls, stress rounds, feature/default-only coverage or mutation checks.

## Rollout, experiment matrix and acceptance goals

All numerical thresholds below are **proposed acceptance goals**, not measured
results or enabled governance. Record approval before altering gate scope or
criteria (methodology/convergence.yaml `bar_raise_governance`).

**Phase A — baseline, primary-owned full runs:** pinned revision, quiescent host,
same toolchain/config. Capture at least three cold fixture/build runs using new
private targets (never wipe the host), five warm forced-full runs, five ordinary
memo-eligible runs, and five changed-tree runs. Stratify by machine/lane rather
than pool the fleet. Include source-only, plan-only, test/instrument-only,
feature/config/env changes, added/deleted/renamed files, modes/symlinks, and a
checkout A→B→A switch with deliberately older different source bytes. Record
mutations separately: clean→mutant→restored, expected failure identity and bytes,
post-restoration gate result, timeout/signal cleanup. Run sequentially; never
overlap the primary full gate with compiler or source-mutation experiments.

**Phase B — observability only:** root verdict and byte streams identical to
uninstrumented execution; every launched mandatory phase has an end record or
explicit incomplete/signal record; attributed work plus gaps reconciles to root
wall within max(1%, 1 s). Telemetry overhead target <1% median, <2% p95. Missing
logs, coarse clocks, sampling and compilation freshness are named. Small samples
support medians/ranges, not reliable p95 claims; collect at least 20 comparable
runs for a provisional p95, and retain raw data.

**Phase C — shadow incremental/cache:** continue running every mandated check
while separately predicting hits. Seed at least one meaningful defect in every
claimed input class; instrument mutation survivors, unknown inputs, stale
artifacts, absent helpers, unsupported capabilities, truncated logs and all-skips
responses. Acceptance: **zero silent false passes and zero missed seeded defects**;
selected/executed target counts and failure identities agree with full audits.
Race A/B checkouts and interrupted mutation restoration must never reuse another
checkout's or mutant's passing result. Expected compile failure is not a semantic
mutation kill unless that is the declared failure mode.

**Phase D — approved optimization:** compare matched cold/warm, mutation-free and
mutation workloads against Phase A. Suggested goals: warm forced-full p50 at least
20% lower; unchanged memo end-to-end no slower than baseline and setup overhead
reduced; mutation-fixture p50 at least 30% lower where compilation dominated;
cold p50 no more than 5% worse unless justified by correctness. Warm isolated
targets should have no unexplained workspace rebuilds on unchanged inputs.
Report cache-hash/setup cost, memory peak, lock wait, execution count and failure
latency alongside wall time. No claimed speedup based on omitting mandatory work.

**Rollback:** retain old path and full audit as oracle during rollout. Any missed
seeded defect, wrong-root artifact, zero-test green, scope/stamp mismatch or
unrestored source disables the proposed optimization and reruns the full oracle.
Cache corruption/unavailable provenance is a miss, never a pass. Ledger records
must state the actual evidence regime and incomplete runs explicitly.

## Primary handoff

Use this report's callsite inventory to annotate the primary full-run transcript.
First obtain actual durations for tracked-file invalidation, workspace compile/
execution, live-ledger test, three Lua integrations, serial feature pass, data
steps 375/417/590 and the release nested-gate/private-build fixtures. The historical
six-row log does not settle any of those today. Keep the successful full gate and
mutation restoration evidence attached to the pinned source/config identities.
This research session made no commits, branches, pushes or production edits.
