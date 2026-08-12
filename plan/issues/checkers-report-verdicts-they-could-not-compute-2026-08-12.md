# Two checkers report a VERDICT when they could not run — one false all-clear, one false alarm

- Order: 702-68zj
- Class: enhancement
- Filed: 2026-08-12, windows host, branch `windows-next`
- Found by: meta-orchestration cycles 9 and 10, one instance each, both while
  the checkers were being used for their actual purpose

## The class

A checker that cannot execute must say **that**, not answer the question anyway.
Both instances below emit a normal, actionable verdict when their dependency is
missing or unusable, and in both cases the verdict is wrong in the direction
that costs the most.

This project already has the right convention and applies it elsewhere:
`build-guest-binaries.sh --verify` emits `verify:skip-stale-staging` (order
447), and `check-tray-import-surface.sh` emits `skip:no-tray-binary` /
`skip:no-import-reader` (620-duta). These two scripts predate or missed it.

## Instance 1 — `check-stranded-in-progress.sh` reports a false ALL-CLEAR

Live on this host right now:

```
$ scripts/check-stranded-in-progress.sh
summary: in_progress=0 stranded=0 threshold_events=0

$ tillandsias-plan status 184
184  in_progress  secure-channel-maturity-ladder

$ tillandsias-plan expire-claims --dry-run
expire-candidate  184  secure-channel-maturity-ladder  2026-08-11T05:40:00Z
summary: in_progress=1 expired=1 unknown_age=0
```

The sweep says zero; the ledger says one; the expiry tool agrees with the
ledger. The same script reported `in_progress=1 stranded=1` one cycle earlier
with the ledger unchanged.

Cause: the binary probe takes the first match of
`./target/release/tillandsias-plan`, `./target/debug/tillandsias-plan`, then
PATH. On a Windows host with a shared checkout, a WSL build leaves a **Linux
ELF** at `./target/release/tillandsias-plan` alongside the usable
`tillandsias-plan.exe`. The probe picks the ELF, `query` fails with
`Exec format error`, stderr is discarded, `rows` is empty, and empty rows are
counted as zero stranded packets. The two explicit early exits (`jq` absent, no
binary found) print the same all-zero summary for the same reason.

Why this instance is the worse of the two: the script's stated purpose is
catching work that is *invisible in both directions* — `ready` queries skip an
`in_progress` packet and burndown does not count it. A sweep that reports zero
because it could not look makes that work invisible in a third way, and does it
while printing the exact line an operator reads as "checked, nothing there".

## Instance 2 — `check-fragment-closure-evidence-added.sh` reports a false ALARM

Cycle 9, blocking `./build.sh --check`:

```
violation:closure-without-evidence:3
[build] this change adds a fragment recording a closure with no evidence-bearing event (686-7qcm)
```

No fragment in that change recorded a closure. The plan binary was stale and
lacked the `closure-evidence-check` subcommand; the binary said so clearly on
stderr — *"the ARTIFACT is stale relative to the checkout: rebuild it"* — and
the wrapper turned that into a violation count. Rebuilding produced
`ok:closure-evidence:3`.

The binary's diagnosis was correct and already written. The wrapper discarded it
and substituted a wrong one.

## Smallest next action

Give both scripts a third verdict and use it:

- `check-stranded-in-progress.sh`: probe the plan binary by RUNNING it
  (`capabilities` or `--help`), not by testing an executable bit that lies on a
  shared Windows/WSL checkout; on failure or missing `jq`, emit
  `summary: unavailable:<reason>` instead of an all-zero line. Prefer a
  platform-appropriate binary rather than first-found.
- `check-fragment-closure-evidence-added.sh`: distinguish a non-zero exit that
  means "violations found" from one that means "subcommand absent"; emit
  `skip:stale-plan-binary` and pass, since a stale artifact is host state, not a
  ledger defect (the same ruling order 447 made for staging).

## Verifiable closure

- With `jq` removed from PATH, and with an unusable plan binary, the stranded
  sweep emits `unavailable:` and NOT an all-zero summary.
- **Negative control**, load-bearing: with both dependencies present and a
  genuinely stranded packet in the ledger, it still reports that packet — a fix
  that emitted `unavailable:` unconditionally would satisfy the first check
  while disabling the sweep entirely.
- The closure gate run against a deliberately stale binary emits
  `skip:stale-plan-binary` and exits 0; against a current binary and a real
  evidence-free closure fragment it still fails.

## Related

- 672-bz7u — `expire-claims`, whose disagreement with the sweep is what exposed
  instance 1.
- 641-e2qa — why the stranded sweep exists at all.
- 447, 620-duta — the skip-verdict convention both instances should follow.
