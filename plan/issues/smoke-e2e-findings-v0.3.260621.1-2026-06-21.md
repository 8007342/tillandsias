# Smoke E2E Findings: v0.3.260621.1 (2026-06-21)

- release_tag: v0.3.260621.1
- date: 2026-06-21
- host: linux_mutable
- verdict: BLOCKED

## Summary of Run

1. **Install**: **PASS** — Downloaded and verified `v0.3.260621.1` (installed successfully on PATH).
2. **Reset**: **PASS** — `podman system reset --force` completed successfully, leaving a pristine substrate.
3. **Init**: **PASS** — `tillandsias --debug --init` completed cleanly. All containers built, network created, and Vault initialized/unsealed correctly (`init_exit=0`).
4. **OpenCode**: **BLOCKED** — Launched `tillandsias . --opencode --prompt "Use the /meta-orchestration skill"`. The in-forge agent aborted at startup because the credential channel was absent and both `tillandsias-git:8080` (git-mirror) and Vault (`https://vault:8200`) were unreachable from inside the forge container.

---

### Work Packet: smoke-finding/forge-credential-channel-blocked

- id: `smoke-finding/forge-credential-channel-blocked`
- owner_host: linux
- capability_tags: [podman, vault, testing, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.3.260621.1`
- evidence:
  - `target/smoke-e2e/04-opencode.log:42` — `fatal: unable to access 'http://tillandsias-git:8080/tillandsias.git/': Recv failure: Connection reset by peer`
  - `target/smoke-e2e/04-opencode.log:119` — `You are not logged into any GitHub hosts. To log in, run: gh auth login`
  - `target/smoke-e2e/04-opencode.log:199` — `vault unreachable`
- repro:
  - Run the release e2e smoke:
    ```bash
    tillandsias . --opencode --prompt "Use the /meta-orchestration skill"
    ```
- next_action: >
    Investigate why `tillandsias-git:8080` (git-mirror) and Vault (`https://vault:8200`) are unreachable from within the forge container, and resolve the container credential forwarding gap.
- events:
  - type: discovered
    ts: "2026-06-21T15:27:00Z"
    agent_id: "gemini-antigravity-worker-20260621T1511Z"
    host: linux_mutable
