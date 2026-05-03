# enforce-trace-presence

## Objective

Enforce that every public function, trait, struct, and enum in `src-tauri/src/` has a `@trace spec:NAME` annotation. This is Phase 2 of the Monotonic Reduction system, which ensures runtime behavior is traceable back to OpenSpec design documents.

## Motivation

Without mandatory @trace annotations, orphaned public APIs accumulate in the codebase with no link to specifications. Traces make the spec-to-code mapping queryable at development and runtime. Enforcement prevents silent drift.

## Requirements

### Scanning

- **Scope**: `src-tauri/src/**/*.rs` (all Rust source files in the Tauri tray app)
- **Targets**: `pub fn`, `pub async fn`, `pub trait`, `pub struct`, `pub enum` (top-level and in nested modules)
- **Exempt**: `fn` (private functions), test-only items (unless `#[cfg(test)]` is a public test)
- **Scanner**: bash/grep-based (no new Rust crates); runs in < 10 seconds

### Permitted Formats

1. **Single-line comment** before function:
   ```rust
   // @trace spec:NAME
   pub fn foo() { ... }
   ```

2. **Doc comment** with @trace anywhere inside:
   ```rust
   /// Description.
   /// @trace spec:NAME
   pub fn foo() { ... }
   ```

3. **Module-level** doc comment (applies to all public items in module):
   ```rust
   //! @trace spec:NAME
   pub fn foo() { ... }
   pub fn bar() { ... }
   ```

### Format Validation

Format regex (machine-verifiable):
```regex
^[[:space:]]*(//|#!?\[)\s*@trace\s+spec:[a-z0-9_-]+(,\s*spec:[a-z0-9_-]+)*[[:space:]]*$
```

**Violations that fail CI**:
- Trailing comma after spec name: `@trace spec:foo,`
- Trailing prose: `@trace spec:foo — reason here`
- Inline URL: `@trace spec:foo https://...`
- Combined @trace + @cheatsheet on one line: use separate lines instead
- Inline after code: `let x = 1; // @trace spec:foo`

### Exit Codes

- `0` = all checks passed
- `1` = errors found (missing traces or format violations)
- `2` = warnings only (use with `--warn-only` flag)

## Implementation

- **Tool**: `scripts/validate-traces.sh --enforce-presence`
- **Flag**: Add `--enforce-presence` to existing Phase 1 validator
- **Integration**: CI calls this before build; developers run locally before push
- **Performance**: Full codebase scan < 10 seconds

## Remediation

When CI reports missing @trace:
1. Identify the spec the function implements (read module doc comment, related specs, git history)
2. Add `// @trace spec:SPECNAME` on the line immediately before `pub fn`
3. Run `bash scripts/validate-traces.sh --enforce-presence` locally
4. Commit with trace URL: `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3ASPECNAME&type=code`

## Related

- [logging-accountability spec](../logging-accountability/spec.md) — Trace annotation usage in logging
- [spec-traceability spec](../spec-traceability/spec.md) — Overall traceability model
- [trace-enforcement cheatsheet](../../cheatsheets/trace-enforcement.md) — Developer guide with examples

## Sources of Truth

- `cheatsheets/build/validation-ci.md` — CI validation patterns and exit codes
- `cheatsheets/languages/rust.md` — Rust visibility and declaration conventions
