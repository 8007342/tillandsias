## Why

Unclean tray shutdowns (crashes, forced termination) leave stale podman secrets in the system. On next startup, secret creation fails with "secret name in use", blocking container launches. This requires manual cleanup (`podman secret rm tillandsias-ca-*`) before the tray can function again.

The fix is to **refresh secrets on each startup**: check if a secret exists, remove it if it does, then create a fresh copy. This makes the tray resilient to unclean shutdowns and ensures all containers get up-to-date CA certificates and credentials.

## What Changes

**Behavior Change**: Ephemeral CA secrets (tillandsias-ca-root, tillandsias-ca-cert, tillandsias-ca-key) are now idempotent on tray startup. If a stale secret exists, it's automatically removed before a fresh one is created.

**Code Change**: In `handlers.rs`, the secret creation logic (`setup_secrets()`) now:
1. Checks if each secret exists via `podman_secret::exists()`
2. If it exists, removes it via `podman_secret::remove()`
3. Creates the fresh secret with `podman_secret::create()`

**No user-facing impact**: This is entirely transparent to users. Tray just works after unclean shutdowns.

## Capabilities

### New Capabilities
- `ephemeral-secret-refresh`: Secret lifecycle management on tray startup — ensures stale secrets don't block container launches

### Modified Capabilities
- `secrets-management`: Spec now documents idempotent secret refresh behavior

## Impact

- **Code**: `src-tauri/src/handlers.rs` (setup_secrets function, ~10 lines changed)
- **Specs**: secrets-management (add MODIFIED requirement for idempotent refresh)
- **Observability**: Existing tracing already in place; will emit "Secret already exists, removing" warnings on restart after unclean shutdown
- **Testing**: Unit tests in podman_secret.rs already cover exists/remove/create; integration test scenario: launch tray, force kill, restart, verify no "secret name in use" error
- **Backward Compatibility**: Fully compatible; old secrets are cleaned up automatically
