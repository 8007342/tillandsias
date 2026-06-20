# Agent Concurrency & Build Collisions on Shared Host

- branch: linux-next
- status: claimed
- owner_host: linux
- source: meta-orchestration feedback
- scope:
  - Investigate OOM or port-collision errors among concurrently running agents (OpenCode, Codex, Claude, Gemini).
  - Implement a local `.lock` file system to serialize access to shared local resources (e.g., e2e test execution and port binding).
  - Enforce explicit termination of `tillandsias` background test processes after tests complete.
  - Integrate autoincremental build numbers for local builds to detect and discard stale binaries instantly.
- current_progress: >
    Slice 1 completed: `scripts/with-smoke-lock.sh` now provides a reusable
    smoke/e2e lock with `flock` plus `mkdir` fallback, Linux build-install
    e2e step scripts use the shared `build-install-smoke-e2e` lock, and the
    local-build/curl-install e2e skill runbooks route Linux gates through the
    same helper.
- next_action: >
    Analyze recent `smoke*.log` and `diag*.log` artifacts for explicit
    process-leak, stale-binary, or port-collision failures; then implement the
    remaining process-termination and autoincremental build-number guardrails.
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
