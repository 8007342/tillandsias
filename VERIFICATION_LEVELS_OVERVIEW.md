# Verification Levels: Overview & Quick Start

@trace spec:verification-level-tracking

This document provides a quick index for the Phase 3 verification level system. See the full design docs for details.

## The Four Levels (Quick Reference)

| Level | Means | Evidence Required |
|-------|-------|---|
| **L0** | Spec exists | Specification document only |
| **L1** | Spec + documented knowledge | Cheatsheet with ≥1 authoritative source URL |
| **L2** | Spec + knowledge + API validation | Integration test validating behavior against upstream |
| **L3** | Spec + knowledge + API + production proof | Runtime telemetry events logged to system |

## Code Annotation (New Syntax)

```rust
// @trace spec:<name>, verified_at:L0|L1|L2|L3
```

**Examples:**
```rust
// @trace spec:proxy-config, verified_at:L1
pub fn setup_proxy() { ... }

// @trace spec:forge-launch, verified_at:L2
pub async fn launch_forge() { ... }

// @trace spec:container-start, verified_at:L3
pub fn start_container() { ... }
```

**Default**: If `verified_at:LX` is omitted, defaults to L0.

## Where to Learn More

1. **User-friendly explanation**: `docs/cheatsheets/verification-levels.md`
   - What each level means
   - Annotation examples
   - When to use each level
   - FAQ

2. **Implementation design**: `PHASE_3_DESIGN.md`
   - Annotation format details
   - Spec file format (new `## Verification Levels` section)
   - CI validator logic (pseudocode)
   - Migration plan
   - Timeline

3. **System model**: `Monotonic reduction of uncertainty under verifiable constraints.yaml`
   - Philosophical foundation
   - Rules for each level
   - CI enforcement modes

## For Different Roles

### Spec Writers

1. When creating a new spec, include `## Verification Levels` section:
   ```markdown
   ## Verification Levels
   
   - **L0**: Specification complete (this document ✓)
   - **L1**: Cheatsheet at `cheatsheets/.../....md` documents patterns
   - **L2**: [Optional] Integration test validates against upstream
   - **L3**: [Optional] Runtime telemetry collected
   
   ### Current Status
   
   Implemented at: **L1**
   ```

2. Declare realistic expectations for evidence

### Implementers

1. When implementing a spec, declare the level you're claiming:
   ```rust
   // @trace spec:my-feature, verified_at:L1
   ```

2. Make sure your claim is backed by evidence:
   - **L1**: Cheatsheet exists with sources
   - **L2**: Integration test exists
   - **L3**: Code emits telemetry events

### Reviewers

1. Check annotation syntax: `// @trace spec:<name>, verified_at:LX`
2. Verify claimed level matches evidence:
   - L1+: Cheatsheet should exist
   - L2+: Integration test should be documented
   - L3: Code should emit telemetry

## CI Validation (Phase 3)

The build script now validates:
- ✅ Spec exists
- ✅ Level syntax is valid (L0/L1/L2/L3)
- ✅ L1+ claims have matching cheatsheets
- ⚠️ L2+ claims have documented tests (warning only, Phase 3)
- ⚠️ L3 claims emit telemetry (warning only, Phase 3)

**Exit code**: 0 if valid (warnings OK), 1 if syntax error or spec missing

## Migration: No Breaking Changes

- **Existing code**: All keep L0 default, no changes required
- **New code**: Declare explicit level with annotation
- **Upgrade path**: Selectively add cheatsheets/tests to higher levels (gradual)
- **No retroactive changes**: Don't lie about old code's evidence

## Common Patterns

### Simple Feature (L0)

```rust
// @trace spec:my-feature, verified_at:L0
// No external evidence, internal algorithm only
pub fn my_feature() { ... }
```

### Standard Feature (L1)

```rust
// @trace spec:proxy-cache, verified_at:L1
// See cheatsheets/runtime/mitm-proxy-design.md for patterns
pub fn setup_proxy() { ... }
```

### API Integration (L2)

```rust
// @trace spec:ollama-pull, verified_at:L2
// Test: tests/integration/test_ollama_api.rs
// Validates against: https://registry.ollama.ai
pub async fn pull_model(name: &str) -> Result<Model> { ... }
```

### Production-Critical (L3)

```rust
// @trace spec:forge-startup, verified_at:L3
// Telemetry event: spec="forge-startup", status, duration_ms
// Logged to: ~/.cache/tillandsias/events.jsonl
pub async fn start_forge(project: &Project) -> Result<()> {
    let start = Instant::now();
    match do_startup().await {
        Ok(id) => {
            emit_telemetry("forge-startup", "success", start.elapsed());
            Ok(id)
        }
        Err(e) => {
            emit_telemetry("forge-startup", "failure", start.elapsed());
            Err(e)
        }
    }
}
```

## FAQ

**Q: Should I add `verified_at:L3` to everything?**

A: No. L0 is the baseline, L1 is typical, L2 is for APIs, L3 is for safety-critical. Start conservative.

**Q: What if I can't write a cheatsheet yet?**

A: Use L0 for now. Upgrade to L1 later when you have time.

**Q: Do I need to update existing code?**

A: No. Existing code stays L0 by default. New code declares explicit levels.

**Q: What if my spec has multiple levels in progress?**

A: Use the `## Verification Levels` section in the spec to show which are done vs. planned:
```markdown
✅ L0: Complete
✅ L1: Cheatsheet written
⏳ L2: Test in progress
🔄 L3: Planned for Phase 5
```

## Files Created (Phase 3)

- `docs/cheatsheets/verification-levels.md` — User guide for all roles
- `PHASE_3_DESIGN.md` — Complete design spec (annotation format, CI logic, timeline)
- `VERIFICATION_LEVELS_OVERVIEW.md` — This file, quick index

## Timeline

- **Phase 3 (now)**: Design complete, CI validator implementation begins
- **Phase 4 (future)**: Introduce cheatsheet metrics, enable stricter validation
- **Phase 5+ (future)**: Automated compaction, full convergence loop

## See Also

- `Monotonic reduction of uncertainty under verifiable constraints.yaml`
- `CLAUDE.md` (trace annotations section)
- `cheatsheets/TEMPLATE.md` (template for new cheatsheets)
