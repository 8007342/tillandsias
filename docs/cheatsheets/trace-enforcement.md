# @trace Enforcement Rules

**Use when:** You need to add @trace annotations to public functions, understand CI enforcement rules, or comply with Monotonic Reduction trace requirements.

## Provenance

- [Tillandsias CLAUDE.md § Trace Annotations](https://github.com/8007342/tillandsias/blob/main/CLAUDE.md#trace-annotations--trace-specname) — project enforcement standards
- [openspec/specs/spec-traceability/spec.md](https://github.com/8007342/tillandsias/blob/main/openspec/specs/spec-traceability/spec.md) — traceability model
- **Last updated:** 2026-05-02

## Enforcement Rules

Every **public function, trait, struct, and enum in `src-tauri/src/`** must have an `@trace` annotation in one of three permitted formats. This is enforced by Phase 2 of the Monotonic Reduction CI validator:

```bash
bash scripts/validate-traces.sh --enforce-presence
```

### When does CI require @trace?

| Item | Required? | Scope | Notes |
|------|-----------|-------|-------|
| `pub fn foo()` | YES | all src-tauri functions | Regular public functions |
| `pub async fn bar()` | YES | all src-tauri functions | Async functions also required |
| `pub trait MyTrait` | YES | all src-tauri types | Trait declarations |
| `pub struct MyStruct` | YES | all src-tauri types | Struct declarations |
| `pub enum MyEnum` | YES | all src-tauri types | Enum declarations |
| `fn foo()` (private) | NO | N/A | Private functions exempt |
| `impl` blocks | NO | N/A | Implementation blocks inherit parent decoration |
| Test modules | YES | `#[cfg(test)]` | Tests are public to rustc, must have @trace |
| Module-level | NO | ~module-level | Use for entire module if all items share same spec |

### Permitted Annotation Formats

#### Format 1: Single-line comment before function

```rust
// @trace spec:forge-launch
pub fn start_container(project: &str) -> Result<(), String> {
    // ...
}
```

- `// ` starts the comment (one or two slashes both work)
- Followed immediately by `@trace spec:SPECNAME`
- Must be on its own line (no code before it)
- On the line **immediately before** the function declaration

#### Format 2: Doc comment with @trace

```rust
/// Start a container for the given project.
///
/// @trace spec:forge-launch
pub fn start_container(project: &str) -> Result<(), String> {
    // ...
}
```

- `/// ` starts a doc comment line
- `@trace spec:SPECNAME` can appear anywhere in the doc comment
- Usually placed after the description and blank line
- Multiple spec lines permitted (one per line)

#### Format 3: Module-level attribute (applies to all items in module)

```rust
//! Container lifecycle management.
//!
//! @trace spec:forge-launch

// ... all pub items in this module inherit the trace

pub fn foo() { ... }
pub fn bar() { ... }
pub struct Baz { ... }
```

- Module-level doc comments (`//!` or `/*! ... */`) can declare `@trace spec:`
- Applies to ALL public items in that module
- Useful when all items in a file/module share the same spec
- Still permits item-level overrides with different specs

### Format Violations (CI will reject these)

| Violation | Example | Fix |
|-----------|---------|-----|
| Trailing comma | `@trace spec:foo,` | Remove comma: `@trace spec:foo` |
| Trailing prose (em-dash) | `@trace spec:foo — launches container` | Move prose to doc comment instead |
| Inline URL | `@trace spec:foo https://...` | Remove URL; cite in commit message instead |
| Multiple specs on one line | `@trace spec:foo, spec:bar` | OK (comma-separated) but keep on one line |
| Combined @trace + @cheatsheet | `// @trace spec:foo, @cheatsheet file.md` | Use separate lines: `// @trace spec:foo` then `// @cheatsheet file.md` |
| Trailing parentheses | `@trace spec:foo (reason)` | Remove; use doc comment for rationale |
| Inline after code | `let x = 1; // @trace spec:foo` | Move to preceding line before function |

### Multiple Specs (When Applicable)

If a function implements multiple specs, list them comma-separated on one line:

```rust
// @trace spec:forge-launch, spec:enclave-network
pub fn launch_with_network(project: &str) -> Result<(), String> {
    // ...
}
```

### How to Add @trace to an Existing Function

**Step 1: Identify the spec.**

Which OpenSpec specification does this function implement or contribute to? Look at:
- The module's doc comment (`//!`)
- Related specs in `openspec/specs/`
- Commit history and comments

**Step 2: Pick a format** (usually Format 1 for simplicity).

**Step 3: Add the annotation** immediately before the function:

```rust
// Before:
pub fn ensure_podman_available() -> Result<(), String> {
    // ...
}

// After:
// @trace spec:init-system-checks
pub fn ensure_podman_available() -> Result<(), String> {
    // ...
}
```

**Step 4: Run the validator locally:**

```bash
bash scripts/validate-traces.sh --enforce-presence
```

If your function is listed, you're done. If not, check:
- Is the function truly public (`pub`)?
- Is it in `src-tauri/src/` (nested files like `src-tauri/src/browser_mcp/mod.rs` are scanned)?
- Does the @trace line match the regex? (See Format section above)

**Step 5: Commit with a trace URL:**

```
fix: add @trace to ensure_podman_available

@trace spec:init-system-checks
https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Ainit-system-checks&type=code
```

### CI Integration

The trace enforcer runs as part of the build pipeline:

```bash
# In CI (manually triggered):
gh workflow run ci.yml

# Locally before pushing:
cargo test --workspace && bash scripts/validate-traces.sh --enforce-presence
```

**Exit codes:**
- `0` = all checks passed
- `1` = errors found (traces missing or format violations)
- `2` = warnings only (when `--warn-only` flag used)

### Troubleshooting

| Problem | Solution |
|---------|----------|
| "pub fn X missing @trace" | Add `// @trace spec:NAME` on line before `pub fn X` |
| "Can't find spec for function" | Check `openspec/specs/` for related spec; use inferred name if new feature |
| "Validator says I'm missing a trace but I added one" | Verify `@trace` is on its own line (not after code); check regex `^[[:space:]]*(//\|#)\s*@trace\s+spec:` |
| "Function is in a module with module-level @trace but still fails" | Module-level traces don't work if function is in a submodule; add item-level annotation instead |

### Related Documentation

- [spec-traceability spec](../../openspec/specs/spec-traceability/spec.md) — high-level traceability model
- [CLAUDE.md § Trace Annotations](../../CLAUDE.md#trace-annotations--trace-specname) — project conventions
- [TRACES.md](../../TRACES.md) — all @trace annotations in codebase (auto-generated)

## Sources of Truth

- `cheatsheets/build/regex-patterns.md` — @trace regex validation patterns
- `cheatsheets/languages/rust.md` — Rust documentation comment conventions
