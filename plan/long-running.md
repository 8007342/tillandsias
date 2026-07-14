# Long-Running Packets — Active View

Filtered view of ACTIVE `multi_cycle: true` packets, per
`methodology/distributed-work.yaml` → `long_running_packets.sub_queue_view`.
`plan/index.yaml` is the source of truth; on disagreement the index wins and
this view is patched forward. Update this file in the same commit as any
cycle that changes a listed packet's phase, status, or verification tally.

| Order | Packet | Phase | Blocked on | Outstanding verifications |
|---:|---|---|---|---|
| 245 | `network-architecture-audit` | review (GPT audit failed 2026-07-14) | stale runtime taxonomy and root-cause claims | opencode-bigpickle (NA-01..06), antigravity-gemini (NA-01,02,03,05), codex-gpt55-highthink re-verification after revision (NA-01,03,04,06) |
| 246 | `credential-secrets-architecture-audit` | research | order 245 ratification | opencode-bigpickle (CS-01..06), antigravity-gemini (CS-01,02,03,05), codex-gpt55-highthink (CS-02,04,05,06) |
| 247 | `proxy-git-mirror-configuration-audit` | research | order 245 ratification | opencode-bigpickle (PG-01..05), antigravity-gemini (PG-01,03,04), codex-gpt55-highthink (PG-02,03,05) |
| 248 | `spec-cheatsheet-contradiction-audit` | research | orders 245+246+247 | claude-opus-highthink (SC-01..05), opencode-bigpickle (SC-01,02,05), antigravity-gemini (SC-02,03,04) |
| 249 | `event-push-architecture` | research (design input recorded) | orders 245+246 | opencode-bigpickle (EP-01..06), antigravity-gemini (EP-01,02,04), codex-gpt55-highthink (EP-03,05,06) |
| 250 | `ultra-minimalistic-tray-ux` | research | order 249 | claude-opus-highthink (TU-01..06), opencode-bigpickle (TU-01,02,04), antigravity-gemini (TU-03,05,06) |
| 251 | `long-running-work-packet-methodology` | verification (LM-04 active-view repair 2026-07-14) | — | opencode-bigpickle (LM-01..05), antigravity-gemini (LM-01,02,04), codex-gpt55-highthink re-verification (LM-03,04,05) |
| 330 | `git-mirror-observability-and-managed-alternatives` | research | order 315 recommendation + Tlatoani adopt/keep decision | no named verification gate |
| 334 | `stable-milestone-v1` | tracking | 12 release-target children + three-platform curl-install evidence | operator evidence gate |

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
