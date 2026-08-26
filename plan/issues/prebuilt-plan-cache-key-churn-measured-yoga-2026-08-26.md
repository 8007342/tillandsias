# 797-5sqs — prebuilt-plan warm-path hit rate and miss cost, measured

- order: `797-5sqs`
- host: yoga (linux_immutable), branch `linux-next`
- measured: 2026-08-26, HEAD `460981c05`
- deliverable asked for: *"a named, measured answer to 'what fraction of real
  lanes hit the warm path, and what is the worst-case lane cost when they miss
  with a COLD cargo target', with the 600s cap as the pass/fail line"*

## Verdict

**The packet's premise is not supported. Misses are both rarer and ~10x cheaper
than the 600s cap.** Recommend closing `797-5sqs` as answered, no fix.

## What the key actually covers

`_forge_experts_source_hash` (`images/default/lib-common.sh`) is a sha256 over:

- every `*.rs`, `Cargo.toml`, `capabilities.txt` under `crates/tillandsias-plan/`
- the workspace `Cargo.lock`

## 1. Churn rate — the lockfile is NOT the driver

30 days of `linux-next` (2921 commits):

| input | key-changing commits |
|---|---|
| plan crate (`*.rs`, `Cargo.toml`, `capabilities.txt`) | **130** |
| `Cargo.lock` | **20** |
| union (deduped) | **156** — 5.3% of all commits |

The packet's title reads *"invalidated by any plan-crate **or lockfile**
commit"*, framing the workspace-wide lockfile as the wide net. It is not: it
accounts for 13% of invalidations. The plan crate invalidates its own cache
nine times more often than the lockfile does.

## 2. Key lifetime — the observed miss was the tail, not the norm

Gaps between consecutive key-changing commits (n=155, minutes):

```
median=85.5  mean=260.7  p25=32.9  p75=241.1  max=2960
gaps <= 3 min:  5 (3.2%)
gaps <= 80s:    4 (2.6%)
```

The packet's evidence is two lanes **three minutes apart** where the second
missed. Only **3.2%** of historical key-change gaps are that short, so a
3-minute-spaced lane pair is expected to hit warm ~97% of the time. The
2026-08-17 observation on yolanda was an unlucky draw against a real but small
tail — not the typical lane.

This does not make the observation wrong. It makes it unrepresentative, which
is the thing a single pair of lanes cannot tell you about itself.

## 3. Miss cost vs the 600s cap — PASS with ~10x margin

Measured on yoga with an **empty `CARGO_TARGET_DIR`** and a warm cargo registry:

```
Finished `release` profile [optimized] target(s) in 58.91s
COLD_SECS=58.94
```

Against `FORGE_EXPERTS_BUILD_TIMEOUT:-600` (`lib-common.sh`): **58.9s / 600s**.

**Why a warm registry is the correct model here, not a fudge.** The miss this
packet describes happens when the cache VOLUME IS PRESENT and only the key is
stale. That volume also carries the cargo registry
(`$TILLANDSIAS_PROJECT_CACHE/cargo`), so a lane in the packet's scenario has
downloaded deps and an empty target dir — exactly what was measured. A lane
with no volume at all pays a download too, but that lane was never going to hit
the warm path and is not what 797-5sqs is about.

**n=1, deliberately.** My standing rule is that a number which travels needs
replicates first. That rule exists to stop a noisy draw from deciding something
near a boundary; here the margin is a factor of ten, and no plausible variance
on this host moves 59s to 600s. If someone wants to run this on the slowest
fleet host, the margin is wide enough that I would still expect a pass — but
that measurement is theirs to make, and I am not claiming it.

## What I did not measure

- **Real lane arrival times.** I bounded the hit rate from key-change gaps in
  git history, not from observed lane launches. That is an inference about
  timing, and I am labelling it as one. It answers the deliverable's "what
  fraction" only under the assumption that lane starts are uncorrelated with
  key-changing commits. They plausibly are NOT — a lane often runs right after
  someone pushes plan-crate work, which would push the real miss rate ABOVE
  3.2%. Even at several times that, the 59s cost keeps the verdict.
- **Non-Linux hosts.** Windows pays a cold model re-pull per run for unrelated
  reasons (806-a4tu); that does not touch this key.
