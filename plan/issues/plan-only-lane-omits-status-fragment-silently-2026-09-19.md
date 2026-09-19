# The plan-only lane can push a claim's notes without its status flip and still report ok:

- **Found:** 2026-09-19, esmeraldinha (esme-windows), while landing 793-zumy.
- **Tool:** `scripts/push-plan-fragments-to-trunk.sh`, default (non-explicit) selection.
- **Severity:** a claim can read as landed while trunk still offers the row to every other host.

## What happened

Four fragments were carried to trunk and the lane reported success:

    ok:fragments-on-trunk:8dee1b4dae4662e04d86d70a5d0d2c9efb0d48d4:4

The four were two `note` events and two `next_action` writes. The **status
fragment was not among them** — `plan/index.d/20260918t201646z-2d627a14-esme-windows.yaml`,
the `field: status` flip `ready -> in_progress` produced by
`tillandsias-plan set-field`. It was not refused and not skipped: **no note
reached stderr naming it**, and the verdict line was indistinguishable from one
that had carried it.

Verified the way the methodology specifies — computed against trunk, not
grepped — by extracting trunk's `plan/index.yaml` + `plan/index.d` and running
the tool there:

    793-zumy	ready	accel-probe-blind-to-wsl2-paravirtualised-gpu

So after an `ok:` verdict, trunk still offered a claimed, in-progress row. On
this particular row that is the exact failure the claim existed to prevent:
793-zumy had already been handed back twice by hosts that could not run it, and
yolanda had written a PICKUP RULE into `next_action` specifically to stop a
third. The prose landed; **the selector does not read prose.**

Pushing the same path explicitly worked first time:

    scripts/push-plan-fragments-to-trunk.sh plan/index.d/20260918t201646z-2d627a14-esme-windows.yaml
    ok:fragments-on-trunk:01e0b951009f5fc953d3a46f551f26a6df71def2:1
    # then, computed against trunk:
    793-zumy	in_progress	…      and `next windows | grep -c 793-zumy` → 0

So the bug is in the DEFAULT candidate set, not in the carrying.

## Why the default selection missed it

    git ls-files --others --exclude-standard -- plan/index.d plan/loop_status.d
    git diff --name-only --cached --diff-filter=A -- plan/index.d plan/loop_status.d
    git diff --name-only --diff-filter=A "$base" HEAD -- plan/index.d plan/loop_status.d

The status fragment was **committed** (in `68f5a76f4`) rather than untracked or
staged, and did not surface as an add against `$base` after this branch had
merged trunk. The four that did ride were all written later in the session. The
exact `$base` resolution is the thing to fix or to prove correct; what is
certain is that a committed-earlier fragment can fall out of the default set
while later ones ride.

## Why this is the same shape as a guard that already exists

The script already refuses `status-loss` for the terminal case: pushing a
`completed`/`obsoleted` event without its status fragment would "leave trunk
offering a closed row as ready — the 1127-apa8 shape". This is that shape one
step earlier in the lifecycle: pushing a **claim's** events without its status
fragment leaves trunk offering a claimed row as ready. Same consequence, same
cause, and the existing guard does not cover it because it keys on terminal
events only.

## Suggested remedies (not implemented here)

1. Extend the `status-loss` refusal: if the carried set contains any event for a
   packet whose status on trunk disagrees with the local fold, refuse and name
   the missing status fragment. This covers claims, not just closures.
2. Make the verdict self-describing: `ok:fragments-on-trunk:<sha>:<n>:<s>` where
   `s` is how many carried a `field: status`. A count of 0 on a run whose local
   fold flipped a status is the signal a human could catch.
3. At minimum, emit the same stderr `note:` for a default candidate silently
   dropped as is emitted for one skipped by the lane grammar. A silent drop and
   a noted skip must not look identical.

## Control worth adopting generally

The methodology's own control for a claim is `tillandsias-plan next <role> |
grep -c <order>` reading 0 **on a trunk checkout**. Reading the lane's `ok:`
line is not that control, and tonight the two disagreed. Anyone whose claim
matters should compute the status against the ref they mean.
