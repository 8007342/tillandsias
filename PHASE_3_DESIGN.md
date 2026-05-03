# Phase 3 Design: Verification Level Tracking

@trace spec:verification-level-tracking

**Status**: Design-only, ready for implementation  
**Timeline**: Design complete 2026-05-02; implementation begins after Phase 3 approval  
**Author**: Claude (Agent)  
**Related**: `Monotonic reduction of uncertainty under verifiable constraints.yaml`, `docs/cheatsheets/verification-levels.md`

---

## Executive Summary

Phase 3 introduces **verification level tracking**: a system for declaring and validating how thoroughly spec claims are backed by evidence. This reduces uncertainty monotonically by tracking the evidence chain:

- **L0**: Spec defines intent (baseline)
- **L1**: Spec + cheatsheet with authoritative sources
- **L2**: Spec + cheatsheet + upstream API validation
- **L3**: Spec + cheatsheet + API + runtime telemetry

The phase adds annotation syntax, CI validation logic, and tracking infrastructure without breaking existing code.

---

## Design Goals

1. **Monotonic reduction of uncertainty**: Each higher level adds observable evidence, making claims more trustworthy
2. **Non-breaking migration**: Existing code stays at L0; new code declares explicit levels
3. **Falsifiable claims**: Every level declares what would prove the claim (cheatsheet presence, API test, telemetry event)
4. **CI enforcement ready**: Phase 3 builds CI validator logic; enforcement (warnings) begins Phase 3, strict errors Phase 4+
5. **Documentation clarity**: Spec writers know what evidence is expected; implementers know what they're claiming

---

## 1. Annotation Format

### Syntax

```
// @trace spec:<name>, verified_at:L0|L1|L2|L3
```

### Rules

1. **Mandatory fields**: `spec:<name>` (already in use); `verified_at:LX` is NEW and OPTIONAL
2. **Default behavior**: If `verified_at` is omitted, assume L0 (no error, just default)
3. **Multiple specs**: All on one line, comma-separated
   ```rust
   // @trace spec:proxy-config, spec:network-security, verified_at:L1
   ```
4. **One level per annotation**: If specs have different levels, use separate annotations
   ```rust
   // @trace spec:proxy-config, verified_at:L2
   // @trace spec:network-security, verified_at:L0
   ```
5. **Language variants**:
   - Rust: `// @trace spec:<name>, verified_at:LX`
   - Shell: `# @trace spec:<name>, verified_at:LX`
   - Markdown: `@trace spec:<name>, verified_at:LX`
   - Comments in other languages: adjust syntax (e.g., `/* @trace ... */` for C/JS)

### Examples

**Baseline (L0, no external evidence)**:
```rust
// @trace spec:tray-state-tracking, verified_at:L0
pub fn track_environment(id: &str, state: State) { ... }
```

**L1 (with cheatsheet)**:
```rust
// @trace spec:container-lifecycle, verified_at:L1
pub fn launch_container(config: &Config) -> Result<Container> { ... }
```

**L2 (with API test)**:
```rust
// @trace spec:ollama-model-pull, verified_at:L2
pub async fn pull_model(name: &str) -> Result<Model> { ... }
```

**L3 (with production telemetry)**:
```rust
// @trace spec:forge-startup, verified_at:L3
pub async fn start_forge(project: &Project) -> Result<()> { ... }
```

**Multiple specs at same level**:
```rust
// @trace spec:enclave-network, spec:proxy-container, verified_at:L1
async fn setup_enclave(&mut self) -> Result<()> { ... }
```

---

## 2. Spec File Format: Verification Levels Section

### New Section in Specs

Each spec MAY include a `## Verification Levels` section (SHOULD for new specs, OPTIONAL for existing specs during Phase 3).

### Template

```markdown
## Verification Levels

- **L0**: Specification complete (this document ✓)
- **L1**: [Optional description] Cheatsheet at `cheatsheets/<category>/<topic>.md` with ≥1 authoritative source
- **L2**: [Optional description] Integration test at `tests/integration/test_*.rs` validates [behavior] against [upstream source]
- **L3**: [Optional description] Runtime telemetry emits `spec="<name>"` events to verify [behavior] in production

### Current Status

**Implemented at: L<X> (as of YYYY-MM-DD)**

✅ L0: Spec complete
✅ L1: Cheatsheet: `cheatsheets/.../...md` (sources: [URL])
⏳ L2: Integration test planned (task: #NNN)
🔄 L3: Telemetry instrumentation in progress
```

### Example 1: Conservative (L0 only)

```markdown
## Verification Levels

- **L0**: Specification complete (this document ✓)
- **L1**: Not planned — internal algorithm, no upstream documentation

### Current Status

Implemented at: **L0**
```

### Example 2: Standard (L0→L1)

