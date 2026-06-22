# Smoke E2E Findings — v0.3.260622.3 — 2026-06-22

- release: v0.3.260622.3
- date: 2026-06-22T04:38Z–04:58Z
- host: linux_mutable
- skill: `/smoke-curl-install-and-test-e2e`
- agent_id: linux-claude-sonnet46-loop-20260622T0438Z
- branch: linux-next @ aa4050f8

## Summary: PASS (with 1 known blocker — same as v0.3.260622.2)

| Step | Result | Notes |
|---|---|---|
| Install | PASS | v0.3.260622.3 downloaded 7.89 MB/s, SHA256 OK, `tillandsias --version` = 0.3.260622.3 |
| Substrate reset | PASS | `podman system reset --force` clean; ps/volume/images all empty |
| `--init` | PASS | All images built, Vault healthy (initialized=true, sealed=false, v=1.18.5), all AppRole roles provisioned, exit 0 |
| Forge launch | PASS | Smoke lock, forge container up, opencode agent ran |
| Forge meta-orch | BLOCKED | Credential channel missing (known issue) — no new work done inside forge |

**No new findings** vs v0.3.260622.2. All vault timeout improvements shipped cleanly.

## Step 3 — Init details (v0.3.260622.3 from scratch)

- Version: `0.3.260622.3` confirmed in init log
- All images rebuilt from scratch (expected after podman reset): proxy, vault, git, inference, forge-base, chromium-core, chromium-framework, forge
- Vault: `initialized=true sealed=false v=1.18.5`
- Transient probe: `Connection reset by peer` on first health check (normal race during Vault startup) — recovered immediately
- Policies written: git-mirror-policy, forge-policy, tray-policy, inference-policy, github-login-policy
- AppRole roles provisioned: git-mirror, forge, tray, inference, github-login
- Exit 0

## Step 4 — Forge run details

- Forge container launched, opencode agent started
- `[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work` — **known issue**, already filed
- Credential Channel Guard FAILED (same as v0.3.260622.2): no `.git/.gh-credentials`, no `GH_TOKEN`, `gh auth status` not logged in
- Git mirror returns **403** (same as v0.3.260622.2 — no regression from connection-reset)
- In-forge agent updated `loop_status.md` + `ACTIVE.md` blocker file (documentation-only work, within exit contract)
- Exit 0

## Known blockers (not re-filed — same as v0.3.260622.2)

- **Forge credential channel**: `plan/issues/forge-credential-channel-blocked-2026-06-21.md`
  - Status: open; smallest next action: re-seed `.git/.gh-credentials` via `podman cp` from host or inject `GH_TOKEN`
  - No regression from v0.3.260622.2 — same 403 on git mirror
- **OpenSpec init in forge entrypoint**: existing known issue; /opsx commands unavailable but doesn't block meta-orch

## Vault timeout change verification

The primary purpose of this smoke was to verify v0.3.260622.3 (vault timeout 60s→120s, order 77) doesn't break the init path. **Confirmed clean**: Vault initialized and unsealed on first attempt in well under 120s on this mutable Linux host. The timeout increase provides headroom for VM guests (macOS VZ, WSL2) without impacting native Linux.

## Events

- type: smoke-pass
  ts: "2026-06-22T04:58:10Z"
  agent_id: "linux-claude-sonnet46-loop-20260622T0438Z"
  host: linux_mutable
  note: >
    v0.3.260622.3 curl-install + podman-reset + fresh-init + forge-launch all
    PASS. Vault timeout 60s→120s change ships cleanly. No new findings vs
    v0.3.260622.2. Forge meta-orch blocked by known credential channel issue.
