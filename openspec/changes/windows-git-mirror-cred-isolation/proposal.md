## Why

The Windows attach flow had two startup-blocking defects that surfaced in
smoke testing on `wsl-on-windows`:

1. **`safe.directory` mismatch on `tillandsias-git`.** The git-daemon runs
   as `git` (uid=1000) but the bare mirrors live on `/mnt/c/...` drvfs
   where every inode reports `uid=0/gid=0` regardless of NTFS ACL (this
   is documented behaviour for WSL drvfs — see
   `cheatsheets/runtime/wsl-mount-points.md`). Git therefore refuses to
   serve the repo with `fatal: detected dubious ownership`. The previous
   `git config --global --add safe.directory <mirror>` ran as root inside
   `ensure_mirror`, so the daemon's `git` user never inherited the
   exemption.

2. **Host-side `git fetch --all` triggers a GUI Credential Manager prompt
   that hangs the tray.** With the recent move from "token-in-URL" to a
   clean `https://github.com/owner/repo` origin, Git for Windows tries
   `git-credential-manager get` against the unauthenticated URL, which
   pops a Microsoft login dialog. The tray's startup sits on the spawn's
   stdout pipe waiting for the modal to be answered, and on a headless
   smoke test this looks like an indefinite hang.

Both block the very first attach after a fresh `--init`, which is the
exact path a Windows release-candidate must walk.

## What Changes

- `ensure_git_service_running_wsl` runs a one-shot bootstrap of
  `git config --system --add safe.directory '*'` in `tillandsias-git`
  before spawning the daemon. The system-wide `safe.directory` exempts
  every UID from the dubious-ownership check, including the daemon's
  `git` user. The setting is idempotent (re-running is a no-op once
  added).
- `ensure_mirror`'s host-side `git fetch --all` is wrapped on Windows
  with three credential-isolation guards:
  - `GIT_TERMINAL_PROMPT=0` — Git won't fall back to TTY input.
  - `GCM_INTERACTIVE=Never` — Git Credential Manager won't pop a UI.
  - `-c credential.helper=` (empties the helper list) followed by a
    shell credential-helper that reads the token from a process-scoped
    env var (`TILLANDSIAS_FETCH_TOKEN`). The token is therefore never
    written to disk and never appears in the command line — only in the
    env block of the spawned `git.exe` process.
- The Linux path is unchanged: `run_git` still routes through the
  `tillandsias-git` container's credential plumbing.

## Impact

- **Specs**: `windows-wsl-runtime` (additive — new requirements for
  daemon ownership exemption and host-side fetch credential isolation).
- **Code**: `src-tauri/src/handlers.rs` only.
- **Cheatsheets**: cited under Sources of Truth — no edits required.
- **Behaviour**: Windows attach completes without GUI prompts and the
  forge can clone via `git://localhost:9418/<project>` after mirrored
  networking activates.
