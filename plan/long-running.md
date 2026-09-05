# Long-Running Packets — Active View

Filtered view of ACTIVE `multi_cycle: true` packets, per
`methodology/distributed-work.yaml` → `long_running_packets.sub_queue_view`.
`plan/index.yaml` is the source of truth; on disagreement the index wins and
this view is patched forward. Update this file in the same commit as any
cycle that changes a listed packet's phase, status, or verification tally.

| Order | Packet | Phase | Blocked on | Outstanding verifications |
|---:|---|---|---|---|
| 245 | `network-architecture-audit` | review (GPT audit failed 2026-07-14) | stale runtime taxonomy and root-cause claims | opencode-bigpickle (NA-01..06), antigravity-gemini (NA-01,02,03,05), codex-gpt55-highthink re-verification after revision (NA-01,03,04,06) |
| 248 | `spec-cheatsheet-contradiction-audit` | research | orders 245+246+247 | claude-opus-highthink (SC-01..05), opencode-bigpickle (SC-01,02,05), antigravity-gemini (SC-02,03,04) |
| 249 | `event-push-architecture` | research (design input recorded) | orders 245+246 | opencode-bigpickle (EP-01..06), antigravity-gemini (EP-01,02,04), codex-gpt55-highthink (EP-03,05,06) |
| 250 | `ultra-minimalistic-tray-ux` | research | order 249 | claude-opus-highthink (TU-01..06), opencode-bigpickle (TU-01,02,04), antigravity-gemini (TU-03,05,06) |
| 251 | `long-running-work-packet-methodology` | verification (LM-04 active-view repair 2026-07-14) | — | opencode-bigpickle (LM-01..05), antigravity-gemini (LM-01,02,04), codex-gpt55-highthink re-verification (LM-03,04,05) |
| 330 | `git-mirror-observability-and-managed-alternatives` | research | order 315 recommendation + Tlatoani adopt/keep decision | no named verification gate |
| 334 | `stable-milestone-v1` | tracking | 12 release-target children + three-platform curl-install evidence | operator evidence gate |
| 353 | `enclave-service-catalog-milestone` | ready | not yet recorded | not yet recorded |
| 373 | `web-share-release-milestone` | ready | not yet recorded | not yet recorded |
| 389 | `deploy-lifecycle-evidence-gating-research` | ready | not yet recorded | not yet recorded |
| 391 | `forge-local-experts-milestone` | ready | not yet recorded | not yet recorded |
| 405 | `codex-opencode-smoke-divergence-comparison` | ready | not yet recorded | not yet recorded |
| 483 | `host-native-sidecar-endpoints` | ready | not yet recorded | not yet recorded |
| 537 | `v06-automation-milestone` | ready | not yet recorded | not yet recorded |
| 543 | `npu-inference-container` | ready | not yet recorded | not yet recorded |
| 546 | `npu-beginner-experts-serving` | ready | not yet recorded | not yet recorded |
| 548 | `spec-expert-embed-and-synthesis` | ready | not yet recorded | not yet recorded |
| 549 | `fat-spec-expert-gpu-slot` | ready | not yet recorded | not yet recorded |
| 554 | `harness-mcp-expert-validation` | ready | not yet recorded | not yet recorded |
| 557 | `claude-mcp-expert-validation` | ready | not yet recorded | not yet recorded |
| 558 | `codex-mcp-expert-validation` | ready | not yet recorded | not yet recorded |
| 591-x7ws | `truly-ephemeral-project-checkout-drop-the-host-mount` | ready | not yet recorded | not yet recorded |
| 682-u3si | `local-telemetry-for-bottleneck-finding-milestone` | ready | not yet recorded | not yet recorded |
| 793-rb9u | `mcp-json-launcher-host-kind-compatibility` | ready | not yet recorded | not yet recorded |
| 829-dkuc | `periodic-deslopification-sweep` | ready | not yet recorded | not yet recorded |
| 917-6iwv | `local-expert-system-in-toolboxes-on-accelerated-hosts` | ready | not yet recorded | not yet recorded |
| 917-zkge | `per-host-nix-cache-rollout` | accumulating (v0.6 attractor — slices only, never drained/closed) | operator's release cadence | forge cold-land wall-time metric (headline); per-host ensure+verify rows as they land |
| 1004-pg9p | `floor-tier-release-smoke-and-metrics` | standing (one floor smoke per published release; esme works it unleased by coordinator assignment while its credential is dead) | operator login on ESMERALDINHA (ledger writes) | per-release floor smoke report on at least one floor host; the three recurrence lines in each floor host's newest loop-status entry |

Protocol summary (canonical: `long_running_packets` in
`methodology/distributed-work.yaml`):

- Claims on these packets are **cycle-scoped**; status returns to `ready`
  after each cycle's commit and stays `ready` until the completion gate is
  satisfied.
- The implementing agent never emits `completed` itself — it sets
  `phase: verification` and waits for the named agents' `verified-by`
  events (all assigned criteria `pass`).
- Any `fail` verdict returns the packet to `phase: review`; affected
  criteria are re-verified from scratch after revision.
- Methodology/spec updates produced by these packets must be **additive**
  (new file, new section, or explicit supersede annotation — no in-place
  rewrites).

## Repair note — 2026-08-25 (yoga, order 251 criterion LM-04)

This view had drifted to **7 of 31 packets correct**. It listed 11 rows, four
of which named obsoleted packets (153, 246, 247, 484), and omitted twenty live
ones. A sub-queue that is 23% accurate is not a view, it is a decoy: an agent
reading it to find claimable long-running work is steered toward dead packets
and away from live ones.

That is the SECOND drift. GPT verification found the first on 2026-07-14
(orders 315/330/334 absent); it was repaired by hand and the packet returned to
verification. Hand repair bought six weeks.

So the repair this time came with a gate: `scripts/check-long-running-view.sh`
compares the orders this table lists against the ledger's live `multi_cycle`
set and fails the build on either direction of divergence. The next drift now
fails a check instead of waiting for a human verifier to notice.

The twenty added rows carry `not yet recorded` in the editorial columns
(blocked-on, outstanding verifications), and that is deliberate honesty rather
than laziness: those columns are judgements no generator can derive from the
ledger, and inventing plausible values would make the view MORE convincing and
no more true — the failure mode this repair exists to end. Whoever next touches
one of those packets should fill in its row from what they actually know.

The gate therefore checks MEMBERSHIP, not rendering. Which orders appear is
derivable and is what rotted; the prose is editorial and stays hand-written.
