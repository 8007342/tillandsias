# NanoClawV2 orchestration engine and launcher leaf

- branch: linux-next
- status: claimed
- owner_host: linux
- source: `openspec/changes/nanoclawv2-orchestration/`
- scope:
  - add a `🦞 NanoClawV2` per-project launch leaf
  - add a baked NanoClawV2 container image
  - add a narrow host control surface for approved orchestration actions
  - add smoke coverage for launch + one approved action
- current_progress: proposal, design, tasks, and spec scaffolded. Slice 1
  (image infrastructure) in progress: images/nanoclawv2/Containerfile created,
  config overlay with orchestration instructions, entrypoint, build-image.sh
  registration added. Slice 1 still pending build verification and commit.
- next_action: complete slice 1 verification (./build.sh --check), commit,
  then proceed to slice 2 (tray launcher leaf)
- events:
  - type: claim
    ts: "2026-06-17T22:07:00Z"
    agent_id: "linux-macuahuitl-gemini-202606172205"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-202606172207"
    expires_at: "2026-06-18T02:07:00Z"
  - type: claim
    ts: "2026-06-19T00:24:30Z"
    agent_id: "linux-big-pickle-20260619002430"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-202606190024"
    expires_at: "2026-06-19T04:24:30Z"
  - type: claim
    ts: "2026-06-19T21:34:00Z"
    agent_id: "linux-tlatoani-gemini-2026-06-19T21:34Z"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-202606192134"
    expires_at: "2026-06-20T01:34:00Z"
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
