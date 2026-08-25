# Wide subagent fan-out loses every incomplete agent's work when the provider limit lands

<!-- @trace spec:methodology-accountability -->
<!-- # freshness: auditor=linux-macuahuitl-fable5-20260825t195813z date=2026-08-25 verdict=updated scope=filed from a live measurement this cycle -->

- **Filed**: 2026-08-25, macuahuitl (`linux_mutable`), meta-orchestration cycle
  `linux-macuahuitl-fable5-20260825t195813z`
- **Class**: `optimization` — this is squarely "explicitly log things that make
  you slower" (Non-Negotiable Exit Contract)
- **Status**: observation + a cheap mitigation. Not proposing a packet yet; see
  "Why no row" below.

## What happened, measured

The cycle claimed a batch of 8 packets and fanned out 8 read-only scout
subagents in parallel to produce implementation plans — one per packet, each
reading code and returning a structured plan.

| outcome | count |
| --- | --- |
| returned a complete plan | 2 |
| died on `You've reached your Fable 5 limit` | 6 |

Aggregate cost of the run: **862,625 subagent tokens, 315 tool calls, 562s
wall-clock.** The six failed agents had spent 98k–114k tokens each and made
35–54 tool calls apiece before dying. Every one of them had done most of its
reading. **All of that work was discarded** — a failed agent returns `null`, so
nothing partial survives.

Roughly 655k of the 862k tokens spent — about **76%** — bought nothing.

## Why it is worth writing down

The failure is not "we hit a limit". Limits are a fact of a rate-limited
provider and the cycle recovered by switching models and re-scouting a smaller
set. The finding is about the **shape** of the loss:

1. **It is all-or-nothing per agent.** An agent 90% through its reading returns
   exactly as much as one that never started. There is no partial-result path,
   so the cost curve is worst precisely for the agents that did the most work.

2. **Wide fan-out concentrates the risk instead of spreading it.** Eight
   concurrent agents burn the shared budget eight times faster, so they all
   approach the ceiling together and then fail together. Running the same eight
   sequentially would have completed several and failed cleanly at the boundary
   — the same total budget buys strictly more finished plans.

3. **It is invisible until the end.** The workflow reports failures only on
   completion, so the cycle had already committed nine minutes before learning
   that six of its eight plans did not exist.

## The mitigation this cycle actually used

Re-scouting **three** packets instead of eight, after switching models. Smaller
fan-out, and the three most tractable packets chosen deliberately rather than
"everything claimed".

Generalised, and cheap enough to apply without any tooling change:

- **Size the fan-out to the work you can finish, not to the batch you claimed.**
  The batch-as-story rule sets what a cycle *implements*; it does not require
  scouting all of it up front.
- **Prefer sequential or small-wave fan-out when the budget is the binding
  constraint** — under a shared ceiling, narrower is strictly better, because
  completed work is retained and incomplete work is not.
- **Release the unreached packets in the same cycle** (which this cycle did:
  746-htj9, 747-knbp, 759-vceg went back to `ready` with handoff notes). A
  scouting failure must not become a stranded claim — that is 641-e2qa arriving
  by a new route.

## What would actually fix it

Have the scouts **checkpoint**: write findings to disk incrementally rather than
returning everything in a final structured payload. An agent killed at 90% would
then leave 90% of its plan behind. This is the same property
`scripts/check-forge-findings-persisted.sh` (741-3y48) enforces for forge
cycles, and for the same reason — and there is a live precedent that it works:
on 2026-08-15 an in-forge run was SIGTERM'd by its launcher's timeout and lost
nothing, because it had pushed incrementally rather than at the end.

The generalisation is the reusable part: **anything that can be killed mid-work
should persist as it goes, not at the end.** Subagent fan-out is currently the
one lane in this loop that does not.

## Why no plan row (yet)

Per the capture-routing rule, a new row needs to be independently schedulable
and to own something no open row owns. The durable half of this — incremental
persistence for work that can be killed — is 741-3y48's territory, and the
tactical half is a habit rather than a code change. Recording it here so the
pattern is visible if it recurs; if a second cycle loses a fan-out the same way,
that is the confirmed pattern that makes it a promotion candidate (and promotion
is Tlatoāni-gated).

## Numbers, for whoever compares against a later run

```
run wf_cae5da78-2b0, 2026-08-25T19:57Z, macuahuitl
  agents: 8    done: 2    error: 6    empty: 0
  subagent_tokens: 862,625      tool_uses: 315      duration: 561,974 ms
  per-failed-agent: 98,811 / 108,070 / 109,567 / 111,994 / 112,554 / 113,872 tokens
  failure: "You've reached your Fable 5 limit"

run wf_e3951830-730, same cycle, 3 agents, after switching models
```
