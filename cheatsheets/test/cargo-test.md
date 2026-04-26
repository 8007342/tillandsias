# cargo test

@trace spec:agent-cheatsheets

**Version baseline**: Cargo 1.83+ (bundled with Rust 1.83+ from Fedora 43)
**Use when**: testing Rust code — unit tests, integration tests, doctests.

## Provenance

- Cargo book — `cargo test` command reference: <https://doc.rust-lang.org/cargo/commands/cargo-test.html> — all flags including `--workspace`, `--doc`, `--no-run`, `--lib`, `--bins`
- Rust reference — `#[test]` and test attributes: <https://doc.rust-lang.org/reference/attributes/testing.html> — `#[test]`, `#[should_panic]`, `#[ignore]`, `#[cfg(test)]`
- **Last updated:** 2026-04-25

Verified against Cargo book: `--workspace`, `--doc`, `--no-run` confirmed; `-- --no-capture` (note: Cargo book uses `--no-capture`, not `--nocapture`; both accepted by libtest) and `-- --test-threads=N` confirmed. `#[tokio::test]` requires `tokio` with `macros` feature.

## Quick reference

| Command | Effect |
|---|---|
| `cargo test` | Build + run all tests (unit + integration + doc) in current package |
| `cargo test name_substring` | Filter: only tests whose path contains the substring |
| `cargo test --workspace` | Run tests for every workspace member |
| `cargo test -p <crate>` | Restrict tests to a single workspace member |
| `cargo test --test <file>` | Run one integration test file (`tests/<file>.rs`) only |
| `cargo test --lib` | Only library unit tests (skip integration + doc) |
| `cargo test --bins` | Only binary unit tests |
| `cargo test --doc` | Only documentation tests (slow — recompiles each block) |
| `cargo test --no-run` | Compile tests but do not execute (useful for cross-builds) |
| `cargo test -- --nocapture` | Stream `println!` / `eprintln!` from passing tests |
| `cargo test -- --test-threads=1` | Serialize execution (debug shared-state flakes) |
| `cargo test -- --ignored` | Run only `#[ignore]`-marked tests |
| `cargo test -- --include-ignored` | Run normal AND ignored tests |
| `cargo test -- --list` | List discovered tests without running |
| `cargo test --release` | Run tests with optimisations (catches release-only bugs) |

| Attribute | Purpose |
|---|---|
| `#[test]` | Mark a function as a test (zero args, returns `()` or `Result`) |
| `#[should_panic]` / `#[should_panic(expected = "msg")]` | Test passes only if it panics |
| `#[ignore]` / `#[ignore = "reason"]` | Skip unless `--ignored` / `--include-ignored` |
| `#[cfg(test)]` | Compile module/item only under `cargo test` |
| `#[tokio::test]` / `#[async_std::test]` | Async test harness (needs the runtime crate) |

## Common patterns

### Pattern 1 — Unit tests colocated in `src/`

```rust
pub fn add(a: i32, b: i32) -> i32 { a + b }

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn adds_positives() { assert_eq!(add(2, 3), 5); }
}
```

Convention for testing private items — the `tests` module sees `super::*`.

### Pattern 2 — Integration tests in `tests/`

```rust
// tests/api.rs — each file is its OWN crate, sees only the public API.
use my_crate::Client;

#[test]
fn round_trips_request() {
    let c = Client::new();
    assert!(c.ping().is_ok());
}
```

Run just this file with `cargo test --test api`.

### Pattern 3 — Doctest in `///` block

```rust
/// Adds two numbers.
///
/// ```
/// assert_eq!(my_crate::add(2, 2), 4);
/// ```
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

`cargo test --doc` runs the example as a real test. Use ```` ```ignore ```` or ```` ```text ```` to opt out.

### Pattern 4 — `#[cfg(test)]` helper module

```rust
#[cfg(test)]
mod test_util {
    pub fn fixture() -> Vec<u8> { vec![1, 2, 3] }
}
```

Helpers compile only under `cargo test` — zero release-binary cost.

### Pattern 5 — Async test with tokio

```rust
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetches_concurrently() {
    let (a, b) = tokio::join!(fetch("/a"), fetch("/b"));
    assert!(a.is_ok() && b.is_ok());
}
```

Requires `tokio = { version = "1", features = ["macros", "rt-multi-thread"] }`.

## Common pitfalls

- **Tests run in parallel by default** — any test mutating shared state (env vars, working dir, global statics, on-disk fixtures, listening ports) flakes intermittently. Either pass `-- --test-threads=1` or guard the resource with `std::sync::Mutex` / `serial_test`.
- **`println!` is captured on pass** — debug output from passing tests is hidden. Add `-- --nocapture` (or fail the test) to see it. The capture is per-test, not global.
- **Integration tests cannot see private items** — files under `tests/` compile as separate crates and only have access to `pub` API. Move tests into `#[cfg(test)] mod` inside `src/` if you need internals.
- **Doctests are slow** — every fenced block is compiled as its own crate. A handful of doctests can dominate `cargo test` runtime. Mark long examples ```` ```ignore ```` or move them to integration tests.
- **`cargo test` rebuilds in test profile** — binaries from `cargo build` are not reused; the first `cargo test` after a build recompiles the world. This is normal, not misconfiguration.
- **No naming convention required** — discovery is by `#[test]` attribute, not function name. `fn it_works`, `fn test_foo`, `fn anything` all work; rename freely without breaking discovery.
- **`#[should_panic]` without `expected = ...`** — passes for ANY panic, including unrelated ones (e.g. a panic during setup). Always pin the message: `#[should_panic(expected = "divide by zero")]`.
- **Filter is a substring match on the full path** — `cargo test foo` matches `tests::foo`, `bar::foo_baz`, and `module::foo::test`. Use `cargo test -- --exact tests::foo` for an exact match.
- **`Result`-returning tests swallow `?` errors as failures** — `fn t() -> Result<(), Box<dyn Error>>` is fine, but a `?` propagating an error fails the test with a terse `Err(...)`. Use `.expect("context")` for readable failure messages.
- **Async tests need a runtime attribute** — bare `#[test] async fn` does not compile. Use `#[tokio::test]` (requires `tokio` `macros` feature) or `#[async_std::test]`.

## Forge-specific

`target/` lives in `/home/forge/src/<project>/target/` and is ephemeral on container stop — test artifacts recompile on next attach. If test cycles hurt, configure `sccache` or mount a persistent volume for `target/` and `~/.cargo/registry`. Tests that hit the network must go through the enclave proxy; direct egress is blocked.

## See also

- `languages/rust.md` — language reference
- `build/cargo.md` — broader cargo workflow (build, clippy, features, workspaces)
- `runtime/forge-container.md` — `target/` ephemerality and proxy-only egress
