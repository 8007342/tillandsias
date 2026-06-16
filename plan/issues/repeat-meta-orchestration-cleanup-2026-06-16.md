# Repeat and Meta-Orchestration Cleanup - 2026-06-16

Status: completed
Owner: linux-next

## Completed

- Replaced ad hoc repeat helper scripts with a single `./repeat` launcher.
- Added `/meta-orchestration` as the long-running host-aware loop skill.
- Made build/install and curl-install e2e skills host-aware and explicit about destructive substrate resets.
- Updated core work, coordination, forge, and release skills with mandatory git discipline: commit/push progress, update plan state, and exit clean/not-ahead.
- Archived noncanonical Markdown intake under `plan/archive/2026-06-16/markdown-intake/`.
- Added `methodology/markdown-distillation.yaml` and `scripts/check-markdown-distillation.sh`.

## Validation

- `scripts/check-markdown-distillation.sh`
- `bash -n repeat claude codex scripts/check-markdown-distillation.sh`
- YAML syntax parse for updated plan and methodology files

## Follow-Up

- Keep the legacy `crates/tillandsias-repeat-graph` code until a separate product decision removes the compiled graph supervisor.
