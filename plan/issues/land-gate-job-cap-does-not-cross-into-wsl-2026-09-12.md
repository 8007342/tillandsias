# scripts/land-on-platform-branch.sh does not carry CARGO_BUILD_JOBS into the WSL gate, so a floor-tier land is OOM-killed rather than slow

**Filed:** 2026-09-12 · **Host:** esmeraldinha (ESMERALDINHA, N100 / 16 GB, Windows 11 + WSL2)
**Filed by:** esme-windows, at coordinator's order (macuahuitl-fedora, 2026-09-12)
**Tier:** floor · **Kind:** bug · **Scope:** plan-only (no crates/, no scripts/ edit in this packet)

trace: scripts/land-on-platform-branch.sh
       scripts/with-wsl2-builder.sh
       methodology/multi-host-development.yaml

## Claim

`scripts/land-on-platform-branch.sh <platform-branch>` runs its mandatory
`./build.sh --check` gate **inside WSL** — the gate log writes `/mnt/c/...`
paths — but nothing carries a `CARGO_BUILD_JOBS` cap across the `wsl.exe`
boundary. `with-wsl2-builder.sh` forwards only `TILLANDSIAS_*`. A cap exported
in the Windows-side shell is therefore **silently ignored** by the gate's cargo,
and on a 16 GB floor host the unbounded workspace compile is killed for low
memory.

The failure mode is the point: this is not "the gate is slow on the floor
tier", it is **the land dies**, after paying for a full workspace compile to
get there.

## Measured

Both runs on this host, same tree (windows-next carrying a 26-merge unpushed
set plus 8 un-gated union-debt records, so the gate was mandatory under
1056-5344), same checkout, nothing else running.

| attempt | exported | outcome | wall |
|---|---|---|---|
| 1 | `PATH` only | **KILLED, low memory**, mid-gate | died during workspace compile |
| 2 | `CARGO_BUILD_JOBS=2` **and** `WSLENV=CARGO_BUILD_JOBS/u` | `ok:land:ca681cec9:attempt-1`, gate green, pushed | 32m13s (02:46:49Z → 03:19:02Z) |

Attempt 1 left **no damage** — origin untouched at 8831f561a, tree clean, no
merge or rebase in progress. That is worth recording as correct behaviour: the
script commits the mandated `origin/linux-next` merge *before* gating, so an
interrupted gate loses only the gate.

Cap application on attempt 2 was verified by **concurrent `rustc` count inside
the distro** (`pgrep -c rustc` = 1, ≤ the cap of 2), not by timings — the
unbounded attempt showed 4. Timings cannot verify a cap on this host because
the drvfs I/O regime dominates.

## Why jobs=2 specifically

From this host's 2026-09-05 four-arm measurement (each arm alone on an idle
host, identical bounded recompile of the widest reverse-dependency set):

| arm | wall | vs unset | io_full peak | rustc_max |
|---|---|---|---|---|
| unset | 415 s | — | 45.64 | 4 |
| **jobs=2** | **427 s** | **+2.9%** | **15.99** | 2 |
| jobs=1 | 493 s | +18.8% | 42.45 | 1 |

**65% less io_full for 2.9% wall.** The curve is non-monotonic with an interior
optimum at nproc/2 — capping harder is not gentler: jobs=1 is 18.8% slower AND
barely reduces stall. Any fix must use a host-class value, not "1 is safest".

## Proposed fix

`land-on-platform-branch.sh` should carry the cap into WSL itself, from a
host-class table, rather than relying on every caller to remember. A bare env
var at the call site is the wrong shipped shape — the same conclusion order
1119-era work reached for `with-wsl2-builder.sh`: the cap belongs inside the
build scripts.

Minimum viable: when the script shells into WSL, set `CARGO_BUILD_JOBS` for the
gate and extend `WSLENV` so it crosses.

## Exit criteria

- "a floor-tier host lands with no cap exported at the call site and the gate's
  cargo runs at the host-class cap; pre-fix result: FAILS (attempt 1 above ran
  unbounded, rustc_max 4, and was OOM-killed)"
- "the applied cap is verified by concurrent `rustc` count inside the distro,
  not by wall time; pre-fix result: N/A (no cap was applied to verify)"
- "NEGATIVE CONTROL: a host whose class table says unset still gates unbounded
  — the fix must not cap hosts that do not need it, since jobs=2 costs 2.9%
  wall and is a floor-tier trade, not a fleet default"

## Not in this packet

- The 0-byte musl guest placeholder warnings the same gate emits are **1122-xi2f**
  (and per coordinator also 1126-w8rq); not duplicated here.
- No `scripts/` edit is made by this packet — it was filed during a release cut
  freeze on authored `crates/`/`scripts/` changes reaching linux-next.

---

## AMENDMENT 2026-09-12 — the cap is necessary but NOT sufficient

A second land on this host was OOM-killed **with the cap crossing correctly**.
The orphan process left behind names where it died:

```
cargo test --workspace --no-fail-fast --manifest-path .../Cargo.toml -- --test-threads=1
```

The gate died in the **test** phase, not the compile phase. `CARGO_BUILD_JOBS`
is a compile-parallelism cap and has no authority over test-binary residency;
tests were already serial at `--test-threads=1`. This is consistent with the
earlier finding that compiling is only ~14% of a green floor gate and the test
phase is the freeze.

**So the fix proposed above would have been believed and would not have
worked.** The honest claim is two claims:

1. The cap must cross into WSL — real, fixes the compile phase, measured.
2. The workspace test phase needs its own floor-tier memory story — **open**.
   I do not know the right lever and will not guess one. It wants measurement:
   peak RSS per test binary, whether any single test dominates, and whether the
   harness kill threshold is reached by one binary or by their sum.

Also measured, and relevant to any budget built on this host: **WSL is capped at
~7942 MB**, half the 16 GB box. The gate's real budget is 8 GB, not 16, and
`ollama serve` is resident in the other locus throughout.

A further operational note: the orphaned `cargo test` **survived the harness
kill** and continued holding ~120 MB. Clear stray `cargo`/`rustc` in the distro
before retrying a killed land, or the retry starts already short.

Neither kill damaged the repo: origin untouched both times, tree clean, no
merge or rebase in progress, because the script commits the mandated
`origin/linux-next` merge before gating.

### Additional exit criterion

- "a floor-tier land survives the workspace TEST phase, not merely the compile
  phase; pre-fix result: FAILS (killed with the cap correctly applied)"
