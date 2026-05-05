# Verification Levels

@trace spec:verification-level-tracking

**Use when**: Declaring how thoroughly a spec claim is verified, designing CI enforcement, understanding code-spec evidence chains, or upgrading evidence quality for critical specifications.

## Provenance

- **YAML source**: `Monotonic reduction of uncertainty under verifiable constraints.yaml` (this repo) — system model defining L0-L3 framework
- **Related specs**:
  - `openspec/specs/agent-source-of-truth/spec.md` — cheatsheet sourcing discipline
  - `openspec/specs/trace-annotation/spec.md` — @trace annotation format
- **Last updated:** 2026-05-02

---

## Overview

The **verification level framework** maps claims made in code to observable evidence that backs them up. It answers: *"How much do we actually know this works?"*

### Why Verification Levels Matter

Code assertions are stronger when backed by evidence:
- **L0**: "We designed this" (spec only)
- **L1**: "We designed it AND documented how" (spec + cheatsheet)
- **L2**: "We designed it, documented it, AND verified against authoritative sources" (spec + cheatsheet + API lookup)
- **L3**: "All of the above PLUS we observe it working in production" (spec + cheatsheet + API + runtime proof)

This creates **monotonic reduction of uncertainty**: as evidence accumulates, confidence increases and drift is detected early.

---

## The Four Levels

### L0: Specification Only

**Definition**: A specification exists and clearly states intent, inputs, outputs, and constraints. Implementation exists but has no external evidence backing it.

**What it means**:
- The spec document exists at `openspec/specs/<capability>/spec.md`
- Code is annotated: `// @trace spec:<name>, verified_at:L0`
- No cheatsheet or upstream documentation is cited
- Suitable for: New capabilities being designed, internal algorithms, proof-of-concept implementations

**Example**:
```rust
// @trace spec:tray-app-lifecycle, verified_at:L0
/// Manages the lifecycle of a running development environment.
/// See openspec/specs/app-lifecycle/spec.md for requirements.
pub fn transition_environment(env_id: &str, target_state: State) -> Result<()> {
    // Implementation ...
}
```

**Evidence required for CI**:
- ✅ Spec file exists
- ✅ Code has annotation with `verified_at:L0`
- ❌ No external evidence required

---

### L1: Specification + Cheatsheet

**Definition**: A specification exists AND a curated cheatsheet in `cheatsheets/` documents the behavior, pinning versions and capturing idiomatic patterns from authoritative sources.

**What it means**:
- Spec exists (L0 requirement)
- Cheatsheet exists at `cheatsheets/<category>/<topic>.md`
- Cheatsheet cites ≥1 high-authority source (vendor docs, RFC, ISO standard, official community project)
- Cheatsheet has `@trace spec:<name>` annotation linking back to the spec
- Code references both: `// @trace spec:<name>, verified_at:L1`
- Suitable for: Well-understood tools/languages, standard patterns, documented APIs

**Example**:
```rust
// @trace spec:proxy-cache-config, verified_at:L1
/// Configures Squid proxy with domain allowlist.
/// See cheatsheets/runtime/mitm-proxy-design.md for patterns.
pub fn setup_proxy_cache(config: &ProxyConfig) -> Result<()> {
    // Implementation references cache control headers, domain matching,
    // all documented in the cheatsheet
}
```

**Corresponding cheatsheet entry** (`cheatsheets/runtime/mitm-proxy-design.md`):
```markdown
@trace spec:proxy-cache-config

## Provenance

- https://wiki.squid-cache.org/Features/CacheControl — Official Squid cache control
- https://tools.ietf.org/html/rfc7234 — HTTP caching semantics
- **Last updated:** 2026-05-02

## Quick reference

[proxy configuration patterns]

## See also

- Related spec: `openspec/specs/proxy-cache-config/spec.md`
```

**Evidence required for CI**:
- ✅ Spec file exists
- ✅ Cheatsheet file exists and cites the spec
- ✅ Cheatsheet cites ≥1 authoritative source with URL
- ✅ Code annotation includes `verified_at:L1`
- ❌ No API testing required

---

### L2: Specification + Cheatsheet + API Verification

**Definition**: Everything in L1 PLUS code or tests validate behavior against live upstream documentation or APIs.

