## 1. Add `keyring` crate dependency

- [x] 1.1 Add `keyring = "3"` to `src-tauri/Cargo.toml` dependencies

## 2. Create secrets module

- [x] 2.1 Create `src-tauri/src/secrets.rs` with keyring read/write/delete functions
- [x] 2.2 Implement `store_github_token(token: &str) -> Result<(), String>` — stores token in native keyring
- [x] 2.3 Implement `retrieve_github_token() -> Result<Option<String>, String>` — retrieves token from keyring, returns None if not found
- [x] 2.4 Implement `migrate_token_to_keyring()` — reads existing `hosts.yml`, extracts token, stores in keyring if keyring entry is empty
- [x] 2.5 Implement `write_hosts_yml_from_keyring()` — retrieves token from keyring, writes `hosts.yml` to the secrets directory for container mount
- [x] 2.6 Register `mod secrets` in `main.rs`

## 3. Integrate with GitHub login flow

- [x] 3.1 Migration happens via startup call and per-launch `write_hosts_yml_from_keyring()` — the interactive `gh auth login` runs in a terminal and writes to the mounted `hosts.yml`; the next startup or container launch picks up the new token

## 4. Integrate with container launch

- [x] 4.1 In `handle_attach_here()`: before building podman run args, call `write_hosts_yml_from_keyring()` so the container gets a fresh `hosts.yml`
- [x] 4.2 In `handle_terminal()`: same — call `write_hosts_yml_from_keyring()` before launch
- [x] 4.3 In `runner.rs` `build_run_args()`: call `write_hosts_yml_from_keyring()` before building args
- [x] 4.4 In `github.rs` `fetch_repos()` and `clone_repo()`: call `write_hosts_yml_from_keyring()` before spawning the container

## 5. Auto-migrate at startup

- [x] 5.1 In `main.rs` tray setup, call `secrets::migrate_token_to_keyring()` early in the async block

## 6. Verify

- [x] 6.1 Run `cargo check --workspace` — zero errors
- [x] 6.2 Run `cargo test --workspace` — all 66 tests pass (4 new secrets tests)
