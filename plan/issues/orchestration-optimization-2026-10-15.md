# Orchestration optimization — 2026-10-15

Operator direction, 2026-10-15: "I have a feeling we've been micro-managing remote sessions and spend a lot of time in integrations ... look for optimization opportunities for your orchestration duties as we've been growing them organically and they likely overlap with each other and are inefficient in all sort of ways."

Umbrella: 1730-9b9w. Author: the macuahuitl coordinator, from today's own logs and conversation.

## What the coordinator did per PR today

Every peer change passed through one coordinator session, by hand, in this sequence:

1. Relay: re-push yolanda's `salvage/...` ref as `work/<order>`, because the pre-push hook refuses Windows `work/` pushes without a full stamp.
2. Open the PR.
3. Re-run `./build.sh --preflight` in the coordinator checkout.
4. Launch the land queue as a systemd unit, plus a background waiter.
5. Read the result, open the eviction comment, and diagnose.
6. Message the peer, wait for the fix, then repeat from step 3.
7. Push plan fragments: write, check, push, verify on trunk, delete the local copy, fast-forward. That is five commands each time.

## Measurements (land runs 74-84)

| | count |
|---|---|
| land runs | 11 |
| PRs landed | 26 |
| bounced (evicted or requeued) | 8 |
| skipped (not a work ref) | 1 |
| coordinator re-preflights | ~20 |
| bounces those re-preflights would have caught | **0** |

Bounce causes:

| cause | n | cost | catchable before a gate? |
|---|---|---|---|
| carried-silent (no Carried-Waiver trailer) | 3 | round trip (the queue checks this before gating) | yes: `--preflight` doesn't run the landing-mode carried check |
| push did not land (keyring, DNS) | 2 | requeue | partly |
| gate red: combined `tray,listen-vsock` test set | 1 | a full gate | yes: a `cargo check` with both features |
| gate red: line-window record + a flaky timing test | 1 | a full gate | partly |
| merge conflict with a sibling PR | 1 | round trip | yes: an instant `git merge-tree`, and earlier with an overlap advisory |
| not a `work/<order>` ref | 1 | skip and a re-push | yes: a name check at PR open |

Other measured costs:

- **Every PR gates alone.** Each gate takes ~17-35 min, so 26 lands cost roughly 26 serial gates on one host. That is the largest time sink.
- **The queue fixes its candidate list at launch.** Turning #427 into a draft mid-run did not stop it from being gated and landed.
- **A release-tier-only red reached cut time.** A litmus string pinned by #427 went red; only the release tier runs the pre-build litmus, so no land gate saw it. It was found by manual triage hours later. Two release-gate runs were also spent on interference reds.
- **Micro-management round trips.** About a dozen peer questions had answers already settled by a standing rule or the row's own scope: whether to close or take a row, a WIP check, slice-ref naming, push-now-or-hold, releasing stale rows, design yes/no inside scope. Each one held a peer for a message cycle.
- **Message volume.** Most peer reports ran to 15-40 lines. Yoga's one-line `READY:/DONE:` grammar carried the same decisions.
- **Self-inflicted risk.** Nothing stops the coordinator writing to the checkout while the queue gates there. It happened once today (a harmless no-op merge). Only discipline stands in the way.

## Measured again while writing this

- **One host broke every host's plan lane.** About 04:37Z, yoga pushed a fragment whose depends_on named an order. Trunk's fold failed, and every plan-lane push was refused fleet-wide until the coordinator landed a correcting list-replace. The coordinator's own push of that fix was refused at first, because its push script resolved an older installed plan binary.

## Improvements (rows)

| row | change | expected saving |
|---|---|---|
| 1731-cshq | The land queue gates ready candidates as a **merge train**: stack them, gate once, land all on green, and bisect only on red | ~N-1 gates per run (3 of 4 gates on a 4-PR run) |
| 1732-a7m4 | `--preflight` runs the landing-mode carried check, a combined-feature `cargo check` when headless crates change, and the work-ref name check | 5 of today's 9 bounces |
| 1733-7gpz | The queue re-reads draft status and runs `git merge-tree` per candidate before gating; at PR open, an overlap advisory names other open PRs touching the same files | stops gating a held PR; early collision warnings |
| 1734-cqgk | Peers own their PRs end to end: Windows may push `work/` refs on a preflight stamp, peers open non-draft PRs, and the coordinator stops relaying and re-preflighting | removes steps 1-3 for every peer PR |
| 1735-hjeu | A peer autonomy charter in methodology: 3-5 row queues, decisions inside a row's scope, four escalation triggers, a one-line status grammar | removes the dozen round trips |
| 1737-xbh3 | Every host judges the ledger with a plan binary that matches trunk; the plan lane refuses, at the pushing host, a fragment that would break trunk's fold | ends fleet-wide plan-lane outages like today's (a depends_on naming an order) |
| 1736-rnx2 | After each land run, the queue runs the pre-build litmus scoped to the specs the landed PRs touched; while it gates, a lock refuses checkout writes | release-tier reds surface the same day, not at the cut |

Applied immediately, by message: yoga received a five-row queue under the charter's terms (2026-10-15) as the first measured case. The other peers move to it as their current rows close.

## How to measure the change

For the next week, per land run, record:

- PRs landed per gate run;
- bounces and their causes;
- coordinator messages per landed PR;
- peer questions that a standing rule answered.

Today's baseline:

- 26 lands / 11 runs (2.4 per run);
- 9 bounces;
- roughly 3-4 coordinator messages per landed PR.
