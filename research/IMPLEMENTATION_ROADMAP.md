# Podman Abstraction Layer — Implementation Roadmap

**Based on**: IDIOMATIC_PODMAN.md research findings  
**Timeline**: 8-12 weeks, five prioritized phases  
**Ownership**: Tillandsias core team (headless + podman crates)

---

## Overview

This roadmap translates the research report into concrete implementation tasks. Each phase is:
- **Independent**: Can be merged separately without blocking others
- **Deliverable**: Produces testable code and observability improvements
- **Aligned**: With Tillandsias' "NEVER polling" and security-first principles
- **Tracked**: Via OpenSpec changes (one per phase)

---

## Phase 1: Event-Driven Architecture (Weeks 1-3)

**Priority**: 🔴 **HIGHEST** — blocks all downstream phases  
**Effort**: 2-3 weeks  
**Impact**: Eliminates polling, aligns with stated principles  
**Dependencies**: None

### Scope: Replace polling with `podman events` streaming

#### Deliverables

1. **New `PodmanEventStream` type** (async streaming)
   - File: `crates/tillandsias-podman/src/events.rs` (complete rewrite)
   - Behavior: Stream `podman events --format=json` with filtering
   - Output: Typed `PodmanEvent` enum (Start, Stop, Die, Health, etc)
   - Error handling: Reconnect on socket close (ephemeral failures)

2. **Integrate event stream into headless runtime**
   - File: `crates/tillandsias-headless/src/main.rs`
   - Behavior: Replace polling loop with `tokio::select!` waiting on events
   - Observability: Emit JSON events on stdout as before
   - Graceful shutdown: Cancel event stream on SIGTERM

3. **Remove all `sleep()` polling loops**
   - Search: `grep -r "sleep(" crates/tillandsias-headless crates/tillandsias-core`
   - Replace: Integrate with event stream instead
   - Test: Verify zero sleep() calls remain in hot path

4. **Update state machine** (`crates/tillandsias-core/src/state.rs`)
   - Add: Event-driven state transitions
   - Remove: Time-based polling state predictions
   - Test: State machine handles all event sequences

#### Testing

```bash
# Verify events are received
timeout 10 podman run --rm -d alpine sleep 100 2>&1 | \
  while read -r line; do
    echo "[event] $line"
  done

# No sleep() calls in hot path
cargo grep -n 'sleep\|Sleep' --lib tillandsias-headless | wc -l
# ✓ Should be 0 (or only in test helpers)

# Event stream never misses state changes
cargo test --test event_reliability -- --nocapture
# ✓ All events captured in order
```

#### Metrics (Before/After)

| Metric | Before | After | Target |
|--------|--------|-------|--------|
| CPU wake-ups per minute | 12 (every 5s) | < 1 (event-driven) | 0 |
| Latency to detect container exit | 2.5s (avg) | < 100ms | < 50ms |
| Memory for polling state | 2-4 MB | < 100KB | < 100KB |

#### OpenSpec Change

- **Spec**: `openspec/specs/container/event-driven-orchestration.md`
- **Type**: Enhancement (existing feature, better implementation)
- **Backwards compat**: Yes (same output, faster)

---

## Phase 2: Error Categorization & Retry Logic (Weeks 4-5)

**Priority**: 🟡 **HIGH** — unblocks Phase 3, improves reliability  
**Effort**: 1-2 weeks  
**Impact**: Automatic retry on transient failures, clear error semantics  
**Dependencies**: Phase 1 (optional but recommended)

### Scope: Categorize Podman errors, enable retry with backoff

#### Deliverables

1. **Enhanced `PodmanError` enum** (with categorization)
   - File: `crates/tillandsias-podman/src/errors.rs`
   - Variants:
     - Transient: `NetworkUnreachable`, `Timeout`, `TemporaryFailure`
     - NotFound: `ImageNotFound { image }`, `ContainerNotFound { container }`, `NetworkNotFound { network }`
     - Configuration: `InvalidConfig { reason }`, `PermissionDenied { detail }`, `StorageFull`
     - Unknown: `Unknown { message, source: Option<Box<dyn Error>> }`
   - Methods:
     - `is_transient(&self) -> bool`
     - `is_not_found(&self) -> bool`
     - `is_configuration(&self) -> bool`
     - Impl `std::error::Error` with proper `source()` support

