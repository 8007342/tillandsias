# Intake replay on real evictions — 2026-11-23

@trace order:2249-tif9, order:2248-zcqh

What the bundle intake gate (`./build.sh --changed <base> --intake`, 2248-zcqh,
#1391) would have said about every head the full gate evicted on macuahuitl
since 2026-11-19. Operator-approved bundle-landing design (2026-11-22); phase 2
is decided on these numbers.

## Method

- Input: 57 gate/preflight evictions from macuahuitl's queue logs (host-fault
  rc=255, conflict and carried-silent evictions excluded), with the evicting
  step for the 25 whose gate log still exists (logs before ~11-21 are pruned).
  Classes from the coordinator:
  - flakes: keep_id_warm #1295/#1320, browser #1330, and the timing leak
    #1345/#1349/#1369/#1378, which 2244-ge9s fixes;
  - host faults: #1248/#1287 (JOBS=6 lanes) and #1326 (podman tmpfs);
  - killed gates: rc=143/137;
  - no log: 28 rows.
  The file is `target/replay/heads.txt` on lenovinha; rows are reproduced below.
- Tool: `scripts/lua/replay-intake-on-evictions.lua -- <heads-file>`. For each
  row it takes the PR's own change (`git diff --name-only base...head`) and a
  detached worktree at the head, which carries that head's own fixture map. It
  then runs gate-changed.sh from #1391 there with `--list --intake --files`.
  Selection only: nothing executes in the head's tree.
- Scoring, code reds with a step only:
  - caught: the evicting fixture is in intake's run set;
  - caught-heavy: intake marks the member HEAVY, so the bundle gate runs it in
    full;
  - deferred: the fixture is named on the `deferred:` line;
  - missed: intake would pass it.

## Result

| | n |
|---|---|
| rows | 57 |
| scored code reds | 14 |
| caught (run set) | 10 |
| caught-heavy | 3 |
| deferred | 0 |
| **missed** | **1** |
| **recall** | **13/14** |
| HEAVY verdicts (all rows) | 26/57 (46%) |
| median selection time | 2.35 s |

**The miss: #1249 (5e60118f5).** It changed only `scripts/run-litmus-test.sh`,
and the gate refused it on the capability-row publish guard. Neither
`test-capability-row-check.sh` nor `test-pending-capability-row-does-not-wedge.sh`
is selected for that change. There are two explanations: the red was
environmental (the guard reads host state), or the fixture reads the litmus
runner without naming it. The kept log decides which; until then it counts as
a miss.

**HEAVY reasons** (22 distinct heads, current map): every one is a guard file;
none is an unmapped path.

| guard | heads |
|---|---|
| `build.sh` | 11 |
| tillandsias-plan sources | 5 |
| `scripts/with-tillandsias-builder.sh` | 3 |
| other shared libs | 3 |

HEAVY is the real cost lever. Most build.sh edits add one wired block, so
narrowing the build.sh guard would move about half of HEAVY into scoped intake.

## Not measured yet

- **Intake RUN time.** 2.35 s is the selection only. The selected sets are
  130-200 fixtures plus 1-17 crates per head, so executing them for 57 heads
  on one host would take hours. The post-land shadow on macuahuitl
  (`--run --intake` on each landed head, with nextest live there) gives the
  real wall time.
- **p (per change).** Of 14 scored code reds, 1 passes intake. p needs the
  denominator: the number of landings in the same window. With N landings,
  p ≈ 1/N for the scored window. The 28 no-log rows and the 2 "unknown" rows
  (#1246) are unscored either way.

## Raw rows

```
row 1240 57de80f19 class=code verdict=intake run=170 deferred=10 crates=3 judged=caught
row 1240 1315545e2 class=code verdict=intake run=191 deferred=10 crates=17 judged=caught
row 1241 a5eed555a class=code verdict=intake run=179 deferred=10 crates=3 judged=caught
row 1249 5e60118f5 class=code verdict=intake run=132 deferred=15 crates=1 judged=missed
row 1260 c317963ee class=code verdict=intake run=150 deferred=15 crates=16 judged=caught
row 1260 c317963ee class=code verdict=intake run=150 deferred=15 crates=16 judged=caught
row 1261 ba5c08801 class=code verdict=intake run=150 deferred=15 crates=16 judged=caught
row 1291 a8e1bdbce class=code verdict=heavy judged=caught-heavy
row 1301 26eb43deb class=code verdict=heavy judged=caught-heavy
row 1301 4eb4fc1fe class=code verdict=heavy judged=caught-heavy
row 1312 9317e6f77 class=code verdict=intake run=177 deferred=10 crates=3 judged=caught
row 1313 1eb1ee30c class=code verdict=intake run=196 deferred=10 crates=17 judged=caught
row 1314 aafe3e84e class=code verdict=intake run=190 deferred=10 crates=3 judged=caught
row 1358 6695e8ed0 class=code verdict=intake run=197 deferred=10 crates=8 judged=caught
summary rows=57 heavy=26 scored=14 caught=13 deferred=0 missed=1 recall=13/14 median_select_ms=2349
```

The full 57-row output (unscored rows included) is `target/replay/replay.out`
on lenovinha, and the tool reproduces it from the heads file.
