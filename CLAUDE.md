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

**Ask, don't read.** Reads go through the local MCP servers first; the
filesystem is the fallback. Canonical rule:
`methodology/distributed-work.yaml` → `mcp_first_read_path`.

- `forge-plan` / `project-plan` — `plan_answer`, `plan_next`, `plan_query`,
  `plan_status`, `plan_blocked_by`, `methodology_ask`, `methodology_path`,
  `spec_answer`
- `project-info` — `search_code`, `grep_code`, `find_files`, `file_summary`,
  `read_file`, `project_structure`

Good first questions: *"what is the current Direction?"*, *"what's next?"*,
*"what v0.5 work can I do on linux?"*

Fall back to reading files for exactly three reasons, and name the one that
applies: **unavailable** (MCP down or `confidence=unsupported` — fall back and
keep going, then record it), **verification** (before anything irreversible,
read the cited span — the span, not the file), **not exposed** (no tool covers
it; if the loop needs it repeatedly, that is a missing tool — file a packet).

This block used to `sed -n '1,220p'` four files including `plan/index.yaml`,
which is 31,678 lines. Truncating a ledger to its first 220 lines is not a
summary of it — the head of an append-only file is its oldest content.

When multiple hosts or platform branches are active:
`methodology_ask "multi-host branch and merge rules"`, falling back to
`methodology/multi-host-development.yaml` and
`plan/issues/multi-host-coordination-2026-05-24.md`.

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
- Before EVERY push of a non-linux-next branch, merge `origin/linux-next` into
  it and resolve conflicts locally (methodology `pull_merge_cadence.pre_push_gate`).

Canonical details: `methodology/multi-host-development.yaml`.
