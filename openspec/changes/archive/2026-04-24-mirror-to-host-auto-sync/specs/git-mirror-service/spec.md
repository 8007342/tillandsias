## ADDED Requirements

### Requirement: Mirror → host working-copy auto-sync on push

The tray SHALL trigger a fast-forward attempt on the host working copy at `<watch_path>/<project>` for every successful push to the enclave bare mirror at `$CACHE_DIR/tillandsias/mirrors/<project>`. The sync MUST be event-driven by a filesystem watcher on the mirrors root; polling is forbidden in every trigger path (startup, watcher, shutdown). The first matching `scanner.watch_paths` entry wins.

#### Scenario: Forge push propagates to host working copy
- **WHEN** a forge container pushes a new commit to its enclave mirror
- **AND** the host has a clean working copy of the project at
  `<watch_path>/<project>`
- **AND** the host's current branch is a strict ancestor of the mirror's
  corresponding branch
- **THEN** within 1 second the filesystem watcher detects the ref update
  under `refs/heads/` or `packed-refs`
- **AND** the tray runs `git fetch <mirror_dir>` + `git merge --ff-only`
  in the host working copy
- **AND** the working-tree files update to reflect the new commit
- **AND** the event is logged with `accountability=true` and the fields
  `project`, `branch`, `from`, `to`

#### Scenario: No polling anywhere in the sync path
- **WHEN** auditing `src-tauri/src/mirror_sync.rs` and call sites
- **THEN** no `tokio::time::interval` / `std::thread::sleep` loop drives
  the sync cadence
- **AND** the only triggers are (1) tray startup, (2)
  `notify::recommended_watcher` kernel events, and (3) `shutdown_all`
- **AND** the debounce window inside the watcher (500 ms) coalesces
  rapid event bursts but does not poll — it is reset by incoming events,
  not a timer

### Requirement: Mirror sync never clobbers user work

The sync SHALL be strictly non-destructive with respect to the user's
host working copy. In every case below the sync SHALL skip, log the
reason at debug/info level, and leave the host untouched:

- Uncommitted changes in the host working tree (`git status --porcelain`
  is non-empty).
- Host is on a detached HEAD, in the middle of a rebase, merge, or bisect.
- Host branch has commits the mirror does not (fast-forward impossible).
- The host branch does not exist on the mirror at all.
- The host path exists but is not a git working copy.
- The host working copy does not exist.

`git merge --ff-only` is the enforcement — if it returns non-zero for
any reason, we report the typed `SyncResult` and do not retry with any
lossy strategy (no `--hard`, no `--force-with-lease`, no rebase).

#### Scenario: Dirty working tree short-circuits
- **WHEN** the host has `git status --porcelain` non-empty
- **THEN** `sync_project` returns `SyncResult::HostDirty`
- **AND** the working tree is not modified by the sync
- **AND** no `git merge`, `git reset`, or `git checkout --force` is run

#### Scenario: Diverged branch short-circuits
- **WHEN** the host branch has one commit the mirror does not AND the
  mirror has a different commit the host does not
- **THEN** `sync_project` returns `SyncResult::HostDiverged`
- **AND** neither side's history is rewritten

#### Scenario: Absent host is not auto-created
- **WHEN** a mirror exists for project X but no `<watch_path>/X` exists
  on the host
- **THEN** `sync_project` returns `SyncResult::HostAbsent`
- **AND** no directory is created on the host
- **AND** no clone is performed (user must explicitly `git clone` when
  they want a local checkout)

### Requirement: Tray startup sweeps all mirrors

On tray startup, the tray SHALL run one `sync_project` call for every
directory found under `$CACHE_DIR/tillandsias/mirrors/`, iterating the
configured `scanner.watch_paths` to find the corresponding host working
copy. This catches any push that landed in the mirror after the last
session exited but before the host was synced (e.g. tray crash between
mirror post-receive and working-copy fast-forward).

#### Scenario: Startup sweep catches stranded commits
- **WHEN** the tray starts and a project's mirror has
  `refs/heads/main` ahead of the host's `main`
- **AND** the host is clean and on `main`
- **THEN** the startup sweep fast-forwards the host before the menu
  is first rendered
- **AND** the watcher is armed for subsequent event-driven syncs

### Requirement: Tray Quit triggers a final sync

`shutdown_all()` SHALL run a `sync_all_projects` sweep BEFORE stopping
containers. This ensures any push that landed in the last ~500 ms
(inside the inotify debounce window) reaches the host before the mirror
or git-service containers disappear, closing the gap between "in-flight
event" and "gone container".

#### Scenario: Quit-time sync covers the inotify debounce window
- **WHEN** a forge pushes a commit ≤500 ms before the user clicks
  tray Quit
- **THEN** the inotify debounce may not have fired yet when `shutdown_all`
  starts
- **AND** `shutdown_all` runs `sync_all_projects` synchronously before
  tearing containers down
- **AND** the host working copy receives the fast-forward
- **AND** the subsequent container teardown does not disturb the already-
  synced state