```markdown
## Verification Levels

- **L0**: Specification complete (this document ✓)
- **L1**: Cheatsheet documents patterns and sources for Squid proxy configuration

### Current Status

Implemented at: **L1** (as of 2026-05-02)

- ✅ L0: Spec complete
- ✅ L1: Cheatsheet at `cheatsheets/runtime/mitm-proxy-design.md`
  - Sources: https://wiki.squid-cache.org/Features/CacheControl, RFC 7234
```

### Example 3: High-Assurance (L0→L3)

```markdown
## Verification Levels

- **L0**: Specification complete (this document ✓)
- **L1**: Cheatsheet at `cheatsheets/runtime/container-lifecycle.md` with container lifecycle patterns
- **L2**: Integration test at `tests/integration/test_podman_api.rs` validates against live podman API
- **L3**: Telemetry on every container launch captures duration, success/failure, and container ID

### Current Status

Implemented at: **L3** (as of 2026-05-02)

- ✅ L0: Spec complete
- ✅ L1: Cheatsheet exists with provenance
- ✅ L2: Integration test validates container state transitions against podman API
- ✅ L3: Telemetry logged to `~/.cache/tillandsias/events.jsonl` with structure:
  ```json
  {
    "timestamp": "...",
    "spec": "forge-container-launch",
    "status": "success|failure",
    "duration_ms": 3200,
    "container_id": "tillandsias-<project>-<genus>-<hash>"
  }
  ```
```

---

## 3. CI Validator Enhancement (Phase 3 Logic)

### Overview

The CI validator from Phase 2 (which checks spec existence) is extended to:
1. Parse `verified_at:LX` annotations
2. Validate level syntax
3. Check evidence chain completeness
4. Report mismatches

### Pseudocode: Phase 3 Validator

```
FUNCTION validate_traces_phase_3():
  results = []
  
  FOR each code location with `// @trace spec:<name>, verified_at:LX`:
    
    # Check 1: Syntax validation
    IF level NOT IN {L0, L1, L2, L3}:
      results.add(FAIL, "Invalid level: {level}")
      CONTINUE
    
    # Check 2: Spec existence (Phase 2, unchanged)
    FOR each spec_name:
      spec_path = "openspec/specs/{spec_name}/spec.md"
      IF NOT file_exists(spec_path):
        results.add(FAIL, "Spec not found: {spec_path}")
        CONTINUE
      ELSE:
        results.add(PASS, "Spec exists: {spec_name}")
    
    # Check 3: L1+ evidence (cheatsheet presence)
    IF level >= L1:
      cheatsheet_found = FALSE
      FOR each file IN cheatsheets/:
        IF contains_annotation("{spec_name}") OR 
           contains_sources_of_truth_section_with("{spec_name}"):
          cheatsheet_found = TRUE
          BREAK
      
      IF cheatsheet_found:
        results.add(PASS, "Cheatsheet found for L1: {spec_name}")
      ELSE:
        results.add(WARN, "L1 claimed but cheatsheet missing for {spec_name}")
    
    # Check 4: L2+ API validation (test existence)
    IF level >= L2:
      test_documented = code_has_comment_with("test", "integration", "verify")
      test_exists = file_exists_matching("tests/integration/test_*.rs")
      
      IF test_documented AND test_exists:
        results.add(PASS, "L2 test documented and present: {spec_name}")
      ELSE:
        results.add(WARN, "L2 claimed but integration test unclear for {spec_name}")
    
    # Check 5: L3+ runtime validation (telemetry)
    IF level >= L3:
      telemetry_emitted = code_contains("telemetry::emit") AND 
                          code_contains("spec =") AND
                          code_contains("verification_level")
      
      IF telemetry_emitted:
        results.add(PASS, "L3 telemetry found: {spec_name}")
      ELSE:
        results.add(WARN, "L3 claimed but no telemetry emission for {spec_name}")
  
  # Summary
  failures = count(results where status == FAIL)
  warnings = count(results where status == WARN)
  
  IF failures > 0:
    PRINT "Phase 3 validation FAILED ({failures} errors)"
    RETURN EXIT_CODE_1
  ELSE:
    PRINT "Phase 3 validation passed ({warnings} warnings, see details above)"
    RETURN EXIT_CODE_0

```

### Validator Phases

| Phase | Mode | Behavior |
|-------|------|----------|
| **Phase 3 (now)** | Inform | Parse + report mismatches, WARN on all issues, exit 0 |
| **Phase 4 (future)** | Advise | Strict on L1+ (FAIL if cheatsheet missing), WARN on L2+ |
| **Phase 5 (future)** | Enforce | Strict on all levels (FAIL on any mismatch), L3 for safety-critical |

### Implementation Notes

1. **Annotation parsing**: Extend Phase 2's regex from:
   ```rust
   @trace\s+spec:([a-z0-9_-]+)
   ```
   to:
   ```rust
   @trace\s+spec:([\w\-]+)(?:,\s*spec:[\w\-]+)*,\s*verified_at:(L[0-3])?
   ```

2. **Cheatsheet lookup**: Check both:
   - `@trace spec:<name>` in cheatsheet file
   - Spec name in `## Sources of Truth` section

