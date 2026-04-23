# Tasks — ci-node24-audit-and-fix

## Part 1: Update GitHub Actions to Node 24-native versions

- [x] Update `actions/checkout` from v4 to v6 (SHA pin)
- [x] Update `actions/setup-node` from v4 to v6 (SHA pin)
- [x] Update `actions/upload-artifact` from v4 to v7 (SHA pin)
- [x] Update `actions/download-artifact` from v4 to v8 (SHA pin)
- [x] Update `dtolnay/rust-toolchain` to latest master SHA
- [x] Update `swatinem/rust-cache` to v2.9.1 (SHA pin)
- [x] Update `sigstore/cosign-installer` from v3.7.0 to v4.1.1 (SHA pin)
- [x] Confirm `softprops/action-gh-release` v2.6.1 is already latest (no change)
- [x] Remove `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` env var (all actions now native Node 24)

## Part 2: Fix Rust unused code warnings

- [x] Remove unused `Path` import from `ca.rs`
- [x] Remove unused `HashMap`, `Deserialize`, `Serialize` imports from `handlers.rs`
- [x] Remove dead `ensure_tools_overlay` re-export from `handlers.rs` (direct path used)
- [x] Add `#[allow(dead_code)]` to `bash_path` (cross-platform utility for Windows)
- [x] Add `#[allow(dead_code)]` to `GH_AUTH_LOGIN` (used by GitHub login flow)
- [x] Add `#[allow(dead_code)]` to `remote_url` field (parsed for future UI use)
- [x] Add `#[allow(dead_code)]` to `mirror_path` field (stored for future mount paths)
- [x] Add `#[allow(dead_code)]` to `any_versioned_forge_exists` (API for upgrade paths)
- [x] Add `#[allow(dead_code)]` to `get_proxy_ip` / `get_proxy_ip_pub` (proxy build routing)
- [x] Add `#[allow(dead_code)]` to `init::run` / `init::run_build_only` (CLI entry points)
- [x] Add `#[allow(dead_code)]` to `ensure_secrets_dirs` (secrets mount flow)
- [x] Add `#[allow(dead_code)]` to `store_github_token` (GitHub login flow)
- [x] Add `#[allow(dead_code)]` to `INSTALL_INCOMPLETE` (reserved error string)

## Verification

- [x] `cargo clippy --workspace` — zero unused code warnings
- [x] `cargo test --workspace` — all tests pass
