# Level-5 obligation defects: research, fixes and plan rows (2026-11-11)

Order `2080` (umbrella `2080-3tzc`, 22 implementation rows). Spec proposal:
`openspec/changes/obligation-evidence-contract`. Source of the six points:
`plan/issues/observatorium-blind-design-2026-11-09/` (comparison, learnings,
derivation). The level-5 document itself is `docs/matrix/level-5-phd.md` in the
tillandsias.org repository, not this one.

Nothing proposed here refuses a push. Every new check is a report; turning one
into a refusal is a bar raise for the operator.

## Operator decisions, 2026-11-11 (relayed by the coordinator)

- The spec proposal `obligation-evidence-contract` is **approved**. The
  umbrella `2080-3tzc` is completed on that approval and its dependent rows are
  claimable.
- The denominator change to (obligation, platform) cells, default all three
  platforms, is **approved**. It takes effect at the first release cut made
  after every row of the measure story (story 1 below) has landed on trunk.
  Until then the published headline stays in obligations; at that cut the
  snapshot records the scope change and prints both units once.
- Design floor hosts are yoga (Linux), yolanda (Windows) and
  tlatoanis-macbook-air (macOS). A platform cell's evidence should be
  producible on that platform's floor host. This touches `2080-axw3` (its real
  records come from the floor hosts) and the reading of every platform cell.
- Near-zero idle overhead, no polling, exponential backoff where waiting cannot
  be avoided. Nothing in this order runs while idle: the witness is emitted
  once at the end of a run, readers consume committed files, and a missing
  witness is an `unmeasured` cell, never a wait. Recorded on `2080-h3mb` and in
  the change's design.
- Left open, standing as proposed, carried by row `2081-2wf3`: which platform a
  WSL or forge record fills; unsigned witnesses first; whether an increase ever
  refuses.

## What was measured, and where

Trunk `e1f8d7f01`, a Linux host, `scripts/centicolon-grade.sh` with a plan
binary built from that tree, no litmus results stream present (records=0):

```
ok:centicolon-grade:R=1574 satisfied=0 denominator=1574 declared=1569 traced=5 positively_tested=0 records=0
```

| fact | value | how |
|---|---|---|
| obligations | 1574 = 70 requirement-only + 1504 scenario | kinds in the extractor's output |
| invariants, extracted and not graded | 126 | same output |
| reason `no-binding` | 1569 | the static grader's output |
| obligations with a candidate step | 5 | same |
| litmus files / with a `requirement:` key | 629 / 3 | file count and a key search |
| specs in the bindings registry / tombstoned | 149 / 22 | `openspec/litmus-bindings.yaml` |
| rungs assigned by code | 3 of 7 | the `hist` table in the observed grader |

The exercise reported 1571 obligations, 1566 no-binding and 5 unrun at release
v56.11.7.1. Three scenarios were added since; the 5 read `unrun` there and
`candidate` here for the same reason (no green record). The figures agree.

Not measured here: any macOS or Windows run; any release-tier run; the
committed history rows beyond what the exercise quotes.

## Point 1 — `d_v` is never defined

**Finding.** The level-5 text writes `d_v = d(I_v, T_v)` and calls
non-increase the mechanically checkable release rule, then offers the residual
`R_S = Σ w_i (1 − C_i)` as "a proposed binary accounting contract". No file in
this repository defines `d_v`. The one live number is `R` from the `observe`
function in `centicolon-grade-observed.lua`: a count of obligations below
`positively_tested`. The weighted table in the methodology is read by no code;
`centicolon_function` and `Weights` in `obligation.rs` are called only by the
`score-checks` verb, over 16 gate check names, which is a different population.
The check that would enforce non-increase, `check-centicolon-ratchet.lua`,
compares against `last.txt` in an untracked output directory, so a fresh clone
has no baseline and no release is ever compared with another.

**Research.** GQM (Basili, Caldiera, Rombach) requires a metric to be derived
from a stated goal and question and to have an operational definition before it
is collected; a metric named in a rule with no definition fails at the
quantitative level by construction. The level-5 text already states the
measurement-theory condition itself: unit, scope and evidence policy fixed
across a comparison.

**Fix.** Define `d_v` as the count of required (obligation, platform) cells
below the bar under a named policy, `unweighted-positive-test/1`. That is `R_S`
with unit weights over cells. Print the policy name with every number. Label
the weighted table `not-implemented`. Compare releases only under one policy
name. Commit per-cell rows at each release cut and make the non-increase check
read them, reporting added, retired and regressed cells separately (the level-5
text's own point: non-increase of the total does not imply each credit is
kept).