3. **Test heuristic**: Look for:
   - Comment near code: `// Test: tests/integration/test_*.rs`
   - Or nearby test file with matching pattern
   - Or code comment mentioning "integration test"

4. **Telemetry heuristic**: Search function body for:
   - Call to `telemetry::emit()`
   - String literal containing `spec = "<name>"`
   - String literal containing `verification_level`

---

## 4. Migration Path: Defaults and Gradual Upgrade

### Current Code (Unchanged)

Existing traces without `verified_at:LX` default to L0:
```rust
// @trace spec:old-feature
// Implicitly: verified_at:L0 (backward compatible)
fn old_code() { ... }
```

**No changes required to old code.**

### New Code (Forward Looking)

All new code declares explicit level:
```rust
// @trace spec:new-feature, verified_at:L1
pub fn new_code() { ... }
```

### Spec Writers

When creating a new spec or updating an old one, add `## Verification Levels` section documenting expected evidence:

```markdown
## Verification Levels

- **L0**: Specification complete ✓
- **L1**: Cheatsheet planned (task: #NNN)
- **L2**: Integration test planned (task: #MMM)
```

### Do NOT Retroactively Upgrade Old Code

Example: **Avoid this pattern**

```rust
// WRONG: Changing old traces to higher levels without evidence
// BEFORE: // @trace spec:proxy-config
// AFTER:  // @trace spec:proxy-config, verified_at:L2

// This is a lie if you haven't written the integration test!
```

**Correct approach**: Keep old code at L0, selectively upgrade high-impact specs:
1. Identify critical specs (safety, frequently-used)
2. Write cheatsheet → update to L1
3. Write integration test → update to L2
4. Add telemetry → update to L3

---

## 5. Telemetry Event Structure (L3 Support)

### Event Format

L3-compliant code emits structured events. Example:

```json
{
  "timestamp": "2026-05-02T14:32:15.123Z",
  "spec": "forge-container-launch",
  "cheatsheet": "runtime/container-lifecycle.md",
  "verification_level": "L3",
  "status": "success",
  "duration_ms": 3200,
  "project_id": "my-app",
  "container_id": "tillandsias-my-app-aeranthos-abc123",
  "thread_id": "runtime-pool-2",
  "hostname": "fedora-silverblue"
}
```

### Required Fields (L3)

- `timestamp`: ISO 8601 UTC
- `spec`: Spec name (must match code annotation)
- `status`: "success" | "failure" | "timeout" | "degraded"
- `verification_level`: "L3"

### Optional Fields (Recommended)

- `cheatsheet`: Path to cheatsheet, if consulted
- `duration_ms`: Wall-clock time
- `error`: Error message if status != "success"
- `project_id`: Project identifier
- `container_id`: Container or resource being operated on
- `hostname`: Machine where event originated

### Logging Destination

Events logged to:
- **Local**: `~/.cache/tillandsias/events.jsonl` (append-only, rotated)
- **Remote** (future): Optional central telemetry sink

### Rust Emission Pattern

```rust
use serde_json::json;

// @trace spec:forge-container-launch, verified_at:L3
pub async fn launch_forge(project: &Project) -> Result<ContainerId> {
    let start = Instant::now();
    
    match create_and_start_container(project).await {
        Ok(container_id) => {
            // Emit success event
            emit_l3_event(json!({
                "spec": "forge-container-launch",
                "cheatsheet": "runtime/container-lifecycle.md",
                "verification_level": "L3",
                "status": "success",
                "duration_ms": start.elapsed().as_millis() as u64,
                "project_id": project.id,
                "container_id": container_id,
            }));
            Ok(container_id)
        }
        Err(e) => {
            // Emit failure event
            emit_l3_event(json!({
                "spec": "forge-container-launch",
                "cheatsheet": "runtime/container-lifecycle.md",
                "verification_level": "L3",
                "status": "failure",
                "error": e.to_string(),
                "duration_ms": start.elapsed().as_millis() as u64,
                "project_id": project.id,
            }));
            Err(e)
        }
    }
}
```

---

## 6. Documentation & Communication

### Cheatsheet

**File**: `docs/cheatsheets/verification-levels.md` (created as part of this phase)

Contents:
- Definition of each level (L0-L3)
- Code annotation examples
- Spec file format template
- CI validator logic (pseudocode)
- Migration plan
- FAQ

