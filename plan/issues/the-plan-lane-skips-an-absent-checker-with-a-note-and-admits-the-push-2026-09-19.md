# the plan lane skips an absent checker with a note, and admits the push anyway — the measured-short shape in the lane itself

- filed: 2026-09-19
- host: lenovinha-silverblue
- scoped by: macuahuitl-fedora
- trace: order:1153-j2nm, order:1261-bn7v

## The shape

`attempt_plan_only_lane` calls each of its checkers guarded like this:

```sh
if [[ -f scripts/check-<name>.sh ]]; then
    ...refuse on failure...
else
    LANE_NOTES+=("scripts/check-<name>.sh absent — skipped")
fi
```

An absent checker does not refuse. It appends a note and **the push proceeds**.
So the lane admits a push it did not fully check, and records that fact only in
prose that nothing reads.

That is precisely the **measured-short** shape: a verdict that claims a scope it
did not cover. `ok:` is emitted either way.

## It is already guarded — but only where the fixture runs

`scripts/test-claims-fleet-visible.sh` ARM 1 exists for exactly this and it
works. Demonstrated on 2026-09-19, when 1261-bn7v wired a new checker into the
lane without adding it to the fixture's curated scratch-clone set:

```
FAIL: ARM 1: the lane skipped a checker as absent, so the lane was measured
short: plan-only lane: note: scripts/check-append-vs-origin-fold.sh absent — skipped
```

The arm caught it in the push path on the first tree where the new checker met
it. **Inside the fixture, the contract is enforced.**

On a real host, nothing enforces it. A checkout missing a lane checker — a bad
merge, a partial clone, a `git clean`, a checker renamed on one branch and not
another — pushes with a shorter lane and says `ok:`.

## Why the note is not a mitigation

The note goes into `LANE_NOTES` and is printed to stderr among the lane's other
output. Nothing parses it, nothing gates on it, and the verdict line does not
mention it. A consumer keying on the lane's result — which is what consumers do —
cannot distinguish a lane that ran eight checkers from one that ran six.

This is the same distinction the salvage-audit row turns on: **the artifact was
whole, and the world was not.** The lane completed; its coverage did not.

## Exit criteria

- An absent lane checker **REFUSES** the push rather than skipping it. "I could
  not check this" and "I checked this and it passed" are different claims and
  only one licenses an `ok:`.
- The refusal names the missing checker and the remedy, so a reader knows whether
  their checkout is broken or a checker was renamed.
- NEGATIVE CONTROL: a lane with every checker present still admits exactly what
  it admits today. A fix that refuses more broadly has replaced a silent gap with
  a loud one in the wrong place.
- NEGATIVE CONTROL, second: the **deliberately optional** cases, if any, are
  enumerated by name rather than covered by the same fallback. If every absence
  refuses, an intentionally-absent checker must be declared, not inferred from
  its absence — otherwise the first legitimately-optional checker reintroduces
  the fallback.
- `test-claims-fleet-visible.sh` ARM 1 stays green, and its curated list gains a
  comment stating what the list IS — already done at `ae4749426`, cited here so
  the fix does not undo it.

## Scope

This is about the LANE. The same guarded-call shape appears elsewhere and is not
in scope; widening it is how a narrow fix becomes a sweep nobody can review.
