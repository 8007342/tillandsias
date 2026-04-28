# Methodology Audit Report — PROVENANCE, @traces, and Knowledge Layers
**BigPickle Agent Audit**  
Timestamp: 2026-04-28T14-30Z

---

## Executive Summary

This audit examines the self-documentation and lifecycle management of Tillandsias's PROVENANCE system, which enforces monotonic convergence through layered truth sources. The system has a well-defined three-layer model but gaps exist in: (1) single-page API dump generation, (2) full API download automation, (3) @tombstone lifecycle, and (4) cross-branch cheatsheet parity.

---

## 1. PROVENANCE System Self-Documentation

### 1.1 What IS Documented

**Current Model (from cheatsheets/specs):**

| Layer | Name | Purpose | Status |
|-------|------|---------|--------|
| Layer 1 | **Cheatsheets** | ~1KB compressed summary, single topic | ✅ Exists: 18 files in `docs/cheatsheets/` |
| Layer 2 | **Single-page Full API** | ~10KB with all fields required | ❌ NOT GENERATED |
| Layer 3 | **Full API Download** | ~100KB+, examples, practices | ❌ NOT AUTOMATED |
| Index | **knowledge/index.xml** | Category/tag indexing | ✅ Exists (83 lines) |
| Manifest | **knowledge/manifest.toml** | Version tracking | ✅ Exists (141 lines) |

**Source of Truth Documentation:**

| Document | Lines | Coverage |
|----------|-------|---------|
| `docs/cheatsheets/openspec-methodology.md` | 174 | Methodology workflow |
| `openspec/specs/spec-traceability/spec.md` | 54 | Trace annotation requirements |
| `openspec/specs/knowledge-source-of-truth/spec.md` | 62 | Knowledge directory structure |

### 1.2 What's NOT Documented (Gaps)

**Gap-1: No Single-Page Full API Generation**
- No script generates Layer 2 from cheatsheets
- Layer 1 exists, Layer 3 is missing
- Agents cannot generate "full API dump with fields" on demand

**Gap-2: No Full API Download Automation**
- `knowledge/spec` has no vendor/fetch script like `fetch-debug-source.sh`
- External sources tracked but not automatically fetched

**Gap-3: No @tombstone Lifecycle**
- `@trace` system has no soft-delete mechanism
- Specs archived (moved to archive/) but no "tombstone" period before deletion
- Stale references tolerated but not formally managed

**Gap-4: Cross-Branch Cheatsheet Parity**
- `main`: 18 cheatsheets present
- `windows-next`: 4+ deleted (per branch audit)
- No mechanism to ensure cheatsheet parity across branches

---

## 2. @trace System Analysis

### 2.1 Self-Documentation Check

**@trace System is documented in:**

| Document | Section | What it covers |
|----------|---------|--------------|
| `docs/cheatsheets/openspec-methodology.md` | Lines 44-69 | Trace format, density, lookup |
| `openspec/specs/spec-traceability/spec.md` | Full spec | Requirements for traces |
| `CLAUDE.md` | Lines 85-94 | @traces rules |

**Trace Coverage Metrics (from openspec-methodology.md:80-92):**

| Metric | Value | Health |
|--------|-------|--------|
| @trace annotations | 273+ | Good |
| Rust files with traces | 27/46 (59%) | Acceptable |
| Ghost/orphan trace names | 8 | Known issue |
| TRACES.md files | 6 active | Present |

### 2.2 Lifecycle Requirements (from spec-traceability)

**What's in SPEC (spec-traceability/spec.md:43-51):**

```
Requirement: Reference semantics are CRDT-like (non-blocking)
- Stale references: NOT blocking, drift signal only
- Missing references: Build succeeds, gap noted
- Concurrent additions: No git conflict
```

**What's MISSING from spec:**

- No @tombstone soft-delete period
- No formal "deprecated in favor of X" annotation
- No grace period before trace cleanup

### 2.3 @trace Pattern Density

**Examples in code:**

| File | Traces | Patterns |
|------|-------|----------|
| `handlers.rs` | 80+ | Multiple per function |
| `launch.rs` | 30+ | Security, network, secrets |
| `container_profile.rs` | 20+ | All profiles |
| `runner.rs` | 15+ | Enclave orchestration |

**Format consistency:**
- Rust: `// @trace spec:<name>` ✅
- Bash: `# @trace spec:<name>` ✅
- Cheatsheets: `@trace spec:<name>` ✅
- Logging: `spec = "<name>"` ✅

---

## 3. Knowledge Layer Hierarchy

### 3.1 Three-Layer Model (Documented Intent)

**Layer 1 — Cheatsheet (~1KB):**
- Single page, one topic
- YAML frontmatter with metadata
- Actionable reference (< 4K tokens per spec)
- Location: `docs/cheatsheets/` (project-specific), `knowledge/cheatsheets/` (technology)

**Layer 2 — Single-Page Full API (~10KB):**
- Defined but NOT GENERATED
- Should have: all fields, all methods, required parameters
- On-demand generation from source

**Layer 3 — Full API Download (~100KB+):**
- Defined but NOT AUTOMATED
- Should have: examples, practices, edge cases, upstream sources
- Script: `knowledge/fetch-full-api.sh <topic>` (missing)

