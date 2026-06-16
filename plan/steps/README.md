# Plan step deliverables

Each active plan step in `plan/index.yaml` points at a deliverable Markdown file.
For in-flight steps that file lives here as `NN-<slug>.md`; once a step is
completed and a hygiene cycle archives it, the file moves to
`plan/archive/<date>/steps/` and the `deliverable:` pointer in `plan/index.yaml`
is updated to the archived path.

Current active frontier:

- No active step deliverable currently lives in this directory.
- Immediate work is tracked in `plan/issues/ACTIVE.md`; the completed
  destructive Linux smoke deliverable remains here as
  `50-full-build-install-reset-init-forge.md` until the next archive pass.

## Step file template

A step deliverable should be cold-start readable by a different future agent:

```markdown
# Step NN — <title>

- **Status**: ready | in_progress | blocked | needs_clarification | completed
- **Owner host**: linux | macos | windows | any | release
- **Branch**: linux-next (plan writes) / <platform>-next (code)
- **Depends on**: <step ids>
- **Specs**: <openspec spec ids>

## Goal
<one paragraph>

## Tasks
- [ ] <task> — owned files, acceptance evidence

## Evidence / handoff
<what was verified; checkpoint SHA; residual risk; next action>
```

Keep notes idempotent and portable (plain repo paths, no `@`-style references).
The active frontier and per-host claimable queues are tracked in
`plan/index.yaml` and `plan/issues/<host>-next-work-queue-*.md`.
