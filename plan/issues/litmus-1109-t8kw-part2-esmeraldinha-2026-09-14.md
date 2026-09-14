# 1109-t8kw part 2 — the closure measurement on an AT-RISK floor-tier host

Order 1109-t8kw part 2 asks for the closure artifact `verifiable_closure`
names and nobody had pasted: both litmus specs run on a host where the
git-identity probe prints AT-RISK, with the pass/fail counts and the probe
output recorded together.

**Result: the closure is NOT met.** Both specs are red. This document says
which failures are the packet's own subject, which are floor-tier budget,
and which I could not classify — because "12 red" is not a finding until it
is broken into those three.

trace: plan/index.yaml order 1109-t8kw (next_action item 2)

---

## Regime, stated before any verdict

Every line below was produced at the **Windows / Git Bash (MINGW) locus**,
which is the AT-RISK one on this host. This matters more than usual here:

- `LOCUS_UNAME=MINGW64_NT-10.0-26200`
- Invoked `scripts/run-litmus-test.sh` **directly**. NOT through `./build.sh`,
  which re-execs into the `tillandsias-build` distro — and that distro reads
  **SAFE** on the same probe. The two loci of this one host disagree, so a
  verdict without a locus is not a measurement.
- `TILLANDSIAS_HOST_TIER` is **unset**, not `low-end`. esmeraldinha is
  floor-tier by the operator's tiering; the env var is the selector's routing
  and not this row's precondition (macuahuitl's reading, recorded as theirs).
- HEAD at run time reported `26ed73ba9`, an empty commit **tree-identical** to
  `d7db273f3` (same tree `50c60c5c3`). It was a stray local artifact, since
  removed; the tree under test is `d7db273f3`'s. Recorded rather than quietly
  corrected because the log says one SHA and the branch now says another.

### The AT-RISK probe, embedded in the same run as the verdicts

Not cited from an earlier run — re-executed inside the same script that ran
the litmus tests, so the evidence carries its own precondition:

```
PROBE_INIT_RC=0
PROBE_COMMIT_RC=128
PROBE_VERDICT=AT-RISK
PROBE_FIRSTLINE=Author identity unknown
TIER=[unset]
```

The full text git gives is `unable to auto-detect email address (got
'bullo@Esmeraldinha.(none)')` — the `(none)` domain is the cause. There is no
global `user.name`/`user.email`; this repo commits only because it carries a
**repo-local** identity, which a scratch checkout does not inherit. That is
exactly the predicate the packet is about.

---

## Counts

| spec | PASS | FAIL | SKIP | executed | rate | elapsed |
|---|---|---|---|---|---|---|
| meta-orchestration | 20 | 3 | 1 | 23 | 86% | 510s |
| forge-environment-discoverability | 15 | 9 | 1 | 24 | 62% | 1163s |

`START_UTC=2026-09-14T17:21:19Z`, `END_UTC=2026-09-14T17:49:12Z`.
Both specs `Status: [FAIL]`, runner rc=1.

**The three originally-filed instances are green at this locus**, which is the
one useful positive: `committable-branch-guard-shape` passes 7/7, including
step 4 "a checkout with NO git identity fails closed with
blocked:no-git-identity" — the arm whose precondition actually bites here.
The rewritten capability-manifest fixture is treated separately below.

---

## Classification of the 12 failures

### A. This packet's own shape — a host-inherited precondition the arm never constructs (6)

**1. `credential-channel-check-shape` step 8/10** — the only one I proved
causally rather than inferred.

The arm pins `env PATH=/usr/bin:/bin`. On MINGW, git lives at
`/mingw64/bin/git`; `/usr/bin/git` and `/bin/git` are both **absent**, so
`check-credential-channel.sh` runs with no git at all and cannot resolve the
`insteadOf` mirror config.

```
PATH=/usr/bin:/bin              -> rc=1 out=missing:no-credential-channel
PATH=/mingw64/bin:/usr/bin:/bin -> rc=0 out=ok:forge-git-mirror
```

One variable, red to green. The guard is **correct**; the fixture did not
build the world it asserts about. This is next_action item 1(d) — tools
assumed present — on a locus where the assumed path is wrong rather than the
tool missing.

**2-5. Four arms failing on `jq: Bad JSON in --rawfile text /proc/self/fd/0:
Could not open /proc/self/fd/0`.** MSYS has no `/proc/self/fd`. Affected:
`forge-plan-expert-build-shape` 10/17, `methodology-path-query-citability`
18/21, `expert-groundtruth-harness` 18/31, `expert-capability-skew-honesty`
16/29. All four are BEHAVIOURAL arms piping through jq by fd path. Not
classified further: I did not reproduce each one individually, and the shared
error text is a symptom match, not membership — the row's own converse rule.
Counted here because the text names a platform facility, but whoever fixes
them must reproduce each.

**6. Two arms contaminated by git's CRLF warning** — `salvage-net-roundtrip`
9/9 and `expert-refresh-cargo-target-shape` 2/3. Both captured
`warning: in the working copy of '<file>', LF will be replaced by CRLF the
next time Git touches it` **into the verdict variable** and compared it
against an expected `ok:` token. Note `salvage-net-roundtrip` step 9 failed
with **rc=0** — the command succeeded and the fixture still scored it red,
because it graded stderr as the verdict. That is the packet's shape with a
sharper edge: not a missing precondition but a channel the arm did not
separate.

### B. Floor-tier budget, NOT assertion failures (2)

- `build-cache-sweep-trigger` step 1/15 — **[TIMEOUT]** at a 30s step budget;
  the runner reports `31.0s (killed at budget — censored; the true time is
  longer)`.
- `capability-manifest-guard` step 1/1 — **[TIMEOUT]** at a 300s step budget,
  `300.6s (killed at budget — censored)`.

**`capability-manifest-guard` is one of the three originally-filed instances,
rewritten at af7529a26 under 1114-p2ht. It did NOT assert false here — it ran
out of time.** That distinction is the whole point: this is not evidence the
fix regressed, and reporting it as "the capability-manifest fixture is red
again" would have been wrong in a way that costs someone a wasted
investigation. What it IS evidence of is that a 300s single-step budget does
not fit the floor tier, which is a separate finding and arguably 1109-t8kw's
sibling: a fixture that assumes it is running on a fast host is also asserting
a property of its environment.

### C. Not classified — red with EMPTY output (3)

`plan-answer-envelope-citability` 6/21, `citation-frame-and-caller-relation`
8/8, `project-answer-synthesis-refusal-typed` 3/10. Each produced
`expected=ok:<token>` and `output=` with nothing after it. An empty output
distinguishes nothing: a genuine assertion failure, a missing MCP server, and
a swallowed error all look identical. I am not guessing which. Whoever takes
these must re-run with the arm's output captured to a file rather than into a
compared variable — the same lesson the CRLF pair teaches from the other side.

---

## What this does and does not close

- It **does** supply the closure artifact's measurement: both specs run at an
  AT-RISK locus with counts and the probe output, which had never been pasted.
- It **does not** close 1109-t8kw. `verifiable_closure` requires both specs to
  **pass** on an AT-RISK, floor-tier host. They do not: 12 failures, of which
  **6 are new instances of this packet's own shape**, 2 are floor-tier budget,
  3 are unclassified.
- The 6 in group A are candidates for part 1's enumeration, and they were
  found by running rather than by grepping — which suggests part 1's predicate
  sweep will undercount, since none of these six would be caught by scanning
  for `git init`-without-identity.

Nothing was edited. Part 2 is a measurement, and a measurement that fixes what
it measures cannot be re-run against the thing it graded.
