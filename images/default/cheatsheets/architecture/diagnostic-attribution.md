---
tags: [diagnostics, fail-loud, guards, debugging, observability]
languages: [bash, rust]
since: 2026-08-26
last_verified: 2026-08-26
sources:
  - plan/archive/packets-2026-08.yaml order:894-scxy
  - plan/archive/packets-2026-08.yaml order:886-qmdz
  - plan/archive/packets-2026-08.yaml order:887-bz88
  - plan/index.yaml order:889-twhe
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
---

# Diagnostic attribution: name the layer that FAILED, not the layer you OBSERVED

**A signal that names the wrong layer costs more than no signal.**

A missing signal leaves a reader searching. A *misattributed* one leaves them
searching **confidently, in the wrong place, and stopping when they find nothing
there**. That is why this is worse than silence, and it is the whole rule.

## The rule

When a check fails, it observes one layer and reports about it. The layer it can
see is often not the layer that failed. Before emitting a diagnostic, ask:

> Did the thing I am naming actually fail, or is it merely the thing I could see?

If you cannot tell the two apart, **the fix is a discriminator, not better
wording**. A discriminator is a cheap probe whose result differs between the two
causes. Without one, a confident message is a guess wearing evidence's clothes.

## Worked instances (all measured, 2026-08-25/26, one fleet, one night)

| # | The signal | The layer it named | The layer that failed | Cost |
|---|---|---|---|---|
| 1 | `gh`: "The token in keyring is invalid" | keyring | GitHub (401 on a healthy, unlocked keyring holding an intact 40-char token) | 3 hosts diagnosed the wrong subsystem; one built a mechanism on the premise; 2 published hypotheses had to be falsified |
| 2 | plan-only lane: "new capture was REFUSED" | the capture | the scratch tree's unfoldable BASE | 2 hosts hard-blocked reading a lane failure that was a ledger-setup failure |
| 3 | `gate-stamp.sh`: "~100-150 ms per spawn on Windows/MSYS" | Windows spawn cost | nothing — the number was unmeasured, 6-9x too high, and aimed at the wrong process (the gate runs in WSL at 0.69 ms) | a design justified by a ghost |
| 4 | credential guard: `blocked:gh-cli-only` on a branch merely BEHIND origin | the credential | ref state — a non-fast-forward the remote can only issue *after* authenticating | a hard cycle stop with an inert remedy |

Instance 4 is the **control**: it was fixed (886-qmdz), its replacement
`ok:gh-keyring-push-verified-refstate-refused` fired correctly on a different
host days later, and it stayed fixed. The class is real *and* tractable.

## How to build a discriminator

The pattern that worked in every case above: find a probe whose answer is
**different for the two candidate causes**, and make it cheap enough to run on
the failure path only.

- Credential rejected vs unretrievable → `gh api user`. 200 = the stored
  credential was accepted; 401 = it was rejected server-side. Runs only when the
  push probe already failed, so the healthy path pays nothing.
- Behind-branch vs bad credential → probe a fresh unique ref. A create is always
  fast-forwardable, so authentication is the only thing left that can fail it.
- Our refusal vs theirs → retry with the local hook out of the way.

**Do not extract a secret to discriminate.** `secret-tool search --all` prints
the value inline; two hosts put live `gho_` tokens into their own transcripts
learning that. Exit status carries the same information.

## Name the third state

Two-state classifiers silently mis-bucket a third. The credential case has
**three**, not two: rejected server-side, unretrievable locally, and *stored in
plaintext with no keyring involved at all* — where every keyring probe is
irrelevant rather than merely negative. Ask what else could be true before
shipping a binary answer.

## Verifying a mechanism is not verifying where it runs

A distinct sub-shape, measured three times in one evening by one host, all in
the same direction: **the mechanism was verified to the line number every time,
and where it runs was inferred.**

| Claim | Mechanism (verified) | Blast radius (inferred, wrong) |
|---|---|---|
| a gate fixture destroys uncommitted work | `test-gate-stamp-memoization.sh:208` runs `$ROOT/build.sh --check --install` against the real checkout — correct to the line | "any gate run with a dirty tree" — but the recurring cycle only runs `--check`, which is unaffected |
| the local-build e2e skill is exposed | `SKILL.md:107` runs `--ci-full --install` — correct | "`linux_mutable`, `macos` and `windows`, because the routing table sends all three to that skill" — but the skill branches on `uname -s`; macOS and Windows use different build commands entirely |

