<!-- @trace spec:git-mirror-service -->
# git-mirror-service Specification

## Status

status: active

## Purpose

Per-project bare mirror repositories live inside a named Podman volume mounted
at `/srv/git` in the git service container. Git daemon serves clones and pushes
over the enclave network. A pre-receive relay forwards exactly the proposed ref
transaction to the configured upstream with `git push --atomic` before the
mirror acknowledges it locally. GitHub credentials arrive through the Phase
6.5 Vault AppRole path. The git service reads the GitHub token from Vault at
push time via Vault CLI; the token never crosses into a forge container.
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
- **AND** the pre-receive hook SHALL accept the update as durable local-only state
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
- **AND** the mirror has a configured upstream
- **THEN** the push SHALL succeed only after the upstream atomically accepts the proposed refs
- **AND** the commits SHALL then be persisted in the bare mirror volume

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

### Requirement: Pre-receive relay verifies acknowledgement durability
The bare mirror SHALL preserve receive-pack's complete `oldsha newsha refname`
transaction, validate local policy, and invoke the Tillandsias relay helper
from `pre-receive`. The relay helper SHALL construct explicit refspecs for
exactly those refs and SHALL issue one `git push --atomic` to `origin`. The
mirror SHALL acknowledge and commit its local ref transaction only after the
configured upstream accepts the complete atomic transaction. `post-receive`
SHALL perform bookkeeping only and MUST NOT be the relay authority because its
exit status cannot change receive-pack's result. The relay MUST NOT run
`git push --mirror`, `git push --all`, or touch an unmentioned upstream ref.
If no upstream is configured, the pre-receive hook SHALL explicitly classify
the update as durable local-only state.

@trace spec:git-mirror-service

#### Scenario: Push is acknowledged only after upstream acceptance
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has a remote `origin` configured
- **THEN** the pre-receive relay SHALL push only the stdin-provided refs using
  one atomic transaction of explicit `<newsha>:<refname>` refspecs
- **AND** receive-pack SHALL report success only after that relay succeeds
- **AND** SHALL log the update/deletion counts and verified result via `--log-git`

#### Scenario: Unmentioned upstream refs are never touched
- **WHEN** a forge push updates `refs/heads/feature-a`
- **AND** the upstream repository has `refs/heads/main`, `refs/heads/release`,
  and tags that are absent from the sparse mirror
- **THEN** the relay helper SHALL NOT delete, force-update, or rewrite any
  upstream ref except `refs/heads/feature-a`
- **AND** the hook source SHALL contain a guard explaining that `--mirror` is forbidden

#### Scenario: Bulk deletes are guarded
- **WHEN** a forge push deletes more than ten refs in one receive transaction
- **THEN** the relay helper SHALL reject those deletions unless
  `TILLANDSIAS_ALLOW_BULK_DELETE=1`
- **AND** the local ref transaction SHALL remain unchanged

#### Scenario: Push to local-only mirror
- **WHEN** a forge container pushes to the mirror
- **AND** the mirror has no remote `origin`
- **THEN** the pre-receive hook SHALL classify and accept a durable local-only update
- **AND** post-receive SHALL NOT label the update upstream-verified

#### Scenario: Remote push fails (missing or expired credentials)
- **WHEN** the pre-receive relay has an HTTPS upstream without a readable Vault credential
- **OR** the atomic upstream push fails (e.g., 401 Unauthorized)
- **THEN** the hook SHALL fail without an interactive prompt and log a redacted error
- **AND** the forge's `git push` SHALL return non-zero
- **AND** neither the mirror nor upstream SHALL partially update the proposed refs
- **AND** the user can refresh credentials via "GitHub Login" in the tray

### Requirement: Reconciliation fetch never clobbers exported refs
The mirror's startup reconciliation `git fetch origin` SHALL update remote-tracking refs
(`refs/remotes/origin/*`) only and SHALL NOT map upstream branches or tags onto
the mirror's exported `refs/heads/*` or `refs/tags/*`. The bare repo's
`remote.origin.fetch` SHALL be `+refs/heads/*:refs/remotes/origin/*` with
`remote.origin.tagOpt=--no-tags`. A newly initialized empty mirror SHALL be
seeded once with an explicit `+refs/heads/*:refs/heads/*` and
`+refs/tags/*:refs/tags/*` refspec so clones over the git daemon observe heads
and tags. The unsafe all-refs direct mapping (`+refs/*:refs/*`) SHALL NOT be
restored.

@trace spec:git-mirror-service

#### Scenario: One push converges mirror and upstream
- **WHEN** a forge pushes a new commit to the mirror while upstream is stale
- **THEN** the pre-receive relay SHALL leave the proposed local
  `refs/heads/*` transaction intact
- **AND** after the acknowledged relay the mirror and upstream SHALL advertise the same
  SHA without requiring a second identical push

#### Scenario: Startup retry forwards a locally stranded commit
- **WHEN** a prior session left a commit in the mirror that never reached upstream
- **AND** the startup retry loop reconcile-fetches before re-pushing
- **THEN** the fetch SHALL NOT reset the mirror's exported head to the stale
  upstream SHA
- **AND** the stranded commit SHALL be forwarded to upstream

### Requirement: GitHub token delivery uses Vault AppRole
The git service container SHALL receive a short-lived Vault AppRole token scoped
to `git-mirror-policy`. The launcher SHALL mount that token as a podman secret
at `/run/secrets/vault-token`; the hook SHALL read the GitHub token from Vault
at `secret/github/token` through `vault-cli` only at push time. No D-Bus socket,
keyring API, bind-mounted token file, or askpass helper SHALL cross the enclave
boundary. The deprecated `--legacy-keyring-secrets` fallback was removed in v0.3.

