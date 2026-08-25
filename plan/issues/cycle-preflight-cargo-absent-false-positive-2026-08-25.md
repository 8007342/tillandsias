# `blocked:preflight:plan:cargo-absent` fired on a host that has cargo — and self-cleared

- Date: 2026-08-25
- Host: linux_immutable (Fedora Silverblue, ostree-booted), branch `linux-next`
- Class: `research` (unexplained terminal verdict; observability gap)
- Owner: unassigned

## Observation

First tool call of the cycle, 20:27 UTC:

    scripts/cycle-preflight.sh  ->  blocked:preflight:plan:cargo-absent   (rc=1)

Corroborating probes in the same window all agreed the toolchain was absent:

    command -v cargo rustc   -> nothing
    ls ~/.cargo/bin          -> no output
    ls ~/.rustup /nix        -> absent
    target/                  -> absent

So the verdict looked like the GENUINELY-ABSENT case that order 876-irn7
explicitly preserved, and the cycle was treated as blocked.

~30 minutes later, with nothing installed or changed by this cycle:

    ls -la ~/.cargo/bin      -> populated, mtime 13:30 today (BEFORE the cycle started)
    cargo --version          -> cargo 1.98.0 (797e8a9bc 2026-08-05)
    scripts/cycle-preflight.sh -> ok:cycle-preflight:rebuilt+expert-absent+services-ok:degraded:image-missing:build-inference

`./build.sh --check` (whose line 48 does the same `$HOME/.cargo/bin` PATH export
that preflight's 876-irn7 fallback does) compiled and ran the workspace tests
successfully during that same window.

## Why this matters

876-irn7 narrowed a false positive by resolving `$CARGO_HOME/bin` and
`$HOME/.cargo/bin` before declaring absence. That fallback was present in the
script that answered `blocked:` here, and the directory it probes existed with a
working `cargo` in it at the time. So this is a SECOND false-positive shape that
the 876-irn7 fix does not cover, on the one verdict that stops a cycle outright.

Unattended, this costs a whole cycle and reads to a human as a missing toolchain.

## Smallest next action

Make the verdict self-diagnosing rather than guessing at the cause: on the
absence path, have `cycle-preflight.sh` print (to stderr, keeping the one-line
verdict grammar intact) the evidence it used — `$CARGO_HOME`, `$HOME`, the
candidate dirs it probed, and each dir's `test -d` / `test -x` result. A
terminal verdict that cannot be re-derived after the fact is a verdict nobody
can act on; the next occurrence then names its own cause instead of costing
another forensic cycle.

Hypotheses worth recording but NOT resolved here (do not fix on a guess):
sandboxed/limited-visibility `$HOME` in the harness's first shells; a home-dir
mount or automount not yet settled at that point; a concurrent rustup operation.