2. **Parse Podman CLI errors into categories**
   - File: `crates/tillandsias-podman/src/client.rs`
   - Detection: Pattern match stderr for "image not found", "network not found", etc.
   - Exit codes: Map 125 → configuration error, 127 → not found, etc.
   - Fallback: Unknown if pattern doesn't match

3. **Retry helper with exponential backoff**
   - File: `crates/tillandsias-podman/src/retry.rs` (new)
   - Function: `retry_with_backoff<F, T>(f: F, max_retries: usize) -> Result<T>`
   - Backoff: 100ms → 200ms → 400ms → ... → 30s (capped)
   - Logging: Emit `warn!()` on transient errors, `error!()` on permanent
   - Cancellation: Respect `tokio::time::Instant::now() + timeout`

4. **Update all container operations**
   - Files: `crates/tillandsias-podman/src/client.rs`, `launch.rs`
   - Apply: Wrap `launch()`, `stop()`, `inspect()` with retry logic
   - Configuration: Retries for transient only; fail fast for not-found/configuration
   - Logging: Structured logging with attempt count, backoff duration

#### Testing

```bash
# Test error categorization
cargo test --lib tillandsias_podman::errors --lib tillandsias_podman::client

# Test retry logic with transient failures
cargo test --lib tillandsias_podman::retry -- --nocapture

# Verify no hang on permanent errors
timeout 5 cargo test --lib tillandsias_podman::client::launch_not_found
# ✓ Should exit quickly (not wait for retries)
```

#### Observability

```rust
// Structured logging
info!(attempt=1, backoff_ms=100, error=?err, "Transient error, retrying...");
warn!(attempt=3, backoff_ms=400, "Max retries exceeded");
error!(error=?err, "Permanent error, giving up");
```

#### OpenSpec Change

- **Spec**: `openspec/specs/container/error-handling-and-retry.md`
- **Type**: Enhancement (new capability)
- **Backwards compat**: Yes (same behavior, better observability)

---

## Phase 3: Enclave Formalization (Weeks 6-8)

**Priority**: 🟡 **HIGH** — improves architectural clarity  
**Effort**: 2-3 weeks  
**Impact**: First-class Enclave type, enables reattachment, cleaner state machine  
**Dependencies**: Phase 1 (event-driven), Phase 2 (error handling)

### Scope: Formalize Enclave lifecycle as first-class resource

#### Deliverables

1. **`Enclave` type** (first-class container collection)
   - File: `crates/tillandsias-podman/src/enclave.rs` (new)
   - Fields:
     - `name: String` (enclave identifier)
     - `network: String` (podman network name)
     - `containers: Vec<Container>` (proxy, git, forge, inference)
     - `state: EnclaveState` (Initializing, Ready, Degraded, Shutting, Destroyed)
     - `created_at: SystemTime`
   - Methods:
     - `create(name, config) -> Result<Enclave>` (atomic setup)
     - `reattach(project_path) -> Result<Enclave>` (reconnect to running enclave)
     - `shutdown(self) -> Result<()>` (atomic teardown)
     - `health_check() -> Result<EnclaveHealth>` (status summary)

2. **`Container` type** (lifecycle model)
   - Fields:
     - `id: String` (Podman container ID)
     - `name: String` (container name)
     - `state: ContainerState` (Created, Running, Stopped, Error)
     - `created_at: SystemTime`
     - `started_at: Option<SystemTime>`
     - `exit_code: Option<i32>`
   - Methods:
     - `launch(client, spec) -> Result<Container>`
     - `stop(client) -> Result<()>`
     - `inspect(client) -> Result<ContainerState>`
     - `logs(client) -> Result<impl Stream<Item=String>>`

3. **`EnclaveState` enum** (state machine)
   - `Initializing` → `Ready` (success) or `Degraded` (some containers failed)
   - `Ready` → `Shutting` (graceful shutdown)
   - `Shutting` → `Destroyed` (cleanup complete)
   - `Degraded` → `Ready` (recovery) or `Shutting` (give up)

4. **Reattachment logic** (restart tool, reconnect to running enclave)
   - Behavior: Query Podman for network, list containers on it, reconstruct state
   - Use case: User kills tray, restarts, tool reconnects without recreating containers
   - Atomicity: Fail if network exists but is partially degraded

#### Testing

```bash
# Create enclave
cargo test --lib tillandsias_podman::enclave::create

# Reattach to enclave (after simulated crash)
cargo test --lib tillandsias_podman::enclave::reattach

# State transitions
cargo test --lib tillandsias_podman::enclave::state_transitions

# Atomic shutdown
cargo test --lib tillandsias_podman::enclave::shutdown
```

