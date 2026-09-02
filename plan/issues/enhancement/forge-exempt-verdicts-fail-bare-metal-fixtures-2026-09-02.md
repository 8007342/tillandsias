# enhancement: guards that legitimately answer `skip:forge-exempt` / `unavailable:` are consumed by fixtures that expect the bare-metal grammar

- **Date**: 2026-09-02
- **Classification**: enhancement (forge lane; gate reliability)
- **Status**: ready
- **Discovered by**: forge meta-orchestration cycles 2026-09-02T20:30Z and 21:10Z (macuahuitl-tillandsias-forge)
- **Related**: order 964-fwvh (two instances fixed), order 923-ws3r (could-not-run vs violation), order 850-bif2 / 889-ewvt

## The pattern

THREE separate gate fixtures failed on this forge in one session, all for the
same structural reason and none for a defect in the thing under test:

1. `test-pre-push-empty-ref-list` — installs a spy hook at
   `<repo>/.git/hooks/pre-push`, and the forge image sets `core.hooksPath`
   globally, which replaces that directory for every repo on the host. The spy
   was written, git never ran it, five arms read `<none>`. Reported as "the
   plan-only fast lane's acceptance path is unproven". FIXED (964-fwvh).
2. `check-capability-row.sh fixture` — the ephemeral-identity guard runs at top
   level, before the `case` dispatch, so `fixture` was refused for lacking a
   stable host identity even though it supplies its own. Reported as "a stale
   row can be consumed as a current fact again". FIXED (964-fwvh).
3. `litmus:build-cache-sweep-trigger` — `check-build-cache-sweep.sh` correctly
   answers `skip:forge-exempt` on an ephemeral forge (its `target/` dies with
   the container, so there is nothing to sweep), and the litmus step expects
   the pinned bare-metal verdict grammar. OPEN — this issue.

## Why it is one defect and not three

Each guard has an honest verdict for "this question does not apply here" —
`skip:forge-exempt`, `unavailable:forge-identity-ephemeral`. The guards are
right. What is missing is that their FIXTURES and CALLERS were written on hosts
where that branch never fires, so the exempt verdict reaches an assertion that
only knows the applicable-host grammar.

The cost is not the red itself. It is that every one of these reports a defect
in the SUBJECT ("a stale row can be consumed as a current fact again") rather
than in the environment, which is the most expensive shape a red gate can have:
it sends the reader to audit correct code. Order 923-ws3r already drew this
distinction once for the archiver, separating "violation" from "could not run"
into different exit codes precisely because the merged message pointed at
neither.

## Reduction candidates

1. **A shared exempt vocabulary the fixtures know about.** The verdict grammars
   already carry `skip:` and `unavailable:` prefixes; a fixture asserting a
   guard's grammar should accept them as a valid branch and assert the REASON
   token instead of demanding an applicable-host verdict.
2. **Run each fixture's exempt branch deliberately.** A fixture that never
   exercises `skip:forge-exempt` cannot notice that its caller mishandles it.
   The exempt path deserves a positive case, the same way 964-fwvh's fix added
   one for the `.claude` locus.
3. **Audit the remaining guards for the same shape** before another forge finds
   them one at a time. `check-daily-maintenance.sh` (`skip:forge-exempt`) and
   `check-build-cache-sweep.sh` are the two that name forge exemption
   explicitly; the `unavailable:` family is wider.

## Verifiable closure

A forge cycle runs `./build.sh --check` AND the `meta-orchestration` litmus
spec green with no fixture failing for an exempt-verdict reason, and each
guard's exempt branch has a positive fixture case that would fail if the caller
regressed to demanding the applicable-host grammar.

## Note on scope

Instances 1 and 2 were fixed in-cycle because they blocked the gate this forge
needed to push at all. Instance 3 does not block `--check` (which runs no
litmus) and is filed rather than fixed, so the pattern gets decided once rather
than patched a fourth time.
