## Why

Right now the enclave mirror is the authoritative recipient of every forge
push — commits land there first, then the git-service container's
post-receive + startup retry-push forwards them to GitHub. But the user's
host working copy at `<watch_path>/<project>` never hears about those
commits unless the user manually `git pull`s. Side effects:

- User finishes a session in OpenCode Web, sees `HelloWorld.java` in the
  agent's view, switches to their local terminal, and the file isn't
  there. Confusing.
- Recovery flows for stranded commits (e.g. `86e54f0` in the
  `lakanoa` mirror before we had HTTPS_PROXY) required the user to
  manually `git fetch /var/home/…/cache/…/mirrors/<project>` — awkward.
- GitHub sync is transparent (post-receive hook fires automatically); host
  sync needs the same "just happens" property.

The user's ask: "make sure that changes pushed to remote are also synced to
the local checkout in home/src/<project> on the host. [...] Event driven,
no polling anywhere." Mirror already is the source of truth; the host
working copy is the authoritative view *for the user* and should converge
to it whenever the mirror changes.

## What Changes

- **New module `src-tauri/src/mirror_sync.rs`.** `sync_project` does a
  fast-forward-only fetch from the bare mirror into a host working copy;
  never clobbers dirty trees, never resolves divergence automatically,
  never creates a working copy that isn't already there. Outcomes are
  surfaced as a typed enum for logging + future UI.
- **Three trigger points, all event-driven:**
  1. **Tray startup** — one-shot sweep of every mirror, catching up
     anything stranded by a crash in a previous session.
  2. **Filesystem watcher (inotify / FSEvents)** on
     `$CACHE_DIR/tillandsias/mirrors/`. Every change to
     `<project>/refs/heads/*`, `<project>/packed-refs`, `<project>/HEAD`,
     or `<project>/FETCH_HEAD` fires a sync for that project. Debounced
     500 ms to coalesce the burst a single `git push` produces (loose
     ref write + pack + HEAD update).
  3. **Tray Quit / `shutdown_all`** — final sweep before containers stop,
     so the last push of the session lands on the host even if its inotify
     debounce window hadn't expired.
- **No polling anywhere.** All three triggers are inherently event-driven
  (startup event, FS kernel notification, menu click).
- **`shutdown_all` sweep runs BEFORE the forge stop loop** so we still have
  the live mirror state (it's bind-mounted, persistent, but clearer
  ordering anyway).
- **Container-stop hook** (already present, unchanged) — when a forge /
  opencode-web container stops, we sync once more for that project. Extra
  safety: if the FS watcher missed an event for any reason, container
  stop catches it.

## Capabilities

### Modified Capabilities

- `git-mirror-service`: adds three "mirror → host working copy" sync
  requirements (triggers: startup, inotify, shutdown) plus the
  never-clobber contract.

## Impact

- **Rust**: `src-tauri/src/mirror_sync.rs` NEW (~300 LOC incl. tests);
  `src-tauri/src/main.rs` + `src-tauri/src/handlers.rs` +
  `src-tauri/src/event_loop.rs` gain small hook points. `notify` added
  to `src-tauri/Cargo.toml` (was a workspace dep, not previously used in
  tray crate).
- **No container / image changes** — host-side only.
- **No config changes** — uses the existing `scanner.watch_paths` list to
  locate the host working copy per project.
- **No new permissions** — reads/writes only under the user's own watch
  paths, and writes are `git fetch` + `git merge --ff-only` (both
  refuse on dirty working tree).
- **Tests**: six unit tests with tempdir fixtures for the core sync
  paths (ff ok, dirty, diverged, detached, absent mirror/host). Watcher
  integration-tested manually via live forge push.
