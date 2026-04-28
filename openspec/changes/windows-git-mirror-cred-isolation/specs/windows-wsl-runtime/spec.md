## ADDED Requirements

### Requirement: Git daemon SHALL bypass drvfs ownership checks for mirrors served from /mnt/c

Tillandsias SHALL configure system-wide `safe.directory='*'` in `/etc/gitconfig` of the `tillandsias-git` distro before spawning the git daemon, so the daemon's `git` user (uid=1000) can read bare mirrors located on `/mnt/c/...` drvfs (which always reports `uid=0/gid=0` regardless of NTFS ACL). The bootstrap SHALL be idempotent — re-running on every daemon spawn is a no-op once `*` is present in the system gitconfig. The configuration SHALL be set in `/etc/gitconfig` (system scope) rather than `~/.gitconfig` of any specific user, so future user additions inherit the exemption.

#### Scenario: First daemon spawn applies the exemption

- **GIVEN** A freshly imported `tillandsias-git` distro with no
  pre-existing `/etc/gitconfig` entry for `safe.directory`
- **WHEN** Tillandsias spawns the git daemon for the first time
- **THEN** `git config --system --get-all safe.directory` in the distro
  reports `*` after the spawn, AND the daemon serves bare mirrors
  located on `/mnt/c/.../tillandsias/mirrors/<project>` without the
  "dubious ownership" error.

#### Scenario: Subsequent daemon spawns are no-ops

- **GIVEN** `safe.directory='*'` already present in `/etc/gitconfig`
- **WHEN** Tillandsias respawns the daemon
- **THEN** the bootstrap SHALL detect the existing entry and skip the
  `git config --system --add` invocation (idempotent), AND the daemon
  starts successfully.

### Requirement: Host-side mirror fetch SHALL NOT trigger Git Credential Manager

Tillandsias SHALL ensure the host-side `git fetch --all` against a mirror with a clean `https://github.com/owner/repo` origin never spawns a Git Credential Manager UI dialog on Windows. The fetch SHALL pass three orthogonal guards: (1) `GIT_TERMINAL_PROMPT=0` so Git does not fall back to TTY input; (2) `GCM_INTERACTIVE=Never` so GCM logs and exits rather than displaying any UI; (3) `-c credential.helper=` (empty) to clear the inherited helper chain, followed by `-c "credential.helper=!<shell-helper>"` that responds with credentials read from a process-scoped env var named `TILLANDSIAS_FETCH_TOKEN`. The token SHALL be injected into the env via `Command::env()`. The token MUST NOT appear in the command line of `git.exe`, on disk under `.git/config`, or in any gitconfig file.

#### Scenario: Authenticated fetch succeeds via env-only helper

- **GIVEN** A GitHub PAT in the Windows keyring AND a mirror with clean
  `https://github.com/owner/private-repo` origin
- **WHEN** Tillandsias runs the host-side `git fetch --all` during
  attach
- **THEN** the fetch SHALL succeed without spawning any
  `git-credential-manager.exe` process AND `tasklist /v` for the
  `git.exe` PID SHALL NOT show the token in the command line.

#### Scenario: Missing token degrades silently

- **GIVEN** No GitHub token in the keyring
- **WHEN** Tillandsias runs the host-side `git fetch --all` during
  attach
- **THEN** Tillandsias SHALL still set `GIT_TERMINAL_PROMPT=0` and
  `GCM_INTERACTIVE=Never` AND clear the helper chain. The fetch MAY
  fail for private repos (logged at `debug` level) but SHALL NOT block
  the attach with a UI prompt.

## Sources of Truth

- `cheatsheets/runtime/wsl-mount-points.md` — drvfs uid=0 reporting
  rationalises the system-wide safe.directory exemption.
- `cheatsheets/runtime/secrets-management.md` — env-only credential
  pattern is preferred over command-line and disk-based alternatives.