Routing to a *skill* is not routing to a *command*. Dispatch, branch selection,
and host routing are facts about the world that live **outside the file you are
reading**, and they are easy to treat as obvious in a way a mechanism never is.

So verify them **separately and by the same standard**:

- Which caller actually invokes this? (`grep` the callers, do not assume.)
- Does the invoking path *reach* this line — is it behind a branch, a flag, a
  host test?
- Which hosts run that caller, and does the routing table's destination
  branch again once it gets there?

**Why this matters beyond tidiness: a warning scoped wider than its defect gets
discounted the next time you send one.** Over-scoping is not the safe direction.
It spends credibility that the next real warning needs, and it sends readers to
check things that were never at risk.

## This applies to your own tests

The same defect appears in fixtures, where it is harder to see because the
result is green:

- an environment that quietly does not reproduce the condition (a stub that was
  never created, a missing dependency, a base that will not fold) — the fixture
  cannot fail, and reports that as a pass;
- an assertion that greps for a word and cannot tell an imperative from its
  negation ("do NOT go looking at secret-service" matching a test for "does not
  mention secret-service").

A green fixture that could not have gone red is a diagnostic naming the wrong
layer: it says "the property holds" when it means "I did not test the property".

## The specimen trap: a guard fired by the proof that it works

A string-matching guard will eventually match its own mutation control — the
deliberately-broken specimen you keep in the fixture to prove the guard is real.

**It has a nasty property: it appears at the exact moment you prove the guard
works**, so the instinct is to *weaken the guard* rather than scope it. That is
backwards. The specimen is evidence, not a defect; exclude the file where the
string is a specimen, and leave the guard's teeth alone.

Measured instances, all in one week and all in guards written to catch
misattribution:

| Guard | Fired on |
|---|---|
| "the diagnosis must not send readers to the keyring" | the sentence *"Do NOT go looking at secret-service"* |
| `check-bash-dialect` (bash-4 constructs) | a regex that *searches for* bash-4 constructs |
| "shipped diagnostics must not source the lib" | the comment explaining why they deliberately don't |
| "no caller may use the fixed-depth source path" | the mutation control demonstrating that it fails |

The order matters: **scope the check, then re-run the mutation and confirm it
still fails.** A scoping change is one keystroke away from a guard that no longer
catches anything, and the mutation control is the only thing that tells the two
apart.

## Rejecting a true mechanism because its cause is wrong

The ordinary error is naming a plausible contributor without measuring. There is
a rarer inverse, and it is more dangerous because refuting the cause *feels* like
refuting the claim — and the refutation is usually well-evidenced, which makes it
convincing.

Measured instance, 2026-08-26:

- One host offered "scratch usage grew where nobody was watching it," attributing
  it to a specific sibling change. **The attribution was wrong** — the arithmetic
  closed without it and the change moved data *out* of the pressured filesystem.
- The other host rejected the whole claim: *"it is fully accounted for by my own
  action"* — stated as fact while its shell could not run `quota -s`.
- On recovery, measurement showed **both wrong**. Their own builds were ~9.6 GB
  against a 24.96 GiB quota; a dead session from the previous day held 12 GB. The
  mechanism — unreaped scratchpads accumulating until any ordinary session tips
  it over — **was real**. Only the named contributor was not.

The packet filed from that exchange was a full scope too narrow, because the
mechanism went out along with the bad attribution.

**Split the two before you reject either.** "Your cause is wrong" and "your
mechanism is wrong" are different claims needing different evidence. And a
counter-claim you cannot measure is an inference too — label it as one, in the
same breath you demand that of someone else.

## When you are relayed a diagnosis

**N endorsements are not N evidence.** A relayed claim arrives carrying the
sender's weight, and a misattributed signal propagates faster than a correct one
because it sounds specific. Re-verify before acting — and re-verify a
*retraction* the same way, or you have merely changed which unchecked claim you
believe.
