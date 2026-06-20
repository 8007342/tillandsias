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
    ALL SLICES COMPLETE (1–4). Slice 4 (2026-06-20T09:04Z): 3 integration
    smoke tests added in lib.rs — launch_smoke_initialize_and_tools_list
    (initialize handshake + 5-tool list), broker_smoke_status_action_returns_tool_result
    (nanoclaw.status end-to-end), broker_smoke_denied_tool_returns_tool_error_not_rpc_error
    (deny path returns isError=true, not RPC error). 12/12 tests pass total.
    litmus-nanoclawv2-mcp-shape.yaml written (pre-build, 7 critical_path steps).
    litmus-bindings.yaml updated (80% coverage; live container gap deferred to
    e2e gate). tasks.md: all 4.x tasks marked done.
    cargo fmt PASS; cargo test 12/12 PASS; ./build.sh --check PASS.
    Commit: 1dbdd809. Push blocked (SSH unavailable in Cowork session).
- status: done (pending push)
- next_action: Operator push `git push origin linux-next` (4 commits ahead).
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
    (deferred; consistent use of nanoclawv2 throughout all slices — no action needed)
  - live container launch smoke (requires runtime podman + built image) — deferred
    to local-build e2e gate at release time (noted in litmus-bindings.yaml gap)
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
  - type: progress
    ts: "2026-06-20T09:16Z"
    agent_id: "linux-macuahuitl-claude-20260620T0904Z"
    host: "linux"
    lease_id: "nanoclawv2-orchestration-20260620T055600"
    note: >
      Slice 4 complete: 3 integration tests in lib.rs (in-process UnixStream
      pair, no filesystem socket). launch_smoke_initialize_and_tools_list verifies
      initialize handshake and 5-tool list. broker_smoke_status_action_returns_tool_result
      proves nanoclaw.status flows through allowlist→execute→envelope path.
      broker_smoke_denied_tool_returns_tool_error_not_rpc_error confirms deny path
      returns isError=true tool result, not a JSON-RPC error. 12/12 total tests
      pass. litmus-nanoclawv2-mcp-shape.yaml written (pre-build, 7 steps).
      litmus-bindings.yaml updated. tasks.md 4.1–4.4 done. Commit 1dbdd809.
      Push blocked — SSH unavailable in Cowork. linux-next now 4 ahead of origin.