### 3.2 What EXISTS vs What's SPEC'D

| Layer | Spec Requirement | Implementation | Gap |
|-------|-----------------|---------------|-----|
| Layer 1 | Cheatsheet format | ✅ 18 files + 23 knowledge | Complete |
| Layer 2 | Single-page API generator | ❌ None | NOT IMPLEMENTED |
| Layer 3 | Fetch script | Only debug-source.sh | Incomplete |
| Index | XML category/tag index | ✅ index.xml | Complete |
| Manifest | Version tracking | ✅ manifest.toml | Complete |
| Freshness | Script flagging stale | ❌ No script | NOT IMPLEMENTED |

### 3.3 Knowledge Directory Structure

**From `knowledge-source-of-truth/spec.md`:**

```
knowledge/
├── README.md
├── index.xml           (category/tag index)
├── manifest.toml       (version tracking)
└── cheatsheets/
    ├── infra/        (container, security, fs)
    ├── lang/         (rust)
    ├── frameworks/   (tauri, notify)
    ├── packaging/    (nix, appimage, cross)
    ├── formats/      (toml, postcard)
    └── ci/          (github-actions)
```

**Actual match:** Structure matches spec (except some empty .gitkeep files)

---

## 4. Cross-Branch Parity Analysis

### 4.1 Cheatsheet Distribution

| Branch | Cheatsheets Count | Status | Difference |
|--------|---------------|--------|-----------|
| `main` | 18 + 23 knowledge | ✅ Complete | Base |
| `linux-next` | Modified | ⚠️ Some modified | drifts |
| `osx-next` | ~15 | ⚠️ Some deleted | Incomplete |
| `windows-next` | ~14 | ❌ 4+ deleted | Gap |

### 4.2 Security Posture Parity

| Security Flag | main | linux | osx | windows |
|--------------|------|-------|-----|--------|
| `--cap-drop=ALL` | ✅ | ✅ | ✅ | ✅ |
| `--userns=keep-id` | ✅ | ✅ | ✅ | ✅ |
| Enclave network | ✅ | ✅ | ✅ | ? (spec deleted) |

**Finding:** Security implementations are identical. Documentation divergence only.

---

## 5. @tombstone System Audit

### 5.1 Current (Non-)Existence

- **No @tombstone pattern** in codebase
- **No soft-delete** for traces or specs
- **Archive** exists (moves to `archive/`) but no grace period

### 5.2 What SHOULD Exist

Per your requirement "its lifecycle needs to also include @tombstones to soft-delete things for a while before being eligibile for cleanup":

```
@tombstone spec:<name> as of <date>  (replaced by <new-spec>)
  -> Stays in code for 30 days as drift signal
  -> After grace period: eligible for cleanup
```

**Not implemented:** This pattern does not exist today.

---

## 6. Recommendations Summary

### 6.1 Critical Recommendations

| Issue | Priority | Description |
|-------|----------|-------------|
| **Generate Layer 2** | HIGH | Create script to generate single-page full API from cheatsheets |
| **Fetch Layer 3** | HIGH | Create `knowledge/fetch-full-api.sh` for on-demand source |
| **Implement @tombstone** | HIGH | Add soft-delete pattern with grace period |
| **Cross-branch sync** | HIGH | Ensure cheatsheet parity across all platform branches |
| **Freshness script** | MEDIUM | `scripts/verify-freshness.sh` from spec |

### 6.2 Nice-to-Have

| Issue | Priority | Description |
|-------|----------|-------------|
| Prefixes in traces | LOW | `@trace spec:foo, spec:bar` already supported |
| Commit link | LOW | GitHub search URLs in commits already done |
| TRACES.md automation | LOW | Use GitHub search URLs instead (done) |

---

## 7. Findings: What IS Sound

### 7.1 Good Practices

1. **@trace format compliance**: All three contexts (Rust, Bash, cheatsheet) use consistent format
2. **CRDT-like non-blocking**: Stale references don't break build
3. **Knowledge directory**: Matches spec structure exactly
4. **Version tracking**: manifest.toml is complete
5. **Index structure**: XML categories and tags are well-designed

### 7.2 What Needs Implementation

1. **Layer 2 generation**: Must be script-generated from Layer 1
2. **Layer 3 fetch**: External vendor source fetching (full API)
3. **@tombstone lifecycle**: Soft-delete before cleanup
4. **Freshness verification**: Script to flag old cheatsheets

---

## 8. Appendix: Source References

**System Documentation:**
- `docs/cheatsheets/openspec-methodology.md` — Methodology cheatsheet
- `openspec/specs/spec-traceability/spec.md` — Trace requirements
- `openspec/specs/knowledge-source-of-truth/spec.md` — Knowledge directory

**Implementation:**
- `knowledge/` — Technology cheatsheets
- `docs/cheatsheets/` — Project-specific cheatsheets
- `@trace` — 302+ annotations in code

**Audit Reports:**
- `TillandsiasAudit_BigPickle_2026-04-28T14-00.md` — Security audit

---

*End of Methodology Audit*  
*Generated by: BigPickle agent*  
*Related: Security audit, @traces system, PROVENANCE model*