**What it means**:
- All L1 requirements met
- Integration test (or documented test scenario) verifies claims against upstream
- Examples:
  - HTTP request to official docs API and parsing response
  - Command-line invocation of tool with version check
  - Schema validation against published XSD/JSON schema
- Code annotation: `// @trace spec:<name>, verified_at:L2`
- Suitable for: APIs that change, tool version-sensitive behavior, standards-compliance critical features

**Example**:
```rust
// @trace spec:ollama-model-pull, verified_at:L2
/// Pulls a model from ollama registry and verifies against manifest.
/// Test: tests/integration/test_ollama_registry_api.rs
/// Last verified: 2026-05-02 against ollama v0.4.3
pub async fn pull_model(name: &str) -> Result<Model> {
    // Implementation validates against live ollama API
}
```

**Corresponding test** (`tests/integration/test_ollama_registry_api.rs`):
```rust
#[tokio::test]
async fn test_ollama_model_manifest_schema() {
    // Fetches real manifest from registry.ollama.ai
    // Validates against spec: openspec/specs/inference-model-pull/spec.md
    // @trace spec:ollama-model-pull, verified_at:L2
    let manifest = fetch_manifest("qwen2.5:0.5b").await.unwrap();
    assert!(manifest.config.size > 0);
    // ... more assertions
}
```

**Evidence required for CI**:
- ✅ Spec exists
- ✅ Cheatsheet exists, cites spec and authoritative sources
- ✅ Integration test exists and validates against upstream
- ✅ Test or code comment documents: source, last verified date, version
- ✅ Code annotation includes `verified_at:L2`

---

### L3: Specification + Cheatsheet + API Verification + Runtime Validation

**Definition**: Everything in L2 PLUS the system collects runtime telemetry showing the specification is actually working in production.

**What it means**:
- All L2 requirements met
- Code emits structured events (telemetry, logging) that prove the behavior works
- Events include:
  - `spec = "<name>"` field linking to spec
  - `cheatsheet = "<path>"` field if cheatsheet was consulted
  - `verification_level = "L3"`
  - Success/failure outcome and any errors
- Events accumulate in append-only log and feed metrics system
- Code annotation: `// @trace spec:<name>, verified_at:L3`
- Suitable for: Safety-critical paths, security boundaries, high-failure-rate operations

**Example**:
```rust
// @trace spec:forge-container-launch, verified_at:L3
pub async fn launch_forge(project: &Project) -> Result<ContainerId> {
    let start = Instant::now();
    match create_and_start_container(project).await {
        Ok(container_id) => {
            // Emit L3 telemetry event
            telemetry::emit(TelemetryEvent {
                spec: "forge-container-launch",
                cheatsheet: "runtime/container-lifecycle.md",
                verification_level: "L3",
                status: "success",
                duration_ms: start.elapsed().as_millis() as u64,
                project_id: project.id.clone(),
                container_id: container_id.clone(),
            });
            Ok(container_id)
        }
        Err(e) => {
            telemetry::emit(TelemetryEvent {
                spec: "forge-container-launch",
                cheatsheet: "runtime/container-lifecycle.md",
                verification_level: "L3",
                status: "failure",
                error: e.to_string(),
                // ...
            });
            Err(e)
        }
    }
}
```

**Corresponding telemetry event** (logged to `~/.cache/tillandsias/telemetry.jsonl`):
```json
{
  "timestamp": "2026-05-02T14:32:15Z",
  "spec": "forge-container-launch",
  "cheatsheet": "runtime/container-lifecycle.md",
  "verification_level": "L3",
  "status": "success",
  "duration_ms": 3200,
  "project_id": "my-app",
  "container_id": "tillandsias-my-app-aeranthos-abc123"
}
```

**Evidence required for CI**:
- ✅ Spec exists
- ✅ Cheatsheet exists, cites spec and authoritative sources
- ✅ Integration test validates against upstream (L2)
- ✅ Code emits telemetry events with spec, status, duration
- ✅ Code annotation includes `verified_at:L3`
- ✅ Telemetry events are collected and queryable (future phase)

---

## Code Annotation Format

### Syntax

```rust
// @trace spec:<spec-name>, verified_at:<L0|L1|L2|L3>
```

### Rules

