# The selector discarded the query's exit code, so a stale binary read as a drained ledger (order 643-bnag)

- Date: 2026-08-10
- Host: windows (windows-next), meta-orchestration cycle 5
- Class: `optimization/` — counterfeit completion, second occurrence
- Related: `632-retq` (same defect, different door), `632-39p3` (introduced the trigger)

## The same failure, walking back in

Order `632-retq` fixed `scripts/select-work-batch.sh` reporting
`refused:no-eligible-work` — the greedy loop's **terminal state** — when `jq` was
missing. The fix added a jq preflight guarding that one dependency.

Six hours later the same counterfeit was reachable again through a different
door, and it was live rather than hypothetical:

```
$ scripts/select-work-batch.sh windows          # with jq present
refused:no-eligible-work:query returned nothing for role windows
```

The ledger was not drained. The query had **failed**:

```
$ tillandsias-plan query --status ready --claimable-by windows --json
error: unknown query flag: --claimable-by
$ echo $?
2
```

`--claimable-by` landed with `632-39p3` a few hours earlier. Any host whose
`tillandsias-plan` predates that commit — including this Windows checkout — got a
clean exit-2 failure from the binary and was told the plan was empty.

## The binary was not at fault

This is worth stating plainly, because the instinct is to blame the tool. The
binary behaves exactly as it should: it names the unknown constraint on stderr
and exits non-zero. Every piece of information needed to diagnose the problem was
produced.

The script threw all of it away:

```bash
raw="$("$PLAN" query … --json 2>/dev/null)"    # stderr discarded
[ -n "$raw" ] || { echo "refused:no-eligible-work:…"; exit 1; }   # exit code never read
```

`2>/dev/null` discarded the reason and `[ -n "$raw" ]` inferred health from
output volume. Under that test, *every* failure mode of the query — stale binary,
unreadable ledger, permissions, a panic — is indistinguishable from an empty
result set.

## Why the earlier fix did not catch it

`632-retq` guarded a specific dependency (`jq`) rather than the general shape.
That was the narrower lesson available at the time, and it left the pattern
intact: infer health from output rather than branch on the tool's own verdict.
A preflight enumerates the failures you thought of. An exit-code check covers the
ones you did not.

## Fix

`scripts/select-work-batch.sh` now captures the query's exit code and stderr:

- non-zero with `unknown query` in stderr → `refused:stale-plan-binary:` naming
  the binary path and the rebuild command;
- non-zero otherwise → `refused:query-failed:` quoting the exit code and the
  actual stderr line;
- zero and empty → `refused:no-eligible-work:`, which now means what it says.

The `unknown query` match is deliberately loose: the wording is version-dependent
(an older binary says "unknown query **flag**", a newer one says "unknown query
**constraint**"). Pinning either exact phrase would silently degrade the
diagnosis to the generic branch on half the fleet — which is the same
failure-in-a-direction-nothing-observes this guard exists to prevent.

Also fixed while here: argument validation now precedes environment probes.
`--budget 0` on a jq-less host was refusing with `missing-tool`, so one bad
invocation produced different diagnoses on different hosts, and the litmus's
bad-budget control only genuinely tested hosts that happened to have jq.

## Pinned by

Three steps added to `litmus:cycle-batch-triage-shape`, each two-sided (the right
token must appear **and** `no-eligible-work` must not):

- a stub binary that fails like a stale one → `stale-plan-binary`;
- a stub that fails some other way → `query-failed`, with the reason quoted;
- `--budget 0` under an absent jq → `bad-role:budget`.

`TILLANDSIAS_PLAN_BIN` was added as a test seam. Without it these refusals are
untestable on hosts whose binary is current — which is exactly the hosts CI runs
on, and exactly why the hole survived its first fix.

## Note on the Windows blocker

For three cycles this host's drain has been reported as blocked on `jq`
(`632-retq`). That diagnosis is now incomplete: **two** independent faults gate
it. Even with jq installed, the local binary is too old for `--claimable-by` and
the selector would refuse — now loudly, with the rebuild command, instead of
claiming the plan is empty.
