## 1. Extend kill_container with explicit signal

- [x] 1.1 In `crates/tillandsias-podman/src/client.rs:251`, change `kill_container` signature to `pub async fn kill_container(&self, name: &str, signal: Option<&str>) -> Result<(), PodmanError>`. When `signal` is `Some(s)`, prepend `["--signal", s]` to the args. When `None`, preserve today's exact behavior (no `--signal` flag → podman default = SIGTERM).
- [x] 1.2 Update the single existing caller in `crates/tillandsias-podman/src/launch.rs:151` (`self.client.kill_container(container_name).await`) to pass `None` as the new signal argument so default-SIGTERM behavior is preserved for the timeout-fallback path.
- [x] 1.3 `cargo check --workspace` — confirm no other callers exist.

## 2. New helpers in handlers.rs

- [x] 2.1 Add `pub(crate) async fn list_running_tillandsias_containers() -> Vec<String>` near the existing infra helpers (around `handlers.rs:1000`). Implementation: shell out to `podman ps --filter name=tillandsias- --format {{.Names}}`, split lines, strip whitespace, filter empty. Errors return an empty vec (defensive — verification continues with what it can see).
- [x] 2.2 Add `pub(crate) async fn kill_and_remove(name: &str)`. Calls `client.kill_container(name, Some("KILL"))`, sleeps 500 ms, then `client.remove_container(name)`. Logs `accountability = true, category = "enclave", spec = "app-lifecycle, podman-orchestration"` on entry naming the container.
- [x] 2.3 Add `#[cfg(unix)] pub(crate) fn pkill_orphan_conmon()`. Implementation: spawn `pkill -TERM -f 'conmon.*--name tillandsias-'`, ignore exit code (1 = no matches is fine). Log `accountability = true, category = "enclave"` whether or not anything matched.
- [x] 2.4 Add `#[cfg(not(unix))] pub(crate) fn pkill_orphan_conmon()` as a no-op stub.

## 3. verify_shutdown_clean step

- [x] 3.1 Add `pub(crate) async fn verify_shutdown_clean()` in `handlers.rs`. Body:
  - Loop with 200 ms tokio sleep, 5-second total budget. On each tick call `list_running_tillandsias_containers()`. If empty, log `accountability = true, category = "enclave", spec = "app-lifecycle", "verify_shutdown_clean: zero stragglers"` and return.
  - When the budget elapses with non-empty stragglers: for each name, await `kill_and_remove(&name)`. Re-check after the SIGKILL pass.
  - If still non-empty: call `pkill_orphan_conmon()`. Wait 500 ms. Re-check.
  - If STILL non-empty: emit one `error!(accountability = true, category = "enclave", spec = "app-lifecycle", reason = "survived_all_escalation", container = %name)` per remaining straggler and return without blocking further.
- [x] 3.2 Add `verify_shutdown_clean().await;` as the last line of `shutdown_all` in `handlers.rs:3916` (after the existing orphan-sweep block at lines 4023–4045, before the function returns).

## 4. Tests

- [x] 4.1 In `crates/tillandsias-podman/src/client.rs` `tests` module (or wherever existing `kill_container`-adjacent tests live), add `kill_container_default_signal_omits_flag` asserting that calling with `None` produces a `podman` arg vec equal to `["kill", "<name>"]` (no `--signal`).
- [x] 4.2 Add `kill_container_explicit_kill_signal_includes_flag` asserting `Some("KILL")` produces `["kill", "--signal", "KILL", "<name>"]`. If the existing client tests are integration-style (need real podman), add the new tests at the arg-building layer instead — extract `build_kill_args(name, signal) -> Vec<String>` and unit-test it.
- [x] 4.3 If `verify_shutdown_clean` ends up factorable into a pure scheduling helper (e.g., `next_action(stragglers, last_step) -> EscalationStep`), unit-test the escalation-state machine independently of podman. If it stays I/O-coupled, gate the integration with `#[ignore]` and document how to run manually.
- [x] 4.4 `cargo test --workspace --lib` and `cargo test -p tillandsias --bin tillandsias` — both green.

## 5. Manual verification

- [x] 5.1 `./build.sh --check` and `./build.sh` (debug). Launch tray, attach to one project, then `Quit`. Confirm `podman ps --filter name=tillandsias-` returns empty before the tray process exits (look in tray log for `verify_shutdown_clean: zero stragglers`).
- [x] 5.2 Reproduce the failure mode: launch tray, attach, then `kill -STOP` the forge container's PID 1 with `podman exec`-spawned `kill`, click Quit. Confirm escalation logs fire (`category = "enclave"` SIGKILL escalation log, possibly conmon-pkill log) and the container is gone after `shutdown_all` returns.
- [x] 5.3 Confirm graceful shutdown is unchanged in the happy path — total time from `Quit` click to process exit is roughly the same as before (verification phase exits on first tick when nothing strays).

## 6. Trace + cheatsheet

- [x] 6.1 Confirm every new function carries `// @trace spec:app-lifecycle` (and `spec:podman-orchestration` where relevant) near the function definition.
- [x] 6.2 Add a short note at the bottom of `docs/cheatsheets/tray-state-machine.md` (or new cheatsheet `docs/cheatsheets/shutdown-escalation.md` — author's choice) documenting the three escalation tiers (graceful → SIGKILL → conmon-pkill) and how to interpret the accountability logs after a Quit.

## 7. Version

- [x] 7.1 No version bump now — bump happens at archive time per CLAUDE.md.
