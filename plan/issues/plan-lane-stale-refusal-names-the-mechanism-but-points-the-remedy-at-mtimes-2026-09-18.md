# the plan lane's STALE refusal names the validator-surface mechanism and then points the remedy at mtimes

- filed: 2026-09-18
- host: lenovinha-silverblue
- requested by: macuahuitl-fedora
- trace: order:1152-y3bv, order:1129-4su6

## The refusal, verbatim

```
plan-only lane: REFUSED — the resolved plan binary is STALE (full gate required)
  resolved: ./target/release/tillandsias-plan
  via:      validator-surface hash — validate-yaml/check --strict-fragments/the
            fragment checkers' own sources changed since this binary was built
            (1152-y3bv); a change elsewhere in the crate or in the workspace
            Cargo.lock would NOT have triggered this
  newer:    scripts
```

## What is wrong with it

The `via:` line is **correct and precise**. The `newer:` line is the problem:
`newer: scripts` is the vocabulary of an **mtime** comparison, and it sits
directly under a line explaining that the verdict came from a **hash**. A reader
does what the last line tells them.

There is no remedy line at all. The actual remedy —

```
scripts/check-plan-binary-current.sh      # prints stamped:plan-binary-validator-surface:...
```

— appears nowhere in the message. It is named in the *other* branch of
`_lane_staleness_check` (the rc=2 mtime-fallback case), which is not the branch
that fired here.

## Two wrong turns, measured — this is the evidence

I hit this on a plan-only push and the message sent me the wrong way twice
before I read the source:

1. **Rebuilt the binary.** `cargo build --release -p tillandsias-plan` — Finished.
   Pushed. Still refused.
2. **Checked mtimes**, because `newer: scripts` says to.
   `find crates/tillandsias-plan Cargo.lock -type f -newer <binary>` → nothing.
   `find scripts -type f -newer <binary>` → nothing.
   By the mtime test the binary was already fresh. The message was pointing at a
   comparison that was not the one failing.

Only reading `_validator_surface_verdict` showed the mechanism: a **stored
stamp** is compared against a **current hash**, and an incremental rebuild
produces a new binary *without re-minting the stamp*. The binary was current and
the stamp was not — a state the message has no vocabulary for.

Third attempt, after `scripts/check-plan-binary-current.sh`: admitted
immediately.

## Why it is worth fixing rather than learning

The refusal is on the **plan lane**, which is the lane hosts use while trunk is
frozen or a gate is red — i.e. exactly when a host has least slack. And a
rebuild is the obvious first move, costs a minute, and *does not work*, which
teaches the reader that the message is unreliable rather than that they
misread it.

This is a diagnostic-attribution defect, the class this milestone exists for: a
message that names its mechanism accurately and then hands the reader the wrong
instrument.

## Exit criteria

- The refusal emitted by the **validator-surface** branch prints the remedy
  `scripts/check-plan-binary-current.sh` explicitly, on its own line.
- It does **not** print `newer: <path>`, or prints it under a label that cannot
  be read as an mtime claim — the surface-hash branch has no "newer file" to
  name, and offering one invites the wrong experiment.
- NEGATIVE CONTROL, and it is the one that matters: the **mtime-fallback**
  branch (rc=2, no stamp recorded yet) keeps ITS remedy and does not acquire the
  stamp remedy. The two branches fail for different reasons and must not
  converge on one message — collapsing them would fix this instance by making
  every future one ambiguous.
- A fixture asserts each branch's text separately, so a later edit cannot make
  one branch emit the other's remedy.

## Not in scope

The staleness logic itself is correct and this row does not touch it. 1129-4su6
is right that a stale binary can accept a fragment shape the current rules
refuse; the verdict is doing its job. Only the message is wrong.
