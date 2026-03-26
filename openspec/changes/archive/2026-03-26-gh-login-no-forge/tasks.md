## 1. Rust — handlers.rs

- [x] 1.1 Add `build_tx: mpsc::Sender<BuildProgressEvent>` parameter to `handle_github_login()`
- [x] 1.2 Before extracting `gh-auth-login.sh`, check `client.image_exists(FORGE_IMAGE_TAG).await`
- [x] 1.3 If image missing: emit `BuildProgressEvent::Started { image_name: "forge" }`, call `run_build_image_script("forge")` via `spawn_blocking`, emit `Completed` or `Failed`
- [x] 1.4 If build fails: return early with error (do not open terminal)
- [x] 1.5 After image confirmed present: proceed with existing terminal-open logic (unchanged)

## 2. Rust — event_loop.rs

- [x] 2.1 Update `MenuCommand::GitHubLogin` arm to pass `build_tx.clone()` to `handle_github_login`

## 3. OpenSpec

- [x] 3.1 Write `proposal.md`
- [x] 3.2 Write `tasks.md`
- [x] 3.3 Write `specs/gh-login-no-forge/spec.md` — update `gh-auth-script` spec with new first-run scenario

## 4. Verification

- [x] 4.1 `./build.sh --check` passes (type-check only)
- [ ] 4.2 Manual test: delete forge image, click GitHub Login, observe build chip then terminal
