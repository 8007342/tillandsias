# Markdown Distillation Audit - 2026-05-24

## Status

Active. Ad hoc Markdown is now treated as intake only. Durable knowledge belongs
in OpenSpec specs, methodology, provenance-backed cheatsheets, or plan steps and
issues.

## Policy

- `CLAUDE.md` may contain only local command affordances and canonical pointers.
- `.claude/*.md` may remain only as tombstone pointers.
- Top-level implementation reports may remain only as compatibility pointers.
- New architecture, process, release, or implementation facts must be added to
  the canonical artifact named below.

## Distillation Map

| Intake file | Canonical destination |
|---|---|
| `CLAUDE.md` | `methodology.yaml`, `methodology/bootstrap/router.yaml`, `methodology/multi-host-development.yaml`, `plan.yaml` |
| `.claude/IMPLEMENTATION_STATUS.md` | `plan/index.yaml`, `plan/steps`, `openspec/specs/*`, `TRACES.md` |
| `.claude/PHASES_3_5_IMPLEMENTATION.md` | `openspec/specs/host-shell-architecture`, `openspec/specs/vsock-transport`, `openspec/specs/vm-idiomatic-layer`, `openspec/specs/windows-native-tray`, `openspec/specs/macos-native-tray` |
| `CACHE_SEMANTICS_ARCHITECTURE.md` | `openspec/specs/forge-cache-dual`, `openspec/specs/forge-staleness`, `openspec/specs/cache-recovery-mechanism`, cache cheatsheets |
| `CONVERGENCE_WORKFLOW.md` | `methodology/convergence.yaml`, `methodology/proximity.yaml`, convergence dashboard docs |
| `DIAGNOSTICS_STREAM_IMPLEMENTATION.md` | `openspec/specs/runtime-diagnostics-stream`, runtime logging cheatsheets, `TRACES.md` |
| `ForgeAudit_20260519T164526Z.md` | `docs/cheatsheets/git-mirror-lifecycle-audit.md`, relevant plan issues |
| `IMPLEMENTATION_REPORT.md` | owning OpenSpec specs, `TRACES.md`, plan step evidence |
| `IMPLEMENTATION_ROADMAP.md` | `plan/index.yaml`, `plan/steps`, `methodology/bootstrap/router.yaml` |
| `LITMUS_FRAMEWORK_DESIGN_SUMMARY.md` | `methodology/litmus.yaml`, `methodology/verification.yaml`, `openspec/litmus-bindings.yaml` |
| `README-ABOUT.md` | `README.md`, OpenSpec specs, cheatsheets |
| `RELEASE-HANDOFF.md` | release plan steps, `docs/VERIFICATION.md`, `docs/UPDATING.md` |
| `RELEASE-NOTES.md` | release workflow output or governed changelog; not an untracked planning surface |

## Current Audit Result

This pass refreshed these canonical artifacts:

- `openspec/specs/git-mirror-service/spec.md`
- `openspec/specs/tillandsias-vault/spec.md`
- `docs/cheatsheets/git-mirror-lifecycle-audit.md`
- `openspec/litmus-tests/litmus-git-mirror-safe-refspec-push.yaml`
- `methodology/multi-host-development.yaml`
- `methodology/event/031-markdown-sprawl-distillation.yaml`

Retained ad hoc Markdown files should be reduced to tombstone stubs pointing to
this issue and the canonical artifacts above.