- **Multiple specs on same line**: `// @trace spec:foo, spec:bar, verified_at:L1` (comma-separated)
- **Default level**: If `verified_at:LX` is omitted, defaults to `L0`
- **One level per annotation**: `verified_at:L2` applies to all specs in that annotation
- **Placement**: Immediately before the function/const/module it describes
- **Language variations**:
  - Rust: `// @trace spec:<name>, verified_at:L1`
  - Bash: `# @trace spec:<name>, verified_at:L1`
  - Markdown/docs: `@trace spec:<name>, verified_at:L1`

### Examples

**Single spec, L0**:
```rust
// @trace spec:tray-menu-rendering, verified_at:L0
fn render_menu(&self) -> MenuItems { ... }
```

**Single spec, L2**:
```rust
// @trace spec:proxy-cache-config, verified_at:L2
fn setup_proxy(config: &ProxyConfig) -> Result<()> { ... }
```

**Multiple specs, L1**:
```rust
// @trace spec:enclave-network, spec:proxy-container, verified_at:L1
async fn configure_enclave(&mut self) -> Result<()> { ... }
```

**No explicit level** (defaults to L0):
```rust
// @trace spec:tray-state-tracking
fn track_container_state(&self, id: &str) { ... }
```

---

## Spec File Format: Declaring Expected Verification Levels

New specs SHOULD include a `## Verification Levels` section declaring what evidence is required/desired. This guides implementation priority and helps maintainers understand the spec's maturity.

### Template

```markdown
## Verification Levels

- **L0**: Specification complete (this section ✓)
- **L1**: [Optional] Cheatsheet added describing implementation patterns and upstream sources
- **L2**: [Optional] Integration test validates [specific behavior] against [upstream source/API]
- **L3**: [Optional] Runtime telemetry collects [specific metric] to verify [behavior] in production

### Current status

Implemented at: **L1** (as of 2026-05-02)

Cheatsheet: `cheatsheets/runtime/proxy-cache-design.md`

Upstream source: https://wiki.squid-cache.org/Features/CacheControl
```

### Full Example

```markdown
<!-- openspec/specs/proxy-cache-config/spec.md -->

# proxy-cache-config Specification

@trace spec:proxy-cache-config

## Purpose

Configure Squid proxy to cache HTTP/HTTPS responses with domain-based allowlist.

## Requirements

[... detailed requirements ...]

## Verification Levels

- **L0**: Specification complete (this document)
- **L1**: Cheatsheet at `cheatsheets/runtime/mitm-proxy-design.md` documents cache control headers, domain patterns, and Squid configuration idioms
- **L2**: Integration test `tests/integration/test_proxy_cache_schema.rs` validates cache control response headers against HTTP/1.1 spec (RFC 7234)
- **L3**: Telemetry logged on every proxy request (cache hit/miss) to verify cache effectiveness in production

### Current status

Implemented at: **L2** (as of 2026-05-02)

- ✅ L0: Spec complete
- ✅ L1: Cheatsheet exists with RFC 7234 provenance
- ✅ L2: Integration test validates cache headers
- 🔄 L3: Telemetry instrumentation in progress (Phase 4)
```

---

## CI Validator Logic (Phase 3)

The CI validator (enhanced from Phase 2) performs these checks:

### Check 1: Annotation Syntax

```
For each code location with `// @trace spec:<name>, verified_at:LX`:
  - Extract spec name(s) and level
  - Validate level ∈ {L0, L1, L2, L3}
  - If level is missing, default to L0 ✓
  - If level is invalid, FAIL ✗
```

### Check 2: Spec Existence

```
For each `spec:<name>`:
  - Lookup openspec/specs/<name>/spec.md
  - If spec exists: PASS ✓
  - If spec missing: FAIL ✗ (same as Phase 2)
```

### Check 3: L1+ Evidence Chain

```
For each code with verified_at:L1 or higher:
  - Spec exists? (Check 2)
  - Cheatsheet exists? Find any cheatsheets/ file that:
    - Contains `@trace spec:<name>` OR
    - Contains spec name in `## Sources of Truth` section
  - If found: PASS ✓
  - If missing: WARN (not error, yet)
```

### Check 4: L2+ API Test Documentation

```
For each code with verified_at:L2 or higher:
  - Code comment or nearby test file should document:
    - Location of integration test (e.g., tests/integration/test_*.rs)
    - What API/upstream is being validated
    - Last verified date + version
  - If documented: PASS ✓
  - If missing: WARN
