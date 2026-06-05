# Plan archive — 2026-06-05

Cold-start context: this archive was created during the 2026-06-05 plan-hygiene +
pre-Vault obsolescence audit cycle (Linux host, branch `linux-next`). The v0.3.0
"Fedora Pivot" wave (steps 24–31) had fully drained — `plan.yaml` showed
`next_step: none` and `plan/loop_status.md` reported all hosts IDLE — but a fresh
audit reopened real work (see `plan/issues/pre-vault-obsolescence-audit-2026-06-05.md`
and new steps 32–36 in `plan/index.yaml`). These completed/stale artifacts were
moved here to de-clutter the active plan dirs.

Nothing here is live work. The canonical record of each step remains in
`plan/index.yaml` (status `completed`); only the deliverable Markdown was relocated,
and the `deliverable:` pointers in `plan/index.yaml` were updated to this path.

## steps/ — completed v0.3.0 step deliverables (index status: completed)

| Step | Title |
| --- | --- |
| 24 | Diagnostics Stream & Event-Driven Observability |
| 25 | Multi-Host UX Parity & Menu Stabilization |
| 26 | Forge Toolchain Expansion (Post-Audit) |
| 27 | Release v0.3.0 Milestone |
| 28 | Build Pipeline Optimization & Forge Lean-Up |
| 29 | Agent Launch Stability & Race Condition Fixes |
| 30 | GitHub & Vault Integration Integrity |
| 31 | Multi-Host Simplification & Debt Payoff |

## issues/ — completed-wave and superseded refinement notes (zero live references)

Each file below had **no remaining references** anywhere in the repo (verified
2026-06-05 by whole-repo ripgrep, excluding archives). They are completed-wave
orchestration plans, closed clarification/gap notes, or tombstone records:

- `CLARIFICATION-release-approval-gate-2026-05-14.md` — resolved release-gate clarification.
- `inference-deferred-model-pulls-2026-05-16.md` — closed inference backlog note.
- `osx-next-tombstoned-2026-05-25.md` — superseded osx-next reset note.
- `podman-control-plane-overhaul-2026-05-18.md` — step 15.5 deliverable, completed.
- `residual-backlog-wave-plan-2026-05-14.md` — completed residual-backlog plan.
- `security-privacy-audit-2026-05.md` — earlier security audit, superseded by the 2026-06-05 audit.
- `tray-legacy-cache-tombstone.md` — tombstone record (cache specs retired).
- `wave-1-linux-focus-2026-05-14.md`, `wave-18..24-*-orchestration-2026-05-14.md` — completed wave orchestration plans.
- `windows-build-findings-2026-06-02.md` — superseded by later Windows build-findings.

44 issue files remain in `plan/issues/` because they still carry live
cross-references from `skills/`, code, or sibling issues (per-host work queues,
multi-host coordination/integration ledgers, active gap notes, the markdown
distillation audit, etc.).
