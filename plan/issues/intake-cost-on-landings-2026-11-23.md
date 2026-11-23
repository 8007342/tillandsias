# Intake cost over real landings — 2026-11-23

@trace order:2249-tif9, order:2256-mvmy, order:2248-zcqh

The phase-2 question for the bundle-landing design: **what fraction of typical
changes get intake ≤ ~1/3 of a full gate?** This answers it on lenovinha, from
measured intake runs and a model priced over every landing since 2026-11-19.

## Measured (lenovinha: 16 cores, 13 GB, nextest 0.9.152)

Full gate, `./build.sh --check` on trunk bef93adad: **2030 s**, green
(macuahuitl does it in 631 s, about 3.2x faster; the shares carry over, the
seconds do not). One third of a full gate is **677 s**.

| sample | kind | fixtures (serial/pool) | crates | intake | share of full gate |
|---|---|---|---|---|---|
| #1384 plan follow-up | plan-only | none (plan lane) | — | 13 s | 0.6% |
| #1380 | single-crate Rust | 110 (85/25) | 3 | 383 s | 19% |
| #1361 | wide Rust | 191 (143/48) | 16 | 618 s | 30% |
| #1382 | small scripts, 5 files | 175 (122/53) | 4 | 644 s | 32% |
| #1389 | scripts, 10 files | 179 (124/55) | 4 | 700 s | 34% |

Each run used the selector from #1406 (2256-mvmy) over the merge's own tree, so
the fixtures are the ones that existed then.

Where the time goes in a scoped run:
- serial fixtures, 175-402 s;
- the pool, 59-151 s;
- Rust 32-68 s (warm build 0.3-15 s, nextest 31-48 s, doctests 1-5 s);
- headless feature passes 73-126 s when headless is selected.

Residual reds were all explained and none were intake's:
- `test-gate-changed-selects-by-input` followed the harness's inherited
  `TILLANDSIAS_GATE_CHANGED_ROOT` (2260-qw67);
- `check-no-competing-gate` read the harness as a gate (2260-qw67);
- `build-stack-ledger` hit this host's offline cargo cache, a host fault.

Two intake defects found by these runs are fixed in 2256-mvmy:
- the pool parallelised fixtures that `--check` never overlaps (false reds);
- a serial row's `wait` deadlocked on the loop's own process substitution
  (a 46-minute hang).

## Model

`t = 2.6 s × selected fixtures + 52 s if any crate + 95 s if headless + 10 s`

- 2.6 s per fixture: serial and pool cost about the same per fixture; the pool
  buys little today.
- 52 s for any crate: build, nextest and doctests.

Error on the four scoped samples: +6, -11, -5, +16%.

## Priced over every landing (first-parent merges of origin/linux-next since 2026-11-19 00:00 PST)

Tool: `scripts/lua/cost-intake-on-landings.lua`, which runs `--list --intake` on
each landing's tree (selection only). A diff entirely under `plan/` is priced
as the plan lane, 13 s.

| set | n | plan-lane | scoped | HEAVY | ≤ 1/3 of a full gate |
|---|---|---|---|---|---|
| real PR landings | 176 | 11 | 105 | 59 (34%) | 116/116 non-HEAVY; **66% of all** (HEAVY counted as not under) |
| all landings incl. plan-only adoptions | 262 | 97 | 105 | 59 | 202/202 non-HEAVY; **77% of all** |

Scoped intake over real PR landings: p10 251 s, p25 482, **p50 531**, p75 602,
p90 643, max 674.

The top decile sits within the model's ±16% error of the 677 s line, so read it
as "≤ 1/3, with the top ~10% borderline". Scaled to macuahuitl (÷3.2), scoped
intake is p50 ~166 s and p90 ~200 s.

## What it means for phase 2

- **HEAVY is the binding constraint (34% of PRs), not scoped intake time.**
  2250-gwfy moved only build.sh's block-only share. The rest is guard files:
  tillandsias-plan sources (kept wide on purpose: the plan binary runs every Lua
  fixture), with-tillandsias-builder.sh and the shared libs.
- **Scoped time scales with the selected-fixture count**, and two levers cut it:
  - the .step series (2253-j2at onward): inline blocks become pool-safe steps;
  - 2261-8gx5, narrower derived inputs. A 5-file scripts change selects ~175
    fixtures because 129 fixtures read the whole `scripts/` directory, mostly
    through dynamic paths (`"$ROOT/scripts/${name}.sh"`).