```

### Check 5: L3+ Telemetry Emission

```
For each code with verified_at:L3:
  - Code should emit telemetry event with:
    - spec = "<name>"
    - cheatsheet = "<path>" (optional but recommended)
    - verification_level = "L3"
    - status = "success" | "failure"
  - If emits: PASS ✓
  - If missing: WARN
```

### Failure Modes

| Scenario | Action |
|----------|--------|
| Spec missing | FAIL (Phase 2 rule, unchanged) |
| Level syntax invalid | FAIL |
| L1+ claimed but cheatsheet missing | WARN → (future) ERROR |
| L2+ claimed but test/comment missing | WARN → (future) ERROR |
| L3 claimed but no telemetry | WARN → (future) ERROR |

---

## Migration Plan for Existing Code

### Current State

Existing code with `// @trace spec:name` (no `verified_at:LX`) defaults to **L0** and requires no changes.

### New Code (Going Forward)

- All new specs start at **L0** (baseline)
- Developers declare the **intended** level in the code annotation
- CI validator warns on mismatches but doesn't block (Phase 3)
- Example:
  ```rust
  // @trace spec:new-feature, verified_at:L1
  // (Implies: I'm committing to a cheatsheet + sources)
  pub fn new_feature() { ... }
  ```

### Gradual Upgrade Path

1. **Phase 3 (now)**: Add annotations, defaults to L0, no errors
2. **Phase 4**: Introduce cheatsheet metrics, enable L1 enforcement
3. **Phase 5**: Enable L2/L3 enforcement for critical paths
4. **Stabilization**: All public APIs require ≥L1, safety-critical require L3

### Do NOT Retroactively Change Existing Annotations

Example of what NOT to do:
```rust
// BAD: changing all old traces to L1
// OLD:   // @trace spec:proxy-config
// NEW:   // @trace spec:proxy-config, verified_at:L1
```

This is wasteful. Instead:
- Let old code stay at L0
- Write cheatsheets and tests for high-impact specs only
- Document expected level in spec's `## Verification Levels` section
- Gradually converge toward higher levels

---

## Checking Your Work

### For Spec Writers

Before archiving a new spec, ask:
1. ✅ Did I write a `## Verification Levels` section?
2. ✅ Did I declare realistic L0-L3 expectations?
3. ✅ Did I add a timeline for reaching higher levels?

### For Implementers

Before committing code, ask:
1. ✅ What level am I claiming? (L0/L1/L2/L3)
2. ✅ Does my annotation match the spec's expected level?
3. ✅ If I claimed L1+, do I have a cheatsheet with sources?
4. ✅ If I claimed L2+, did I write an integration test?
5. ✅ If I claimed L3, does my code emit telemetry?

### For Reviewers

When reviewing a PR:
1. Check annotation syntax: `// @trace spec:<name>, verified_at:LX`
2. Verify spec exists
3. For L1+: Confirm cheatsheet with sources exists
4. For L2+: Confirm test is documented
5. For L3: Confirm telemetry emission code is present

---

## FAQ

**Q: Should I declare L3 for everything?**

A: No. L3 is expensive (requires telemetry infrastructure). Start with L1 or L2, upgrade critical paths later.

**Q: What if I can't write a cheatsheet yet?**

A: Declare L0 now, upgrade to L1 later. Don't retroactively lie about your evidence.

**Q: Can I have multiple specs at different levels on the same function?**

A: One level per annotation, but you can have multiple annotations:
```rust
// @trace spec:proxy-config, verified_at:L2
// @trace spec:network-security, verified_at:L0
fn setup_proxy() { ... }
```

**Q: Who decides if L1→L2 upgrade is worth the effort?**

A: The OpenSpec change process. Update the spec's `## Verification Levels` section and include the effort in task planning.

**Q: Can I emit telemetry in tests only?**

A: No. L3 requires production telemetry. Tests feed L2 (API verification).

---

## See Also

- `Monotonic reduction of uncertainty under verifiable constraints.yaml` — System model and full framework
- `openspec/specs/trace-annotation/spec.md` — @trace syntax and macro enforcement
- `openspec/specs/agent-source-of-truth/spec.md` — Cheatsheet discipline
- `cheatsheets/TEMPLATE.md` — Template for writing a new cheatsheet
- `PHASE_3_DESIGN.md` — Phase 3 implementation roadmap
