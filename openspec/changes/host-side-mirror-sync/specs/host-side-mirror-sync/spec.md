# Host-side mirror sync — capability

## ADDED Requirements

### Requirement: Token never written to disk in a file the forge can read

The GitHub token used for mirror→remote push SHALL NOT be persisted in any
file path that is readable from inside any Tillandsias-managed forge
distro/container. On Windows specifically, files under `/mnt/c/...` are
visible to every WSL distro that auto-mounts the C: drive, so any token
stored there is reachable from the forge.

#### Scenario: forge agent attempts to read the token

- **WHEN** an agent in the forge runs `cat /mnt/c/.../mirrors/<project>/config`
  or `git -C /mnt/c/.../mirrors/<project> config remote.origin.url`
- **THEN** the output SHALL NOT contain a GitHub token
- **AND** the URL SHALL be the clean `https://github.com/owner/repo.git` form

### Requirement: Host-side daemon performs the GitHub push

A background task in the Tillandsias tray binary SHALL detect new commits
landing in any managed mirror and push them to GitHub using the host's
Windows Credential Manager. The daemon runs in the tray's process — never
in the forge or any WSL distro.

#### Scenario: forge pushes; mirror is synced shortly after

- **WHEN** a forge process runs `git push origin` and the push lands in the
  bare mirror
- **THEN** within ≤5s (filesystem watcher) or ≤10s (polling fallback) the
  host-side daemon SHALL invoke `git -C <mirror> push --mirror origin` using
  a token read from Windows Credential Manager
- **AND** on success, the post-receive marker file SHALL be removed
- **AND** the accountability log SHALL include a `category="git-sync"` event
  with the project name and commit count

### Requirement: post-receive hook emits a queued-sync marker only

The mirror's `hooks/post-receive` SHALL only touch a marker file at
`<mirror>/.tillandsias-pending-sync` and echo a user-visible "queued for
GitHub sync" line to stderr. The hook SHALL NOT invoke `git push` and SHALL
NOT read any credential. This makes the hook identical across Linux and
Windows host flows; the divergence (host-side daemon vs git-service container)
SHALL live in the consumer of the marker, not the producer.

#### Scenario: A push lands in the mirror and the hook fires

- **WHEN** a forge process runs `git push origin` and the daemon receives the
  push
- **THEN** the post-receive hook SHALL create or touch
  `<mirror>/.tillandsias-pending-sync`, AND SHALL print a single line to
  stderr starting with `[git-mirror] queued`, AND SHALL exit with status 0
  without invoking `git push` to any remote.

### Requirement: Sync failures retain the marker for retry

The host-side daemon SHALL leave the `.tillandsias-pending-sync` marker in
place when `git push --mirror origin` fails for any reason (network, auth,
remote rejection). The marker SHALL be removed only after a successful push.
The next mirror change OR the next tray attach to the project SHALL trigger a
retry. Users SHALL see a tray notification on the first failure containing
the GitHub-side error message.

#### Scenario: GitHub push fails and the marker is retained

- **GIVEN** a `.tillandsias-pending-sync` marker present after a forge push
- **WHEN** the host-side daemon's `git push --mirror origin` returns non-zero
- **THEN** the marker file SHALL still exist on disk, AND a tray notification
  SHALL be raised once with the GitHub error stderr, AND the next marker-
  triggering event SHALL re-attempt the push.

### Requirement: Diagnostics surface the sync flow

The `--diagnostics` flag SHALL include a `[mirror-sync]` source that streams
every sync attempt with timestamps, commit counts, and outcome (success /
queued / failed). The cheatsheet `cheatsheets/runtime/git-mirror-credential-flow.md`
SHALL document how to grep this stream and what each line means.

#### Scenario: --diagnostics shows queued and synced lines

- **WHEN** the user runs `tillandsias <path> --diagnostics --opencode` AND a
  forge push lands in the mirror
- **THEN** the diagnostics stream SHALL contain a `[mirror-sync] queued
  <project> <sha>` line followed (within the daemon's polling window) by
  either a `[mirror-sync] synced <project>` or `[mirror-sync] failed
  <project>: <reason>` line.

## Sources of Truth

- `cheatsheets/runtime/wsl-mount-points.md` — why /mnt/c is visible to all distros
- `cheatsheets/runtime/windows-credential-manager.md` — Win Credential API
- `cheatsheets/runtime/git-mirror-credential-flow.md` — credential flow diagram (new)
