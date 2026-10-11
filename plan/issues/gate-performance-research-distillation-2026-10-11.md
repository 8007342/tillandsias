# Gate performance research: distillation and verdicts, 2026-10-11

Order 1604-fsxu. Evaluated on macuahuitl (linux) against trunk `ed7a73185`
(origin/linux-next after #337). Source: Codex's research branch
`research/litmus-lua-performance-20261011` (five reports at frame `cdba630ce`,
kept verbatim under `plan/issues/research/research-*-2026-10-11.md`). The
operator asked for an evaluation of "our slow and sloppy tests" and
integration where appropriate. This document is the integration: what the
research got right, what it got wrong, what it missed, and which packets
carry the fixes. Where this document and a research report disagree, this
document stands; it was written against the moved trunk and a measured gate.

## The measurement the research did not have

The research's gate-costs report says the timing log held "six records, dated
September 6-7" and that existing telemetry "cannot establish a current
cold/warm baseline". That was true of the research worker's checkout, not of
the gating host: `.cache/metrics/tillandsias-timing.jsonl` is per checkout,
and on macuahuitl's gating checkout it held 282,944 records, including a
complete per-step record set for the `./build.sh --check` that gated #337
(preamble 21:48:08Z, `build-check` 1,195,036 ms, exit 0). Every `_step`
banner in build.sh and every data step in `scripts/gate-steps.d/` emits a
`step:<slug>` record with `duration_ms`; the litmus runner emits one per
`litmus:<name>`. So the attribution question is answerable today from the
log, without new instrumentation, for everything the gate runs after its
preamble. The research's instrumentation proposals (run/span ids, parent
links, monotonic clocks) remain reasonable, but they are not the blocker it
described.

Attribution of that 1,195 s gate (all durations `duration_ms` from the log,
sorted, one run, warm-ish host that had gated an hour earlier):

| Step (banner slug, shortened) | ms | Class |
| --- | ---: | --- |
| running-workspace-tests (cargo test --workspace) | 104,159 | compile+execute |
| the-litmus-runner-selects-identically-with-and-without-jq/yq (1375-6pnd) | 76,002 | fixture runs a real spec end to end twice |
| a-tool-materialization-red-names-its-arm (1269-gfdi) | 68,116 | fixture runs the litmus runner |
| a-claim-names-a-workstation (1201-hsf9) | 54,778 | `cargo test --release` for one unit test |
| running-feature-gated-tests (tray, listen-vsock) | 53,126 | compile+execute |
| every-fragment-event-lands-on-a-real-packet | 51,247 | ledger-bound |
| the-fleet-activity-read (1223-wzc4) | 46,893 | fixture, git-history bound |
| the-plan-archiver-preserves-the-ready-set (831-ezea), a memo MISS | 46,023 | ledger-bound (misses after every land) |
| litmus-suite (82 selected pre-build tests) | 39,067 | litmus |
| the-token-instrument (1119-6wn6) | 39,059 | fixture |
| a-missing-ruby-reads-as-could-not-run (965-sxec) | 37,608 | runs the archiver AGAIN as its positive control |
| a-memo-hit-is-observable (1074-96z9) | 28,278 | fixture |
| the-credential-guard-still-answers-when-its-probe-is-killed | 20,636 | fixture |
| the-loop-status-audit-can-still-read-cycle-metrics | 15,409 | fixture |
| everything else (347 step records, each under 14 s) | ~272,000 | |
| **sum of all 361 `step:` records** | **953,025** | |
| **unattributed (build-check minus the sum)** | **~242,000** | preamble: 1599-egzz tracked-file touch, memo lookup, tool setup, sidecar staging |

Two things the table settles:

1. The slow part of this gate is not static source scanning. The Lua and
   shell deciders the research inventoried in depth cost seconds each; the
   three it benchmarked (dead inputs 2.2 s, line windows 0.7 s, steps-can-fail
   0.2 s) sum to about 3 s of 1,195 s. A 10x speedup of the whole static
   subsystem would save well under 60 s. The research reports say this
   themselves in their caveats ("a whole-gate 10x is not established"), but
   their recommendation section still leads with the snapshot/index runtime.
   That architecture is not where the time is, and it is not filed as work.
2. The time is in fixtures that re-run heavy production machinery (nested
   litmus runs, a second cargo profile, a second archiver pass), in the two
   cargo test passes, and in ledger-bound checks whose cost grows with the
   ledger. Those are what the packets below address.

The 1599-egzz touch is in the unattributed preamble. Its stderr note
(`note:gate-touch:... touched in Ns`) is the only record of it; the
coordinator reports about +170 s here. It is a correctness fix for a
demonstrated false green (one CARGO_TARGET_DIR shared by worktrees, mtime-only
freshness) and is NOT to be removed or narrowed for a timer; the research
agrees. What is filed is making its cost visible (1604-runj) and stopping
nested gates from repeating it mid-gate (1604-8uae).

