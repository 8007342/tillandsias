# v0.5 queue scoping triage — 2026-07-28

- **Class**: research/ (coordinator survey; drives ledger hygiene + drain ordering)
- **Trigger**: operator directive after the v0.4 release — "see what's properly
  scoped, and what might require further reducing into simpler packets".
- **Method**: 7 thematic bucket agents + adversarial synthesis over the 127
  nonterminal v0.5 packets. Staleness was a first-class verdict: orders 125–330
  predate the Fedora pivot, Vault, the mirror relay, order-437 clone-only lanes,
  and the v0.4 stability wave.

## Headline

The queue is NOT uniformly stale, but roughly a third of it needs work before
it can be drained honestly: **8 packets look already satisfied**, **2 are
obsolete-candidates**, **18 need a premise refresh**, and **19 exceed the
forge-cycle envelope and need splitting** into named child slices.

## Immediate drain order (ranked, coordinator-adopted)

1. **334 stable-milestone-v1** — highest value/effort in the survey: v0.4 is
   already stable-promoted, yet 48 stale `release_target` markers outrank the
   real backlog in every worker's selection.
2. **495 preflight-evidence-dirties-forge-gate** — zero staleness, fix
   pre-decided, removes a self-defeating release gate. *(drained this cycle)*
3. **322 mirror-authenticated-push-transport** — decision-record gate for order
   451, the v0.5 blocker removing the operator-rejected unauthenticated
   receive-pack path.
4. **479 heterogeneous-inference-specs** — sole gate holding five EXPERTS
   implementation packets (480–484); pure spec work.
5. **153 vm-headless-persistent-listener** — implementation complete at
   705d57ae; only four named verified-by events remain. Closure unblocks 151
   and cleans the 154/155 carve-outs.
6. **464, 461, 435, 448, 477, 493, 246a** — small, fresh-premise packets.

## Contradictions the synthesis caught (coordinator rulings)

- **153 status drift** — carried `status: ready` AND `phase: verification`
  simultaneously; the transport bucket read the phase, others read the status.
  **Fixed this cycle**: `status: in_progress` (per the long-running-packet rule,
  implementation-complete means `phase: verification`, never `ready`).
- **141a vs 142c duplicate slice** — both propose the guest↔container hop with
  podman-secret PSK delivery. Ruling: it belongs to 142 (per-boot key
  hardening); 141's remainder is the close-out reconciliation only.
- **400 vs 457 duplicated scope** — both build a spec/cheatsheet expert on
  394's pipeline. Needs a coordinator ruling BEFORE either drains; do not claim
  both.
- **486 vs 247a same-commit coverage** — 486 counts e6777c88 as closing its
  criteria while 247a treats the same commits as unaudited TLS-chain input.
  Both readings are legitimate; 247a's audit must cite 486's closure rather
  than re-litigate it.
- **147 vs 148 criterion duplication** — 147's headless-crash criterion
  duplicates 148's whole scope; the refresh must assign it to exactly one.
- **334 vs 440 scheduling conflict** — both rewrite large swaths of the ledger
  (48 marker clears vs whole-ledger status-vocabulary normalisation). They must
  not run concurrently; 334 first (it shrinks 440's surface).

## Already-satisfied and obsolete claims → adversarial verification required

The 8 already-satisfied claims (137, 150, 399, 279, 319, 328, 130, 132) and 2
obsolete candidates (158 vault-blocking-watch, 382 guest-staged-gitdir) were
sent to a dedicated refutation pass rather than closed on bucket assertion —
a wrongly-closed packet silently drops real work. Results land as per-packet
closure events citing verified evidence, or stay open with the exact remainder
named. Note for 158: an obsolete MECHANISM with a live INTENT (avoid polling
Vault) gets rewritten, not deleted.

## Splits proposed (19 packets)

Child slices are recorded in the workflow journal (run wf_644c1721-c34) and
get promoted into `plan/index.yaml` as the parents are claimed — shaping a
packet into drainable children is itself a valid reduction step, but promoting
all 19 at once would flood the ready queue ahead of the drains above.
Highest-value first: 125 (host-guest-transport-linux, keystone for 128), 141,
142, 394, 309, 496.
