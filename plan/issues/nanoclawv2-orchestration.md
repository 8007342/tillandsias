# NanoClawV2 orchestration engine and launcher leaf

- branch: linux-next
- status: ready
- owner_host: linux
- source: `openspec/changes/nanoclawv2-orchestration/`
- scope:
  - add a `🦞 NanoClawV2` per-project launch leaf
  - add a baked NanoClawV2 container image
  - add a narrow host control surface for approved orchestration actions
  - add smoke coverage for launch + one approved action
- current_progress: proposal, design, tasks, and spec are scaffolded; no code
  has been changed yet
- next_action: claim the packet and wire the launcher, broker, and smoke
  hooks
- blocker: none
- evidence_required:
  - proposal.md, design.md, tasks.md, and spec.md are written and consistent
  - launcher path is branch-aware and allowlisted
  - smoke coverage proves launch on supported hosts
- open_questions:
  - exact host transport mix for the broker: MCP only vs MCP + HTTPS
  - final allowlist for approved orchestration actions in v1
  - whether the image should be named `nanoclaw` or `nanoclawv2` in the
    Containerfile tree while keeping the user-facing label `🦞 NanoClawV2`
