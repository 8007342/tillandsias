# Tillandsias Security & Architecture Audit Report
**BigPickle Agent Audit**  
Timestamp: 2026-04-28T14:00Z

---

## Executive Summary

This audit covers the Tillandsias cross-platform system tray application (Rust + Tauri v2) that orchestrates containerized development environments using a privacy-first enclave architecture. The codebase demonstrates sophisticated security engineering with room for improvement in cross-platform spec alignment.

**Overall Assessment: MOSTLY SOUND** with identified gaps requiring fixes.

---

## Section 1: Security, Isolation & Privacy Boundaries

### 1.1 What's SOUND (Correct Implementation)

| Area | Status | Evidence |
|------|--------|----------|
| Hardcoded security flags | ✅ CORRECT | `launch.rs:48-51`, `handlers.rs:636-638`: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id` are non-negotiable and hardcoded |
| Zero-credential forging | ✅ CORRECT | `container_profile.rs:208-236`: `forge_opencode_profile()` and `forge_claude_profile()` have empty `secrets` lists |
| Enclave network isolation | ✅ CORRECT | `tillandsias-podman/src/lib.rs:16`: `ENCLAVE_NETWORK = "tillandsias-enclave"`; forge containers use `tillandsias-enclave` only (no bridge) |
| Process limits per container | ✅ CORRECT | `container_profile.rs:58,216,232,369,412,443`: pids_limit correctly scoped (512 for forge, 32 for proxy, 128 for inference) |
| Read-only service containers | ✅ CORRECT | `container_profile.rs:370,414,444`: proxy, inference, git_service have `read_only: true` with proper tmpfs mounts |
| Accountability logging | ✅ CORRECT | `logging.rs`, `accountability.rs`: No token values in logs, spec URLs at trace level |
| @trace coverage | ✅ GOOD | 302 @trace annotations across codebase linking to specs |

### 1.2 What's BRITTLE / Needs Fixes

#### ISSUE-1: Cross-Platform Branch Divergence — Major Documentation Gap

**Finding:** `windows-next` has deleted critical security documentation:
- `docs/cheatsheets/enclave-architecture.md` (COMPLETE DELETION — 230 lines)
- `docs/cheatsheets/forge-launch-critical-path.md` (173 lines)
- `docs/cheatsheets/input-escaping.md` (72 lines)
- `docs/cheatsheets/mitm-proxy-design.md` (960 lines)

**Impact:** The windows-next branch lacks source-of-truth documentation for:
- Enclave network topology and security invariants
- Proxy allowlist architecture
- Credential isolation boundaries

**Source Files:**
- `git diff origin/main..origin/windows-next -- docs/cheatsheets/enclave-architecture.md` (deletion confirmed)

**Recommended Fix:**
```
fix-cross-platform-spec-archive
- Restore deleted cheatsheets from main to windows-next and osx-next
- Add PROVENANCE header tracking spec lineage per file
- Ensure every security cheatsheet has cross-platform applicability markers
```

#### ISSUE-2: linux-next Secret Mount Drift — `ClaudeDir` Introduction

**Finding:** `linux-next` introduces `SecretKind::ClaudeDir` in `container_profile.rs:138`:
```rust
/// Mount ~/.claude/ into the container (rw).
ClaudeDir,
```

**Inconsistency with main:**
- Main branch: forge profiles have empty `secrets` (correct for Phase 3 offline)
- Linux-next: `ClaudeDir` suggests mounting Claude config dir into forge

**Spec Conflict:**
- `openspec/specs/secret-management/spec.md:9-24`: "Forge containers SHALL have zero credentials"
- `openspec/specs/forge-offline/spec.md:9`: "Forge containers have zero credentials"

**Source Files:**
- `crates/tillandsias-core/src/container_profile.rs` (main + linux-next diff)
- `openspec/changes/archive/2026-04-04-forge-offline-isolation/tasks.md` (incomplete task: "Remove SecretKind::GitHubToken and SecretKind::ClaudeDir")

**Recommended Fix:**
```
fix-secret-mount-coherence
- Remove SecretKind::ClaudeDir from profile definitions on main
- Ensure forge_opencode_profile() and forge_claude_profile() have zero secrets
- Verify against secret-management spec zero-credential requirement
```

#### ISSUE-3: Dual-Path hosts.yml Persistence

**Finding:** The `hosts.yml` bind mount persists alongside tmpfs token files per `secret-management.md:85-92`:
- This is documented as "transitional" but no Phase 4 cleanup tracked

**Spec Gap:** No requirement for hosts.yml removal timeline in `secret-management/spec.md`

**Source Files:**
- `src-tauri/src/secrets.rs` (hosts_yml write)
- `docs/cheatsheets/secret-management.md:85-92` (dual-path documentation)

**Recommended Fix:**
```
fix-hosts-yml-cleanup
- Add requirement in secret-management spec for hosts.yml removal timeline
- Implement Phase 4 of fine-grained-pat-rotation to remove dual-path
```

### 1.3 High-Level Security Patterns

#### What's CORRECT:
- **Defense in depth**: Multiple layers (tmpfs + keyring + deny list)
- **Ephemeral by default**: All containers use `--rm`
- **Hardened network**: Forge has ZERO external route — enclave-only
- **Credential proxy**: Git service acts as credential proxy via D-Bus

#### What Needs Attention:
- **Documentation drift**: Cross-platform branches must maintain spec sync
- **Incomplete tasks**: Archive changes with abandoned tasks should be explicitly cancelled, not left pending
- **Phase tracking**: Phases 1-3 marked complete in docs, but some implementation tasks incomplete

---

## Section 2: @trace Coverage & Observability

### 2.1 @trace Distribution

**Total @trace annotations found:** 302 (Rust) + shell scripts + cheatsheets

**Coverage by Spec:**

| Spec | Annotations | Status |
|------|-------------|--------|
| `spec:enclave-network` | 53 | ✅ Comprehensive |
| `spec:podman-orchestration` | 40+ | ✅ Comprehensive |
| `spec:proxy-container` | 35+ | ✅ Comprehensive |
| `spec:secret-management` | 25+ | ✅ Comprehensive |
| `spec:git-mirror-service` | 52 | ✅ Comprehensive |
| `spec:inference-container` | 12 | ✅ Covered |
| `spec:layered-tools-overlay` | 40+ | ✅ Covered |

**Source Files:**
- `grep "@trace spec:" src-tauri/src/*.rs` (302 matches)
- `grep "@trace spec:" crates/tillandsias-*/src/*.rs` (extensive coverage)

### 2.2 TRACES.md Auto-Generation

**Status:** Present and functional for active specs but incomplete for archived changes:

**Finding:** TRACES.md files link code annotations to specs but some archived changes show outdated links:
- `openspec/specs/tray-icon-lifecycle/TRACES.md` (active, correct)
- ARCHIVED changes: Some TRACES.md files reference deleted files or incomplete implementations

**Source Files:**
- `openspec/specs/*/TRACES.md` (6 active TRACES)
- `openspec/specs/*/spec.md` (44+ spec files)

**Recommended Fix:**
```
fix-trace-link-audit
- Run generate-traces.sh on main
- Verify all TRACES.md links resolve to existing source lines
- Update or archive orphaned TRACES files
```

---

## Section 3: CHEATSHEETS & PROVENANCE

### 3.1 What's SOUND

**Active CHEATSHEETS with PROVENANCE:**

| Cheatsheet | Status | PROVENANCE |
|-----------|--------|------------|
| `enclave-architecture.md` | ✅ Current on main | Linked to specs, 230 lines |
| `secret-management.md` | ✅ Current on main | Linked to secrets and enclaves |
| `logging-levels.md` | ✅ Current | Full accountability documentation |
| `token-rotation.md` | ✅ Current | Details tmpfs + GIT_ASKPASS |
| `terminal-tools.md` | ✅ Current | Tool references |

**PROVENANCE markers present:**
- Line-level `@trace spec:<name>` annotations in cheatsheets
- Source file references linking to Rust implementation
- Related specs section at bottom of each cheatsheet

### 3.2 Gaps & Divergence

**CRITICAL:** `windows-next` and `osx-next` diverge by DELETING cheatsheets:

| Deleted in windows-next | Impact |
|--------------------------|--------|
| `enclave-architecture.md` | Loss of security model source of truth |
| `forge-launch-critical-path.md` | Loss of launch flow documentation |
| `input-escaping.md` | Loss of shell safety patterns |
| `mitm-proxy-design.md` | Loss of proxy architecture (960 lines) |

**Root Cause:** Branch-per-machine strategy without cross-branch sync of documentation

**Source Files:**
- `git diff origin/main..origin/windows-next --stat` (files deleted)

**Recommended Fix:**
```
fix-documentation-parity
- Ensure all branches maintain identical docs/cheatsheets/
- Use PROVENANCE headers to track which spec a cheatsheet satisfies
- Add cross-platform markers (e.g., "PLATFORM: linux|macos|windows")
```

---

## Section 4: Specification Completeness

### 4.1 Active Specs (44+ files)

| Spec | Lines | Requirements | Coverage |
|------|-------|---------------|-----------|
| `enclave-network/spec.md` | 33 | 15+ requirements | ✅ Complete |
| `secret-management/spec.md` | 231 | 30+ requirements | ✅ Complete |
| `proxy-container/spec.md` | 266 | 25+ requirements | ✅ Complete |
| `git-mirror-service/spec.md` | 104 | 9 requirements | ✅ Complete |
| `forge-offline/spec.md` | 40 | 3 requirements | ✅ Covered |
| `secret-rotation/spec.md` | 162 | 10 requirements | ✅ Covered |
| `logging-accountability/spec.md` | 97 | 9 requirements | ✅ Covered |

### 4.2 Specification Gaps

#### ISSUE-4: Missing Cross-Platform Spec Divergence Tracking

**Finding:** No spec requirement tracks platform-specific behavior differences:
- Linux: podman-native networking
- macOS: podman machine required
- Windows: podman machine + WSL2 backend

**Spec Gap:** `spec:cross-platform` exists but doesn't enforce identical behavior

**Source Files:**
- `crates/tillandsias-core/src/config.rs` (platform detection)
- `crates/tillandsias-podman/src/client.rs` (machine management)

**Recommended Fix:**
```
fix-cross-platform-spec
- Add requirement: "All platforms MUST produce identical container security posture"
- Document platform-specific orchestration differences in cross-platform spec
- Add test verification of security flag parity across platforms
```

#### ISSUE-5: Incomplete Archive Changes

**Finding:** Some OpenSpec changes are archived but contain incomplete task items:
- `openspec/changes/archive/2026-04-04-forge-offline-isolation/tasks.md`:
  - Task 1.2: "[ ] Remove SecretKind::GitHubToken and SecretKind::ClaudeDir" (NOT COMPLETE)

**Source Files:**
- `openspec/changes/archive/*/tasks.md` (multiple archived changes)

**Impact:** Incomplete tasks create confusion about Phase completion status

**Recommended Fix:**
```
fix-archive-task-cleanup
- Mark incomplete tasks as cancelled, not pending
- Add "ABANDONED" status to orphaned task items
- Ensure archived changes reflect actual code state
```

---

## Section 5: Implementation vs. Specification Coherence

### 5.1 Verified Coherent Pairs

**Security Enforcement (✅ COHERENT):**

| Spec Requirement | Implementation | Verified |
|-----------------|---------------|----------|
| Forge zero credentials | `forge_opencode_profile()` secrets: [] | ✅ |
| Non-negotiable flags | `launch.rs:48-51` | ✅ |
| pids limits per role | `container_profile.rs` | ✅ |
| Read-only services | `proxy_profile().read_only = true` | ✅ |
| Token tmpfs | `token_file::write()` | ✅ |
| Enclave network | `ENCLAVE_NETWORK` constant | ✅ |

**IPC Model (✅ COHERENT):**

| Spec Requirement | Implementation | Verified |
|-----------------|---------------|----------|
| Git mirror clone | `entrypoint-forge-*.sh` git clone | ✅ |
| HTTP via proxy | env vars `HTTP_PROXY` | ✅ |
| D-Bus for git service | `SecretKind::DbusSession` | ✅ |
| ollama local | `OLLAMA_HOST` env var | ✅ |

### 5.2 Specification Gaps (Not Yet Implemented)

**Known Unimplemented Features:**

| Feature | Spec Location | Status |
|---------|---------------|--------|
| Fine-grained PAT rotation | `fine-grained-pat-rotation/` | Phase 1-2 only |
| hosts.yml removal | `secret-management/spec.md` | Not in requirements |
| Per-project allowlist | `enclave-architecture.md:141` | Planned, not spec'd |
| Windows D-Bus equivalent | `spec:cross-platform` | Incomplete |

---

## Section 6: Cross-Platform Branch Comparison

### 6.1 Branch State Summary

| Branch | Version | Divergence from main | Security Docs |
|--------|---------|---------------------|----------------|
| `main` | v0.1.37.25 | — | ✅ Complete |
| `linux-next` | +2 build | Spec changes, SecretKind expansion | ⚠️ Modified |
| `osx-next` | +2 build | Entry point changes, locale changes | ⚠️ Some deleted |
| `windows-next` | +2 build | MAJOR deletions (cheatsheets) | ❌ Incomplete |

### 6.2 Security Posture Parity

**Verified Security Flags Across Branches:**

| Flag | main | linux-next | osx-next | windows-next |
|------|------|------------|----------|-------------|
| `--cap-drop=ALL` | ✅ Present | ✅ Present | ✅ Present | ✅ Present |
| `--security-opt=no-new-privileges` | ✅ Present | ✅ Present | ✅ Present | ✅ Present |
| `--userns=keep-id` | ✅ Present | ✅ Present | ✅ Present | ✅ Present |
| `--rm` | ✅ Present | ✅ Present | ✅ Present | ✅ Present |
| Enclave network | ✅ Present | ✅ Present | ✅ Present | Unknown (spec deleted) |

**Finding:** Security flags are correctly implemented across all branches BUT the specification documentation is missing on windows-next.

---

## Section 7: Good Practices Documented

### 7.1 Architecture Excellence

1. **Event-driven (NEVER polling)**: notify crate for filesystem, podman events for containers
2. **Defense in depth**: tmpfs token files + host keyring + D-Bus proxy + OpenCode deny list
3. **Ephemeral by default**: --rm on all containers, tmpfs for secrets
4. **Process isolation**: per-container pids limits preventing fork bombs
5. **Accountability windows**: Curated output hiding secrets

### 7.2 Operational Excellence

1. **Monotonic convergence**: OpenSpec ensures specs and code move toward each other
2. **Trace annotations**: @trace creates bidirectional spec-code links
3. **Cheatsheets as sources of truth**: Comprehensive operational knowledge bases
4. **Version tracking**: Full 4-part version with build automation

### 7.3 Security Discipline

1. **Non-negotiable flags**: Hardcoded in launch.rs, cannot be overridden
2. **Zero-credential forge**: Phase 3 achieves credential-free development environments
3. **Network isolation**: Internal-only enclave with controlled egress
4. **Credential proxy pattern**: Git service as credential holder, not forge

---

## Recommendations Summary

### Critical Fixes Required

1. **fix-cross-platform-spec-archive**: Restore deleted cheatsheets to windows-next and osx-next
2. **fix-secret-mount-coherence**: Remove SecretKind::ClaudeDir, verify zero credentials

### Recommended Improvements

3. **fix-hosts-yml-cleanup**: Add Phase 4 requirement for hosts.yml removal
4. **fix-trace-link-audit**: Verify TRACES.md links resolve
5. **fix-documentation-parity**: Ensure all branches maintain identical docs/
6. **fix-archive-task-cleanup**: Mark incomplete tasks as cancelled
7. **fix-cross-platform-spec**: Add identical behavior requirement for all platforms

---

## Appendix: Source References

**Core Security Implementation:**
- `src-tauri/src/launch.rs` (lines 48-51: security flags)
- `src-tauri/src/handlers.rs` (lines 636-638: security flags)
- `crates/tillandsias-core/src/container_profile.rs` (profiles definition)
- `crates/tillandsias-podman/src/lib.rs:16` (ENCLAVE_NETWORK)

**Specification Files:**
- `openspec/specs/enclave-network/spec.md` (15 requirements)
- `openspec/specs/secret-management/spec.md` (30 requirements)
- `openspec/specs/forge-offline/spec.md` (3 requirements)
- `openspec/specs/proxy-container/spec.md` (25 requirements)

**Cheatsheets:**
- `docs/cheatsheets/enclave-architecture.md` (source of truth: security model)
- `docs/cheatsheets/secret-management.md` (credential lifecycle)
- `docs/cheatsheets/token-rotation.md` (tmpfs pattern)
- `docs/cheatsheets/logging-levels.md` (accountability system)

**Trace Generation:**
- `@trace spec:` pattern (302 annotations in Rust)
- `scripts/generate-traces.sh` (TRACES.md generation)

---

*End of Audit Report*  
*Generated by: BigPickle agent*  
*Branch reviewed: main + linux-next + osx-next + windows-next*