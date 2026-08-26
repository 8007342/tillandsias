# research: `query`'s view of archived packets flipped on an unchanged tree — 2026-08-23

- class: research
- owner: linux
- status: open
- found_by: linux-yoga-fable5-20260823t1101z during the 829-dkuc orphaned-obsoletion repair
- trace: scripts/check-fragment-status-loss.sh (resolver re-check block), c1f6595c5 ("archived rows still answer")

## Finding

On one tree (post-rebase, HEAD carrying lenovinha's 829-dkuc retraction
fragments), `check-fragment-status-loss.sh` produced two different verdicts
minutes apart with no plan file changing in between:

1. First run (inside `./build.sh --check`): the `query --json --limit 0` map
   did NOT contain the five retracted split-parents (inference-policy-router,
   plan-methodology-experts-rung1, proxy-git-mirror-configuration-audit,
   vm-headless-persistent-listener, +1), so their `obsoleted` declarations
   flagged as "NO SUCH PACKET is in the fold" — a red trunk gate.
2. After four read-only `tillandsias-plan status <pid>` calls (which answered
   `obsoleted` for all four, i.e. resolved through plan/archive), a re-run of
   the same check on the same tree passed: `query` now returned the packets.

Hypothesis: archive answering is served through a lazily built index/cache,
so `query`'s corpus depends on whether some prior call warmed it — meaning
the fragment-status-loss map (and anything else batching over `query`) is
nondeterministic across cold/warm states. Two hosts saw exactly this skew
live: lenovinha's gate was green when it filed the retraction fragments;
yoga's first post-merge gate was red on the same declarations.

The check now re-asks the per-packet resolver before failing an unknown-pid
terminal declaration (declared == resolved ⇒ advisory, supersession of an
archived row), which makes the gate robust to the asymmetry. The open
question is the asymmetry itself.

## Smallest next action

Reproduce cold-state `query --json --limit 0` (fresh cache dir / fresh clone)
and diff its packet_id set against the warm state; if a lazy archive index is
confirmed, either make `query` deterministic (always-or-never include
archives, or a `--include-archived` flag consumed by the check) or document
the cold/warm contract beside c1f6595c5's "archived rows still answer".
