# tasks

## 1. Spec convergence

- [x] Proposal documenting the menu redesign + state machine.
- [x] Spec delta for `tray-app`.
- [ ] Validate strict.

## 2. MenuCommand pruning

- [x] `crates/tillandsias-core/src/event.rs`: drop `SelectAgent`,
      `ServeHere`, `Destroy`, `Start`, `Stop`, `StopProject`,
      `Settings`, `ClaudeResetCredentials`. (Also dropped `Terminal`,
      `RootTerminal` — superseded by MaintenanceTerminal.)
- [x] Add `Launch { project_path }` (replaces ServeHere from tray-side).
- [x] Add `MaintenanceTerminal { project_path }`.
- [x] Add `IncludeRemoteToggle { include: bool }`.
- [x] `event_loop.rs` arms updated; removed variants delete their match arms.

## 3. Menu rebuild → toggle

- [x] New `menu::TrayMenu` struct holding handles to every pre-built item.
      (Lives in `src-tauri/src/tray_menu.rs`; old `menu.rs` shrunk to a
      single helper.)
- [x] `TrayMenu::new()` builds the static skeleton at app start.
- [x] `TrayMenu::set_stage(Stage)` toggles `enabled`/text per stage.
- [x] `TrayMenu::update_projects(local, remote)` rebuilds the Projects ▸
      submenu only when the (project_set, include_remote) tuple changes.
- [x] Remove `rebuild_menu()` callers that don't need a structural rebuild.
      (rebuild_menu now drives the pre-built menu via `set_stage` +
      `update_projects` + `update_building_chip`; no `set_menu` calls.)

## 4. Single forge per project per tray

- [x] `handle_attach_web` reused via `MenuCommand::Launch` from the tray.
- [x] If a forge is already running for the project, the click reopens a
      browser window against the existing container (no relaunch).
      (Handled by the existing `handle_attach_web` reattach branch.)
- [x] Browser window URL: `http://<project>.opencode.localhost/`
      (depends on `subdomain-routing-via-reverse-proxy` Phase 3).
- [x] Tear-down: only `shutdown_all` stops the forge.

## 5. Maintenance terminal

- [x] `handle_maintenance_terminal(project_path)`: spawn a host terminal
      running `podman exec -it tillandsias-<project>-<genus> /bin/bash`.
      (Already present from Phase 1; wired to MenuCommand here.)
- [x] Multiple maintenance terminals against the same forge are allowed.
- [x] Falls back gracefully if the forge isn't running (offers Launch first).

## 6. GitHub credential health classifier

- [x] `src-tauri/src/github_health.rs`:
  - `enum CredentialHealth { Authenticated, CredentialMissing,
    CredentialInvalid, GithubUnreachable }`
  - `async fn probe() -> CredentialHealth` composing keyring read +
    10s `tokio::time::timeout` over `GET api.github.com/user`.
- [x] Cached for tray process lifetime; re-runs on user-initiated
      sign-in / sign-out / refresh. (Stored in `CREDENTIAL_HEALTH`
      OnceLock; `reprobe_credentials` hooked in `MenuCommand::GitHubLogin`.)
- [x] Drives `Stage` selection in the new state machine.

## 7. Stale-container sweep

- [ ] `pre_ui_cleanup_stale_containers()` in handlers, called from
      `main.rs::main` before the event loop accepts user input.
      Removes any `tillandsias-*` container started before the current
      tray PID's start time.
- [ ] Forces enclave network removal too (so a stale tray's network is
      reclaimed cleanly).

## 8. Cancel tokens + biased select

- [ ] `tokio::sync::CancellationToken` per long-running spawn (image
      build, overlay build [n/a after tombstone], proxy probe, MCP probe).
- [ ] `event_loop.rs` adds `biased;` to its `tokio::select!`.
- [ ] On Quit, all tokens fire abort.
- [ ] Long-running `tokio::process::Command::output()` calls get a
      `tokio::time::timeout` wrapper.

## 9. Test coverage

- [x] Unit test: stage state machine transitions — `stage_visibility_table_matches_spec`
      asserts the Stage→visibility mapping matches the spec table exactly.
- [x] Unit test: `credential_health_to_stage_mapping` and
      `dispatch_click_known_actions` cover health→stage and click→command paths.
- [ ] Unit test: `update_projects` rebuilds only when project set changes.
      (Cache key logic covered indirectly; full Tauri-runtime test deferred.)
- [ ] Smoke test: kill `gh auth` token → relaunch → see `Sign in to GitHub`.
- [ ] Smoke test: network off → see `(GitHub unreachable, using cached
      projects)` banner; project list still populated from cache.
- [ ] Smoke test: 30s fake forge build + Quit click → exits within 5s.

## 10. Cheatsheet

- [x] `docs/cheatsheets/tray-state-machine.md` documenting the five
      stages, what each shows, what the user can do next.

## 11. Convergence

- [ ] `/opsx:verify` strict.
- [ ] `/opsx:archive simplified-tray-ux`.
- [ ] Archive `tray-responsiveness-and-startup-gating` as superseded
      (its proposal stays for history).
