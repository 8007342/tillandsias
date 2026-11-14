# Design — obligation-evidence-contract

Research, measurements and sources:
`plan/issues/level5-obligation-defects-2026-11-11.md`. Earlier design this
builds on: `plan/issues/centicolon-enforceable-metric-design-2026-09-26.md`
(sections 4.3 to 4.5 designed three of the four missing rungs and a per-regime
minimum; none was built).

## Context

The grader is three Lua predicates run by `scripts/centicolon-grade.sh`:
`centicolon-extract.lua` (obligations from specs), `centicolon-grade-static.lua`
(binding, enforcement, reachability, tier) and `centicolon-grade-observed.lua`
(green records from a results stream). `check-centicolon-ratchet.lua` compares
the result with a per-checkout file. The lattice type `ObligationState` in
`crates/tillandsias-plan/src/obligation.rs` has seven variants; the graders
use three.

## Goals / Non-Goals

Goals: every number the level-5 document names is either computed by code under
a stated definition, or listed as unmeasured with the reason. A platform's
failure is always visible. A reader can check a pass without trusting the
grader.

Non-goals: semantic adequacy of a test (whether an assertion tests the
scenario stays a reviewer's judgement); a weighted score; any refusal on push;
grading `### Invariant:` blocks (126 today, extracted and not graded — a
separate row when this contract is stable).

## Decisions

**D1. `d_v` is a count of cells under a named policy.**
`d_v = |{(o, p) : p ∈ scope(o), state(o, p) < bar}|`, policy
`unweighted-positive-test/1`, bar `positively_tested`. This is the level-5
residual `R_S` with every weight 1 and the obligation set widened to cells. A
count is chosen over the weighted table because no code reads the weights, and
a second number nobody computes is the defect being fixed. A policy change is a
new policy name and a comparison break, never a silent re-weighting.
Alternative considered: keep obligation as the unit and report platform beside
it. Rejected by the ruling: an aggregate must not mask a platform.

**D2. The cell is (obligation, platform); the aggregate is the minimum.**
Platforms are `linux`, `macos`, `windows`. The minimum is the meet of the
existing chain order, so `SpecState`'s componentwise order extends to cells
without a new type: a cell is one more coordinate.

**D3. Scope defaults to all three; narrowing is declared in the spec.**
A `platforms:` line in the spec's Status block (beside the existing `phase:`
line), overridable for one requirement by `<!-- platforms: … -->` on the line
after its `<!-- req-id: … -->`. Default-all makes forgetting the declaration
show up as unmeasured cells, which is the safe direction; default-none would
let an undeclared obligation count nowhere.
Consequence: the denominator rises from 1574 obligations to at most 4722 cells.
That is a scope change and is reported as one at the release it lands in.

**D4. A record names its product platform; regime is not platform.**
The existing `regime` is the runner's userland (`linux`, `darwin`, `msys`). A
Windows host re-executes its gate inside WSL, so its records say `linux`. The
record gains `platform`, set from the bare-metal host family and passed into a
re-exec explicitly. A record without it earns nothing (`unattributed`).

**D5. Binding is per scenario.**
A step's `scenario:` key names one obligation id. `requirement:` alone earns
`traced`. Done now because 0 obligations are satisfied: no credit is lost and
1569 keys are not written at the wrong granularity. The pilot `1395-64r7`
should write `scenario:` keys.

**D6. Each rung has one rule, and the grade lists the rungs it cannot assign.**
`negatively_tested` and `runtime_observed` follow sections 4.3 and 4.4 of the
2026-09-26 design. `evidence_bundled` is redefined: a verified witness covers
the cell's records. The earlier definition (a ledger closure naming the
requirement with an evidence SHA) ties the top rung to plan bookkeeping, which
a public reader cannot check; a witness can be checked with the repository
alone. `absent` is an identifier a key or the baseline names that the extractor
does not emit.

