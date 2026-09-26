# CentiColon as an enforceable metric on the Lua substrate (design)

- Date: 2026-09-26. Author: macuahuitl (Fable agent, delegated by the coordinator session at the operator's direction). Base: origin/linux-next `1047cb178`.
- Operator direction (2026-09-26, verbatim in the delegation): "now that we have LUA runtime for our LITMUS TESTS and the capability to run LUA scripts and things like LANGUAGE PROCESSORS to query the contents of our code and yaml files to see if artifacts exists and actually verify their completeness, it's time for Fable to revisit our CENTICOLON approach — it might be closer to being an enforceable metric, which would close a lot of the theoretical bugs in our methodology."
- Code is cited by symbol. Every count below names the command that produced it and was taken on the base above in a detached worktree; the two design docs this builds on are `plan/issues/lua-runtime-host-dependency-replacement-design-2026-09-26.md` and `plan/issues/scripting-runtime-lua-no-pipes-design-2026-09-26.md`.
- Packets filed from this design: 1395-n7qd, 1395-88tp, 1395-ue3i, 1395-miwn, 1395-64r7; events on 1334-57at, 1325-ygq5, 1356-vv5m, 902-5bf9, 976-kk6x, 977-448j. See §9.

## 0. The answer in five lines

1. One CentiColon obligation is one `#### Scenario:` block under a `### Requirement:` that carries a `req-id`, in a spec whose status is active or draft; a requirement with no scenario is one obligation by itself. Its identity is `cc:<req-id>:<sha256(scenario title)[:8]>` — stable under reordering and prose edits, and a new identity when the title changes, which is the operator's tombstone rule applied mechanically.
2. Extraction is a Cacheable Lua predicate over `openspec/specs/*/spec.md` and `openspec/litmus-bindings.yaml`, so the obligation list is a pure function of repo bytes: measured on this tree, three processes produced the same sha256 of the JSON.
3. An obligation is satisfied at `positively_tested` only when a litmus step that names its req-id (`requirement:` key) has an assert key, lives in a file that is bound, not retired, and in a tier a gate runs, AND a recorded run of that file on this tree is green in a named regime. Existence earns `traced`; only execution earns the rung the count keys on.
4. R = the number of obligations below `positively_tested`, printed on every `--check` with its denominator and regime; a ratchet refuses a rise caused by a LOST satisfaction, reports a rise caused by an ADDED requirement as a scope change, and accepts a fall only through a recorded tombstone. V_c is computed from the same line as it lands in `plan/loop_status.d` on trunk.
5. What it still cannot see is named as residue in the same output, never counted as satisfied: adequacy of an assertion (mutation arms are the partial answer), regimes nobody ran (per-regime satisfaction), and the semantic identity of an edited requirement. Turning any warning here into a refusal is a bar raise that the operator approves.

## 1. What CentiColon IS in this repo today (measured, not assumed)

`git grep -n -i centicolon` over methodology, openspec, plan, scripts and crates. The name is used for four different objects.

| Object | Where | What it counts | Computed by anything? |
|---|---|---|---|
| The unit and scoring model | `methodology/proximity.yaml` (`proximity.unit`, `obligation_budget.base_weights`, `earning_rules`, `penalties`, `anti_gaming`, `release_projection`) and `methodology/math-foundations.yaml` (`obligation_state` seven-state chain, `centicolon_function`) | one hundredth of a normalized spec-obligation closure point; obligations are MUST/SHOULD requirements, invariants, litmus signals, trace signals, provenance bindings, weighted 25–120 | The lattice and ranking function exist in Rust (`ObligationState`, `SpecState`, `Weights`, `centicolon_function`, `Regime` in `crates/tillandsias-plan/src/obligation.rs`; orders 977-56fd, 977-dpbj). Nothing feeds it spec obligations. |
| The number local CI prints | `scripts/local-ci.sh` `write_convergence_artifacts`, `check_weight`, `check_spec_ref`; `tillandsias-plan score-checks` (977-j6qu) | 16 CI check ids (rust-clippy, litmus-pre-build, no-python-scripts …) weighted 30–180; denominator 990 in `--fast`, 1390 with the post-build and runtime phases | Yes, on every `--check`. The obligations are gate steps, not requirements. Yesterday's record on this host (`target/convergence/centicolon-signature.jsonl`, 2026-09-25T21:52Z, tree a729e13ea): `expected_total_cc 990, actual_earned_cc 990, residual_cc 0, percent_closed 100, litmus_tests_run 0`. The published dashboard (`docs/convergence/centicolon-dashboard.json`) was last generated 2026-08-09 with 29 records. |
| The ledger backfill | `scripts/centicolon-backfill.sh` (977-3dee) | packets whose `verifiable_closure` names a resolvable litmus test | Ran once, 2026-09-03: 16 of 600 packets, ceiling `traced` because "the ledger carries the closure's NAME, not the test's RESULT". Coverage 2.6%. |
| The coordinator's residual debt | `skills/coordinate-multihost-work/SKILL.md` "Velocity & Finite-Time Convergence Guarantee": R = N_CentiColons + N_UnimplementedSpecs + N_OpenIssues, V_c = (R_{t-3} − R_t)/Δt, V_min = 1 unit/hour; `methodology/convergence.yaml` `finite_time_convergence_and_velocity_control` defines R_t as "sum of named residual CentiColon obligations + count of unimplemented spec requirements" | three terms in three different units | No. No script, verb or fixture computes R or V_c; the hourly loop status records carry neither. |

Why it stayed theoretical, in one sentence each:

- The unit was never grounded in the artifact it names. `proximity.yaml` says the denominator is "derived from the spec"; the only implemented denominator is a list of shell check ids. The 670 `### Requirement:` headings and 1,505 `#### Scenario:` blocks in `openspec/specs/*/spec.md` (grep counts) never enter any score.
- Nothing binds below spec level. `openspec/litmus-bindings.yaml` maps `spec_id` → litmus names (141 spec ids, 518 bindings); 0 of 454 litmus files mention a `req-id` (`grep -l 'req-id' openspec/litmus-tests/*.yaml`), and 2 carry a `requirement:` key in the pre-976-suab dotted form, which `scripts/run-litmus-test.sh` never reads. A spec with one grep-shaped test and nineteen scenarios reads "covered".
- Results are not a stream. The runner writes logs, `local-ci.sh` writes one `check-logs.jsonl` row per check, and no artifact records "litmus X was green on tree T in regime H". That is exactly why 977-3dee could not credit past `traced`.
- The gate does not run the tests that would earn the rung. `drift_control.a_green_gate_MUST_NOT_be_read_as_the_litmus_assertions_having_run` says so; the signature line above confirms it (`litmus_tests_run 0`).
- Three definitions of R disagree and each waits for the others. The skill's third term (open issues) is a queue length, not a correctness obligation; adding it to a weighted cc score is adding apples to a queue.

## 2. The methodology's theoretical bugs, and which ones a measured CentiColon closes

"Theoretical bug" here means a guarantee the methodology states that no mechanism enforces. Each row names the closing mechanism from §3–§5 or says the metric cannot reach it.

| Stated guarantee | Where it is prose today | Closed by a measured CentiColon? How |
|---|---|---|
| Finite-time convergence: V_c ≥ V_min or an alignment event fires | skill §Velocity; `convergence.yaml` `finite_time_guarantee` | Partly. R becomes a number per `--check` (§5.1) and V_c a number per coordination pass (§5.3). The alignment EVENT stays a coordinator decision reported against that number, never auto-triggered (a peer cannot commit operator spend). |
| "A green gate ≠ the property holds" | `drift_control`; memory rule | Yes. `positively_tested` keys on an execution record for the bound file on THIS tree (§4.2), not on the file existing or the gate being green. |
| Orphan fixtures: a test nothing runs reads as guarding something (1325-ygq5, standing 55 on 2026-09-21; now `warn:added-test-unreferenced` with a standing count) | `check-added-test-is-referenced.sh` warns; the standing corpus is inherited | Yes, as residue. An orphan satisfies no obligation; every obligation it names stays in R with reason `inert:unbound`. The number 1325-ygq5's flip-to-refusal was waiting for is R's `inert` term. |
| The census overstates enforcement by a quarter (1334-57at: ENFORCED 247 = REACHABLE 181 + INERT 66) | the census reports; nothing consumes INERT | Yes. The grader consumes the same reachability rule (bound AND not `phase: retired`) as the gate between `traced` and `positively_tested` (§4.2). |
| Litmus bindings name spec ids nothing resolves (1356-vv5m, done at spec level) | `check-litmus-bindings.sh` now resolves spec ids | Yes, one level down. A `requirement:` key that names a req-id absent from the extractor's output is refused by name; the population of resolved keys is asserted (§4.2, 1395-88tp). |
| `verifiable_closure` is prose (977-448j refuses new rows without a scorable form) | the gate accepts `litmus:`, `scripts/*.sh`, `cargo test`, or `unscoreable:` | Partly. A fourth scorable form `centicolon: <req-id>[,…]` names the obligations a packet closes; at closure the grader must show them ≥ `positively_tested` (§5.4). Existing rows are not re-judged. |
| Closure evidence SHAs are never checked for content | `closure-evidence-check` verifies an evidence-bearing EVENT exists, not that the SHA resolves or touches the claimed files | Yes, as an Observing predicate: `git cat-file -e <sha>^{commit}` on origin (the `GitRef` helper already has `commit_exists`) and the commit's diff names the packet's `owned_files` (§4.3). |
| 1381-za6b closed "completed" with 3 of 4 criteria unmet; caught by a manual review | the closure event cites `be25a7f39; 578 unit tests passed; full ./build.sh --check passed; litmus:gh-auth-script passed` | Yes, for the spec half. Requirement 7a82bc19 (Mobile QR Code Device Flow) has 2 scenarios and 5 MUST clauses and no litmus step names it; the grader reports both scenarios at `declared`, so a closure naming `centicolon: 7a82bc19` would have been refused, and a closure NOT naming it would show the spec's R unchanged by a "completed" feature — visible in the same pass that reviewed it. The credential-path findings (1383-5hpk) are not reachable by this metric; see §6. |
| Denominator gaming (`anti_gaming.deleting_obligations_requires_tombstone_or_bounded_uncertainty_exception`) | prose in `proximity.yaml` | Yes. A req-id that disappears from the extractor's output between base and head must appear in an `openspec/changes/**` record or a tombstone line, else the ratchet refuses the fall (§5.2). |
| Monotonicity only under a fixed denominator | `centicolon_function` returns `Regime::Broken` when an obligation is tombstoned | Already implemented; the ratchet reads the regime and refuses to COMPARE across a broken one rather than refusing the change (§5.2). |

Not closed by any count (§6): semantic adequacy of an assertion; regimes that were never run; whether an edited requirement kept the right identifier (`requirement_identity_across_edits.enforced_by: author-judgement-only`); requirements the spec should have and does not; open unknown events.

## 3. The unit and its extraction (Cacheable)

### 3.1 Unit

An obligation is the smallest thing a litmus step can be bound to and still be a proposition: a scenario is WHEN/THEN shaped, a requirement heading is a title, a MUST token is a word. Counting MUST tokens is rejected because a prose edit changes the count without changing the obligation (this tree: 3,810 MUST/SHALL tokens under requirements versus 1,436 scenarios; the same requirement reworded moves the first and not the second). Counting requirements alone is rejected because it is too coarse to grade: 4 of gh-auth-script's 7 requirements have 3 or more scenarios and one litmus step cannot honestly claim all of them.

- Population: every `### Requirement:` heading in `openspec/specs/<spec>/spec.md` whose next line is `<!-- req-id: <hex> -->` (guaranteed by `check-requirement-ids.sh`, 976-suab), in a spec whose status is `active` or `draft`. Status is read from the `## Status` section in either spelling the corpus uses (`status: active` on its own line in 36 files; a bare word under the heading in 143). `obsolete`, `deprecated`, `retired`, `proposed` are out of the denominator and reported as `excluded:<status>` counts so a status flip is visible (§5.2).
- Each `#### Scenario:` under the requirement is one obligation. A requirement with zero scenarios contributes one obligation for its own MUST sentence. `### Invariant:` blocks (144) are obligations of a second kind, weight and grading identical, identity `cc:inv:<spec>:<sha256(title)[:8]>`; they are counted separately in the output because `proximity.yaml` weights them differently and the operator may keep that.
- Identity: `cc:<req-id>:<sha256(normalized scenario title)[:8]>`. Rationale: the req-id is the operator-ruled stable handle; the title hash makes a renamed scenario a new obligation (a refinement keeps the title, a changed obligation gets a new one — the same rule `proximity.yaml` states for requirements, now decidable for scenarios because a title change is a byte change). Ordinals are rejected: inserting a scenario would renumber its siblings.
- Per obligation the extractor also emits `spec`, `req_id`, `title`, `must_tokens` (informational), `traces` (the `@trace spec:` list under the requirement), and `spec_digest` so a grader can tell which spec bytes a run was measured against.

### 3.2 Extraction

A Cacheable predicate (`PredicateClass::Cacheable`, `build_environment_logged`): `fs.read` for the spec files and the bindings registry, `yaml.parse` for the registry, `json.encode` with the 1384-bp6t sorted encoder for the output. No clock, no shell, no `fs.list` — the spec list comes from the bindings registry's `spec_id`s plus the argument, and an unlisted spec directory is reported as `unregistered` rather than silently skipped (the 1356-vv5m direction: the population is asserted, not inferred). When `fs.list` lands (§4 of the no-pipes design) the directory walk replaces the registry as the population source and the registry becomes a cross-check.

Feasibility, measured on this tree with the shipped binary (`tillandsias-plan lua scripts/… gh-auth-script`, a 40-line script using only `fs.read`, `yaml.parse`, `hash.sha256`, `json.encode`):

```
{"bound":["litmus:gh-auth-script-smoke","litmus:gh-auth-script-shape"],"requirements":7,"scenarios":19,
 "rows":[{"id":"4a8426ff","scenarios":3,…},{"id":"a8878caa","scenarios":2,…},{"id":"ffb548a7","scenarios":3,…},
         {"id":"2458b36e","scenarios":5,…},{"id":"98d98496","scenarios":2,…},{"id":"7a82bc19","scenarios":2,…},
         {"id":"9c34ea81","scenarios":2,…}],"spec_digest":"db8e6237…","status":"active"}
```

Three consecutive processes: sha256 of stdout `1b35acd0…` all three times. Over all 179 spec directories the same script reports 670 requirements and 1,436 scenarios under requirements (the remaining 69 `#### Scenario:` blocks sit under `### Invariant:` or section headings and are the second kind above). Memoisation is content-addressed on the files read (`ReadLog`, `file_digest`, `CacheEntry::still_valid`), so an unchanged corpus costs one digest pass on the second `--check`.

Determinism rules the extractor must obey, all already enforced by the runtime: sorted `pairs` and `json.encode` (1384-bp6t), `os.setlocale` withheld, no `print` in the Cacheable class (the predicate returns its JSON through `expert.log_info` today and through `out.line` once 1384-bqhy's `script run` exists; the pilot uses the sandboxed `lua` CLI's `print`, which is Observing and acceptable for a probe, not for the gate).

## 4. Completeness, not existence: the grading checks and their classes

The lattice is `ObligationState` as implemented: absent → declared → traced → positively_tested → negatively_tested → runtime_observed → evidence_bundled. Each rung below names the mechanical check, what artifact it reads, and whether the check is Cacheable (pure over repo bytes) or Observing (needs git, a run log or origin).

### 4.1 `declared` — Cacheable

The obligation is in the extractor's output. This is the denominator.

### 4.2 `traced` and `positively_tested` — Cacheable, then Observing

`traced` (Cacheable): some litmus step carries `requirement: <req-id>` (file-level `requirement:` applies to every step in the file; step-level overrides). The key already exists in two files in the dotted form; the grader accepts both spellings during migration and counts them separately. A req-id that resolves to nothing is REFUSED by name (`violation:centicolon-requirement-unresolved:<n>`), and zero resolved keys across a non-empty litmus corpus is a refusal, not `ok:0`. The 902-5bf9 `steps:` form carries the same key per step.

`positively_tested` needs four facts, the first three pure and the fourth observed:

1. The referencing step is ENFORCED by the census's rule (`census-litmus-step-enforcement.sh`: an `assert_exit`, `assert_output_contains`, `assert_output_matches`, `assert_output_nonempty` or `success_pattern` KEY in the step block). An `expected_behavior` string alone earns nothing — 2,178 of 2,613 steps are in that bucket today and that is the overstatement 1329-m8dk and 1334-57at measured.
2. The file is REACHABLE: its declared name is in `litmus-bindings.yaml` under a spec the file itself declares (`test-litmus-binding-truth.sh`'s rule), its `phase` is not `retired`, and it is not in `unbound-grandfathered.txt`. Otherwise the obligation stays `traced` with reason `inert:unbound`, `inert:retired` or `inert:grandfathered`.
3. The file's tier is one a gate runs: `size` ∈ {instant, quick} and `phase: pre-build` for the pre-build tier (`size_matches_filter`), or an e2e phase for the release tier. The tier is recorded on the obligation so a regime claim (§4.5) can say WHICH gate.
4. (Observing) A results record says the file ran green on this tree: `{ts, host, regime, tree, litmus, status}` in a per-test stream the runner appends. That stream does not exist yet — `run-litmus-test.sh` prints PASS/FAIL and `local-ci.sh` records one row per check id, not per test — and it is the one new writer this design needs (1395-88tp, one JSONL line per executed test, the `record-ci-phase-result.sh` shape). `tree` is the sha of the spec file plus the litmus file, not the commit, so a record survives unrelated commits and dies when either input changes. A record from a host whose regime the gate step names (`STEP_SECOND_REGIME`, 106 of 107 steps carry one) counts for that regime only.

Cacheability boundary: 1–3 are a pure function of repo bytes and can be memoised; 4 reads a log and is Observing, so the grader is two predicates, `centicolon-grade-static` (Cacheable) and `centicolon-grade-observed` (Observing), and the gate runs the second only after the first.

### 4.3 `negatively_tested` — Cacheable over bytes, with an Observing arm

A second step in the same file, naming the same req-id, whose name matches `check-litmus-mutation-arms-mutate.sh`'s MUTATION/SABOTAGE pattern and whose command WRITES (that guard's rule), with a green record. The 1391-8ikx fragment's "Pre-fix result: FAILS" is the packet-level spelling of the same thing; at obligation level it is a step. A named arm without a write is already a violation of 1059-pb2j, so the grader reuses that verdict rather than re-deciding it.

### 4.4 `runtime_observed` — Observing

A green record for a `phase: runtime` or `post-build` file naming the req-id, from a release-tier run (`ci_phase` covering pre-build AND post-build AND runtime, the 1174-6r4k rule `check-release-tier-freshness.sh` already applies).

### 4.5 `evidence_bundled` — Observing, needs origin

A ledger closure names the obligation (`centicolon: <req-id>` in `verifiable_closure`, §5.4) with an evidence SHA that (a) resolves on origin (`git cat-file -e <sha>^{commit}` against `origin/linux-next`; the `GitRef` helper's `commit_exists` is the existing symbol), (b) whose diff touches at least one of the packet's `owned_files`, and (c) whose tree contains the litmus file that satisfies the obligation. This is the content check the delegation asked for, and it is what would have refused `23bbaf3aa` for 1381-za6b: `be25a7f39` resolves and touches `openspec/specs/gh-auth-script/spec.md`, but no litmus in that tree names 7a82bc19.

Per-regime satisfaction: every rung from `positively_tested` up is recorded per regime (`linux`, `darwin`, `windows`, `forge`) because the record carries the host. The obligation's state for R is the MINIMUM over the regimes the spec's `@trace`d gate step names in `STEP_SECOND_REGIME`; regimes with no record are listed as `unmeasured:<regime>` residue, never as satisfied (memory rule: green on one regime).

## 5. The metric, the ratchet and where it plugs in

### 5.1 R, printed every `--check`

One verdict line from `check-centicolon-ratchet.sh` (later a `.lua` under 1384-bqhy's `script run`):

```
ok:centicolon:R=<n> denominator=<d> declared=<a> traced=<b> positively_tested=<c> negatively_tested=<e> inert=<i> unmeasured=<u> excluded=<x> regime=<monotone|broken:<why>> floor=<f> tree=<spec-corpus-digest>
```

R = obligations below `positively_tested` = declared + traced (inert obligations are `traced` by construction, so `inert` is a sub-count of `traced`, printed so 1325-ygq5's number is visible). The denominator, the histogram and the regime travel with R because `math-foundations.yaml` requires them reported separately and `obligation.rs`'s `Score` already has that shape; the ratchet feeds `centicolon_function` with one `Weights` entry per obligation at `earned_at = PositivelyTested`, so there is ONE ranking function (977-j6qu's rule) and `score-checks`' 16 gate ids stop being reported under this name (they remain a gate-health line).

Expected first value on this tree: R ≈ 1,436 of 1,436 under requirements (0 satisfied, because no litmus step names a req-id) before the active-status filter, which the pilot must report exactly. That the metric starts at 100% residual is the point: the 990/990 line it replaces was the number that could not fall.

### 5.2 The ratchet — what is refused, what is reported

The floor file `scripts/portability/centicolon-floor.txt` holds `R` and the denominator at the last land, per the 1375-tsfu and 1384-bxhk shape (floors only descend; the population is asserted; the pattern is in the script header).

| Change between base and head | Verdict | Why |
|---|---|---|
| R falls, denominator unchanged | `ok:`, floor lowered | progress |
| Denominator rises (new req-id or scenario) and R rises by the same obligations | `ok:… regime=broken:scope-added:<n>`, floor rewritten with the new denominator | adding a requirement raises debt honestly; refusing it would punish writing specs |
| Denominator falls (a req-id or scenario title vanished) | REFUSED unless each vanished id appears in `openspec/changes/**` or on a `tombstone:` line in the spec or bindings registry; then `regime=broken:scope-removed:<n>` | `anti_gaming.deleting_obligations_requires_tombstone_or_bounded_uncertainty_exception`, now decidable |
| A spec's status leaves {active, draft} | same as a fall of every obligation it held | a status flip is the cheapest way to shed debt |
| R rises with the denominator unchanged (a `requirement:` key removed, a file unbound or retired, an assert key deleted, a step renamed off its mutation arm) | REFUSED: `refused:centicolon-ratchet:lost=<n>:<first id>` | a satisfaction was lost and no obligation changed |
| A results record is absent for a previously green file on an unchanged tree | not a rise; the record is keyed on input digests, so an unchanged file keeps its record | prevents a fresh clone reading as a regression |
| The extractor or grader cannot run (binary stale, no bindings file, zero population) | `blocked:centicolon:<why>` | never `ok:0` |

Diff-scoped like every ratchet in this tree: standing debt is never reddened (1130-i6xj). Phase 0 prints `warn:` for the two REFUSED rows and `ok:` otherwise; flipping `warn:` to `refused:` is the bar raise in §7.

### 5.3 V_c, from the line that lands on trunk

`cycle-metrics.sh` already emits pinned `key=value` lines into each `plan/loop_status.d` record. It gains one: `centicolon: R=<n> denominator=<d> regime=<m> tree=<digest> host=<h>`. `centicolon-velocity.sh` (1395-miwn) reads the last four records on `origin/linux-next` for the same host with the same denominator and prints `centicolon-velocity: v_c=<obligations/hour> window=<n> comparable=<yes|no:<why>>`. Records across a `broken` regime are not comparable and say so; fewer than four comparable records say `window=<n>` and no velocity. V_c < V_min is printed as `note:centicolon-velocity:below-minimum` — a report the coordinator acts on; the alignment event in the skill is a decision, not a hook. The skill's R formula is amended by an event to reference this line and to drop N_OpenIssues from R (queue length is reported beside it, in its own unit).

### 5.4 Where it plugs into the one classifier

The ratchet is a gate step (`scripts/gate-steps.d/<prefix>-1395-ue3i.step`, `STEP_SCRIPT` literal, `STEP_SECOND_REGIME` recorded before it enters `--check`) so the preflight door and the gate loop see the same verdict through the same classifier (`_pf_run_guard` today, `verdict.classify` after 1384-bqhy). Verdict tokens are the house grammar (`ok:`, `warn:`, `refused:`, `blocked:`, `skip:`) so `check-logs.jsonl` and the freshness auditor need no change.

The ledger side: `check-scorable-obligation-added.sh` (977-448j) accepts a fourth scorable form, `centicolon: <req-id>[, <req-id>…]` in `verifiable_closure`; `check-declared-closures-added.sh` resolves each id against the extractor (an unknown id is `violation:declared-closure-unresolvable`); and at closure time (set-field to completed/verified/done, or the hand-authored fragment path `closure-evidence-check` guards) the Observing grader must show every named obligation ≥ `positively_tested` in at least one regime, else the closure is `warn:` in phase 0 and refused after the bar raise. Rows with `unscoreable:` are untouched.

### 5.5 Goodhart, named per move

| Move | Caught by |
|---|---|
| Add `requirement:` keys to steps that assert nothing | rung 1 of §4.2: no assert key, no credit; the census's KEY rule, not a substring |
| Add an assert that cannot fail (`grep -c` piped to `true`) | not caught mechanically; §6 residue. The mutation arm (§4.3) is the partial answer and the coordinator's sampling the rest |
| Delete a MUST, a scenario or a spec's active status | §5.2 REFUSED without a change record |
| Reword a scenario title to shed a red obligation | it becomes a new obligation at `declared`; R is unchanged or rises, and the old id shows as `scope-removed` needing a record |
| Bind a test under a spec it does not declare | `test-litmus-binding-truth.sh` already refuses new ones; the grader uses the same rule |
| Claim a regime that never ran | per-regime records; `unmeasured:<regime>` residue |
| Lower R by raising the floor file by hand | floor file changes are diff-scoped and must accompany a lowered R or a `broken:` regime in the same commit; a bare edit is refused |

## 6. Honest limits, and how each stays visible

- Semantic adequacy. A step that names a req-id and asserts a source string is `positively_tested`; whether it tests the SCENARIO is a judgement. Visible as: the grader prints the asserting step's name and assert key beside every satisfied obligation, so a reviewer reads the assertion, not the count; `negatively_tested` is printed as its own column so "positively tested with no mutation arm" is a named class (today every satisfied obligation will be in it).
- Regimes nobody ran. `unmeasured:<regime>` is a residue column, and R is the minimum over named regimes; a macOS-only spec with a Linux-only record is residual, not satisfied.
- Identity across edits. `requirement_identity_across_edits.enforced_by: author-judgement-only` stands. The title hash mechanises the scenario half; the requirement half still depends on whether the author kept the req-id, and the ratchet can only see that an id vanished, not whether it should have.
- Requirements the spec lacks, and unknown events. Out of reach by construction; `open_unknown_events` stays a separate field in the dashboard shape.
- Findings outside the spec. 1383-5hpk (a token leak in the real credential path) was found by reading code, not by an unmet scenario. The metric counts what the spec names.

## 7. Bar raises: what needs the operator

`bar_raise_governance` says the loop may propose and must not enable. Mapped onto this design:

| Part | Bar raise? | Approval needed |
|---|---|---|
| Extractor, grader, the `ok:centicolon:` line, V_c line, floor file (phase 0, report/warn only) | No: reporting a number is not a finding class | none; lands as ordinary packets |
| `warn:` → `refused:` for R rising by a lost satisfaction | Yes: a new class of refusal on every push | operator, recorded under `approved_bar_raises` with the number it was decided against (1325-ygq5's WARN-then-refuse-on-a-number shape) |
| `warn:` → `refused:` for a denominator fall without a change record | Yes | operator |
| Refusing a packet closure whose `centicolon:` obligations are below `positively_tested` | Yes: changes what "completed" can mean | operator; also amends `methodology/convergence.yaml` (a methodology change) |
| Requiring `requirement:` on NEW litmus steps (the adoption forcing function, 902-5bf9's `steps:` counter extended) | Yes | operator; the counter runs first so the flip is decided against a number |
| Replacing the 990-point `score-checks` line in the signature JSONL with the obligation-level R | Yes at the release boundary: the release dashboard's `expected_total_cc` changes meaning | operator at the next cut (a release cut is itself the canonical bar raise) |
| Amending the skill's R formula and V_min | methodology change | operator |

## 8. Pilot (design only): gh-auth-script and forge-hot-cold-split

Both extracted with the shipped binary today (§3.2). Neither has a litmus step naming a req-id.

gh-auth-script: 7 requirements, 19 scenario obligations, bound tests `litmus:gh-auth-script-shape` (pre-build, instant, 6 steps, 1 with an assert key) and `litmus:gh-auth-script-smoke` (pre-build, quick, fake-podman harness). Expected grader output today: declared 19, traced 0, R_spec = 19. The pilot litmus `litmus-gh-auth-script-requirements.yaml` gives each of the following a `requirement:`-keyed, assert-keyed step with a mutation arm: 4a8426ff (3 scenarios: `handle_github_login` spawns the terminal; `launch_in_terminal` errors with no emulator; the CLI flag is inline), a8878caa (2: non-tty without `--with-token` exits before Podman; `--with-token` inherits stdin without `--tty`), 2458b36e (the 5 in-container verification/Vault scenarios, pinnable through the fake harness the smoke test already drives), 98d98496 (2: the drop guard). Expected after the pilot: positively_tested 12, R_spec = 7, with 7a82bc19's two scenarios (Mobile QR Code display; Mobile authorization polling and persistence) and 9c34ea81's two (refresh rotation; explicit refresh) named as `declared` residue and ffb548a7's three at `traced` if only shape steps can be written for them. That residue IS the 1381-za6b finding, printed by a script.

forge-hot-cold-split: 7 requirements, 20 scenario obligations, bound tests `litmus:forge-hot-cold-split-shape` (2 steps), `litmus:forge-hot-cold-split-tmpfs-shape`, `litmus:harness-contract-probe`. Expected today: R_spec = 20. Pilot: dd7d6e7e (2 scenarios, the four tmpfs mounts and the cheatsheet staging), 79bda5bb (4 size caps), 0d24437b (2, `--memory` pairing) are pinnable from `crates/tillandsias-headless` source shapes with assert keys; 0d67b862 (3, the pre-flight RAM refusal) needs the fake harness; 185fbe6c (4, the tmpfs-overlay lane) has scenarios the shape test cannot reach without a running forge. Expected after: positively_tested 8–11, `unmeasured:darwin` for every scenario the spec's macOS regime names, R_spec 9–12.

Both numbers are predictions to be replaced by the grader's pasted output in 1395-64r7's completion event; the packet's closure asserts the pre-fix value (0 positively_tested) as evidence, per the 1391-8ikx shape.

## 9. Packets

New rows (fragment `plan/index.d/20260926t…-1395-n7qd-centicolon-…-macuahuitl.yaml`), hosts per the fleet tiers (Linux → lenovinha then yoga; macOS → macbookair; Windows → yolanda; the operator's forge macuahuitl-forge may take Linux-side predicate work; never macuahuitl):

| Order | Slice | Role / priority / release | Depends on | Host |
|---|---|---|---|---|
| 1395-n7qd | the extractor: Cacheable predicate over specs + bindings → obligation JSON; status filter; unregistered-spec refusal; hermetic fixture wired as a gate step | any, p1, v0.5 | — | macuahuitl-forge or lenovinha |
| 1395-88tp | the grader: `requirement:` keys resolved and refused by name; ENFORCED × REACHABLE × tier; the per-test litmus results stream (one JSONL line per executed test); per-regime states; mutation arm | linux, p1, v0.5 | 1395-n7qd | lenovinha |
| 1395-ue3i | the ratchet and the classifier seam: `ok:centicolon:` line, floor file, `broken:scope-*` regimes, refusals behind an enforce switch, gate step with a second regime, fourth scorable form in 977-448j's gate | any, p1, v0.5 | 1395-88tp | lenovinha; macbookair records the second regime |
| 1395-miwn | V_c: the `centicolon:` line in `cycle-metrics.sh`, `centicolon-velocity.sh` over `plan/loop_status.d` on origin, comparability across broken regimes | any, p2, v0.5 | 1395-ue3i | yoga |
| 1395-64r7 | the pilot: requirement-keyed litmus for gh-auth-script and forge-hot-cold-split, bound, with mutation arms; the grader's output pasted as the closure | linux, p2, v0.5 | 1395-88tp | lenovinha or yoga |

Events (same fragment): 1334-57at (the grader consumes REACHABLE/INERT; INERT gates nothing and stays visible as residue — the answer to its `next_action`'s open question), 1325-ygq5 (the standing orphan count becomes R's `inert` term, the number the flip was waiting for), 1356-vv5m (the resolver's requirement-level sibling), 902-5bf9 (`requirement:` per `steps:` step; the adoption counter grows a `req-keyed=<n>` field), 976-kk6x (the lattice gets a corpus-level obligation source; `score-checks` keeps its 16 ids as gate health under another name), 977-448j (the fourth scorable form).

Sequence: 1395-n7qd → 1395-88tp → {1395-ue3i, 1395-64r7} → 1395-miwn; the bar raises in §7 after 1395-ue3i has printed a number for at least one coordination window.

## 10. Not verified here

- No build was run and nothing was wired into a gate; every number is from the shipped binary at the base and from `git grep`. The extractor probe used the sandboxed `lua` CLI (Observing, for `print`), not the `predicate` verb; the Cacheable class was exercised only far enough to confirm `fs.read`, `yaml.parse`, `hash.sha256` and `json.encode` are reachable and `print` is not.
- The active-status denominator was not computed: the probe's status regex reads only the `status: <word>` spelling; the pilot reports the exact figure.
- Whether `run-litmus-test.sh` can append a per-test record without touching 902-5bf9's dispatch seam was not checked against a working tree; the two rows name the same runner and the later one holds.
- V_min = 1 obligation/hour is the skill's number for a different R; the first four comparable records decide whether it is a sensible floor for this one, and that decision is the operator's.
