# Smoke E2E Findings — v0.3.260622.2 — 2026-06-22

- release: v0.3.260622.2
- date: 2026-06-22T03:59Z–04:17Z
- host: linux_mutable
- skill: `/smoke-curl-install-and-test-e2e`
- agent_id: linux-claude-opus48-loop-20260622T0359Z
- branch: linux-next @ c06fdd9d

## Summary: PASS (with 1 known blocker)

| Step | Result | Notes |
|---|---|---|
| Install | PASS | v0.3.260622.2 downloaded, SHA256 OK, `tillandsias --version` matches |
| Substrate reset | PASS | `podman system reset --force` clean; ps/volume/images all empty |
| `--init` | PASS | All 5 images built, Vault healthy (initialized=true, sealed=false), all AppRole roles provisioned, exit 0 |
| Forge launch | PASS | Smoke lock, forge container up, opencode agent ran |
| Forge meta-orch | BLOCKED | Credential channel missing (known issue) — no new work done inside forge |

No new findings. All issues observed match previously filed packets.

## Step 3 — Init details (v0.3.260622.2 from scratch)

- Version upgrade detected: `cached 0.3.260621.1 → current 0.3.260622.2`
- All images rebuilt from scratch (expected after podman reset): proxy, vault
- Vault: `initialized=true sealed=false v=1.18.5`
- Transient probe: `Connection reset by peer` on first health check (normal race during Vault startup) — recovered immediately
- Policies written: git-mirror-policy, forge-policy, tray-policy, inference-policy, github-login-policy
- AppRole roles provisioned: git-mirror, forge, tray, inference, github-login
- Exit 0

## Step 4 — Forge run details

- Forge container launched, opencode agent started
- `[entrypoint] WARNING: OpenSpec init failed — /opsx commands may not work` — **known issue**, already filed in `smoke-e2e-findings-2026-06-16.md`
- Meta-orchestration skill invoked, blocked at Credential Channel Guard
- Git mirror now returns **403** (was Connection reset in v0.3.260621.2) — improvement; service is reachable but no auth credentials
- Forge agent discarded uncommitted changes before exit (clean workdir)
- Exit 0

## Known blockers (not re-filed)

- **Forge credential channel**: `plan/issues/forge-credential-channel-blocked-2026-06-21.md`
  - Status: open; smallest next action: re-seed `.git/.gh-credentials` or inject `GH_TOKEN`
  - Note: git mirror improved from Connection-reset to 403 — auth plumbing present, credentials absent
- **OpenSpec init in forge entrypoint**: `plan/issues/build-install-smoke-e2e-findings-2026-06-16.md`
  - Status: existing known issue; /opsx commands unavailable but doesn't block meta-orch

## Events

- type: smoke-pass
  ts: "2026-06-22T04:17:36Z"
  agent_id: "linux-claude-opus48-loop-20260622T0359Z"
  host: linux_mutable
  note: >
    v0.3.260622.2 curl-install + podman-reset + fresh-init + forge-launch all
    PASS. No new findings. Forge meta-orch blocked by known credential channel
    issue (existing packet). Git mirror improved from connection-reset to 403.
