# Active Work — 2026-06-27T05:05Z

## In Progress

| Order | Packet ID | Host | Status | Notes |
|-------|-----------|------|--------|-------|
| 104 | hardcoded-ip-eradication | linux | in_progress | Sub-task `remove-port-publish` blocked on vsock/podman-exec transport migration for native Linux |
| 112 | forge-harness-auth-device-flow | linux | in_progress | Slice 1 done (006f395d): ProviderId + Vault API key storage + forge env injection. Phase 2 (ICAP, --xxx-login CLI) deferred |

## Blocked

| Task | Blocker | Owner |
|------|---------|-------|
| hardcoded-ip/remove-port-publish | Needs vsock or podman-exec transport path for host→vault on native Linux before removing -p 127.0.0.1:8201:8200 | linux |

## Queue Summary

Linux queue: **drained** for this cycle. No `ready` or `pending` packets remain.
Next unblock: shape a packet for native-Linux vault access via podman-exec proxy (no port publish).

## Recent Completions (last 3 days)

- 2026-06-27 order 111: ZeroClaw release packaging (flake.nix + release.yml + install.sh)
- 2026-06-27 order 110: Vault credential persistence (keyring unseal, container rebuilds survive)
- 2026-06-27 order 109: Proxy env centralization (proxy_env_args() helper, apply_proxy_env())
- 2026-06-26 order 108: Transparent proxy feasibility verdict (TPROXY not feasible; containers.conf [engine] env recommended)
