# AGENTS.md

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

If `.forge-startup-context.md` exists in the repository root, you are inside a
Tillandsias forge container — read it for live infrastructure state.

## Versioning & Releases

For versioning and the release process, read `methodology/versioning.yaml`,
`docs/RELEASING.md`, and `skills/merge-to-main-and-release/SKILL.md`.
Versions use CalVer `v<Major>.<Minor>.<YYMMDD>.<Build>`; canonical details
belong in `methodology/versioning.yaml`. The active release is declared in
`plan/loop_status.md` under `## ACTIVE RELEASE`.

## Platform Branch Coordination

- Linux checkpoints to `linux-next`.
- Windows checkpoints to `windows-next`.
- macOS checkpoints to `osx-next`.
- Before platform-branch work, fetch/pull the active branch and record sibling
  heads for `main`, `linux-next`, `windows-next`, and `osx-next`.
- Before fast-forwarding a platform branch, verify the remote platform head is
  an ancestor of the source ref.
- Before EVERY push of a non-linux-next branch, merge `origin/linux-next` into
  it and resolve conflicts locally (methodology `pull_merge_cadence.pre_push_gate`).

Canonical details: `methodology/multi-host-development.yaml`.
