# the salvage audit's honest path is unreachable in production and its confident-wrong path is the default

- filed: 2026-09-19
- host: lenovinha-silverblue
- trace: order:1226-jb8y
- reproduction: yoga-silverblue
- criterion and fixture observation: lenovinha-silverblue

## The inversion, which is the finding

`scripts/salvage-audit.sh` fetches the ref namespaces it then enumerates, and a
fetch failure is **deliberately not fatal**:

```sh
git fetch -q "$REMOTE" "+${_pat}:refs/remotes/${REMOTE}/${_pat#refs/heads/}" 2>/dev/null || \
    echo "  note: could not fetch $_pat from $REMOTE; auditing locally-known refs only" >&2
```

There are two failure shapes and **the safe one cannot happen in production**:

- **TOTAL** failure, no local refs surviving: the audit reports
  `skipped:salvage-audit:no-refs:...`. Honest. But it requires an empty clone,
  and nobody audits from one.
- **PARTIAL** failure, local refs surviving an earlier fetch: the audit
  continues over whatever it already had and reports a **confident clean
  verdict**. This is the default state of every real host.

A guard whose honest path is unreachable and whose confident-wrong path is the
norm is a different class of defect from one that is merely sometimes wrong.

## Reproduced on demand (yoga, 2026-09-19)

Create a local ref under a dead remote so the namespace is non-empty, then audit
against that remote:

```
note: could not fetch refs/heads/work/* from deadremote-1226; auditing locally-known refs only
every ref is landed, superseded or stale — nothing outstanding.
ok:salvage-audit:1r:0w:0f:branch=origin/linux-next
```

**`ok:` and "nothing outstanding" over a namespace it just said it could not
read.** The guard whose entire purpose is that stranded work must not read as
landed asserts that nothing is stranded. Consumers read the verdict token, not
the note on stderr: a coordinator deciding a ref is safe to delete, a land tool,
a human.

## The fixture holds the evidence and never looks

`scripts/test-salvage-audit.sh` captures both streams — `out="$(... 2>&1)"`, and
so do its four other captures. The note is therefore **in `$out`**. And:

```
grep -c -e 'could not fetch' -e 'locally-known' scripts/test-salvage-audit.sh  ->  0
```

Twelve arms, and not one asks whether the world it graded was complete.

## Exit criteria

- A degraded read emits its **own verdict token** — not `ok:`. Whatever the
  spelling, it must not be the string a clean audit produces, because every
  consumer keys on that token.
- A degraded read does **not** print "nothing outstanding", or any positive
  claim about refs it did not fetch. Absence of evidence is not the evidence of
  absence, and this is the row where that distinction is load-bearing.
- NEGATIVE CONTROL: a complete read still reports `ok:` unchanged. A fix that
  makes every audit degraded-looking has removed the signal instead of fixing it.
- NEGATIVE CONTROL, second: the TOTAL-failure path keeps reporting
  `skipped:salvage-audit:no-refs`. It is already honest and must not be folded
  into the new token — two different states, two different verdicts.
- The fixture's live-state arms assert on the new token and **skip by name** when
  it is present, rather than grading a partial world. They must not grep the
  prose note; that is why the audit change comes first.

## Ordering

The audit first, the fixture second and dependent. The fixture has nothing to
key on until the token exists, which is why this is not a fixture patch.

## What is NOT claimed

This does **not** claim to be the cause of the two transient fixture failures
observed on yoga (ARM 2 in a gate, ARM 1b in the builder toolbox, each green on
re-run). The demonstrated mode produces `0w:0f`, which would have hit the
original ARM 2's `:0w:` **skip**, not its **FAIL** — so the observed signature
needs a partial read that still leaves differences. Mechanism demonstrated,
attribution open. Do not close those observations against this row without
evidence.

## Candidates for those observations: three eliminated, one REOPENED

Each killed by a measurement rather than an argument:

1. **relay-merge count** (lenovinha's) — ELIMINATED. yoga's failing gate audited
   the same population, 40 salvage + 29 work refs, and found zero direction
   labels.
2. **container versus host** — ELIMINATED. Byte-identical verdicts,
   `69r:23w:178f`, in both, and from two different checkouts.
3. **stderr capture loss** (lenovinha's) — ELIMINATED. The fixture captures
   `2>&1` at every one of its five invocations, so stderr loss cannot explain a
   failure inside it.
4. **branch age** (yoga's) — **REOPENED, and this is the row's methodological
   lesson.** It was recorded as eliminated on a sweep of current / 6h / 1d / 3d
   giving 28 / 25 / 24 / 16, reported as "monotonic but never reaches zero".
   "Never" was a claim about the unsampled remainder. Measured on lenovinha at a
   **7-day** baseline (`d6da54e90`):

       is-AHEAD           0
       ref-may-be-AHEAD   15576
       ABSENT-from        0

   ARM 2 greps the **literal** `is-AHEAD`, and `ref-may-be-AHEAD` does not
   contain it — `be-AHEAD` is not `is-AHEAD`. (Empirically, not by reading: one
   full-population run counted 28 and 152 from the same output.) So at that
   baseline differences exist, the verdict is not `:0w:`, the grep is false, the
   skip is false — **FAIL**. Branch age alone reproduces the observed signature,
   with no ref-population change and no degraded fetch.

   **It is NOT established as the cause.** yoga's failing gate ran against a
   branch that audits at is-AHEAD=28 today, on a host that had fetched minutes
   earlier and whose gate reported the same 69 refs. For branch age to be the
   cause there, `origin/linux-next` would have had to be roughly a week stale in
   that checkout at that moment. Live mechanism, unsupported explanation — two
   different claims, and both belong here.

THE ELIMINATION FAILED BECAUSE THE SWEEP STOPPED ONE SAMPLE SHORT of the answer.
That is worth more to a later reader than a clean list would have been.

Neither host could eliminate its own hypothesis: yoga killed lenovinha's
relay-merge story, lenovinha killed yoga's branch-age story — and then
lenovinha's own further measurement revived it. A single-host investigation
closes this as flaky at step one.

The trigger for those two observations remains uncharacterised, and `fetch
--prune` destroys the ref state that produced them, so it is not reconstructible
after the fact.

Note the reasoning hazard this row walked into and out of: the degraded-read
defect below was briefly argued for as "the last candidate standing". That is
not safe reasoning here, and it is now visibly unsafe — the standing depended on
an elimination that later failed. The degraded-read finding stands on its own
reproduction, and on nothing else.