**Optimization.** The committed history already carries a scope digest per
row, so scope change is derivable without new producer work; only the per-cell
rows are new.

Rows: `2080-46gg`, `2080-k87a`, `2080-kugs`.

## Point 2 — the binding population

**Finding.** The static grader marks an obligation `traced` only when a litmus
step carries a `requirement:` key naming its req-id. Three files of 629 carry
one. So the published "0 of N" measures the absence of keys, not the absence of
tests: 149 specs are already bound to litmus files at spec level in the
bindings registry. Second, the grader's `refs` table is keyed by req-id, so one
green requirement-keyed step promotes every scenario under that requirement
(the level-5 text names this: "scenario candidates are shared at requirement
level").

**Research.** Gotel and Finkelstein's analysis of the traceability problem
separates pre- and post-requirements-specification traceability and finds that
links decay unless creating them is part of ordinary work rather than a
separate task. That argues against a one-off binding drive and for a mechanism
that makes each change carry a link.

**Fix.** (a) Bind per scenario with a `scenario:` key; `requirement:` alone
earns `traced`. (b) Count unbound obligations per spec in one Lua check and
offer the count as a carried-obligation backlog at the advisory stage, so a
change touching a spec or a litmus file carries one binding. (c) Keep leading
the public page with the unbound count, as the rebuilt home page already does.

**Optimization.** Do (a) first, now: with 0 satisfied and 5 bound, changing
granularity costs nothing; after binding 1569 obligations it would cost a
rewrite. And generate candidates: a report that pairs each unbound scenario
with the enforced, reachable steps in litmus files already bound to its spec
turns most bindings into a review of a short list. The report proposes and
never writes a key, because whether a step tests a scenario is a judgement.

The pilot row `1395-64r7` (ready, two specs) should write `scenario:` keys and
so should follow `2080-4tg9`.

Rows: `2080-4tg9`, `2080-4yw9`, `2080-zsf5`.

## Point 3 — the seven-rung lattice is paper

**Finding.** `ObligationState` has seven variants and tests for their order.
The graders assign `declared`, `traced` and `positively_tested`. `absent` is
unreachable (the denominator is the declared set), and `negatively_tested`,
`runtime_observed` and `evidence_bundled` have no assigning code. Rules for
three of them were designed on 2026-09-26
(`plan/issues/centicolon-enforceable-metric-design-2026-09-26.md`, sections 4.3
to 4.5) and not built.

**Research.** In GSN an argument element with no supporting evidence is marked
undeveloped rather than drawn as supported; the notation makes "claimed, not
yet evidenced" a visible state. The same applies to a rung nothing can assign.
For the negative rung, mutation analysis is the standard evidence that a test
can fail: a test earns it by detecting a seeded fault.

**Fix.** The histogram always has seven keys and the grade lists
`unassigned_rungs` by name; the list shrinks as rules land. `absent` is an
identifier a binding key or the committed baseline names that the extractor
does not emit. `negatively_tested` and `runtime_observed` follow the 2026-09-26
rules, per platform. `evidence_bundled` is redefined as "a verified witness
covers the cell's records" (point 5): the earlier rule tied the top rung to
ledger bookkeeping a public reader cannot check.

**Optimization.** The negative rung reuses the mutation-arm name pattern and
the writes rule of `check-litmus-mutation-arms-mutate.sh`; the runtime rung
reuses the static grader's `tier_of` function. No rule is decided twice.

Rows: `2080-cjtf`, `2080-e36r`, `2080-e3ii`, and `2080-jfuf` for the top rung.

## Point 4 — status per (obligation, platform)

**Ruling (operator, 2026-11-11).** An obligation must hold independently on
each of Linux, macOS and Windows, since some hold only on some. Status is per
(obligation, platform). A platform-specific obligation declares its scope. An
aggregate never masks a platform failure.

**Finding.** The extractor emits no platform. The `observe` function keeps one
latest record per (step, digest) across every host and promotes on any green
one, copying `host` and `regime` into the output without using them. So one
Linux pass satisfies an obligation everywhere. Two further facts:

- `regime` is the runner's userland (`linux`, `darwin`, `msys`). A Windows
  host re-executes its gate inside WSL, so its records say `linux`. Regime
  cannot attribute a pass to Windows.
- The grading host reads only its own timing log. Records from other platforms
  never reach it, so even a per-platform grader would show two empty columns.

**Research.** The Rust project's platform support policy is the clearest
published precedent: a target is "guaranteed to work" only where automated
testing runs on that target after each change; "guaranteed to build" is a
separate, weaker tier; anything else "may or may not work". A claim is made per
target and its strength is the evidence that target has.

**Fix.** The extractor emits a scope per obligation: all three by default,
narrowed by a `platforms:` line in the spec's Status block or a comment beside
a req-id, closed vocabulary, unknown token refused. A result record names its
product platform in its own field. The observed grader holds one state per
cell; the aggregate is the minimum over required cells; a required cell with no
record reads `unmeasured`. The site prints the three platform counts with any
aggregate and its honesty check fails a page that omits them.

Default-all is chosen so that a forgotten declaration shows as unmeasured
cells, the safe direction. The cost is stated: the denominator moves from 1574
obligations to at most 4722 cells, a scope change to be reported at the release
it lands in.

**Optimization.** The minimum is the meet of the existing chain order, so
`SpecState`'s componentwise order extends to cells with no new type. Cross-
platform records arrive as witnesses (point 5), so the transport is built once.

Rows: `2080-5vcj`, `2080-axw3`, `2080-87z2`, `2080-mi5f`.

## Point 5 — no exportable witness

**Finding.** A pass exists as a line in a host-local timing log. Nothing
exported lets another host or a reader check it. `plan/attestations` holds a
precedent: per-platform JSON stamps with a command, a result and source file
digests, in an ad-hoc shape.

**Research.** The in-toto attestation framework defines a Statement that binds
a typed predicate to subjects identified purely by digest. Its test-result
predicate carries a result, the configuration and lists of passed and failed
test names, with the tested source artifacts as subjects. SLSA provenance
separates what was run (build definition) from who ran it (run details, a
builder id). SLSA's verification summary attestation lets a verifier publish
"checked against policy P, result R" so consumers need not see every input.
DSSE is the signing envelope those formats use.

**Fix.** A `tillandsias-plan` witness verb (Rust): emit one Statement per
platform run, subjects the sha256 of each litmus and spec file, predicate the
platform, tier, runner build id, source revision and per-test results. It
refuses a host name, user name or absolute path, because a machine name is
sensitive and must not be published. Verify needs only the witness and the
repository at the named revision; a subject whose bytes differ earns nothing.
A signature is SSHSIG under its own namespace and optional; the verifier prints
`unsigned` or `signed` and never inflates. The grader accepts verified
witnesses as record sources for every platform, which is how macOS and Windows
cells get filled on the host that cuts the release. The site publishes them
with the verify command and labels any cell without one "claimed by the
grader".

The grade as a whole, published per release, is then a verification summary:
policy name, inputs by digest, result.

**Optimization.** One mechanism serves three points: the cross-platform
transport (4), the top rung (3) and the public witness (5). Emission is
deterministic so the same stream yields the same bytes.

Rows: `2080-h3mb`, `2080-hnit`, `2080-jfuf`, `2080-n5z6`.

## Point 6 — eleven obligations unmeasurable as written

The derivation lists 13 items; 11 are single obligations and two are
cross-cutting (the public witness, covered by point 5, and the "89% closed"
wording, already handled by the site's honesty check). Disposition of the 11:

| obligation | why unmeasurable | disposition | row |
|---|---|---|---|
| L5-07 non-increase of `d_v` | `d_v` undefined | define it | `2080-46gg`, `2080-kugs` |
| L5-08 weighted residual | weights unused; two residuals | one policy, named; weighted labelled not-implemented | `2080-46gg` |
| L5-16 aligned weights across releases | no alignment rule | compare only under one policy name | `2080-kugs` |
| L5-13 required platform | no platform set | declared scope, cells | `2080-5vcj`, `2080-87z2` |
| L5-20 the configured bar | per obligation or global unstated | global, named by the policy | `2080-xvup` |
| L5-06 operator decision | no public evidence form | `approved_bar_raises` exists; export and check it | `2080-r6hs` |
| L5-10 cycle bound K | K never fixed | withdraw the number; print cycles since last decrease | `2080-xvup` |
| L5-24 complexity ratio | ratio of undefined quantities | define as counted lines over named globs, advisory | `2080-xvup` |
| L5-17 workstream residuals | workstreams have no obligations | withdraw until one has | `2080-xvup` |
| L5-05 stability | no exported signal | export `RefineOutcome` | `2080-y9c5` |
| L5-29 unknown-event intake | no count | export intake and classified counts | `2080-y9c5` |

**Research.** A GSN assurance case records each claim with its evidence or
marks it undeveloped. A register with that shape, checked by code, is the
general fix: the document may keep an obligation only with a measuring field or
an explicit `unmeasured` and the reason.

**Fix.** `observatorium/data/measurability.yaml`, 29 entries, with a Lua check
that fails on a missing entry or on a measuring field the grade lacks. Each row
above moves one entry. The public page then links the register.

**Optimization.** Withdrawing is cheaper than measuring and equally honest;
four of the eleven are proposed as withdrawals or plain declarations.

Rows: `2080-cpyd`, `2080-r6hs`, `2080-xvup`, `2080-y9c5`, `2080-zk9f`.

## Rows, in three host-cycle stories

Story 1, measure (v0.5): `2080-46gg` distance defined; `2080-4tg9` scenario
binding; `2080-4yw9` unbound census; `2080-zsf5` bind candidates; `2080-5vcj`
platform scope; `2080-axw3` platform in the record; `2080-87z2` platform
cells; `2080-cjtf` seven rungs; `2080-cpyd` measurability register.

Story 2, evidence (v0.6): `2080-e36r` negative rung; `2080-e3ii` runtime rung;
`2080-h3mb` witness emit; `2080-hnit` witness verify; `2080-jfuf` witnesses as
records and the top rung; `2080-k87a` per-cell release rows; `2080-kugs`
committed baseline.

Story 3, publish (mixed): `2080-mi5f` per-platform site counts; `2080-n5z6`
witness and register pages; `2080-r6hs` bar-raise records; `2080-xvup`
declare or withdraw; `2080-y9c5` stability and unknown events; `2080-zk9f`
public text.

Five rows depended directly on the umbrella's approval (and others through
them). It was given on 2026-11-11, so no row of this order waits on the
operator; each waits only on the rows it depends on.

## Not settled

1. **WSL and forge records.** Which platform cell may a record made inside WSL
   on a Windows host, or inside a forge container, fill? Proposed, not ruled:
   the bare-metal host's platform for WSL; none for a forge unless the host
   platform is passed in. The Windows floor host should confirm what the WSL
   run actually exercises. Carried by `2081-2wf3`.
2. **Who signs a witness.** An approval key needs a user check per signature
   and does not fit an unattended gate. Proposed, not ruled: unsigned first,
   labelled. Carried by `2081-2wf3`.
3. **Where witnesses are committed**, and whether the plan-only push lane
   should admit that directory. To settle when `2080-h3mb` is claimed.
4. **When the denominator changes.** Settled 2026-11-11: the first release cut
   after the measure story lands (see the decisions above).
5. **Whether non-increase ever refuses**, and against which number that bar
   raise is decided. Proposed, not ruled: it stays a report. Carried by
   `2081-2wf3`.
6. **Tests that are not litmus steps.** The grader sees only litmus files.
   Cargo tests and Lua fixtures earn nothing unless a litmus step runs them.
   Not addressed by this order; it may be most of the real test population.
7. **Invariants.** 126 are extracted and not graded. Out of scope here.
8. **`unknown event` record form.** `2080-y9c5` assumes the ledger records
   them in a countable way; that was not verified.
9. **`openspec` CLI.** Not installed on this host, so the change was written
   by hand in the layout of existing changes and `openspec validate` was not
   run.

## Sources

Fetched 2026-11-11:

- in-toto Statement v1: https://github.com/in-toto/attestation/blob/main/spec/v1/statement.md
- in-toto test-result predicate: https://github.com/in-toto/attestation/blob/main/spec/predicates/test-result.md
- SLSA provenance v1.0: https://slsa.dev/spec/v1.0/provenance
- SLSA verification summary attestation v1.0 (the page notes v1.2 is current): https://slsa.dev/spec/v1.0/verification_summary
- DSSE: https://github.com/secure-systems-lab/dsse
- Rust platform support tiers: https://doc.rust-lang.org/nightly/rustc/platform-support.html
- GSN Community Standard, version 3: https://scsc.uk/gsn-standard (the page confirms the version; the statements about undeveloped elements above are from the standard as recalled, not from this page)

Cited from memory, not re-read today:

- Basili, Caldiera, Rombach, "The Goal Question Metric Approach" (1994): https://www.cs.umd.edu/users/mvz/handouts/gqm.pdf (the URL returned a PDF whose text could not be extracted)
- Gotel and Finkelstein, "An analysis of the requirements traceability problem", ICRE 1994, doi 10.1109/ICRE.1994.292398
- DeMillo, Lipton, Sayward, "Hints on test data selection: help for the practicing programmer", IEEE Computer 1978 (mutation analysis)
- Knight and Leveson, "An experimental evaluation of the assumption of independence in multiversion programming", IEEE TSE 1986 (the shared-specification effect the exercise relies on)
