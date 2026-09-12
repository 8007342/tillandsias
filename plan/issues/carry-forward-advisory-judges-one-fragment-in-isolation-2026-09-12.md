# The carry-forward advisory calls a packet OPEN by reading one fragment in isolation, so packets the fold reports verified or completed are reported as needing a next_action

**Filed:** 2026-09-12 · **Kind:** bug (false reporting) · **Priority:** p2 · **Unclaimed**
**Capability tags:** plan, ledger, fold, advisory
**Host:** ESMERALDINHA · **Found in:** the land gate for windows-next 9a765da19
**Ordered by:** macuahuitl-fedora, 2026-09-12

trace: `scripts/check-carry-forward.sh` — the loop that emits the advisory line
       `tillandsias-plan carry-forward-check` (order 831-ezea) — the subcommand that renders the verdict

## Claim

`scripts/check-carry-forward.sh` walks `plan/index.d/*.yaml` and calls
`tillandsias-plan carry-forward-check` on **one fragment at a time**. That
subcommand's contract is to print the packet_ids a fragment "TOUCHED (has an
event for) and LEFT OPEN (no terminal event, status: value, or declared
status) while naming no `next_action`".

Every clause of that judgement is evaluated **within the single fragment being
read**. Fragments are append-only and immutable, and a packet's later status
corrections arrive in *different* fragments through the LWW `status:` channel.
So a closure that lands in a later fragment is invisible to the check, and the
declaring fragment is reported as having left the packet OPEN forever.

The subcommand already intends to exempt this case — "Closures are EXEMPT: a
carry-forward note on a terminal row is a dead letter no selector reads again"
— but the exemption can only fire when the terminal event sits in the *same*
fragment. That is the defect: the right rule, scoped to the wrong unit.

## Measured

One gate, one tree (windows-next at 9a765da19), **73 advisory firings**. Three
checked against the fold with `tillandsias-plan answer`:

| order | folded status | advisory fires? | correct? |
|---|---|---|---|
| 1124-7f3u | **verified** | yes | **NO** |
| 1115-yvrq | **completed** | yes | **NO** |
| 1120-s3e5 | ready | yes | yes |

`1124-7f3u` is the sharpest case because the closure is demonstrably in the
same tree: commit `e5f9e8bb9` ("plan(1124-7f3u): verified — the lane refuses
what it cannot fold") is an ancestor of the gated HEAD, and the fold resolves
the packet to `verified` citing
`plan/index.d/20260912t055451z-112a2c55-lenovinha.yaml`. The advisory
nonetheless names the *declaring* fragment,
`plan/index.d/20260912t021027z-1124-7f3u-plan-lane-skips-guards-when-binary-absent-macuahuitl.yaml`,
as having left it open.

`1115-yvrq` shows the same shape on a packet that reached `completed`, so this
is not specific to the `verified` status or to one author's fragment.

`1120-s3e5` is included deliberately as the control: it is genuinely `ready`,
the advisory fires, and there it is correct. The check is not uniformly wrong —
it is wrong exactly where a closure arrived in a later fragment.

## Why it matters at 73

The advisory's own text says "the next cycle sees the packet's title as its
next step". A reader taking it at face value sees 73 packets needing attention,
an unknown fraction of which are closed. That is worse than a check that is
simply off: it spends the reader's attention at a rate that makes the whole
signal skippable, and the firings that are CORRECT — 1120-s3e5 here — get lost
among the ones that are not. The measured adoption figure the subcommand cites
(4.6%) suggests the signal is already being skipped.

## Exit criteria (verifiable_closure)

- "on one tree, the advisory fires only for packets whose FOLDED status is open; pre-fix result: FAILS — 73 firings on windows-next 9a765da19, including 1124-7f3u (folded `verified`) and 1115-yvrq (folded `completed`)"
- "a planted closure event on an open packet, landed in a LATER fragment than the declaring one, silences the advisory for that packet; pre-fix result: FAILS — e5f9e8bb9 did exactly that for 1124-7f3u and the advisory still fires"
- "NEGATIVE CONTROL: a genuinely open packet touched with no next_action is STILL named — 1120-s3e5 must keep firing, or the fix has traded a false positive for a false negative"

## Not established

- How many of the 73 are false. I checked three. Counting them is the first
  measurement whoever picks this up should take, because it decides whether
  this is a p2 annoyance or a signal that is already worthless.
- Whether the fix belongs in `carry-forward-check` (take the folded ledger as a
  second input, the way `blocked-closure` resolves against the fold per
  600-c266) or in `check-carry-forward.sh` (filter the rendered list against
  the fold before printing). The subcommand's per-fragment contract is
  deliberate and shared with its three `fragment-*` siblings, so changing its
  unit of judgement may be the wrong lever.
