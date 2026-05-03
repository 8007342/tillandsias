# Proposal: Migrate Secrets to Podman --secrets

## Executive Summary

Replace bind-mounted certificate files and environment variable-based credential passing with podman's built-in `--secret` mechanism. This eliminates permission issues with `--userns=keep-id`, prevents secrets from appearing in process listings and audit trails, and aligns with Tillandsias' ephemeral-first design principle.

## Problem

### Current State: Insecure Credential Passing

1. **CA Certificates**: Bind-mounted as files (`-v /tmp/ca.crt:/etc/squid/certs/...`)
   - Fail with permission errors in rootless containers (`--userns=keep-id`)
   - Visible in `podman inspect` output
   - May be exposed if filesystem is compromised

2. **GitHub Tokens**: Passed via environment variables (`-e GITHUB_TOKEN=...`)
   - Visible in `podman ps` output
   - Visible in `ps -eaux` inside container
   - Risk of accidental logging (echo, debug prints)

3. **No Built-In Cleanup**: Secrets may persist in `/tmp` after container exits

### Root Cause

Tillandsias uses `--userns=keep-id` for security (run container with host UID). This breaks file-based credential passing because:
- Container process (UID 1000) cannot read host-mounted files with strict ownership checks
- OpenSSL requires specific ownership/permissions that are incompatible with bind mounts
- Environment variables are insecure (visible in process inspection)

## Solution: Podman Secrets

### What Podman Secrets Provide

✅ **Not exposed in process listings** — secrets don't appear in `ps`, `podman ps`, or logs
✅ **SELinux-protected** — container processes can read, other processes cannot
✅ **Work with --userns=keep-id** — no UID mapping issues
✅ **Ephemeral by default** — created at session start, destroyed at shutdown
✅ **Mounted read-only** — containers cannot modify secrets at `/run/secrets/<name>`

### Proposed Changes

1. **CA Certificates**
   - Generate in tray: `openssl req ... > ca.crt && ca.key`
   - Create secrets: `podman secret create tillandsias-ca-cert ca.crt`
   - Mount to containers: `--secret=tillandsias-ca-cert`
   - Container reads from: `/run/secrets/tillandsias-ca-cert`

2. **GitHub Token**
   - Retrieve from OS keyring (GNOME Keyring, KDE Wallet)
   - Create secret: `podman secret create tillandsias-github-token $TOKEN`
   - Mount to containers: `--secret=tillandsias-github-token`
   - Container reads from: `/run/secrets/tillandsias-github-token`

3. **Cleanup**
   - On tray shutdown: `podman secret rm tillandsias-*`
   - Ephemeral secrets are gone immediately

## Migration Path

### Phase 1 (Current Release): Cheatsheets and Documentation
- Create `cheatsheets/utils/podman-secrets.md` (how podman secrets work)
- Create `cheatsheets/utils/tillandsias-secrets-architecture.md` (Tillandsias-specific usage)
- Create specs: `podman-secrets-integration`, `secrets-management` (updated)
- Document in `CLAUDE.md`: "Next release will migrate to podman secrets"

### Phase 2 (Release + 1): Implement Podman Secrets
- Modify `handlers.rs`: use podman secrets for CA certs
- Modify `handlers.rs`: use podman secrets for GitHub tokens
- Update container entrypoints to read from `/run/secrets/`
- Deprecate bind-mount method (log warnings)
- Dual-support: accept both old (bind-mount) and new (secrets) methods

### Phase 3 (Release + 2): Deprecation Period
- Bind-mount method still works (with deprecation warning)
- All new code uses secrets only
- Migration guide in release notes

### Phase 4 (Release + 3): Cleanup
- Remove bind-mount support entirely
- Remove deprecation warnings
- Archive change

## Affected Components

| Component | Impact | Change |
|-----------|--------|--------|
| **handlers.rs** | High | Replace bind-mount CA with `podman secret create` |
| **launch.rs** | High | Add `--secret=tillandsias-ca-cert/key/github-token` flags |
| **proxy entrypoint** | Medium | Copy secrets to working directories |
| **git entrypoint** | Medium | Read token from `/run/secrets/` |
| **Tray shutdown** | Low | Add `podman secret rm` calls |
| **Cheatsheets** | High | Document podman secrets thoroughly |
| **CLAUDE.md** | Low | Add note about secrets architecture |

## Specifications to Create or Update

### New Specs

- `podman-secrets-integration` — How Tillandsias uses podman secrets
- `secrets-management` (update) — Clarify ephemeral vs persistent, add secrets architecture

### Updated Specs