### Update Existing Docs

- **CLAUDE.md**: Add reference to verification levels in trace annotations section
- **openspec/config.yaml**: Add verification_levels to spec schema (if enforced)
- **Build script validation**: Integrate CI validator as `./scripts/validate-traces-phase3.sh`

### Communication

1. **To spec writers**: "New specs should include `## Verification Levels` section showing expected evidence"
2. **To implementers**: "Use `// @trace spec:<name>, verified_at:LX` to declare evidence quality"
3. **To reviewers**: "Check that claimed level matches evidence (cheatsheet, test, telemetry)"

---

## 7. CI Integration: When to Activate

### Phase 3 (Now)

- ✅ Annotation parsing implemented
- ✅ Spec existence validation (unchanged from Phase 2)
- ✅ Evidence chain check (informational, WARN only)
- ✅ Output: "Phase 3 validator passed with N warnings"
- ✅ Exit code: 0 (non-blocking)

### Phase 4 (Future: After Cheatsheet Metrics)

- ⏳ Enforce L1 (FAIL if cheatsheet missing for L1+ claims)
- ⏳ Warn on L2 (WARN if integration test not found)
- ⏳ Telemetry metrics dashboard active
- Exit code: 1 if strict failures

### Phase 5 (Future: After Automated Compaction)

- 🔄 Enforce L2 (FAIL if API test missing for L2+)
- 🔄 Enforce L3 for safety-critical (FAIL if no telemetry)
- 🔄 Automatic cheatsheet compaction active
- Full convergence loop operational

---

## 8. Success Criteria

Phase 3 is complete when:

- [ ] Annotation format `verified_at:LX` is documented and examples provided
- [ ] CI validator parses, validates, and reports verification levels
- [ ] `docs/cheatsheets/verification-levels.md` is comprehensive and clear
- [ ] `PHASE_3_DESIGN.md` (this doc) describes implementation approach
- [ ] First code changes use annotations (e.g., existing safety-critical specs)
- [ ] Build script includes Phase 3 validator and reports pass/warn
- [ ] No breaking changes to existing code (L0 default)

---

## 9. Timeline & Effort Estimate

| Task | Effort | Owner | Timeline |
|------|--------|-------|----------|
| Design document (this file) | 2h | Agent | 2026-05-02 ✓ |
| Cheatsheet: verification-levels.md | 3h | Agent | 2026-05-02 ✓ |
| CI validator implementation (scripts/) | 4h | TBD | Week 1 |
| Annotation rollout (first batch) | 8h | TBD | Week 1-2 |
| Update CLAUDE.md trace section | 1h | TBD | Week 1 |
| Integration test: validate-traces | 3h | TBD | Week 1 |
| **Phase 3 total** | **~21h** | — | **Week 1** |

---

## 10. Open Questions for Design Review

1. **Telemetry infrastructure**: Should we use `serde_json` or `postcard` for events? (Postcard preferred per CLAUDE.md)
2. **Event rotation**: What's the log rotation policy for `~/.cache/tillandsias/events.jsonl`?
3. **Spec schema enforcement**: Should `openspec/config.yaml` encode verification level constraints?
4. **Metrics dashboard**: Who will build the telemetry aggregation for Phase 4?
5. **Backward compatibility**: Are there any specs currently using `verified_at:` accidentally?

---

## Appendix: Diff from Phase 2

### What Changes

1. **Annotation syntax**: Add optional `verified_at:LX` field
2. **Spec format**: Add optional `## Verification Levels` section
3. **CI validator**: Extend to parse and validate levels (non-breaking)
4. **Documentation**: New cheatsheet + design doc

### What Doesn't Change

- Phase 2 spec existence validation (still required)
- Trace annotation requirement (still mandatory on public functions)
- Default behavior (L0 if level omitted)
- Existing code (no forced updates)

---

## Appendix: Example Rollout Sequence

### Week 1: Foundation

1. Merge design docs (this file + verification-levels.md cheatsheet)
2. Implement Phase 3 CI validator
3. Update CLAUDE.md trace section

### Week 2: First Batch

4. Annotate 5 high-impact specs with `verified_at:L1` (enclave, proxy, git-service)
5. Verify cheatsheets exist (they do: mitm-proxy-design.md, container-lifecycle.md)
6. Create integration test for L2 claim (if adding one)

### Week 3: Stabilization

7. Run validator on entire codebase
8. Document any warnings or anomalies
9. Plan Phase 4 (cheatsheet metrics)

---

## References

- `Monotonic reduction of uncertainty under verifiable constraints.yaml` — Master spec
- `docs/cheatsheets/verification-levels.md` — User-facing explanation
- `CLAUDE.md` — Project conventions (trace annotations section)
- Phase 2 output: `scripts/validate-traces.sh` (to be extended)