## Per-report verdicts

| Report | Verdict | Why |
| --- | --- | --- |
| research-gate-costs | keep (verbatim, under research/) | Its callsite inventory is correct against trunk where checked: the three dispatches of `lua_source_agreements` (dedicated target, workspace, exact filter at the 1484-uf29 second check), the release-gates fixture's real `build.sh --check` children with 90 s / 40 s / 300 s ceilings, the capability-manifest fixture's two cold `--release` builds, the 1201-hsf9 `--release` test. Its "six-record telemetry" claim is wrong for the gating host (see above). Its pinned `build.sh:NNN` spans are frame-`cdba630ce` and already stale (the touch moved from `_touch_gating_checkout` at 994 to 1046 on trunk); they carry `cite-ok` and are kept as audit provenance, not as navigation. |
| research-runtime-testing-performance | keep (verbatim) | Honest handoff: records that the full gate never completed under the research's tool deadlines, that an attribution refusal (1204-3s2s, the host-global `/tmp/tillandsias-timing.jsonl` line-count check) fired on a 69 ms decider during a concurrent gate, and the operator's publish ruling. Its "first cuts" list is mostly the static-scan family (items 1-4), which the measurement above ranks last. Items 5-8 are real and are filed. |
| research-lua-index-runtime | keep (verbatim), no packet | A design proposal for a Rust-owned snapshot/index/batch runtime with a ">=10x TARGET" it states is unmeasured. Its audit of existing code (PredicateRegistry re-loads on a memo miss, `cli_run` exits the process, READ_ROOTS is process-global, the ledger cache keys on a validator-surface hash that misses lib.rs/fragments.rs edits) reads correctly against trunk. The ledger-cache invalidation gap is a real finding but it is a diagnostic cache, not gate evidence, and the report says so. Not filing the runtime: the time is not there. |
| research-litmus-scan-inventory | keep (verbatim) | A reproducible lexical census (1,269 files) with an embedded Node program; useful as a map. Its per-guard rewrite table is mostly correct in mechanism (e.g. `file_named` rereads the corpus per name) and mostly irrelevant in cost. Two findings worth keeping: `test-land-queue.sh` runs twice in one `--check` (step 286 and inline; 2.4 s each, measured), and the base64 guard's fail-open candidate filter (`res.status` treats git errors like no match; `pcall(fs.read)` skips unreadable files) is a policy gap, not a performance one. |
| research-fleet-runtime-infra | keep (verbatim) | Off the test-performance topic (Cloudflare login, mirrors, Nix cache, sccache, experts) but factual and dated; it correctly distinguishes landed/completed/measured/proposal and correctly flags that the Nix wrapper refuses a sourced full `build.sh` despite 873-b1nx's design text. No packet from here; 1287-w9s4 and 961-flnk already hold the sccache/builder rows. |

