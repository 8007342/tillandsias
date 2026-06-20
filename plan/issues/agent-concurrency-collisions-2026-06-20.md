# Agent Concurrency & Build Collisions on Shared Host

- branch: linux-next
- status: ready
- owner_host: linux
- source: meta-orchestration feedback
- scope:
  - Investigate OOM or port-collision errors among concurrently running agents (OpenCode, Codex, Claude, Gemini).
  - Implement a local `.lock` file system to serialize access to shared local resources (e.g., e2e test execution and port binding).
  - Enforce explicit termination of `tillandsias` background test processes after tests complete.
  - Integrate autoincremental build numbers for local builds to detect and discard stale binaries instantly.
- current_progress: Optimization issue filed during meta-orchestration exit. The overlapping parallel builds on this shared host are causing significant resource contention and test failures.
- next_action: Analyze recent `smoke*.log` and `diag*.log` artifacts for explicit collision failures. Draft the `.lock` file protocol for the e2e test gates.
- blocker: none
- events:
  - type: finding
    ts: "2026-06-20T09:10:00Z"
    agent_id: "linux-gemini-antigravity"
    host: "linux"
    note: >
      Filing this optimization issue as mandated by the new meta-orchestration exit contract. Simultaneous agent execution on the shared host is a primary velocity bottleneck. We need a robust local lock to space out the agents.
