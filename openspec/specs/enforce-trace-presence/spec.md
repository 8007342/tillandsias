# enforce-trace-presence

## Status

status: active

## Objective

Enforce that every public function, trait, struct, and enum in `src-tauri/src/` has a `@trace spec:NAME` annotation. This is Phase 2 of the Monotonic Reduction system, which ensures runtime behavior is traceable back to OpenSpec design documents.

## Motivation

Without mandatory @trace annotations, orphaned public APIs accumulate in the codebase with no link to specifications. Traces make the spec-to-code mapping queryable at development and runtime. Enforcement prevents silent drift.

## Requirements

### Requirement: Scanning and trace presence enforcement

All public symbols in `src-tauri/src/**/*.rs` MUST have a `@trace spec:NAME` annotation. The scanner MUST target only `pub fn`, `pub async fn`, `pub trait`, `pub struct`, and `pub enum` declarations at all nesting levels. The scanner MUST exempt private functions (`fn` without `pub`) and test-only items (unless they are public tests with `#[cfg(test)]`). The scanner MUST be bash/grep-based with no new Rust crate dependencies and MUST complete in less than 10 seconds.

@trace spec:enforce-trace-presence

### Requirement: Annotation format validation

@trace annotations MUST follow one of three permitted formats:

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

The format MUST match the machine-verifiable regex:
```regex
^[[:space:]]*(//|#!?\[)\s*@trace\s+spec:[a-z0-9_-]+(,\s*spec:[a-z0-9_-]+)*[[:space:]]*$
```

The following violations MUST cause CI failure:
- Trailing comma after spec name: `@trace spec:foo,`
- Trailing prose: `@trace spec:foo — reason here`
- Inline URL: `@trace spec:foo https://...`
- Combined @trace + @cheatsheet on one line (MUST use separate lines)
- Inline after code: `let x = 1; // @trace spec:foo`

@trace spec:enforce-trace-presence

### Requirement: Exit codes and CI integration

The validator MUST return exit code `0` when all checks pass, exit code `1` when errors are found (missing traces or format violations), and exit code `2` when only warnings are detected (when invoked with `--warn-only` flag). CI MUST call the validator before build; developers MUST run it locally before pushing.

@trace spec:enforce-trace-presence

## Implementation

The validator tool `scripts/validate-traces.sh --enforce-presence` MUST be added to (or extended from) the existing Phase 1 validator. CI MUST call this validator before building the binary. Developers MUST run the validator locally before pushing changes. The full codebase scan MUST complete in less than 10 seconds.

@trace spec:enforce-trace-presence

## Remediation

When CI reports missing @trace annotations, developers SHALL:
1. Identify the spec the function implements by reading module doc comments, related specs, or git history
2. Add `// @trace spec:SPECNAME` on the line immediately before the `pub fn` declaration
3. Run `bash scripts/validate-traces.sh --enforce-presence` locally to verify the fix
4. Commit the change with a clickable trace URL in the commit body: `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3ASPECNAME&type=code`

@trace spec:enforce-trace-presence

## Related

- [logging-accountability spec](../logging-accountability/spec.md) — Trace annotation usage in logging
- [spec-traceability spec](../spec-traceability/spec.md) — Overall traceability model
- [trace-enforcement cheatsheet](../../cheatsheets/trace-enforcement.md) — Developer guide with examples

## Sources of Truth

- `cheatsheets/build/validation-ci.md` — CI validation patterns and exit codes
- `cheatsheets/languages/rust.md` — Rust visibility and declaration conventions
