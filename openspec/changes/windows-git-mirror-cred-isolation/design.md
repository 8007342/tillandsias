# Design — windows-git-mirror-cred-isolation

## Problem context

The Windows runtime relies on a `git daemon` process inside the
`tillandsias-git` distro to serve bare mirrors at `127.0.0.1:9418`.
Forge distros clone via `git://localhost:9418/<project>` under WSL2
mirrored networking. The mirrors themselves live on
`%LOCALAPPDATA%/tillandsias/mirrors/`, exposed inside WSL as
`/mnt/c/Users/<user>/AppData/Local/tillandsias/mirrors/`.

Two host/distro UID asymmetries broke this in practice:

1. drvfs reports every inode as `uid=0/gid=0`, even when the underlying
   NTFS ACL grants the user write access. Git's "dubious ownership"
   check refuses to operate on a repo whose `uid` differs from the
   running process's `euid`. The git daemon runs as `git` (uid=1000) so
   even with `safe.directory` set globally for root, the daemon refuses.

2. Removing the embedded token from the mirror's `origin` URL made the
   URL clean (`https://github.com/owner/repo`). On host-side
   `git fetch --all`, Git for Windows then routes credential acquisition
   through Git Credential Manager (GCM), which is configured by default
   to pop a Windows login dialog. That dialog is modal — the tray
   process spawning `git.exe` blocks reading stdout until the user
   answers, manifesting as a startup hang.

## Decision

**System-wide `safe.directory='*'` in `tillandsias-git`.** Set at daemon
spawn time as a one-shot bootstrap, in `/etc/gitconfig` (requires root,
hence the bootstrap runs WITHOUT `--user git`). Why `*` rather than
specific paths:

- Mirror paths are dynamic — one per project — so enumerating them at
  daemon-spawn time would require knowing all current and future
  projects.
- The daemon's `--base-path` already constrains which paths it serves;
  the safe.directory exemption is gated by that boundary.
- The distro is single-purpose: only Tillandsias' git-daemon and
  occasional debug shells run there. The blast radius of a `*`
  exemption is the same as the whole distro's filesystem.

Idempotent: `git config --system --get-all safe.directory | grep -qx '*'`
short-circuits the add when the value is already present.

**Env-only credential helper for host-side fetch.** The existing fetch
in `ensure_mirror` is wrapped on Windows with:

```
GIT_TERMINAL_PROMPT=0
GCM_INTERACTIVE=Never
TILLANDSIAS_FETCH_TOKEN=<from keyring>
git -c credential.helper= \
    -c "credential.helper=!f() { echo username=oauth2; echo \"password=\$TILLANDSIAS_FETCH_TOKEN\"; }; f" \
    -C <mirror> fetch --all
```

The first `credential.helper=` (empty) clears the helper chain (which
otherwise inherits GCM from the global gitconfig). The second appends a
shell helper that synthesises a credential response by reading the env
var. Git for Windows ships `mingw-sh`, which interprets the `!shell-cmd`
prefix per
<https://git-scm.com/docs/gitcredentials#_custom_helpers>.

The token therefore lives only in:
- the keyring (encrypted at rest by Windows Credential Manager),
- the in-memory env block of the `git.exe` process during the fetch
  (process-scoped, not visible to other users),
- the env block of the helper shell that `git.exe` invokes (subprocess
  inherits parent env).

It is NOT in:
- the command line of `git.exe` (visible via `tasklist /v` and
  `wmic process get commandline` to other users),
- any file under `.git/config` (the URL stays clean),
- any file under `~/.gitconfig` or `/etc/gitconfig`.

`GCM_INTERACTIVE=Never` is a belt-and-suspenders measure: even if the
helper chain leaked back to GCM, GCM would log an error rather than pop
the dialog (per
<https://github.com/git-ecosystem/git-credential-manager/blob/main/docs/configuration.md#credentialinteractive>).

## Alternatives considered

- **`http.extraHeader = "Authorization: bearer $TOKEN"`.** Rejected:
  the token would appear in the `git.exe` command line via `-c
  http.extraHeader=...`, leaking to any process that can read other
  processes' command lines on the host.

- **`GIT_ASKPASS=<path>`** pointing to a temp `.bat` that prints the
  token. Rejected: requires writing the token (or a token-printing
  script) to disk in the temp dir. Even with O_TMPFILE-equivalent
  semantics on Windows, this is materially worse than env-only.

- **Skipping the host-side fetch entirely on Windows.** Rejected: it
  would diverge from Linux behaviour and lose the keep-mirror-fresh
  property that lets a forge see GitHub-side updates between attaches.

## Sources of Truth

- `cheatsheets/runtime/wsl-mount-points.md` — drvfs always reports
  uid=0; rationalises the `safe.directory` exemption.
- `cheatsheets/runtime/secrets-management.md` — env-only credential
  pattern; informs the GIT_ASKPASS-vs-env helper trade-off.
