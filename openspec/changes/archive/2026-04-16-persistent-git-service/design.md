# Design: persistent-git-service

## Lifetime model change

| Service | Before | After |
|---------|--------|-------|
| Proxy | Tray-session (started at infra ready, stopped at app exit) | Tray-session (unchanged) |
| Inference | Tray-session (started async, stopped at app exit) | Tray-session (unchanged) |
| Git-service (per project) | Per-forge-cluster (started on first forge for project, stopped when last forge for project exits) | **Tray-session (per project)** — started on first forge, stopped only at app exit |

## Why this is safe

1. **Mirrors are already persistent on disk** at `~/.cache/tillandsias/mirrors/<project>`. Container restart vs no-restart makes no difference to mirror state.
2. **No mutable in-memory state** in the git-service container that would diverge across long uptimes — it is a stateless `git daemon` + push hooks.
3. **D-Bus session-bus forwarding** (`-v /run/user/$UID/bus:/run/user/1000/bus:ro`) is the only "session" coupling. Inside the tray's lifetime the user's session bus path is stable; we do not span user logouts.
4. **One git-service per project**, container name `tillandsias-git-<project>` is unique. No singleton contention.
5. **Resource cost** is ~10 MB resident per project. A user with 10 projects open would spend ~100 MB on git-service daemons — comparable to one extra browser tab.

## Cleanup semantics

Cleanup must continue to happen at app exit so users don't accumulate orphaned containers across tray restarts:

```
shutdown_all(state) {
    // Stop every container in state.running, including GitService rows
    for c in state.running { launcher.stop(c.name) }

    // Belt-and-suspenders: also explicitly stop_git_service for each
    // GitService project so cleanup of the per-project mirror mount lock
    // happens even if launcher.stop missed something.
    for p in state.running.iter().filter(|c| c.container_type == GitService) {
        stop_git_service(&p.project_name).await
    }
}
```

The `for c in state.running` loop already stops every container by name (including git-services), so the second pass is mostly defensive. We keep it because `stop_git_service` knows how to do the right thing if the container is in a half-state that `launcher.stop` doesn't recognize.

## What stays the same

- `ensure_git_service_running()` is unchanged. It already early-returns when state.running has the row OR podman inspect shows it healthy with the right tag. Now those early-returns will fire much more often.
- The image staleness check inside `ensure_git_service_running` only runs when no early-return fires. With persistence, that path is hit only once per project per tray session (or after a forge image upgrade).
- CLI `tillandsias <project>` mode keeps using `EnclaveCleanupGuard` to stop everything on exit. Removing that would orphan containers across CLI invocations since there's no tray to manage them.

## Out of scope

- Multi-tray-instance coordination (singleton lock already prevents this).
- Garbage-collecting git-services for projects the user removed mid-session. Acceptable — they get cleaned up on app exit, and a removed project means the user is unlikely to reattach immediately.
- Pre-warming git-services for *all* known projects at tray startup. The lazy "first attach starts it" model is fine; we only optimize the *second-and-subsequent* attach.
