## Context

Tillandsias creates ephemeral CA certificates (root + intermediate) on every tray startup, storing them in tmpfs (RAM) with 30-day validity. These certificates are injected into containers via podman secrets for HTTPS proxy verification.

Currently, `handlers.rs::setup_secrets()` creates three secrets without checking for existing ones:
- `tillandsias-ca-root` (root certificate)
- `tillandsias-ca-cert` (intermediate certificate)
- `tillandsias-ca-key` (intermediate private key)

If the tray crashes or is force-killed, `cleanup_all()` never runs, leaving stale secrets in the podman backend. Next startup, `podman secret create` fails with "secret name in use".

## Goals / Non-Goals

**Goals:**
- Make secret creation idempotent: refresh stale secrets automatically on startup
- Eliminate "secret name in use" errors from unclean shutdowns
- Require zero user intervention (no manual `podman secret rm` needed)
- Preserve existing secret cleanup on normal shutdown
- Maintain security: secrets are still ephemeral in tmpfs, not persisted to disk

**Non-Goals:**
- Implement persistent secret storage (secrets remain ephemeral)
- Add secret versioning or history
- Support dynamic secret rotation during tray runtime (only on startup)
- Modify podman secret backend or driver

## Decisions

**Decision 1: Check-then-remove-then-create pattern**

Implementation in `setup_secrets()`:
```rust
for (name, value) in [("tillandsias-ca-root", root_cert), ...] {
    if podman_secret::exists(name)? {
        podman_secret::remove(name)?;  // idempotent: succeeds if not found
    }
    podman_secret::create(name, value)?;
}
```

**Rationale**: Uses existing `podman_secret` module functions, maintains clear control flow, fails fast if removal fails (indicates permission issue).

**Alternative Considered**: Use `podman secret create --replace` flag (if available). Rejected: flag availability varies by podman version; explicit remove is more portable.

**Decision 2: Log stale secret removal as `WARN` level**

When a secret is removed because it existed, emit:
```rust
warn!(
    spec = "secrets-management",
    secret = %name,
    reason = "stale secret from unclean shutdown",
    "Removing and refreshing podman secret"
);
```

**Rationale**: Alerts users/operators that an unclean shutdown occurred, without blocking startup. Users can optionally investigate, but tray proceeds.

**Decision 3: No special handling for remove failures**

If `podman_secret::remove()` fails (e.g., permission error), propagate the error and fail startup. This is a genuine problem requiring user intervention.

**Rationale**: A remove failure indicates a deeper issue (corrupted podman backend, permissions). Silently continuing could leave contradictory state.

## Risks / Trade-offs

**Risk 1: Race condition with concurrent tray instances**

If two tray instances start simultaneously on the same machine, both might attempt to remove/create the same secrets, causing transient conflicts.

**Mitigation**: Tillandsias already enforces single-instance via singleton guard (checked in main.rs). No additional sync needed.

**Risk 2: Operator confusion about "stale secret" warnings**

Users seeing "removing stale secret" logs might think something is wrong.

**Mitigation**: Log message is clear and informative. Cheatsheet and troubleshooting docs will explain this as normal behavior after unclean shutdown.

**Trade-off: Performance**

Each startup now calls `podman secret ls` (to check exists) + `podman secret rm` + `podman secret create` per secret. Previously just create. This adds ~30ms per startup (negligible UI impact).

**Mitigation**: Minimal; startup is already waiting for image pulls and container spawns (seconds of latency). 30ms is unnoticeable.

**Risk 3: Operator-created secrets with tillandsias-* names get deleted**

If an operator manually creates a secret named `tillandsias-custom`, it won't be deleted (cleanup_all filters by exact names). But if they use `tillandsias-ca-*`, it will conflict with our cleanup.

**Mitigation**: Document naming convention in cheatsheet: operators should NOT create secrets with `tillandsias-*` prefix. This is an implementation detail.