#### Integration Points

- **Headless runtime**: Initialize enclave on startup, reattach if exists
- **Tray app**: Display enclave name/status in window title
- **Event stream**: Subscribe to container events within enclave
- **Observability**: Emit enclave-level events (EnclaveReady, EnclaveDegraded, etc)

#### OpenSpec Change

- **Spec**: `openspec/specs/container/enclave-model.md`
- **Type**: Enhancement (new abstraction)
- **Backwards compat**: No (refactors container launch/stop), but improves clarity

---

## Phase 4: Cheatsheet Development (Weeks 8-9)

**Priority**: 🟢 **MEDIUM** — knowledge capture, enables agent onboarding  
**Effort**: 1 week  
**Impact**: Future agents understand idiomatic Podman patterns  
**Dependencies**: None (independent)

### Scope: Document Podman patterns in searchable cheatsheet format

#### Deliverables

1. **`cheatsheets/runtime/podman-idiomatic-patterns.md`** (create/finalize)
   - Sections:
     - Event streaming (non-polling)
     - Security flags (always required)
     - Storage isolation (enclave model)
     - Secrets (ephemeral-first)
     - Error handling and retry logic
     - Networking (enclave model)
     - Rootless mode
     - GPU passthrough
     - Logging and observability
     - Common error patterns
     - Performance tips
   - Format: Markdown with code examples (Bash + Rust)
   - Provenance: Links to official docs (Podman, Red Hat, OCI spec, man7)
   - Update date: Last refreshed date

2. **Integrate into cheatsheets/INDEX.md**
   - Add entry: `runtime/podman-idiomatic-patterns.md`
   - Searchable keywords: podman, event, secret, error, network, security

3. **Update code with `@cheatsheet` traces**
   - Add traces to `tillandsias-podman` implementation pointing to cheatsheet
   - Example: `// @cheatsheet runtime/podman-idiomatic-patterns.md — security flags`
   - Enables bidirectional linking between code and knowledge

#### Validation

```bash
# Check cheatsheet provenance
grep -E '^- \[' cheatsheets/runtime/podman-idiomatic-patterns.md | head -5
# ✓ Should show high-authority sources

# Verify Last updated date
grep 'Last updated:' cheatsheets/runtime/podman-idiomatic-patterns.md
# ✓ Should be within 1 week

# Verify INDEX.md mentions it
grep podman-idiomatic cheatsheets/INDEX.md
# ✓ Should find entry
```

#### OpenSpec Change

- **Spec**: Not a spec change; knowledge artifact
- **Track**: Via `methodology/cheatsheets.yaml` (already covered)

---

## Phase 5: Optional — Cross-Platform Secrets (Weeks 10-12)

**Priority**: 🟢 **LOW** — only if macOS/Windows support becomes a requirement  
**Effort**: 3-4 weeks  
**Impact**: Enables Podman Machine (macOS) and WSL (Windows) support  
**Dependencies**: Phase 1 (event-driven), Phase 2 (error handling), Phase 3 (enclave)

### Scope: Integrate with platform-specific keyrings for secret management

#### Deliverables

1. **Platform abstraction layer** (`crates/tillandsias-podman/src/secrets_platform.rs`)
   - Interface: `trait SecretBackend`
     - `get(key: &str) -> Result<String>`
     - `set(key: &str, value: &str) -> Result<()>`
     - `delete(key: &str) -> Result<()>`
   - Implementations:
     - Linux: `LinuxSecretService` (D-Bus-based, org.freedesktop.Secret)
     - macOS: `MacOSKeychain` (Security.framework)
     - Windows: `WindowsCredentialManager` (wincred.h)

2. **Credential retrieval at startup**
   - Behavior: Load GitHub token, CA cert from platform keyring
   - Fallback: Environment variables if keyring unavailable
   - Error handling: Log warn if secrets unavailable, continue (degraded mode)

3. **Platform-specific tests**
   - Test: Retrieve secret from keyring, use in podman container
   - Test: Cleanup on shutdown (no leftovers in keyring)
   - Manual test: Verify on actual macOS/Windows machines

#### Dependencies

- Linux: `zbus` crate (D-Bus client)
- macOS: `security-framework` crate
- Windows: `windows` crate (wincred module)

#### Conditional Compilation

