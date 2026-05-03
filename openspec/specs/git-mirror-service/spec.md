<!-- @trace spec:git-mirror-service -->
# git-mirror-service Specification

## Status

status: active

## Purpose

Per-project bare mirror repositories with git daemon serving clones over the enclave network. Post-receive hooks auto-push to remote. D-Bus forwarding provides host keyring access for credentials.
## Requirements
### Requirement: Bare mirror repository management
The system SHALL create and maintain a bare mirror repository for each project at `~/.cache/tillandsias/mirrors/<project>/`. The mirror SHALL be initialized from the project directory on first launch and updated from remote (if configured) on subsequent launches.

@trace spec:git-mirror-service

#### Scenario: Project with remote origin
- **WHEN** a project directory is a git repo with a configured remote `origin`
- **AND** no mirror exists for this project
- **THEN** the system SHALL create a bare mirror via `git clone --mirror <remote-url>` into `~/.cache/tillandsias/mirrors/<project>/`

#### Scenario: Project with local-only git repo
- **WHEN** a project directory is a git repo without a remote `origin`
- **AND** no mirror exists for this project
- **THEN** the system SHALL create a bare mirror via `git clone --mirror <local-path>` into `~/.cache/tillandsias/mirrors/<project>/`

#### Scenario: Project directory is not a git repo
- **WHEN** a project directory does not contain a `.git` directory
- **THEN** the system SHALL run `git init` and create an initial commit in the project directory
- **AND** then create a bare mirror from the initialized repo

#### Scenario: Mirror already exists
- **WHEN** a mirror already exists for the project
- **THEN** the system SHALL fetch updates from remote (if configured) via `git fetch --all` in the mirror

### Requirement: Git daemon serves mirrors on enclave network
The git service container SHALL run `git daemon` with `--export-all --enable=receive-pack` on the enclave network. Forge containers SHALL clone from `git://git-service/<project>` where `git-service` resolves via the enclave network DNS.

@trace spec:git-mirror-service

#### Scenario: Forge container clones from mirror
- **WHEN** a forge container starts
- **THEN** it SHALL be able to run `git clone git://git-service/<project>` and receive a full working copy

#### Scenario: Forge container pushes to mirror
- **WHEN** a forge container runs `git push origin <branch>`
- **THEN** the push SHALL succeed against the git daemon's receive-pack
- **AND** the commits SHALL be persisted in the bare mirror on the host filesystem

#### Scenario: Multiple forge containers clone independently
- **WHEN** two forge containers clone the same project mirror
- **THEN** each SHALL have an independent working tree
- **AND** pushes from one SHALL be visible to the other after fetch

### Requirement: Post-receive hook auto-pushes to remote
The bare mirror SHALL contain a `post-receive` hook that automatically pushes to `origin` after receiving commits from forge containers. If no remote is configured, the hook SHALL be a no-op.

@trace spec:git-mirror-service

#### Scenario: Push triggers auto-push to remote
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has a remote `origin` configured
- **THEN** the post-receive hook SHALL run `git push --mirror origin`
- **AND** log the result via `--log-git`

#### Scenario: Push to local-only mirror
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has no remote `origin`
- **THEN** the post-receive hook SHALL log "no remote configured, skipping push" and exit cleanly

#### Scenario: Remote push fails (expired credentials)
- **WHEN** the post-receive hook attempts to push to remote
- **AND** the push fails (e.g., 401 Unauthorized)
- **THEN** the hook SHALL log the error via `--log-git`
- **AND** the commits SHALL remain safe in the local mirror
- **AND** the user can refresh credentials via "GitHub Login" in the tray

### Requirement: D-Bus forwarding for host keyring access
The git service container SHALL have the host's D-Bus session bus socket forwarded so that `gh` CLI can access the host OS keyring for GitHub credentials. Credentials SHALL never be written to disk inside the container.

@trace spec:git-mirror-service, spec:secrets-management

#### Scenario: gh auth uses host keyring
- **WHEN** the git service container runs `gh auth token`
- **THEN** it SHALL retrieve the token from the host OS keyring via D-Bus
- **AND** no token SHALL be written to any file inside the container

#### Scenario: D-Bus unavailable
- **WHEN** the D-Bus session bus is not available (headless/SSH)
- **THEN** the git service container SHALL start without credential access
- **AND** remote push operations SHALL fail with an authentication error until the user re-authenticates via "GitHub Login" in an environment with a reachable keyring
- **AND** the system SHALL log a warning via `--log-git`

### Requirement: Git service container lifecycle
The git service container SHALL be started per-project when the first forge container launches and stopped when all forge containers for that project stop. The container name SHALL be `tillandsias-git-<project>`.

@trace spec:git-mirror-service

#### Scenario: Git service starts with first forge
- **WHEN** a forge container is launched for a project
- **AND** no git service is running for that project
- **THEN** the system SHALL start `tillandsias-git-<project>` before launching the forge

#### Scenario: Git service stops when last forge stops
- **WHEN** the last forge container for a project stops
- **THEN** the system SHALL stop `tillandsias-git-<project>`

### Requirement: Git accountability window
All git mirror operations SHALL be logged to the `--log-git` accountability window. Events SHALL include mirror creation, fetch, clone, push, and remote push results. No credentials SHALL appear in logs.

@trace spec:git-mirror-service, spec:runtime-logging

#### Scenario: Mirror creation logged
- **WHEN** a mirror is created for a project
- **THEN** the system SHALL log `[git] Mirror created: <project>` with `@trace spec:git-mirror-service`

#### Scenario: Remote push result logged
- **WHEN** a post-receive hook pushes to remote
- **THEN** the system SHALL log `[git] Remote push: <project> → origin (<success|failure>)` with `@trace spec:git-mirror-service`

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


## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:git-mirror-service" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