Decision: the five reports stay on trunk verbatim under
`plan/issues/research/` (the plan-only lane's research classification), each
with a one-line banner pointing here. Trimming them would discard the
provenance the operator paid for; distilling only would discard the
inventories. This document is the distilled layer.

## Findings judged real, with the measured or bounded saving

| # | Finding | Evidence | Saving on this host | Packet |
| --- | --- | --- | --- | --- |
| 1 | `test-a-claim-names-a-workstation.sh` ARM 6 runs `cargo test --release -p tillandsias-plan <one unit test>`: a second, LTO, test-profile build of the plan crate for one assertion. | step 375 = 54,778 ms; the unit test (`writer_host_default_is_the_compiled_platform_never_a_fabricated_linux`, main.rs) has no profile dependence. | ~50 s per `--check` (dev test profile is warm from the workspace suite). | 1604-se6w, implemented on work/1604-fsxu |
| 2 | `litmus-release-gates-run-locally` step 7 runs `test-gate-stamp-memoization.sh`, whose cases 12/13 start a real `build.sh --check` / `--check --install` and wait for `timeout 90` / `timeout 40` to kill them (rc 124 counts as "real work"). Each forced child also runs the 1599-egzz touch over the real gating checkout, mid-gate. | litmus record 142-144 s on four runs (Oct 8-9); the fixture's own comments; `_touch_gating_checkout` is dispatched on FLAG_CHECK with no nesting guard. | ~90-130 s whenever the fixture is selected (release tier, or a diff touching its inputs); plus whatever the parent re-compiles after the children's touch. | 1604-8uae |
| 3 | `test-capability-manifest-guard.sh` copies crates/assets/images and cold-builds tillandsias-plan twice with `--release` (LTO, codegen-units=1) in a fresh target, to check a compile-time manifest warning that any profile reproduces. | litmus record 101-107 s on four runs. | ~50 s or more whenever selected. | 1604-c5a5 |
| 4 | `test-litmus-runner-reads-without-jq.sh` (1375-6pnd) proves selection parity by running the real `git-mirror-service` spec end to end twice (with tools, with stubbed jq/yq/toolbox); the litmus log shows every test of that spec executing twice during the step. `--list` lists suites; nothing stops after selection. | step 530 = 76,002 ms; two sets of `litmus:` records at 22:05:35Z and 22:06:12Z. | ~65 s per `--check`. | 1604-7mgk |
| 5 | The archiver runs twice per gate: 831-ezea's memoized step (misses whenever the ledger changed, i.e. after every land) and 965-sxec's positive control `./scripts/archive-plan-packets.sh --check` inside `test-archiver-ruby-could-not-run.sh`, which already comments that build.sh ran it earlier in the same gate. | 46,023 ms + 37,608 ms. | ~35 s per `--check`. | 1604-8jbj |
| 6 | `explicit_manifest_cases_match_their_expected_guard_verdicts` evaluated the whole manifest nine times (once, then once per negative control). | source read on trunk; nine `outcomes()` calls. | Negligible: the whole target's seven tests finish in 0.05 s (measured here); the 2,249 ms step is cargo startup and linking, the exact re-run 179 ms. A correctness-neutral cleanup, kept because the coordinator named it and the fix is a counter assertion that fails on the pre-fix body. | 1604-fsxu, implemented |
| 7 | 20% of the gate (~242 s) has no step record: the preamble (touch, memo, setup) runs before `_run` attribution starts. | sum of step records 953 s vs build-check 1,195 s. | none directly; it is what makes the next decision measurable. | 1604-runj |

Not filed, noted: `test-land-queue.sh` twice (2.4 s each; the inline call at
"Checking test-land-queue (1316-bnzt, 1255-s4im)" duplicates step 286);
the exact-filtered `lua_source_agreements` re-run (179 ms); the 1269-gfdi
(68 s), 1223-wzc4 (47 s), 1119-6wn6 (39 s), 1074-96z9 (28 s) fixtures, which
are measured but were not read closely enough here to name a safe cut. They
are the next 180 s if someone wants them.

## Findings judged wrong, stale, or not worth the risk

- "Existing telemetry cannot establish a baseline / no litmus-step timing
  log": wrong on the gating host (282,944 timing records; 17 MB
  `litmus-step-timing.jsonl`). The research read an unexercised checkout's
  cache.
- The ">=10x" acceptance target for the static subsystem: meaningless for
  the gate; the subsystem is about 3 s of 1,195 s.
- Any suggestion of a persistent cross-checkout artifact cache, hardlinked
  fixture targets, or replacing the 1599-egzz touch with a marker: the
  research itself says "keep the touch until negative controls prove the
  replacement"; this document says the same, more plainly. Nothing filed
  trades correctness for speed. 1604-c5a5 keeps the fixture's private cold
  target; it only drops LTO. 1604-8uae keeps the real nested gate; it only
  stops waiting on a wall clock once real work is observed.
- "Coalesce the three Lua integration dispatches": the dedicated unfiltered
  run is mandated (1484-uf29: "keep it unfiltered, a selected count of zero
  would otherwise certify no production decision") and costs 2.2 s. Not
  worth a ledger exception.
- Frame-pinned `build.sh:NNN` and `*.rs:NNN` citations in the reports: stale
  on trunk by construction; they carry `cite-ok` reasons and the citation
  guard accepts them, but a reader should resolve by the symbol named next to
  each one.
- The research's attempt 5 blamed `test-gate-divergence-is-declared.sh` for
  two records in `/tmp/tillandsias-timing.jsonl`; it correctly withdrew the
  blame (a concurrent gate was the likely writer). The 1204-3s2s check is a
  line-count diff on a host-global file with no writer attribution; the
  research's point that it cannot distinguish writers during concurrent gates
  is valid, and only one heavy job runs on this host at a time by rule, so no
  packet.

## Observed during this evaluation, outside the research's scope

- In the 21:48Z gate's litmus records, `litmus:tool-materialization` (22,208
  ms, exit 1, `status: fail`) and `litmus:git-mirror-vault-agent-auto-auth`
  (8,245 ms, exit 1) appear with `status: fail` while the gate was green. Both
  sit between 22:02Z and 22:06Z, inside the 1269-gfdi and 1375-6pnd fixtures'
  windows, so they are most likely those fixtures' deliberate red arms
  writing production-shaped records into the production log (the research
  warned about exactly this: "synthetic fixture litmus passes/fails ... an
  unqualified sum would misattribute fixture work as live gate evidence").
  Not verified here; if a fixture writes to the production log it is the
  1204-3s2s class and belongs with 1604-runj's writer-attribution work.
