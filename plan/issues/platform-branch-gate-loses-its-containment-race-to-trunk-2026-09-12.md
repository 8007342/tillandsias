# A floor-tier platform-branch land cannot win a containment race against trunk, and the race is mostly invisible because the tool retries

**Filed:** 2026-09-12 · **Kind:** bug (structural) · **Priority:** p2 · **Unclaimed**
**Capability tags:** multi-host, land, gate, floor-tier
**Hosts measured:** ESMERALDINHA (floor tier, N100/16GB) and yolanda (capable Windows host)

trace: `scripts/land-on-platform-branch.sh`
       `scripts/hooks/pre-push-local-gate.sh` — the containment refusal
       methodology `pull_merge_cadence.pre_push_gate`

## Claim

`pull_merge_cadence.pre_push_gate` requires that a non-linux-next branch contain
`origin/linux-next` at the moment of the push. `land-on-platform-branch.sh`
satisfies that by merging trunk, then gates, then pushes. On a host whose gate
takes tens of minutes, trunk can move between the merge and the push, and the
land is refused for a containment that was true when it was established.

The gate stamp is valid. The premise underneath it has expired. Retrying
re-merges and re-gates, which re-opens a window of the same width.

## Measured

**esmeraldinha, 2026-09-12.** Land started 09:13:34Z, merged `origin/linux-next`,
gated 39 minutes, pushed at 09:52:56Z:

```
refused:land:push-failed — not a lost race, so retrying cannot help:
pre-push: refused — windows-next does not contain origin/linux-next
  (8a45bd5229d085b2a4326b4522a145618ada3585).
```

Trunk had advanced to `8a45bd522` during the gate. A green floor gate on this
host is 21m41s–25m17s at best; this one was 39 minutes. Trunk moved several
times an hour through this cycle. The next attempt — merge `8a45bd522`, gate
again — succeeded at 10:30:46Z only because trunk happened to hold still for 37
minutes.

**yolanda, same night** (their measurement, their words): attempt 1 passed its
gate and lost the push; attempt 2 carried it.

## Why the incidence cannot be counted from failures

This is the part that decides how the packet is read, and it is yolanda's
observation: **the same race produces a visible refusal or an invisible delay
depending on where in the window trunk moves.**

- esmeraldinha refused on containment — loud, logged, countable.
- yolanda's attempt 1 passed its gate, lost the push, and the tool retried
  automatically. From outside that is not a race at all; it is "that land took
  a while".

So any incidence figure derived from refusals undercounts by however many
retries succeeded quietly, and on a fast host the quiet ones are most of them.
"How often does this happen" will be the first question asked of this packet,
and the honest answer is that nobody currently knows, because the tool's own
resilience is what hides the data.

`land-on-platform-branch.sh` retrying up to four times is correct behaviour and
saves a host whose window is seconds. It cannot save a host whose gate is half
an hour, and it removes the evidence that it was needed.

## The workaround in use, which is not a fix

Per macuahuitl this cycle, floor-tier hosts now push the GATED tree to
`work/<order>` and a fast host merges it into the platform branch. The land
script's own refusal message documents this route. It converts a 39-minute
exposure into a seconds-long merge on a host that can afford it.

It is a workaround: the floor host still cannot land its own platform branch
directly, and the fleet now depends on a second host being awake to complete
the first host's work.

## Exit criteria

- "a floor-tier host with a 30+ minute gate lands its platform branch directly without a containment refusal, on a trunk moving several times an hour; pre-fix result: FAILS (refused 09:52:56Z on esmeraldinha)"
- "the number of lands that hit the race is countable from the ledger, including the ones a retry absorbed; pre-fix result: FAILS — a successful retry leaves no record distinguishable from a slow land"
- "NEGATIVE CONTROL: a genuinely stale base is still refused — the fix must not weaken containment, which exists so a platform branch cannot ship without trunk"

## Shapes worth considering (not a recommendation)

- Re-establish containment *after* the gate and push in one step, so the
  checked premise and the pushed state are the same moment; this changes what
  the gate stamp vouches for and may not be acceptable.
- Emit a counter when a retry is caused by containment or a lost push, so the
  race becomes countable regardless of whether it ends in a refusal.
- Accept the relay as the standing shape for floor-tier hosts and document it
  in methodology rather than as a per-cycle instruction.