@trace spec:git-mirror-service

#### Scenario: Vault token mount on launch
- **WHEN** the git service container is launched and Vault is running
- **THEN** the launcher SHALL mint an AppRole token scoped to `git-mirror-policy`
- **AND** the container SHALL receive `--secret=<generated>,target=vault-token,mode=0400`
- **AND** the container SHALL read `/run/secrets/vault-token`
- **AND** the container SHALL receive `VAULT_ADDR=http://vault:8200` and
  `VAULT_ROLE=git-mirror`

#### Scenario: No Vault token means no credential mount
- **WHEN** Vault has no GitHub token
- **THEN** the git service container SHALL start without a token mount
- **AND** authenticated pushes SHALL fail loudly until the user re-authenticates via "GitHub Login"

#### Scenario: Relay helper reads the GitHub token from Vault
- **WHEN** the git service's pre-receive relay pushes to an HTTPS origin
- **AND** `/run/secrets/vault-token` is present
- **THEN** the hook SHALL run `vault-cli read -field=token secret/github/token`
- **AND** construct the HTTPS auth URL in memory only
- **AND** the token SHALL not appear in process arguments, environment variables, or logs

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
- **WHEN** a pre-receive relay pushes to remote
- **THEN** the system SHALL log the redacted atomic relay result with `@trace spec:git-mirror-service`

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
mirror receive and working-copy fast-forward).

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


### Requirement: Per-project transparency — no hardcoded project names

All code paths that reference the project's name in mirror paths, checkout
paths, container names, volume names, or git config SHALL use a dynamic
variable (`$PROJECT`, `$TILLANDSIAS_PROJECT`, or `<project>` placeholder)
rather than a hardcoded string. The system SHALL work identically for any
GitHub project the host user has cloned, without source changes.

@trace spec:git-mirror-service

#### Scenario: Any GitHub project works without code changes
- **WHEN** a user clones `https://github.com/<user>/<repo>` and launches
  the forge for that project
- **THEN** the git service SHALL create `/srv/git/<repo>` (not
  `/srv/git/tillandsias` or any other hardcoded name)
- **AND** the forge's `insteadOf` rule SHALL include `<repo>` in the mirror URL
- **AND** the pre-receive relay SHALL forward pushes to
  `https://github.com/<user>/<repo>` (the project's actual remote)

#### Scenario: Forge transparency — agents never configure git
- **WHEN** an agent runs inside the forge
- **THEN** `git push`, `git fetch`, and `git clone` SHALL work with zero
  agent-side configuration
- **AND** the agent SHALL see the original GitHub URL in `git remote -v`
- **AND** the agent SHALL NOT need to know about the mirror, Vault tokens,
  or the proxy

### Requirement: Repository-local Git metadata is bidirectionally quarantined

For a host-mounted checkout, the forge SHALL use a writable forge-owned Git
administration directory instead of the host checkout's `.git` directory.
The host worktree, object database, and loose refs SHALL remain shared through
ordered nested mounts. Host repository config, hooks, index, credentials, and
URL rewrites SHALL NOT be visible in the forge, and forge-local Git config
writes SHALL NOT modify the host checkout. Automatic ref packing SHALL be
disabled while loose refs are shared with a private `packed-refs` snapshot.

@trace spec:git-mirror-service

#### Scenario: Forge-local config write cannot poison the host checkout
- **WHEN** a forge runs `git config --local user.x y` or adds a local
  `url.*.insteadOf` rule
- **THEN** the write SHALL succeed against the forge-owned config
- **AND** the host checkout's `.git/config` SHALL remain byte-identical
- **AND** host credential helpers, includes, hooks, and URL rewrites SHALL be
  absent from the forge's effective local config
- **AND** a forge fetch, commit, and push SHALL update the shared objects and
  refs and converge the configured upstream

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:enclave-isolation` — Verify git service is enclave-only and credentials never leak
- `litmus:git-mirror-relay-verified-ack` — Verify missing credentials fail the client push, successful relay converges, and multi-ref rejection is atomic.
- `litmus:git-mirror-safe-refspec-push` — Verify pre-receive and startup retry paths forbid `--mirror`/`--all`, build explicit refspecs, and guard bulk deletes.
- `litmus:git-mirror-ref-convergence` — Verify the reconcile fetch lands in remote-tracking refs only (one push converges mirror + upstream; startup retry forwards a stranded commit; empty-mirror seeding stays cloneable).
- `litmus:forge-gitconfig-bidirectional-quarantine` — Verify writable forge-local config isolation while fetch, commit, object/ref sharing, and push remain functional.

Gating points:
- Bare mirror created at `/srv/git/<project>` inside `tillandsias-mirror-<project>` on first launch
- git daemon serves clones from enclave network only; external clones fail
- Pre-receive relays only changed refs atomically and fails acknowledgement when the configured upstream fails
- Post-receive performs bookkeeping only and cannot establish relay success
- Startup retry uses the same Vault-backed atomic relay helper, never `--mirror` or `--all`
- Reconcile fetch maps upstream into `refs/remotes/origin/*` only; empty mirrors seeded with an explicit heads/tags refspec (one push converges mirror + upstream)
- Vault AppRole token is the only credential path (legacy keyring fallback removed in v0.3)
- Forge containers cannot access any credentials (no D-Bus, no token files, no git config)
- Host and forge repository-local Git config are isolated through the writable `.git` facade while objects and refs remain shared
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
