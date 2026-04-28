# Host-side mirror sync (Windows credential isolation)

## Why

The Windows/WSL implementation of mirror→GitHub sync currently embeds a
GitHub token in the bare mirror's `config` file as `https://oauth2:<TOKEN>@...`.
The forge distro can read `/mnt/c/.../mirrors/<project>/config` and extract
the token — a credential leak compared to the Linux/podman flow where the
token lives only in the tillandsias-git container's tmpfs.

The user explicitly flagged this: *"we need a real git mirror service with
real hooks for syncing the local filesystem in the host"*. Long-term the
forge MUST have zero readable path to the token.

## What changes

- Remove the `oauth2:<TOKEN>@` injection from the bare mirror's origin URL.
  Mirror's `origin` becomes the clean `https://github.com/owner/repo.git`.
- Strip the `git push --mirror origin` from the post-receive hook. The hook
  now just touches a marker file (e.g. `<mirror>/.tillandsias-pending-sync`)
  with the timestamp of the push.
- Add a host-side `mirror_sync` background task in the Tillandsias tray
  binary. It watches each project's mirror directory (filesystem watcher
  via `notify` crate, fallback to 10s polling) and on detected change:
  1. Reads the GitHub token from Windows Credential Manager via the existing
     `secrets::retrieve_github_token`.
  2. Spawns `git.exe -C <mirror> push --mirror origin` with the token passed
     via `GIT_ASKPASS` / `git credential-helper-store` ephemeral file in the
     tray's process memory only.
  3. On success, removes the marker file and logs an accountability event.
  4. On failure, retains the marker (so the next attach retries).
- Repurpose the post-receive hook to write the marker file and emit a
  user-visible "queued for GitHub sync" message so users can `--diagnostics`
  the lifecycle.
- Document the trade-off in `cheatsheets/runtime/git-mirror-credential-flow.md`
  with provenance from Microsoft Credential Manager docs.

## Impact

- Forge process has zero readable path to the GitHub token (closes the leak).
- Push UX is the same from forge: `git push origin` returns success when the
  push lands in the bare mirror; the host-side daemon handles GitHub sync
  asynchronously (typical lag <1s).
- Linux/macOS path unchanged — token continues to live in the tillandsias-git
  container tmpfs as before.
- New spec `host-side-mirror-sync`.

## Sources of Truth

- `cheatsheets/runtime/git-mirror-credential-flow.md` — credential flow diagram
  with redaction conventions and Windows Credential Manager provenance
- `cheatsheets/runtime/wsl-on-windows.md` — why the forge can read /mnt/c
- `cheatsheets/runtime/windows-credential-manager.md` (existing) — Win API
  for credential storage
