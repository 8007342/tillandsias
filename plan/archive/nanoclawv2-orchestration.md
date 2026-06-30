# NanoClawV2 orchestration engine and launcher leaf

- branch: linux-next
- status: superseded (migrating to ZeroClaw)
- owner_host: linux
- source: `openspec/changes/nanoclawv2-orchestration/`
- scope:
  - add a `🦞 ZeroClaw` per-project launch leaf (supersedes NanoClawV2)
  - add a baked ZeroClaw container image (based on fedora:44, entirely in Rust)
  - add a narrow host control surface for approved orchestration actions
  - add smoke coverage for launch + one approved action
- current_progress: SUPERSEDED BY ZEROCLAW. Slice 1 & 2 completed for NanoClawV2, but must now be migrated. NanoClaw uses Node.js and MIT licensing; ZeroClaw is a pure Rust port with an Apache 2.0 license. 
- next_action: HALT NanoClawV2 work. Migrate the existing implementation to ZeroClaw. Update `images/nanoclawv2/Containerfile` to point to a Fedora 44 base compiling the ZeroClaw Rust binary. Rename directories and scripts from `nanoclaw` to `zeroclaw`. See `plan/secure_agent_forge_plan.md` for full context on this architectural shift.
- events:
  - type: claim
    ts: "2026-06-20T05:56:00Z"
    agent_id: "linux-tlatoani-big-pickle-20260620T055600Z"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-20260620T055600"
    expires_at: "2026-06-20T09:56:00Z"
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
  - type: progress
    ts: "2026-06-19T21:35:00Z"
    agent_id: "linux-tlatoani-gemini-2026-06-19T21:34Z"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-202606192134"
    note: >
      Slice 1 checkpoint: verified (./build.sh --check passed) and committed.
      images/nanoclawv2/entrypoint.sh opencode path fixed.
      Ready to start Slice 2 (tray launcher leaf).
  - type: progress
    ts: "2026-06-20T06:00:00Z"
    agent_id: "linux-tlatoani-big-pickle-20260620T055600Z"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-20260620T055600"
    note: >
      Slice 2 complete: registered nanoclawv2 in Rust image builder
      (image_specs, image_build_inputs with forge-base dependency, run_init
      image array). Added to init image order test and image_specs path test.
      All tests pass, clippy clean. Tasks 2.2 and 2.3 marked done.
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
