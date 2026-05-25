<!-- @trace spec:git-mirror-service -->
# git-mirror-service Specification

## Status

status: active

## Purpose

Per-project bare mirror repositories live inside a named Podman volume mounted
at `/srv/git` in the git service container. Git daemon serves clones and pushes
over the enclave network. Post-receive hooks forward only the refs changed by
the forge push to the configured remote. GitHub credentials arrive through the
Phase 6 Vault AppRole path by default, with the deprecated keyring-backed
podman secret kept as a temporary fallback.
## Requirements
### Requirement: Bare mirror repository management
The system SHALL create and maintain a bare mirror repository for each project
at `/srv/git/<project>` inside the git service container, backed by the named
Podman volume `tillandsias-mirror-<project>`. The mirror SHALL be initialized
idempotently, SHALL store the configured upstream URL as `origin` when one is
available, and SHALL survive git service container restarts.

@trace spec:git-mirror-service

#### Scenario: Project with remote origin
- **WHEN** a project directory is a git repo with a configured remote `origin`
- **AND** no mirror exists for this project
- **THEN** the git service SHALL create `/srv/git/<project>` via `git init --bare`
- **AND** SHALL configure the mirror's `origin` remote to the host project's remote URL

#### Scenario: Project with local-only git repo
- **WHEN** a project directory is a git repo without a remote `origin`
- **AND** no mirror exists for this project
- **THEN** the git service SHALL create `/srv/git/<project>` via `git init --bare`
- **AND** the post-receive hook SHALL log "no remote configured, skipping push"
- **AND** forge pushes SHALL remain persisted in the bare mirror volume

#### Scenario: Project directory is not a git repo
- **WHEN** a project directory does not contain a `.git` directory
- **THEN** the system SHALL run `git init` and create an initial commit in the project directory
- **AND** then create a bare mirror from the initialized repo

#### Scenario: Mirror already exists
- **WHEN** a mirror already exists for the project
- **THEN** the git service SHALL preserve existing refs and objects
- **AND** SHALL refresh the mirror's `origin` remote from the launcher-provided URL when one is available

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

#### Scenario: Forge commits use GitHub Login identity
- **WHEN** a forge container starts after GitHub Login saved a git identity
- **THEN** the launcher SHALL inject `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL`
- **AND** the entrypoint SHALL configure repo-local `user.name` and
  `user.email` after entering the project
- **AND** commits created by Codex, OpenCode, OpenCode Web, Claude, or the
  maintenance terminal SHALL use that identity before pushing to the mirror

#### Scenario: Multiple forge containers clone independently
- **WHEN** two forge containers clone the same project mirror
- **THEN** each SHALL have an independent working tree
- **AND** pushes from one SHALL be visible to the other after fetch

### Requirement: Post-receive hook forwards only changed refs
The bare mirror SHALL contain a `post-receive` hook that automatically pushes to
`origin` after receiving refs from forge containers. The hook SHALL read the
`oldsha newsha refname` records from stdin and SHALL construct an explicit
refspec list for exactly those refs. The hook MUST NOT run `git push --mirror`,
`git push --all`, or any other command that rewrites or deletes refs not present
in the forge push. If no remote is configured, the hook SHALL be a no-op.

@trace spec:git-mirror-service

#### Scenario: Push triggers auto-push to remote
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has a remote `origin` configured
- **THEN** the post-receive hook SHALL push only the stdin-provided refs using
  explicit `<newsha>:<refname>` refspecs
- **AND** SHALL log the update/deletion counts and result via `--log-git`

#### Scenario: Unmentioned upstream refs are never touched
- **WHEN** a forge push updates `refs/heads/feature-a`
- **AND** the upstream repository has `refs/heads/main`, `refs/heads/release`,
  and tags that are absent from the sparse mirror
- **THEN** the post-receive hook SHALL NOT delete, force-update, or rewrite any
  upstream ref except `refs/heads/feature-a`
