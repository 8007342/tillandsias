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
- current_progress: >
    Slice 1 (image infra), Slice 2 (tray launcher leaf), and Slice 3 (host
    orchestration surface) complete. New crate `tillandsias-nanoclawv2-mcp`
    implements the Unix-socket MCP server with a 5-tool allowlist
    (advance_work, build, service_launch, forge_delegate, status) and
    project-scope enforcement. Tray `launch_nanoclawv2` spawns the server,
    derives a per-project socket, bind-mounts it into the container, and
    passes `TILLANDSIAS_NANOCLAW_SOCKET`. Config overlay wired with
    `nanoclaw-host.sh` socat bridge and locked OpenCode config.
    9/9 allowlist unit tests pass; `./build.sh --check` PASS.
- next_action: Slice 4 — smoke coverage (launch smoke + broker smoke for one
  approved action + published-release extension).
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
  - whether the image should be named `nanoclaw` or `nanoclawv2` in the
    Containerfile tree while keeping the user-facing label `🦞 NanoClawV2`
  - Slice 4 smoke coverage still needed before the feature is release-ready
  - type: progress
    ts: "2026-06-20T08:33Z"
    agent_id: "linux-macuahuitl-claude-20260620T0822Z"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-20260620T055600"
    note: >
      Slice 3 complete: added crates/tillandsias-nanoclawv2-mcp with
      allowlist.rs (5-tool project-locked allowlist, 9 unit tests),
      server.rs (JSON-RPC dispatch over UnixStream), main.rs (Unix socket
      listener, --project-path arg). Wired tray launch_nanoclawv2() to
      spawn the MCP server process, derive per-project socket under
      $XDG_RUNTIME_DIR, bind-mount into container, set
      TILLANDSIAS_NANOCLAW_SOCKET. Added config-overlay/opencode/config.json
      (MCP-only, no forge tooling) and config-overlay/mcp/nanoclaw-host.sh
      (socat bridge). Updated Containerfile to COPY new overlay. Workspace
      Cargo.toml updated. cargo test -p tillandsias-nanoclawv2-mcp: 9/9 PASS.
      cargo fmt --all -- --check: PASS. ./build.sh --check: PASS. Transport
      decision: MCP-only via Unix socket (same pattern as browser-mcp). Open
      question on image naming deferred to Slice 4 review.
