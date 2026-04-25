# tasks

## 1. Responsiveness audit + fix

- [ ] Grep `src-tauri/src/event_loop.rs` + `src-tauri/src/handlers.rs`
  helpers it directly calls for `std::process::Command::output()` / `.wait()`
  / `.status()`. Every hit must move to `tokio::spawn` + `tokio::process`.
- [ ] Add `biased;` to the main `tokio::select!` in `event_loop::run`
  so `menu_rx` is always polled first.
- [ ] Introduce a `tokio::sync::CancellationToken` per long-running task
  (overlay build, forge image build, proxy health probe, git service
  probe, remote-repos fetch, MCP health). Store in `TrayState` for the
  duration of the task; abort on Quit.
- [ ] Wrap every `tokio::process::Command::output()` in
  `tokio::time::timeout(Duration::from_secs(N), ...)` with a reasonable N
  per call (5s probes, 30s image builds, 60s overlay build).

## 2. Stale-container startup sweep

- [ ] New function `handlers::pre_ui_cleanup_stale_containers()`.
  Lists `podman ps -a --filter name=tillandsias-` and `rm -f`s every
  container whose `.State.StartedAt` is older than this tray's PID
  start time. Force-removes the enclave network too.
- [ ] Call it from `main.rs` setup, spawned off the event loop, with
  its completion signal driving the "Forge build stage" unlock in the
  menu.
- [ ] Log as accountability event: count of removed containers +
  network removal outcome.

## 3. UI gating state machine

- [ ] `TrayState::ready_stage: Stage` with variants:
  `Exit`, `ForgeImageBuilding`, `AwaitingAuth`, `Authenticated`.
  Default: `Exit`. Advances only on infrastructure-ready + auth-ok
  events received from spawned tasks.
- [ ] `menu::build_tray_menu` renders every item always; gates the
  `enabled` flag off `ready_stage` + per-capability readiness.
- [ ] Tooltips describing what each disabled item is waiting for.

## 4. GitHub credential-health classifier

- [ ] New module `src-tauri/src/github_health.rs`:
  - Enum `CredentialHealth { Authenticated, CredentialMissing, CredentialInvalid, GithubUnreachable { reason } }`
  - `async fn probe() -> CredentialHealth` that composes keyring read +
    `gh auth status` + optional `GET api.github.com/user`.
  - `tokio::time::timeout(10s, probe)` wrapper.
  - Classification matrix per spec.
- [ ] Wire into `TrayState::credential_health: CredentialHealth` with
  a single authoritative value, updated only on user-initiated
  sign-in/sign-out/refresh.
- [ ] Menu integration: when `Authenticated`, project lists enabled;
  when `Missing`/`Invalid`, only "Sign in to GitHub" offered; when
  `GithubUnreachable`, lists enabled with "offline" banner served
  from cached repo list.

## 5. Tests

- [ ] Responsiveness canary: spawn a 30s fake-blocking task, dispatch
  `MenuCommand::Quit`, assert the loop's Quit arm runs within 5s and
  the fake task is aborted.
- [ ] Credential classifier unit tests covering each matrix cell.
- [ ] Stale-cleanup test: create a throwaway container named
  `tillandsias-test-stale`, start the cleanup routine, assert it's
  removed.
- [ ] Existing mirror-sync + browser tests stay green.

## 6. OpenSpec + cheatsheets

- [x] Proposal + deltas in
  `openspec/changes/tray-responsiveness-and-startup-gating/`.
- [ ] Validates strict.
- [ ] New cheatsheet
  `docs/cheatsheets/github-credential-health-states.md` with the
  classification matrix and the "GitHub down vs credentials bad"
  decision table.

## 7. Build + smoke test

- [ ] `./build.sh --check` clean.
- [ ] `./build.sh --test` all green incl. new tests.
- [ ] `./build.sh --release --install` rebuild.
- [ ] Smoke test: kill `gh auth` (remove token from keyring), relaunch
  tray — project lists disabled, Quit works. Sign in → lists unlock.
- [ ] Smoke test: start tray with network off — `GithubUnreachable`
  classification; project lists enabled from cache; Quit works.
- [ ] Smoke test: while a long forge image build is in flight, click
  Quit — exits within 5s.

## 8. Spec convergence + archive

- [ ] `/opsx:verify tray-responsiveness-and-startup-gating`.
- [ ] `/opsx:archive tray-responsiveness-and-startup-gating`.
- [ ] Bump version, commit, push, release.
