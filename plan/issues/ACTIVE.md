# Active Work — 2026-06-27T04:43Z

## Latest Release

**v0.3.260627.1** — released 2026-06-27T04:43Z via PR #50
- Linux musl x86_64 + aarch64, macOS arm64 tray, Windows x64 tray
- First release to include `tillandsias-zeroclaw-linux-x86_64`
- https://github.com/8007342/tillandsias/releases/tag/v0.3.260627.1

## In Progress

| Order | Packet ID | Host | Status | Notes |
|-------|-----------|------|--------|-------|
| 104 | hardcoded-ip-eradication | linux | in_progress | Sub-task `remove-port-publish` blocked; `vault_kv_get_via_exec` (order 113) now unblocks key-read operations without port publish |
| 112 | forge-harness-auth-device-flow | linux | in_progress | Slice 1 done (006f395d). Phase 2 (ICAP + --xxx-login CLI) deferred |

## Blocked

| Task | Blocker | Owner |
|------|---------|-------|
| hardcoded-ip/remove-port-publish | Vault container init still uses HTTP port 8201 for unseal/root-token ops; steady-state key reads now use podman exec (no port needed) | linux |

## Queue Summary

Linux queue: **drained** — no ready/pending packets.
Next work candidates: shape packet to remove `-p 127.0.0.1:8201:8200` from vault launch now that steady-state reads use `vault_kv_get_via_exec`.

## Recent Completions

- 2026-06-27 order 113: Eliminate raw credential reads from host tray process
- 2026-06-27 order 112 (slice 1): ProviderId enum + forge container API key injection
- 2026-06-27 order 111: ZeroClaw release packaging
- 2026-06-27 order 110: Vault credential persistence (keyring unseal)
- 2026-06-27 order 109: Proxy env centralization
