## 1. GitHub Module

- [x] 1.1 Create `src-tauri/src/github.rs` with `fetch_repos()` — runs `podman run --rm` with forge image and `gh repo list --json name,url --limit 100`, parses JSON output
- [x] 1.2 Implement `RemoteRepo` struct (name, full_name, clone_url) and list parsing
- [x] 1.3 Implement `clone_repo(full_name, target_dir)` — runs `podman run --rm` with forge image and `gh repo clone <full_name> <target_dir>`
- [x] 1.4 Add `mod github;` to crate root

## 2. State & Caching

- [x] 2.1 Add remote repo cache to `TrayState` — `Vec<RemoteRepo>`, timestamp, loading flag
- [x] 2.2 Implement cache TTL logic (5-minute expiry)
- [x] 2.3 Invalidate cache after GitHub Login/Refresh completes

## 3. Menu Integration

- [x] 3.1 In `menu.rs`, swap GitHub Login label to "GitHub Login Refresh" when `!needs_github_login()`
- [x] 3.2 Add "Remote Projects" submenu inside Settings (only when authenticated)
- [x] 3.3 Populate Remote Projects submenu from cached repo list, filtered against local `~/src/` directories
- [x] 3.4 Show "Loading..." disabled item while fetching, "Could not fetch repos" on error, "Login to GitHub first" when unauthenticated
- [x] 3.5 Show "Cloning <name>..." disabled item during active clone

## 4. Event Handling

- [x] 4.1 Add `MenuCommand::CloneProject { full_name, name }` variant to `event.rs`
- [x] 4.2 Add menu ID dispatch for clone items in `main.rs`
- [x] 4.3 Implement clone handler in `handlers.rs` — spawn forge container, clone, trigger scanner rescan on completion
- [x] 4.4 Add `MenuCommand::RefreshRemoteProjects` variant for triggering background fetch

## 5. Verification

- [x] 5.1 Build and verify: Settings shows "GitHub Login Refresh" when authenticated
- [x] 5.2 Build and verify: Remote Projects submenu lists repos not in ~/src/
- [x] 5.3 Test: click a remote project, verify it clones and appears in the tray menu
