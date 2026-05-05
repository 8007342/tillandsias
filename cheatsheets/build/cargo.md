---
tags: [build, rust, cargo, package-manager, workspaces]
languages: [rust]
since: 2026-04-25
last_verified: 2026-04-27
sources:
  - https://doc.rust-lang.org/cargo/commands/index.html
  - https://doc.rust-lang.org/cargo/reference/manifest.html
  - https://doc.rust-lang.org/cargo/reference/workspaces.html
  - https://doc.rust-lang.org/cargo/reference/profiles.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Cargo

@trace spec:agent-cheatsheets

## Provenance

- Cargo Commands index: <https://doc.rust-lang.org/cargo/commands/index.html> — canonical subcommand list
  local: `cheatsheet-sources/doc.rust-lang.org/cargo/commands/index.html`
- Cargo Manifest reference: <https://doc.rust-lang.org/cargo/reference/manifest.html> — `[package]`, `[features]`, `[dependencies]`
  local: `cheatsheet-sources/doc.rust-lang.org/cargo/reference/manifest.html`
- Cargo Workspaces reference: <https://doc.rust-lang.org/cargo/reference/workspaces.html> — `members`, `resolver`
  local: `cheatsheet-sources/doc.rust-lang.org/cargo/reference/workspaces.html`
- Cargo Profiles reference: <https://doc.rust-lang.org/cargo/reference/profiles.html> — `[profile.*]` keys
  local: `cheatsheet-sources/doc.rust-lang.org/cargo/reference/profiles.html`
- `cargo check` description: <https://doc.rust-lang.org/cargo/commands/cargo-check.html> — "compile without final code-generation step"
  local: `cheatsheet-sources/doc.rust-lang.org/cargo/commands/cargo-check.html`
- **Last updated:** 2026-04-25

**Version baseline**: Cargo 1.83+ (bundled with Rust 1.83+ from Fedora 43)
**Use when**: building / testing / running Rust code in the forge.

## Quick reference

| Command | Effect |
|---|---|
| `cargo build` | Compile current package (debug profile, `target/debug/`) |
| `cargo build --release` | Optimised build (`target/release/`) |
| `cargo check` | Type-check without codegen (fastest feedback loop) |
| `cargo run -- arg1 arg2` | Build + run binary; `--` separates cargo flags from program args |
| `cargo test` | Build + run unit, integration, and doc tests |
| `cargo test name_substring` | Filter tests by name substring |
| `cargo clippy -- -D warnings` | Lint; treat warnings as errors |
| `cargo fmt` / `cargo fmt --check` | Format / verify formatting (CI-friendly) |
| `cargo doc --open` | Build and open rustdoc for current crate + deps |
| `cargo update` | Refresh `Cargo.lock` to latest semver-compatible versions |
| `cargo tree -e features` | Show dep tree with feature edges |
| `cargo --workspace` | Apply command to every workspace member |
| `cargo -p <crate>` | Restrict command to a single workspace member |
| `cargo --features "a b"` | Enable named features (space-separated) |
| `cargo --no-default-features` | Disable the `default` feature set |
| `cargo --all-features` | Enable every feature defined in `Cargo.toml` |

## Common patterns

### Pattern 1 — Bootstrap a new crate

```bash
cargo new my-bin               # binary crate (src/main.rs)
cargo new --lib my-lib         # library crate (src/lib.rs)
cargo init                     # turn cwd into a crate (no new directory)
```

### Pattern 2 — Workspace layout

```toml
# Cargo.toml at repo root
[workspace]
members = ["crates/*"]
resolver = "2"
```

```bash
cargo build --workspace        # build all members
cargo test  -p tillandsias-core # test one member
```

### Pattern 3 — Feature flags

```toml
# crates/foo/Cargo.toml
[features]
default = ["json"]
json    = ["dep:serde_json"]
postcard = ["dep:postcard"]
```

```bash
cargo test -p foo --no-default-features --features postcard
```

### Pattern 4 — Per-project install (avoid `~/.cargo/bin`)

```bash
cargo install --path . --root /tmp/myapp
# binary lands in /tmp/myapp/bin/, easy to delete
```

### Pattern 5 — Custom profile in `Cargo.toml`

```toml
[profile.release]
lto = "thin"
codegen-units = 1
strip = "symbols"

[profile.dev]
opt-level = 1                  # faster tests without losing debuginfo
```

## Common pitfalls

- **`cargo install` writes to `~/.cargo/bin`** — that path is ephemeral inside a forge container. Prefer `--root <persistent>` or rebuild on each session; never assume a previously installed binary survives `tillandsias` restart.
- **`profile.dev` is unoptimised** — test suites that exercise crypto, parsing, or large vec ops feel pathologically slow. Bump `opt-level = 1` (or `2` for hot crates) in `[profile.dev]` before blaming the test code.
- **`--workspace` is all-or-nothing** — on a large repo every member compiles, links, and tests. Use `-p <crate>` plus `--no-default-features` for fast iteration; reserve `--workspace` for pre-push / CI.
- **Feature flags are additive** — once any dependency activates a feature, every crate sees it. You cannot "turn off" a feature another crate enabled. Design features to be opt-in extensions, never mutually-exclusive switches.
- **`Cargo.lock` for libraries** — commit it for binary projects (reproducible builds); historically excluded for libraries, though current Rust guidance is "commit it everywhere". For Tillandsias (binary workspace) it is committed and conflicts at merge are resolved with `cargo generate-lockfile`.
- **`cargo fix --edition --allow-dirty` rewrites source** — runs the compiler's auto-migrations against your tree. Always commit (or stash) before invoking, and review the diff — it can mangle macros and conditional compilation.
- **`build.rs` runs at compile time with full host privileges** — a malicious build script can exfiltrate or wipe the workspace. Audit `build.rs` in new dependencies; the forge container's network isolation limits blast radius but not local damage.
- **`cargo test` re-builds in test profile** — binaries built by `cargo build` are not reused. First `cargo test` after a `cargo build` recompiles the world; this is normal, not a misconfiguration.
- **Doc tests run by default** — `cargo test` executes `///` examples. Mark non-runnable snippets with `text` or `ignore` to keep CI green.

## Forge-specific

- `target/` lives in `/home/forge/src/<project>/target/` — ephemeral on container stop. Cache with `sccache` or a shared volume if rebuild time hurts.
- `~/.cargo/registry` is also ephemeral — first build of new deps re-downloads the index and crates through the enclave proxy.
- Network egress is proxy-only: registry pulls go via `tillandsias-proxy`. A "blocked host" error usually means the registry mirror is not on the proxy allowlist.

## See also

- `languages/rust.md` — language reference
- `test/cargo-test.md` — test invocations
- `runtime/forge-container.md` — `target/` ephemerality