- **AND** the hook source SHALL contain a guard explaining that `--mirror` is forbidden

#### Scenario: Bulk deletes are guarded
- **WHEN** a forge push deletes more than ten refs in one post-receive batch
- **THEN** the hook SHALL refuse to forward those deletions unless
  `TILLANDSIAS_ALLOW_BULK_DELETE=1`
- **AND** the forge push SHALL remain accepted locally so user commits are not lost

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

### Requirement: GitHub token delivery uses Vault AppRole by default
The git service container SHALL receive a short-lived Vault AppRole token scoped
to `git-mirror-policy` by default. The launcher SHALL mount that token as a
podman secret at `/run/secrets/vault-token`; the hook SHALL read the GitHub
token from Vault at `secret/github/token` through `vault-cli` only at push time.
The deprecated `tillandsias-github-token` podman secret MAY be mounted only when
the user explicitly selects the legacy keyring path. No D-Bus socket, keyring
API, bind-mounted token file, or askpass helper SHALL cross the enclave
boundary.

@trace spec:git-mirror-service, spec:secrets-management, spec:native-secrets-store

#### Scenario: Vault token mount on launch
- **WHEN** the git service container is launched and Vault is running
- **THEN** the launcher SHALL mint an AppRole token scoped to `git-mirror-policy`
- **AND** the container SHALL receive `--secret=<generated>,target=vault-token,mode=0400`
- **AND** the container SHALL read `/run/secrets/vault-token`
- **AND** the container SHALL receive `VAULT_ADDR=http://vault:8200` and
  `VAULT_ROLE=git-mirror`

#### Scenario: No token means no credential mount
- **WHEN** Vault has no GitHub token and the legacy keyring path is not selected
- **THEN** the git service container SHALL start without a token mount
- **AND** authenticated pushes SHALL fail loudly until the user re-authenticates via "GitHub Login"

#### Scenario: Hook reads the GitHub token from Vault
- **WHEN** the git service's post-receive hook pushes to an HTTPS origin
- **AND** `/run/secrets/vault-token` is present
- **THEN** the hook SHALL run `vault-cli read -field=token secret/github/token`
- **AND** construct the HTTPS auth URL in memory only
- **AND** the token SHALL not appear in process arguments, environment variables, or logs

#### Scenario: Legacy keyring secret fallback
- **WHEN** the git service starts with `--legacy-keyring-secrets`
- **THEN** the container MAY receive `--secret=tillandsias-github-token`
- **AND** the hook MAY read `/run/secrets/tillandsias-github-token`
- **AND** no Vault env vars SHALL be injected for the legacy-only git launch

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


## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation` — Verify git service is enclave-only and credentials never leak
- `litmus:git-mirror-safe-refspec-push` — Verify post-receive and startup retry paths forbid `--mirror`/`--all`, build explicit refspecs, and guard bulk deletes.

Gating points:
- Bare mirror created at `/srv/git/<project>` inside `tillandsias-mirror-<project>` on first launch
- git daemon serves clones from enclave network only; external clones fail
- Post-receive hook forwards only changed refs to remote if configured, logs result with no credentials
- Startup retry-push uses explicit branch/tag refspecs, never `--mirror` or `--all`
- Vault AppRole token allows the git service to read `secret/github/token`; legacy keyring secret is explicit and deprecated
- Forge containers cannot access any credentials (no D-Bus, no token files, no git config)
- Mirror sync event-driven by filesystem watcher, zero polling
- Sync skips if host has uncommitted changes, diverged branch, or detached HEAD
- Tray startup sweeps all mirrors and syncs host working copies that are clean and ahead

## Sources of Truth

- `cheatsheets/utils/git-workflows.md` — Git Workflows reference and patterns
- `cheatsheets/runtime/unix-socket-ipc.md` — Unix Socket Ipc reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:git-mirror-service" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
