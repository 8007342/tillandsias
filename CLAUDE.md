# CLAUDE.md

## Authority

This file is non-authoritative. `methodology.yaml` is the source of truth for
project workflow, bootstrap, OpenSpec discipline, trace rules, versioning,
multi-agent coordination, and documentation policy.

Durable architecture, process, and release claims must live in:

- `methodology.yaml` and `methodology/`
- `openspec/specs/`
- `cheatsheets/` or `docs/cheatsheets/` with provenance
- `plan.yaml`, `plan/index.yaml`, `plan/steps/`, and `plan/issues/`

Do not add new project knowledge here. If a tool produces useful Markdown,
distill it through `plan/issues/markdown-distillation-audit-2026-05-24.md`.

## Bootstrap

Read these first:

```bash
sed -n '1,220p' methodology.yaml
sed -n '1,260p' methodology/bootstrap/router.yaml
sed -n '1,220p' plan.yaml
sed -n '1,220p' plan/index.yaml
```

When multiple hosts or platform branches are active, also read:

```bash
sed -n '1,240p' methodology/multi-host-development.yaml
sed -n '1,220p' plan/issues/multi-host-coordination-2026-05-24.md
```

## Common Commands

```bash
./build.sh --check
./build.sh --test
./build.sh --ci-full --install
scripts/local-ci.sh --phase runtime
scripts/run-litmus-test.sh --size instant --phase pre-build --compact
scripts/run-litmus-test.sh git-mirror-service --phase pre-build --size instant --compact
```

## Current Coordination Notes

- Linux checkpoints to `linux-next`.
- Windows checkpoints to `windows-next`.
- macOS checkpoints to `osx-next`.
- Before platform-branch work, fetch/pull the active branch and record sibling
  heads for `main`, `linux-next`, `windows-next`, and `osx-next`.
- Before fast-forwarding a platform branch, verify the remote platform head is
  an ancestor of the source ref.

Canonical details: `methodology/multi-host-development.yaml`.
