# tasks

## 1. Core sync module

- [x] `src-tauri/src/mirror_sync.rs` — `sync_project(project, mirror, host)`
  with typed `SyncResult` enum covering every skip reason.
- [x] Uses `git -C <host> symbolic-ref --short HEAD`, `git status --porcelain`,
  `git -C <mirror> rev-parse refs/heads/<branch>`, `git fetch <mirror> ...`,
  `git merge --ff-only` — all via `std::process::Command`, no libgit2.

## 2. Startup sweep

- [x] `sync_all_projects(mirrors_root, watch_paths)` iterates
  `mirrors_root` and finds each project's host dir under any configured
  watch path.
- [x] Called from `main.rs` setup closure after the initial project scan
  completes, before the menu is first rendered.

## 3. Filesystem watcher — event-driven, no polling

- [x] `spawn_watcher(mirrors_root, watch_paths)` uses
  `notify::recommended_watcher` (inotify on Linux, FSEvents on macOS).
- [x] Watches the mirrors root recursively.
- [x] Filters to `refs/heads/*`, `packed-refs`, `HEAD`, `FETCH_HEAD`
  under each project dir.
- [x] 500 ms per-project debounce to coalesce the burst of FS events a
  single `git push` produces.
- [x] Armed on tray startup; survives for tray lifetime.
- [x] `notify = { workspace = true }` added to `src-tauri/Cargo.toml`.

## 4. Shutdown hook

- [x] `shutdown_all()` in `handlers.rs` runs `sync_all_projects` before
  stopping containers so the last ≤500 ms of pushes reach the host.

## 5. Container-stop hook

- [x] `event_loop.rs` — after a Forge / OpenCodeWeb / Maintenance
  container enters Stopped/Absent state, run a one-off sync for that
  project. Belt-and-braces in case the fs watcher missed an event.

## 6. Tests

- [x] `already_up_to_date_returns_noop`
- [x] `mirror_advances_fast_forwards_host`
- [x] `dirty_host_is_skipped`
- [x] `diverged_host_is_skipped_not_force_merged`
- [x] `absent_host_returns_host_absent`
- [x] `absent_mirror_returns_mirror_absent`

## 7. Build + verify

- [x] `./build.sh --check` clean.
- [x] `./build.sh --test` — all sync tests green (6 of 6).
- [ ] `./build.sh --release --install` produces an AppImage including the
  watcher hookup.

## 8. Smoke test (user-driven)

- [ ] Launch tray. Attach Here on a committed-repo project you have
  locally (e.g. `~/src/java`).
- [ ] Ask the agent to add a file and push. Watch your terminal:
  `ls ~/src/java && git -C ~/src/java log -1 --oneline`. Within ~1s
  of the push finishing, the new commit appears.
- [ ] Make your host working tree dirty (`echo x > ~/src/java/scratch`).
  Ask the agent to make another commit and push. The sync should
  skip (HostDirty); your scratch file is untouched.
- [ ] Commit your scratch file locally without pushing. Push from the
  forge. Sync should skip (HostDiverged); both histories intact.

## 9. Spec convergence + archive

- [x] `openspec validate --strict mirror-to-host-auto-sync` passes.
- [ ] After user smoke test: `openspec archive -y mirror-to-host-auto-sync`.
- [ ] Bump version via `./scripts/bump-version.sh --bump-changes`.
