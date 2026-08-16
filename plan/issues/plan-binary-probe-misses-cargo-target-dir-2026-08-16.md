# `plan-binary-probe.sh` never consults `CARGO_TARGET_DIR`, so every Windows cycle using the WSL2 builder refuses its own freshly built instrument

- classification: optimization
- filed: 2026-08-16 (windows/ESMERALDINHA, cycle 2)
- status: **fixed in this commit** — probe extended; defect recorded because the
  family keeps recurring and this instance has an inverted cause
- related: order 704-zcgi (the shared probe this extends), 721-nyev
  (`-x` is a claim, running is evidence), 702-68zj (two earlier in-place fixes),
  770-ifeg (the generic run-don't-stat probe),
  `plan/issues/windows-host-tooling-hits-linux-elves-in-target-2026-08-16.md`

## Symptom

On a Windows host, with a healthy toolchain and a clean checkout:

```
$ bash scripts/with-wsl2-builder.sh scripts/cycle-preflight.sh
[wsl2-builder] Re-execing inside 'tillandsias-build' WSL2 distro...
blocked:preflight:plan:capabilities-refused      # exit 1
```

`blocked:preflight:*` means "do not start the cycle". **The cycle can therefore
never start on this platform** — not for a bad binary, but for a path.

## The binary was fine

Measured immediately after the refusal:

```
$ /root/.cache/tillandsias-wsl2-target/tillandsias/release/tillandsias-plan capabilities
capabilities_exit=0
capability_count=35
```

Built, runnable, and declaring 35 capabilities. Supplying it explicitly turns
the same command green with no other change:

```
$ TILLANDSIAS_PLAN_BIN=<that path> bash scripts/cycle-preflight.sh
ok:cycle-preflight:rebuilt:ok:dev-inference-started:qwen2.5:0.5b:nomic-embed-text
```

So the instrument was healthy the whole time, and preflight had even brought the
dev inference endpoint up. Only the resolution step failed.

## Cause

`resolve_plan_binary()` probes exactly five candidates:

```
./target/release/tillandsias-plan.exe
./target/debug/tillandsias-plan.exe
./target/release/tillandsias-plan
./target/debug/tillandsias-plan
$(command -v tillandsias-plan)
```

`scripts/with-wsl2-builder.sh` sets `CARGO_TARGET_DIR` to a **distro-native**
path (`/root/.cache/tillandsias-wsl2-target/<repo>`) and documents exactly why:

> `TILLANDSIAS_WSL2_TARGET_IN_TREE=1` — keep cargo target/ in the checkout
> (default: distro-native `CARGO_TARGET_DIR`; **9p-backed target/ makes cargo
> crawl**)

So on the default path there is **no `./target` at all** — verified, the
checkout has none — and every candidate misses. `cycle-preflight.sh` runs
`cargo build --release -p tillandsias-plan`, succeeds, then asks a probe that
cannot see what it just built.

## Why this instance is worth filing even though it is fixed

This is the fifth member of a family, and the first with an **inverted cause**.
The previous four (704-zcgi's three, plus `select-work-batch.sh` arriving from
another host with a fresh copy) were all *re-implemented* probes: the call site
wrote `[ -x ./target/release/tillandsias-plan ]` itself and got the Windows/WSL
ELF-vs-`.exe` question wrong. The centralisation fix was "stop re-implementing;
source the shared probe."

Here the call site does everything right — it sources the shared probe, exactly
as 704-zcgi prescribes — and the **shared probe is the thing that looks in the
wrong place**. Centralisation moved the bug rather than removing it, because the
probe encodes an assumption (`the binary is under ./target`) that the build
wrapper deliberately violates for performance reasons.

**Two correct mechanisms disagreed, and neither is wrong on its own.** Keeping
`target/` off 9p is right; probing `./target` was right until the day it wasn't.
That is the shape worth remembering, not the individual path.

## Fix applied

`resolve_plan_binary()` now probes `$CARGO_TARGET_DIR/{release,debug}/
tillandsias-plan[.exe]` **before** the `./target` candidates, when that variable
is set. The probe's discipline is untouched — candidates are still accepted by
RUNNING `capabilities`, never by an executable bit — and the
`TILLANDSIAS_PLAN_BIN` override still short-circuits on existence alone, so the
stale-vs-absent distinction the litmus corpus depends on is preserved.

Verified: `bash scripts/with-wsl2-builder.sh scripts/cycle-preflight.sh` with no
override now returns

```
ok:cycle-preflight:rebuilt:ok:dev-inference-ready:qwen2.5:0.5b:nomic-embed-text
```

## Residual (not closed by this fix)

`resolve_plan_binary` is one of several probes; `plan_binary_has` and the
generic 770-ifeg `resolve_target_binary` share the same `./target` assumption.
They were not touched here because no caller has hit them from a wrapper-built
tree yet, but they will. A follow-up should route every one of them through a
single candidate-directory list that consults `CARGO_TARGET_DIR` once.

Suggested closure for that follow-up: a litmus that sets `CARGO_TARGET_DIR` to a
scratch dir containing a working stub, empties `./target`, and asserts every
probe in `plan-binary-probe.sh` resolves — exit code is the verdict.

## Cost recorded (lower-bound host)

Diagnosing this consumed a full cold build cycle on the floor host:
`./build.sh --check` 11m35s (at `-j4`) plus `cycle-preflight.sh` 21m for the
cold `tillandsias-plan` build. On a fat host the same defect costs a couple of
minutes and is easy to shrug off; here it is a third of an hourly cycle, which
is exactly why the floor host surfaces it.
