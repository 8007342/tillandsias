# v0.4 release triage — 2026-07-27

- **Trigger**: operator directive (The Tlatoani, 2026-07-27 session "linux-next"):
  drain remaining v0.4-blocking work, merge `linux-next` to `main`, ship the
  v0.4 release with all three binaries, then clear residual verification via
  real cross-platform e2e smokes of the published artifact.
- **Method**: 15-packet parallel adversarial triage (one agent per nonterminal
  v0.4 packet + synthesis cross-check), each verdict grounded in ledger
  events, deliverable issues, and code state at HEAD.
- **Headline**: **zero release-blocking packets.** The v0.4 charter ("no
  crashloop, no work loss, no forge/mirror corruption, plus a qualifying host
  smoke PASS") is satisfied: macOS destructive e2e PASS on terminal-attach@v2
  (5a44fd69, 2026-07-27, ancestor of HEAD) and Windows smoke PASS on
  v0.3.260724.1 (`plan/issues/smoke-455-windows-v0.3.260724.1-2026-07-24.md`).

## Dispositions

| Order | Packet | Disposition |
|---|---|---|
| 424 | git-mirror-credential-lifecycle | stays v0.4 in_progress — all 4 exit criteria implemented + offline-verified at HEAD; live real-Vault re-auth evidence session on mutable Linux post-tag (fold order 463's quick probes into the same session per the loop_status matrix ordering "463 then 424") |
| 455 | v04-cross-platform-smoke-queue | stays v0.4 pending — by design closes only against the published v0.4 tag (gating the release on it is circular); Windows column already complete |
| 463 | vault-host-endpoint-soak-fragility | stays v0.4 in_progress — structural fix shipped at 7dfc2101; restarted-Vault + idle-lane/heal probes ride the 424 live session, soak window completes post-release |
| 465 | forge-enclave-isolation-uniform-principle | drained this cycle — HOST_MOUNT escape hatch now emits a Once-gated bordered isolation warning on every honoring path (unit-pinned); principle trace refutes any shipped isolation defect; residual CA lifecycle lives in orders 467/472/473 |
| 466 | macos-forge-no-push-route-lane-decision | stays v0.4 — work-loss defect mitigated at HEAD (244d7e95: SRC-ISOLATION lane wires TILLANDSIAS_GIT_SERVICE; lib-common.sh routes pushes to the mirror); attended push-chain verification + lane decision ride the post-release macOS smoke |
| 468 | forge-claude-transparent-oauth-token-vault-inject | slipped to v0.5 — unimplemented feature, Tlatoani sign-off gated, usability not stability |
| 476 | main-branch-direct-push-guard | prong (b) drained this cycle (scripts/check-committable-branch.sh + litmus); prong (a)/(c) residue open; **branch protection on `main` is an operator API call — handed off, see below** |
| 486 | inference-coldstart-races-proxy-egress-and-hard-gates-launch | criteria 1–2 drained this cycle (e6777c88: CA bundle + bounded egress-gated backoff; hard-abort already fixed at 5ddc80db); criterion 3 (cold-volume race fixture / structural ordering) slips to v0.5 with the inference family |
| 489 | postbuild-meta-orchestration-dirty-start-contract | stays v0.4 — substantive fix merged (02503422); clean-checkout `--ci-full --install` rerun rides the post-tag Linux session |
| 490 | clickable-trace-index-build-dispatch-gap | stays v0.4 ready — dev-loop tooling, post-tag drain on Linux (single `_regenerate_trace_indexes` helper across build dispatches) |
| 491 | bigpickle-macos-terminal-cooperative-debug | stays v0.4 — both round-1 defects fixed + deployed (5d29a1c2); remaining probes ride the first attended post-release macOS smoke |
| 492 | host-pty-slave-retention-eof-teardown | slipped to v0.5 — D5 consequence closed by attach-client detach PtyClose (2026-07-27); structural fix needs live Darwin probe |
| 493 | guest-pty-write-wedge | slipped to v0.5 — P2, one-session blast radius, common trigger removed at HEAD |
| 494 | macos-concurrent-lane-launch-kills-sibling | synthesis-corrected from bare slip: interim leak-not-destroy guard drained this cycle (cleanup path must never force-remove a RUNNING sibling container — work-loss vector); root-cause H1/H2 forensics + full order-443 guard fix slip to v0.5 for the first post-release macOS multi-lane session |
| prov. | codex-lane-state-amnesia / harness-refresh-not-byte-cheap / proxy-cache-never-hits | stay v0.4 in_progress — static fixes merged at HEAD (4ac678a6, 59fcbc50, c2440072); combined rebuilt-image evidence matrix rides the post-release Linux session |

## Operator handoff (order 476)

`main` currently has **no branch protection** (`gh api` returns 404 "Branch not
protected"); three post-bump direct pushes prove recurrence. Enabling
required-PR protection is operator-owned because the release flow itself
pushes the VERSION bump directly to main (skill step 4) — protection settings
must allow the release path (e.g. require PRs but exempt the release
actor/token, or move the bump into the PR). Decision + API call rests with
The Tlatoani.

## Evidence

Full per-packet verdicts with file:line citations preserved in the session
workflow journal (v04-release-triage, run wf_f0e036ba-21d, 16 agents, 0
errors). Verdict summaries reproduced in the dispositions above; packet-level
slip events carry the per-packet reasons in `plan/index.yaml`.
