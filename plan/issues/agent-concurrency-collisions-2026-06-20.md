# Agent Concurrency & Build Collisions on Shared Host

- branch: linux-next
- status: done
- owner_host: linux
- source: meta-orchestration feedback
- scope:
  - Investigate OOM or port-collision errors among concurrently running agents (OpenCode, Codex, Claude, Gemini).
  - Implement a local `.lock` file system to serialize access to shared local resources (e.g., e2e test execution and port binding).
  - Enforce explicit termination of `tillandsias` background test processes after tests complete.
  - Integrate autoincremental build numbers for local builds to detect and discard stale binaries instantly.
- current_progress: >
    Completed. Slice 1 added `scripts/with-smoke-lock.sh` and routed Linux
    smoke/e2e gates through the shared `build-install-smoke-e2e` lock. Slice 2
    added host-side leaked-process cleanup around Linux build/install and init
    smoke steps, plus installed launcher path/version freshness assertions after
    the autoincremental build-number bump.
- next_action: >
    None for this packet. Future collision findings should be filed as narrower
    packets with the failing smoke log and shared resource named explicitly.
- blocker: none
- events:
  - type: finding
    ts: "2026-06-20T09:10:00Z"
    agent_id: "linux-gemini-antigravity"
    host: "linux"
    note: >
      Filing this optimization issue as mandated by the new meta-orchestration exit contract. Simultaneous agent execution on the shared host is a primary velocity bottleneck. We need a robust local lock to space out the agents.
  - type: claim
    ts: "2026-06-20T13:40:55Z"
    agent_id: "linux-macuahuitl-codex-20260620T134055Z"
    host: "linux"
    lease_id: "agent-concurrency-e2e-lock-20260620T134055Z"
    expires_at: "2026-06-20T17:40:55Z"
    note: >
      Claiming a narrow Linux slice: add a reusable smoke/e2e lock helper,
      wire destructive Linux smoke scripts through it, and record targeted
      validation evidence.
  - type: progress
    ts: "2026-06-20T13:46:14Z"
    agent_id: "linux-macuahuitl-codex-20260620T134055Z"
    host: "linux"
    lease_id: "agent-concurrency-e2e-lock-20260620T134055Z"
    note: >
      Implemented the shared smoke/e2e lock helper and wired it into the
      Linux build-install e2e scripts plus both Linux e2e runbooks. The helper
      records wait/acquire/release lines into each smoke evidence directory
      when `TILLANDSIAS_SMOKE_LOCK_LOG` is set.
    evidence:
      - "bash -n scripts/with-smoke-lock.sh scripts/e2e-step1-linux.sh scripts/e2e-step2-linux.sh scripts/e2e-step3-linux.sh — PASS"
      - "scripts/with-smoke-lock.sh success-path smoke invocation — PASS"
      - "scripts/with-smoke-lock.sh failing-command smoke invocation returned exit 7 and logged release — PASS"
      - "git diff --check — PASS"
      - "scripts/with-smoke-lock.sh --name build-install-smoke-e2e -- ./build.sh --check — PASS"
  - type: released
    ts: "2026-06-20T13:46:14Z"
    agent_id: "linux-macuahuitl-codex-20260620T134055Z"
    host: "linux"
    lease_id: "agent-concurrency-e2e-lock-20260620T134055Z"
    reason: >
      Locking slice complete and pushed in this checkpoint; remaining scope is
      process cleanup plus stale-binary/autoincremental build-number hardening.
  - type: claim
    ts: "2026-06-20T17:07:43Z"
    agent_id: "linux-macuahuitl-codex-20260620T170743Z"
    host: "linux"
    lease_id: "agent-concurrency-process-stale-20260620T170743Z"
    expires_at: "2026-06-20T21:07:43Z"
    note: >
      Claiming a narrow Linux slice: analyze recent smoke/diagnostic artifacts
      for process leaks, stale installed binaries, or port collisions; then add
      focused process-cleanup and stale-binary guardrails with targeted evidence.
  - type: completed
    ts: "2026-06-20T17:12:54Z"
    agent_id: "linux-macuahuitl-codex-20260620T170743Z"
    host: "linux"
    lease_id: "agent-concurrency-process-stale-20260620T170743Z"
    implementation_commit: "this commit"
    note: >
      Added `scripts/with-tillandsias-process-cleanup.sh`, which snapshots
      existing user-owned `tillandsias` PIDs, runs the smoke command, terminates
      only new leaked launcher PIDs, and fails an otherwise successful command
      if it leaked a host process. Wired it into Linux build/install and init
      e2e steps. Added post-install assertions that `command -v tillandsias`
      resolves to `$HOME/.local/bin/tillandsias` and that `tillandsias
      --version` matches the post-build `VERSION` file.
    evidence:
      - "bash -n scripts/with-tillandsias-process-cleanup.sh scripts/e2e-step1-linux.sh scripts/e2e-step2-linux.sh scripts/e2e-step3-linux.sh scripts/with-smoke-lock.sh — PASS"
      - "scripts/with-tillandsias-process-cleanup.sh -- true — PASS/no leak"
      - "deliberately leaked fake `tillandsias` process — wrapper terminated it and returned expected exit 70"
      - "pgrep after leak smoke shows only pre-existing user tray process `/home/tlatoani/.local/bin/tillandsias --tray`"
      - "git diff --check — PASS"
      - "./build.sh --check — PASS with known non-fatal dev-proxy warning"

## Observation 2026-06-20T19:05Z (Cowork meta-orch, linux_mutable)

- collision: duplicate ledger work. This cycle independently edited
  `plan/index.yaml` to (a) close step-58 `future-intentions-drain` + its item-7
  parity drain subtask and (b) fix a duplicate `note:` key in the step-65
  github-login-egress event. While the edits were in the shared working tree, a
  concurrent agent committed the identical fixes as `1d6db6dd` (plus an order-59
  packet). Result: this cycle's `git diff plan/index.yaml` was empty at commit
  time; only the ledger files (ACTIVE.md, loop_status.md) carried in commit
  `9c8f3f9a`. No conflict or data loss — net state correct — but two agents
  spent effort on the same fix.
- mitigation idea: a claim/lease marker on `plan/index.yaml` ledger-hygiene
  edits (not just e2e gates) would let read-only meta-orch cycles detect that a
  node closure is already in flight before re-deriving it. Low priority; the
  collision was idempotent.
