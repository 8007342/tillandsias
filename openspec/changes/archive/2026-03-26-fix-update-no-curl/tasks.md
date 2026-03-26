## 1. OpenSpec artifacts

- [x] 1.1 Create `proposal.md`
- [x] 1.2 Create `tasks.md`
- [x] 1.3 Create `specs/fix-update-no-curl/spec.md`

## 2. Implementation

- [x] 2.1 Add `reqwest` as a direct dependency in `src-tauri/Cargo.toml`
- [x] 2.2 Replace `fetch_url` (fetches `latest.json`) — remove `Command::new("curl")`, use `reqwest` via `tokio::runtime::Builder::new_current_thread().block_on(...)`
- [x] 2.3 Replace `download_update` (downloads AppImage archive) — remove `Command::new("curl")`, write response bytes to temp file using `std::io::copy`
- [x] 2.4 Remove unused `std::process::Command` import paths from `update_cli.rs` if no longer needed

## 3. Verification

- [x] 3.1 `./build.sh --check` passes (type-check only, no AppImage needed)
- [ ] 3.2 `./build.sh --test` passes
- [ ] 3.3 Manual: run `tillandsias --update` from an AppImage install and confirm no symbol lookup error