- `proxy-container` — Update CA cert mounting section
- `git-mirror-service` — Update GitHub token passing section
- `ephemeral-guarantee` — Clarify secrets are ephemeral

### Cheatsheets

- `cheatsheets/utils/podman-secrets.md` — Complete reference
- `cheatsheets/utils/tillandsias-secrets-architecture.md` — Tillandsias architecture

## Testing Strategy

### Unit Tests

```rust
// Test secret creation/removal
#[tokio::test]
async fn test_create_ephemeral_secret() {
    let secret_id = podman::secret::create("test-secret", "test-value").await;
    assert!(podman::secret::exists("test-secret").await.unwrap());
    podman::secret::remove("test-secret").await.ok();
    assert!(!podman::secret::exists("test-secret").await.unwrap());
}
```

### Integration Tests

```bash
# 1. Verify CA cert is accessible in proxy container
podman run --secret=tillandsias-ca-cert alpine ls -la /run/secrets/

# 2. Verify GitHub token is accessible in git container
podman run --secret=tillandsias-github-token alpine cat /run/secrets/tillandsias-github-token

# 3. Verify proxy starts with secret-mounted cert
./scripts/diagnose-proxy.sh  # Should not error on permission

# 4. Verify no secrets in process listing
podman run --secret=github-token alpine ps aux | grep -i token  # Should be empty

# 5. Verify secrets cleaned up on shutdown
tillandsias --init && sleep 2 && podman secret ls | grep tillandsias  # Should be empty
```

### Manual Testing

1. Start tray, verify no permission errors in proxy startup
2. Attach to a project, verify git clone works (GitHub token accessible)
3. Kill tray, verify `podman secret ls` shows no tillandsias secrets
4. Verify no secrets in logs: `podman logs tillandsias-proxy | grep -i token` (empty)
5. Verify no secrets in `podman inspect`: check no secret paths in output

## Rollback Plan

If podman secrets cause issues:

1. **Immediate**: Revert `handlers.rs`, `launch.rs`, entrypoint changes
2. **Keep dual-support**: Bind-mount method continues to work
3. **Notify users**: Document issue, provide workaround
4. **Post-mortem**: Investigate root cause (likely SELinux or podman version specific)
5. **Retry**: Fix root cause, re-test thoroughly before next attempt

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Secrets not mounted (podman bug) | Low | Containers fail to start | Test on multiple podman versions, CI gates |
| Permission denied on secret read | Low | Containers crash | SELinux testing, explicit permissions in entrypoint |
| Secrets persist after cleanup | Very Low | Security breach | Verify cleanup in tests, add force cleanup |
| Performance degradation | Very Low | Slow startup | Secrets are tiny, tmpfs-backed |
| Incompatibility with old podman | Low | Doesn't work on old systems | Bump podman version requirement (>= 4.0) |

## Success Criteria

✅ CA certificates mounted via `podman secret` in proxy container
✅ GitHub tokens passed via `podman secret` in git service
✅ All ephemeral secrets removed on tray shutdown
✅ No permission errors with `--userns=keep-id`
✅ Secrets not visible in `podman inspect`, `ps`, or logs
✅ All tests pass (unit, integration, manual)
✅ Comprehensive cheatsheets created with provenance
✅ Zero breaking changes (dual-support for 3 releases)

## Implementation Checklist

Phase 2 (Implement):
- [ ] Create `podman::secret` module with CRUD operations
- [ ] Modify `handlers.rs` to create secrets at tray startup
- [ ] Modify `launch.rs` to pass `--secret` flags to containers
- [ ] Update proxy entrypoint to read from `/run/secrets/`
- [ ] Update git entrypoint to read from `/run/secrets/`
- [ ] Add cleanup in tray shutdown path
- [ ] Write unit tests for secret operations
- [ ] Write integration tests for container access
- [ ] Test on SELinux=enforcing
- [ ] Update `CLAUDE.md` with secrets architecture

Phase 3 (Deprecation):
- [ ] Add deprecation warnings for bind-mount method
- [ ] Document migration path in release notes
- [ ] Keep dual-support working

Phase 4 (Cleanup):
- [ ] Remove bind-mount support
- [ ] Remove deprecation warnings
- [ ] Archive change

## References

- Podman Secrets Docs: https://docs.podman.io/en/latest/markdown/podman-secret.1.html
- Cheatsheets: `cheatsheets/utils/podman-secrets.md`, `cheatsheets/utils/tillandsias-secrets-architecture.md`
- Related Specs: `proxy-container`, `git-mirror-service`, `ephemeral-guarantee`
- OWASP Container Security: https://cheatsheetseries.owasp.org/cheatsheets/Container_Security_Cheat_Sheet.html