**D7. The witness is an in-toto Statement with a test-result predicate.**
Subjects: sha256 of each litmus file and spec file. Predicate: platform, tier,
runner build id, source revision, per-test `PASSED`/`FAILED`/skipped. One
statement per (release or revision, platform). No host name, user name or
absolute path: a machine name is sensitive and must not be published. A
standard envelope is chosen over the ad-hoc JSON already under
`plan/attestations` so that stock tooling can read it. Signature: SSHSIG under
its own namespace, optional; the verifier reports `unsigned` or `signed`.
Alternative considered: Sigstore keyless signing. Rejected for now: it needs a
network identity provider at signing time and hosts must work offline.

**D8. The release baseline is committed, per cell.**
The release cut writes the cell rows for the tag (host stripped). The
non-increase check compares against that file. The per-checkout `last.txt`
stays as a within-checkout advisory.

**D9. A measurability register, checked.**
`observatorium/data/measurability.yaml`, one entry per level-5 obligation. An
entry claiming a measuring field that the grade lacks fails the check, so the
register cannot overstate.

## Risks / Trade-offs

- Tripling the denominator makes the first per-platform headline look worse.
  → Mitigation: it lands as a declared scope change with the per-platform
  counts beside it; the obligation-level count remains printable.
- Witness files add committed bytes each release. → One statement per platform
  per release; results are per test name, not per step.
- A witness proves a run was recorded against given bytes, not that the run was
  honest. → The strength is printed; an unsigned witness is labelled as such.
- Scenario keys are more work to write than requirement keys. → The
  bind-candidates report and the carried-obligation backlog spread the work.
- Platform lines in specs can be wrong. → A wrong narrowing hides cells, so the
  extractor's output lists every narrowed spec and the register page shows the
  list.

## Migration Plan

1. Reports only: policy fields, seven-key histogram, unbound census,
   measurability register (no behaviour change for any gate).
2. Scenario binding and platform scope, then platform cells. The headline unit
   changes here; land it at a release boundary and record the scope change.
3. Rungs, witness, committed baseline.
4. Site and public text.

Rollback at any step is a revert: nothing refuses a push.

## Operator decisions (2026-11-11, relayed by the coordinator)

- **This change is approved.** The umbrella row `2080-3tzc` is completed on
  that approval.
- **The denominator change is approved**: the unit becomes the (obligation,
  platform) cell, default scope all three platforms (D1, D3).
  **The cut:** the first release cut made after every row of the measure story
  has landed on trunk (tasks 1.1, 2.1, 2.2, 2.3, 3.1, 4.1, 4.2, 4.3, 6.1). It
  is stated as a condition and not a version, because cuts are made daily and
  the version is not known in advance. Before that cut the published headline
  stays in obligations. At that cut the snapshot records the scope change and
  prints both units once; after it, only cells.
- **Design floor hosts**: yoga (Linux), yolanda (Windows),
  tlatoanis-macbook-air (macOS). A platform cell's evidence is expected to be
  producible on that platform's floor host: a test that only a larger host can
  run does not fill the cell for the floor. Rows stay tagged by capability; the
  names are today's holders of the three floor roles.
- **Near-zero idle overhead; no polling; exponential backoff where waiting
  cannot be avoided.** Nothing in this change runs while idle. The witness is
  emitted once, at the end of a run that already happened. The grader and the
  site read committed files. No watcher, timer or daemon is added, and nothing
  waits for a witness from another platform: a missing witness is an
  `unmeasured` cell, not a wait.

## Open Questions

Left open by the operator on 2026-11-11. Each stands as proposed, the rows
proceed on the proposal, and row `2081-2wf3` carries them until ruled.

1. A record made inside WSL on a Windows host, or inside a forge container:
   which platform cell may it fill? Proposed, not ruled: the bare-metal host's
   platform for WSL; a forge record fills no cell unless the forge's host
   platform is passed in.
2. Which key signs a witness? An approval key needs a user check per signature,
   which does not fit an unattended gate. Proposed, not ruled: unsigned
   witnesses first, labelled; a per-host witness key later.
3. Does the non-increase check ever become a refusal, and against which number
   is that bar raise decided? Proposed, not ruled: it stays a report.

Not put to the operator and still to settle when task 5.1 is claimed: the
directory witnesses are committed to, and whether the plan-only push lane
should admit it.
