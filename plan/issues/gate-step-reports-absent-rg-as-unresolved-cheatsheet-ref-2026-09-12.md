# Gate step 165-1087-h2z9 reports "a cheatsheet reference does not resolve" when ripgrep is merely absent, so a tooling gap reads as a content failure and blocks the land

**Filed:** 2026-09-12 · **Host:** esmeraldinha (Windows 11 + WSL2 `tillandsias-build`, Fedora 44)
**Kind:** bug (false verdict) · **Tier:** floor · **Scope:** plan-only
**Relates to:** 1087-h2z9 (the step's wiring), 799-tb7q (the host-else-toolbox resolver), 1072-b7eq (gate steps are data)

trace: scripts/gate-steps.d/165-1087-h2z9.step
       scripts/check-cheatsheet-refs.sh
       scripts/check-cheatsheet-tiers.sh (the correct convention, for contrast)

## Claim

`scripts/check-cheatsheet-refs.sh` distinguishes its two failure modes by exit
code: **exit 2** = "ripgrep is available neither on this host nor in the
tillandsias-builder toolbox" (a tooling gap, nothing was checked), **exit 1** =
a reference genuinely did not resolve.

The gate step that wires it cannot express that distinction. Gate steps are
data (1072-b7eq) and carry exactly one `STEP_ERROR` string:

```
STEP_ERROR="a cheatsheet reference does not resolve (1087-h2z9)"
```

So **any** non-zero exit prints that sentence. On a host without `rg`, the gate
announces a content failure that was never observed, and refuses the land.

## Measured

`scripts/land-on-platform-branch.sh windows-next` on this host, 2026-09-12,
LAND_EXIT=3, origin/windows-next left at ca681cec9 (no damage). The verdict
line read:

```
[build] a cheatsheet reference does not resolve (1087-h2z9)
```

while the actual stderr, further down the same log, read:

```
error: ripgrep (rg) is available neither on this host nor in the
       tillandsias-builder toolbox. Install rg, or add it to the
       toolbox init set in scripts/with-tillandsias-builder.sh.
```

Confirmed `rg` absent in the `tillandsias-build` distro. Zero cheatsheet
references were examined. The verdict was not a wrong answer about the
cheatsheets — it was an answer about nothing at all.

Two aggravating details:

1. **The codebase already has the right convention and this step departs from
   it.** In the same gate log, the sibling tier check reports
   `skip:cheatsheet-tiers:cargo-absent (no toolchain on this host; check not
   run)` — absent tool reads as SKIP, not ERROR, explicitly. 799-tb7q had
   already called the old bare refusal "the mis-shaped" behaviour and added the
   host-else-toolbox resolver; the remaining gap is that when BOTH miss, the
   refusal is still shaped as a content failure.
2. **The step was triaged on evidence from one host class.** Its own comment
   says "Measured green and cheap on b026372ff", measured where `rg` is
   present. It was promoted from `--ci-full` to `--check` — "run it where every
   host lands" — without a host lacking `rg` in the enumeration. Green on the
   measuring host is not green fleet-wide.

## Unblocked locally, not fixed

`dnf install -y ripgrep` in the `tillandsias-build` distro (ripgrep 15.2.0,
the version 799-tb7q's comment names). That clears THIS host and is host state,
not a repo change. Every other host that lands `--check` without `rg` and
without a working toolbox hits the same false verdict.

## Exit criteria

- "on a host with no `rg` and no toolbox `rg`, the gate reports a SKIP naming
  the absent tool and does NOT refuse the land; pre-fix result: FAILS (LAND_EXIT=3
  with the content-failure sentence above)"
- "on a host WITH `rg` and a genuinely unresolvable cheatsheet reference, the
  gate still refuses and still prints the 1087-h2z9 sentence; pre-fix result:
  PASSES — this is the behaviour that must be preserved, and is why the fix
  cannot be 'drop the step'"
- "NEGATIVE CONTROL: the skip path is reached only when the checker exits 2, so
  an exit-1 content failure can never be silently downgraded to a skip"

## Shape of the fix (not made here)

The step data format needs a way to say "this exit code is a skip" — e.g. a
`STEP_SKIP_EXIT=2` field the runner honours, mirroring what
check-cheatsheet-tiers does in its own script. Worth deciding whether other
data-wired steps share the defect; this packet only measured this one.
Alternatively `with-tillandsias-builder.sh` grows `rg` in its init set, which
fixes the symptom on toolbox-capable hosts and leaves WSL/dnf hosts exposed.
