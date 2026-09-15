# 1187-iij8 — the floor-tier measurement, and why neither proposed fix works

1187-iij8 assigns this host the measurement half: "esme has the AT-RISK,
low-end locus and can measure; a capable host lands the runner change." This
is that measurement.

**It does not support the row's framing, and I am reporting that rather than
the number it expected.** The dominant variable for the fixture I could time
is not host tier and not filesystem — it is FILE-CACHE WARMTH, which the same
host crosses in both directions within one session. A tier-scaled budget
cannot fix a quantity that varies 72x on one machine with no code change.

trace: plan/issues/litmus-1109-t8kw-part2-esmeraldinha-2026-09-14.md (group B)

Regime: Windows / Git Bash, `MINGW64_NT-10.0-26200`, the floor tier. Host
quiet at each timing (`cargo`/`rustc` process count 0, checked in-script).
No absolute wall-clock is used as evidence; every number below is an elapsed
duration.

---

## 1. The fixture is correct. Only the clock was ever in question.

`build-cache-sweep-trigger` step 1, run directly, uncontended, twice:

```
GATE_RUN1_RC=0  GATE_RUN1_S=6
GATE_RUN2_RC=0  GATE_RUN2_S=5
verdict = ok:build-cache-sweep-not-due:bytes=19886478336:gib=18:marker=…:reason=…
```

Correct verdict, correct grammar, **5-6 seconds against a 30s budget**. The
group B classification holds: this was never an assertion failure.

## 2. But the same fixture took 285s hours earlier, and the difference is the cache

The first timing pair gave `du -sk target` 152s and the gate script 285s.
Those two ran CONCURRENTLY — I started the second while the first was still
running, which is the contention error this whole row is about, committed
while measuring it. They are discarded as evidence and recorded only as an
upper bound.

The serial re-run above gives 5-6s. So one host, one tree, no code change,
produced 285s and 5s. Contention explains part of it; it does not explain
two orders of magnitude.

**The mechanism, measured on a comparable tree:**

```
/c/Users/bullo/.cargo/registry   1,609,520 KiB   50,322 files
  first pass  : 433s
  second pass :   6s
```

**72x, same directory, same command, seconds apart.** And note that tree is
*smaller* than `target` (1.6 GiB vs 18.5 GiB) while having *more* files
(50,322 vs 45,537) — so the driver is neither size nor file count. It is
whether the filesystem metadata is already in the Windows file cache.

`du -sk` must stat every file; a cold stat walk on this filesystem is
pathologically slow, and a warm one is trivial. `find -type f | wc -l` over
warm `target` is 2s, which is why the cost looked implausible at first.

### Honest defect in this probe, recorded because it bounds the number

The cold probe runs `find` over the tree to count files BEFORE timing `du` on
it — so `find` warms the metadata `du` is about to read. **433s is therefore a
LOWER bound on the true cold cost, not a measurement of it.** This is the same
shape as everything else this packet family is about: the step that spoils the
measurement is the step the measurement needed. It does not weaken the
conclusion (the delta is 72x in the conservative direction) but the number
should not be quoted as "the cold cost".

## 3. What I could NOT measure, and why

`capability-manifest-guard`'s single step rebuilds capability artifacts from a
private source copy. Timing it uncensored means running that build on the
floor host — a release-build cost this host's standing selection rule
excludes, and a number produced by a contended or reaped build is not one a
budget should be set from. **Not measured. Not estimated.** A capable host
should take it, and should take it cold and warm, because §2 says the two
readings will differ by more than the budget.

## 4. Correction to my own group B claim

Part 2 filed those two reds as floor-tier budget misses. They ARE timeouts and
the fixtures do pass — but I asserted more than the instrument supported.
The runner's own contention discriminator reads cgroup `cpu.pressure`, and at
this locus there is no cgroup. Both of my timeouts printed:

```
cpu.pressure unavailable in this cgroup — cause UNCLASSIFIED
(slow step vs starved step); no fallback instrument
```

So "genuinely too slow" was **never established** for either arm. By contrast
yoga's 1192-xv4n measurement carries the runner's own
`step NOT contended at kill time` verdict on a quiet host. Those two rows do
not have equal evidential weight and 1187-iij8 should not treat them as a
matched pair: yoga measured a fixture that is genuinely slower than its
budget; I measured a fixture that is fast when warm and hopeless when cold.

## 5. Consequence for the row's two options

- **(b) budgets scale with the declared tier — does not work, and would
  mislead.** The variable is cache warmth, which is not a property of the
  host's tier. A fat host with a cold cache misses the budget identically;
  this floor host with a warm cache beats it by 6x. A multiplier keyed on
  `TILLANDSIAS_HOST_TIER` would scale a constant that is not the problem, and
  worse, would make the red *rarer* rather than *clearer* — it would still
  fire, just less predictably, which is harder to diagnose than today.
- **(a) tally BUDGET distinctly from FAIL — is the better option**, and it is
  the one that survives this measurement, because it does not require anyone
  to predict the duration at all. It reports what happened instead of
  asserting a threshold.

  **(a) must reconcile with an existing decision, which the row does not
  mention.** Order 820-c8q8 deliberately settled that a timed-out step still
  FAILS: *"Reported, never used to change the verdict: the step still FAILS,
  because a step that cannot finish inside its budget has not passed."* I read
  a distinct BUDGET tally as compatible — naming the outcome is not the same
  as passing it — but that is the claimer's call to make explicitly, not a
  detail to discover halfway through.

## 6. The population, for whoever sets the numbers

Enumerated across `openspec/litmus-tests/`:

- 423 files, **2,521 declared step budgets** (2,522 grep hits minus one, a
  comment in `litmus-freshness-inventory-shape.yaml` documenting the runner's
  own parse regex — counted and excluded rather than silently included).
- **2,084 of them are at or below 30s**; 437 above.

Insertion points, cited by symbol: the budget is parsed in
`run_litmus_test_file()` (the `timeout_ms:` regex branch) and converted to
seconds once in the same function before the `timeout --kill-after` call. One
conversion site covers every step including the four implicit 30s defaults, so
either option has a single place to live.

---

## Summary

| question | answer |
|---|---|
| is build-cache-sweep-trigger's fixture correct? | yes — rc=0, correct verdict |
| its cost, warm and uncontended | **5-6s** against a 30s budget |
| its cost cold | ≥285s (contended); mechanism shown at 433s→6s on a comparable tree |
| is the driver host tier? | **no** — same host, 72x swing on cache state |
| capability-manifest-guard | **not measured** — needs a build this host excludes |
| were the two part 2 timeouts proven "too slow"? | **no** — UNCLASSIFIED; the discriminator needs a cgroup |
| which option survives the measurement | **(a)**, subject to reconciling order 820-c8q8 |

Nothing was edited. Released back to `ready` with these numbers on it: the
runner change belongs on a capable host, and this host cannot compile for it.
