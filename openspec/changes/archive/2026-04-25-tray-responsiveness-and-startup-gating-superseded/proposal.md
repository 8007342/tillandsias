## Why

Live issue report (2026-04-24, v0.1.160.212): after a cold launch, the tray
became fully unresponsive. Root cause: a `build-tools-overlay.sh` subprocess
spawned a podman container to compile the forge tools overlay, and the
entire event loop waited on its completion. Symptoms:

- Tray icon clickable but menu showed no projects.
- Quit did nothing — the click queued a `MenuCommand::Quit` that couldn't
  be dequeued because the event loop was blocked on the overlay build.
- Ctrl-C on the launcher terminal did nothing — the Tauri main loop was
  blocked in an await on a sync child process.
- Only SIGKILL from outside the tray could recover.

Two failure modes nested here:

1. **Blocking work ran on the event-loop thread.** Any long IO (overlay
   build, git-service readiness probe, forge image build, remote-repos
   fetch) should execute on a task that yields, so the UI remains
   responsive and `MenuCommand::Quit` is always deliverable.
2. **The UI painted controls for work that wasn't actually available yet.**
   The user clicked "Attach Here" on a project before the pre-reqs
   (overlay, forge image, enclave network, GitHub auth) were ready,
   queuing more blocking work behind the one already stuck — making the
   cascade worse.

Additionally, we discovered a missed class of failure: **a
not-authenticated GitHub session is currently treated identically to
"GitHub is down"**. The correct response differs:

- **GitHub is down** (network partition, GitHub outage) — proceed. The
  mirror is the source of truth; new commits queue for later retry-push.
  The user can keep coding.
- **GitHub credentials are missing / expired / revoked** — do NOT start
  the tray at all. A coding agent that can't push is a trap: the user
  writes work that the mirror will never be able to sync, and only
  discovers this when the mirror's retry-pushes accumulate days of
  failures.

The user's call: refuse to launch when credentials aren't live, but treat
"GitHub unreachable" as a recoverable condition the mirror handles.

## What Changes

### Responsiveness

- **The event loop thread never blocks on IO.** Every long-running
  subprocess (overlay build, forge image build, proxy health probe, git
  service probe, remote-repos fetch, MCP script health probe, etc.)
  runs on `tokio::spawn` with its own cancel token, posting progress
  back via `mpsc`. The main event loop's `tokio::select!` multiplexes
  these completions with the `menu_rx` channel so Quit / Language /
  every other user action is serviced immediately.
- **`MenuCommand::Quit` is processed before any other menu command.**
  Event loop's `select!` branches handle `menu_rx` with priority
  (`biased;`). Any in-flight long-running spawn is aborted via its
  cancel token when Quit fires. `shutdown_all` can still complete in
  bounded time.
- **No subprocess runs attached to the tray PID for more than a few
  seconds.** All spawn calls time-box or background — if a podman
  command doesn't return in N seconds, abort + log; don't wedge the
  loop.
- **Stale containers are terminated on startup.** Before any user
  interaction is possible, `cleanup_stale_containers()` runs first
  (bounded, logged, non-blocking UI). Any `tillandsias-*` container
  older than the current tray PID is force-removed along with the
  enclave network. This prevents the scenario where a crashed previous
  tray left a half-built overlay-builder container alive and the new
  tray inherits it as a "running workload".

### UI gating — natural-progression disabled states

The tray menu SHALL surface which subsystems are ready at any moment,
and SHALL only enable controls whose prerequisites are satisfied. The
progression order (each step enables the next):

1. **Quit + Language selector** — always enabled, regardless of any
   subsystem state. First-class invariant: the user can always bail.
2. **Forge image build progress** — enabled while building, with a
   visible progress indicator. Quit still works.
3. **GitHub login / re-auth** — enabled only after the forge image is
   ready AND the keyring is reachable.
4. **Remote projects + local projects + Attach Here** — enabled only
   after a live GitHub token is proven (`gh auth status` returns 0
   inside a probe container, or keyring + scope match is verified).

Disabled items render with the same label but a dimmed / tooltip
explaining what's waiting. No menu item is silently absent — presence
tells the user the feature exists.

### GitHub credential gating (new)

- **Tray refuses to reach the "ready" state without live GitHub
  credentials.** If `keyring::get("github_token")` returns empty OR
  `gh auth status` fails with an auth error, the tray surfaces the
  "Sign in to GitHub" flow as the only actionable menu item (plus
  Quit + Language). Remote and local project lists stay disabled.
- **"GitHub unreachable" is NOT a credential failure.** The tray
  distinguishes:
  - `network error` / `DNS failure` / `connect timeout` / `5xx` →
    transient, mirror-backed. Tray proceeds; remote-repo list shows
    a "GitHub unavailable, using cached list" banner; new commits
    queue for the mirror's post-receive/startup-retry-push chain.
  - `401 / 403 / scope mismatch / token empty` → credential
    problem. Tray disables project actions and prompts to re-auth.
- The distinguishing probe is a single `HEAD
  https://api.github.com/user` via the `gh` CLI (or direct reqwest),
  classifying the result.
- A separate spec capability `github-credential-health` documents this
  contract.

## Capabilities

### Modified Capabilities

- `tray-app`: adds the responsiveness invariant (event loop never blocks,
  Quit is first-priority) and the natural-progression UI gating.

### New Capabilities

- `github-credential-health`: the probe that distinguishes "down" from
  "unauthenticated", its triggering, caching, and UI gating effect.

## Impact

- **Rust**: `src-tauri/src/event_loop.rs` adopts `biased;` in the
  `tokio::select!` to prioritise `menu_rx`. `handlers::ensure_*` helpers
  grow a cancel-token argument. `main.rs` startup runs
  `cleanup_stale_containers` before the event loop accepts user input.
  New `src-tauri/src/github_health.rs` owns the credential probe + cache.
  `TrayState` gains a `ready_stage: Stage { Exit, Forge, Auth, Projects }`
  discriminator the menu renders from.
- **No container / image changes.** All resilience work is tray-side.
- **No new deps.** We already have tokio + reqwest + keyring.
- **Tests**: new unit tests for the responsiveness path (a canary
  `MenuCommand::Quit` dispatched while a fake long IO is in-flight
  resolves within N ms) and the credential-health classifier
  (status-code + network-error matrix).