```rust
#[cfg(target_os = "linux")]
mod linux {
    use zbus::...
    pub struct LinuxSecretService { ... }
}

#[cfg(target_os = "macos")]
mod macos {
    use security_framework::...
    pub struct MacOSKeychain { ... }
}

#[cfg(target_os = "windows")]
mod windows {
    use windows::Win32::Security::Credentials::...
    pub struct WindowsCredentialManager { ... }
}
```

#### Note

This phase is **deferred** unless macOS/Windows support is actively being developed. Linux-only approach (current) is sufficient for MVP.

---

## Implementation Guidelines

### OpenSpec Discipline

Each phase produces one OpenSpec change:
1. Create: `openspec/changes/<change>/proposal.md` (overview)
2. Design: `openspec/changes/<change>/design.md` (architecture decisions)
3. Spec: `openspec/changes/<change>/specs/<capability>/spec.md` (detailed spec)
4. Implement: Use `/opsx:apply` skill to manage tasks
5. Archive: Use `/opsx:archive` skill to merge delta specs to main

### Code Quality Gates

- **Type checking**: `cargo check --all-targets` passes
- **Tests**: `cargo test --workspace` passes
- **Linting**: `cargo clippy --all-targets` passes
- **Coverage**: New code has >80% test coverage
- **Traces**: All public functions have `@trace spec:*` comments
- **Cheatsheets**: Complex behavior referenced in cheatsheet

### Dependency Management

**Do NOT add external libraries for core operations.**

Allowed additions:
- `tokio` — already present for async
- `tracing` — already present for observability
- Crates for platform-specific code (Phase 5 only):
  - `zbus` (Linux D-Bus)
  - `security-framework` (macOS)
  - `windows` (Windows)

### Git Workflow

1. Create feature branch: `git checkout -b phase1/event-driven`
2. Implement + test: Full cycle per phase
3. Commit with trace: `@trace spec:event-driven-orchestration` in commit message
4. Create PR: Reference OpenSpec change ID
5. Merge when: All gates pass, review approved

### Estimated Timeline

| Phase | Duration | Start | End | Blocker |
|-------|----------|-------|-----|---------|
| 1: Events | 3 weeks | Week 1 | Week 3 | None |
| 2: Errors | 2 weeks | Week 4 | Week 5 | Phase 1 ✓ |
| 3: Enclave | 3 weeks | Week 6 | Week 8 | Phases 1-2 ✓ |
| 4: Cheatsheet | 1 week | Week 8 | Week 9 | Independent |
| 5: Secrets (opt) | 4 weeks | Week 10 | Week 13 | All previous |

**Critical path**: Phases 1 → 2 → 3 (8 weeks)  
**Total with Phase 5**: 12-13 weeks

---

## Success Criteria

### Phase 1: Event-Driven
- ✅ Zero `sleep()` calls in hot path
- ✅ Latency to detect container exit < 100ms
- ✅ All container lifecycle events streamed via `podman events`

### Phase 2: Error Handling
- ✅ Transient errors automatically retry with backoff
- ✅ Not-found errors fail fast (no retry)
- ✅ Configuration errors logged with context

### Phase 3: Enclave
- ✅ Enclave can reattach to running containers after restart
- ✅ Atomic multi-container setup/teardown
- ✅ Enclave health check returns aggregated status

### Phase 4: Cheatsheet
- ✅ Cheatsheet searchable, up-to-date, with provenance
- ✅ All sections have code examples
- ✅ Code has `@cheatsheet` traces pointing to it

### Phase 5: Secrets (if completed)
- ✅ Credentials retrieved from platform keyring
- ✅ No secrets in container logs or ps output
- ✅ Cleanup on shutdown verified

---

## Risk Mitigation

### Risk: Event stream misses state changes
**Mitigation**: Implement fallback health check (periodic verify, not polling)

### Risk: Error categorization has gaps
**Mitigation**: Categorize as Unknown, log context, iterate

### Risk: Reattachment logic breaks existing state
**Mitigation**: Dry-run reattach logic first; only read existing state, don't modify

### Risk: Phase 5 breaks Linux-only deployment
**Mitigation**: Feature-gate secrets platform code; Linux code path unchanged

---

## References

- **Research report**: `research/IDIOMATIC_PODMAN.md`
- **Cheatsheet template**: `cheatsheets/runtime/podman-idiomatic-patterns.md`
- **OpenSpec workflow**: `methodology.yaml`, `methodology/bootstrap/router.yaml`
- **Trace discipline**: `methodology/event/index.yaml`

---

**Document version**: 1.0  
**Last updated**: May 12, 2026  
**Status**: Ready for implementation
