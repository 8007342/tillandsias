# In-forge recon of the expert surface: calibration notes, timings, and two root-caused defects

Filed 2026-08-31 by forge-forge-tillandsias-claude-20260831t005516z (the claude
forge on the macuahuitl host), directed by the macuahuitl-fedora orchestrator
session. Recon ran read-only against the launch seed `main@341ab0010` (index
freshness 2026-08-31T00:35:24Z) before this checkout fast-forwarded to
`linux-next@06b3e1878`; every expert answer cited below reflects that seed.

## Verdict

All four MCP servers up, zero transport errors across 25+ probed calls.
forge-plan answers shaped queries in under 1.5s with line-span citations pinned
to the index commit and refuses everything else typed — the surface works, but
callers need the calibration below, because three of the four
CLAUDE.md-suggested bootstrap questions route somewhere other than where the
docs point. Two defects were root-caused during the probe and are filed
separately (see Related).

## Calibration notes for expert callers (verbatim from the recon report)

- "what is the current Direction?" is answered by `plan_answer` (NOT
  `methodology_ask`, which is a deterministic YAML-path router; it refuses the
  question with confidence=unsupported and lists its 11 routed forms).
- `plan_answer` refuses open-ended prose ("what is the overall state of the
  project right now?" -> confidence=unsupported, zero citations). Overall state
  must be assembled from `plan_next` + `plan_ready` + `plan_burndown`. The
  documented alias "what's next?" works (confidence=exact, identical to
  `plan_next`).
- `plan_burndown` needs a milestone packet id, not a release name ("v0.5" ->
  unresolved warning; `fail-loud-diagnosis-milestone` -> full ~230-child
  burndown).
- `plan_status` needs a concrete packet ref; there is no argument-free overall
  mode ("current" -> error: no packet matches).
- Use `plan_ready role=linux` for host-appropriate work — bare `plan_next`
  (no pickup_role) leaks macOS-only packets into a Linux caller's top-5
  (measured: 635-kagg ranked 5th). role=linux returned a strict subset (~40
  rows fewer); platform-titled rows that remain reflect stale ledger
  pickup_role values (the 884-hfsj failure mode), not a broken filter.
  Milestone/criteria-holder rows (334, 373, 391, 537, 590-z3jh, 630-67jk,
  682-u3si, 700-nz4n) still appear in ready output though plan_next never
  offers them — consumers must drop them.
- `expert_capability` reported ~44 capabilities, skew=none, one degradation:
  `embed_endpoint=unreachable` — root-caused, see Related.
- project-info: `git_status` (verified exact, 22/22), `search_code`,
  `project_type` are accurate. Its descriptive surface is not: three defects,
  filed separately (see Related).

## Timings (wall-clock, in-forge)

forge-plan: 11 calls, 0.23–1.41s each. project-info: 9 calls, ~2.1–2.9s
brackets (project_answer 6.1s). git-tools reads: ~3.3–4.0s brackets.
host-browser service_status: responded, empty output (ambiguous: "no service"
vs swallowed status). Recon overall: 7 agents, 113 tool calls, ~355k tokens,
8m38s wall.

## What is NOT claimed

That the queue ranking probed here is current: every answer is pinned to
`main@341ab0010`, and origin/linux-next was 826 commits ahead at probe time.
Rows filed on branches the seed cannot see are invisible to these experts.

Related:
`plan/issues/dev-loopback-inference-env-leaks-into-forge-settings-2026-08-31.md`
(the embed_endpoint root cause),
`plan/issues/project-info-descriptive-surface-defects-2026-08-31.md`,
884-hfsj (pickup_role staleness), 712-r5x8 (embed_endpoint discoverability),
919-vvyv (fresh-forge embed wiring), order 531, order 391.
