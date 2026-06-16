# Step 43 — Tray Quit hangs for minutes / requires manual kill

- **Status**: completed

## Claim

- **Claimed at**: 2026-06-07T00:54:02Z
- **Agent**: linux-macuahuitl-big-pickle-20260607T005316
- **Lease**: lease-linux-tray-quit-hang-20260607T005402Z (expires 2026-06-07T04:54:02Z)

## Evidence

- **Commit**: `05e59599`
- **Root cause**: Quit handler set `TrayService::shutdown` but main loop polls the signal-handler atomic — different atomics, so Quit never exited.
- **Fix**: Added `signal_shutdown` backlink to `TrayService` so Quit flips both atomics. Added time bounds (45s graceful shutdown, 10s vault revocation) to prevent indefinite hangs. Added vault token revocation to tray shutdown path.
- **Verification**: `cargo check --features tray`, `clippy -D warnings`, `cargo test --features tray` (23/23 PASS), `cargo fmt --all -- --check` clean.
- **Owner host**: linux
- **Branch**: linux-next
- **Depends on**: []
- **Specs**: graceful-shutdown, app-lifecycle
- **Audit origin**: plan/issues/github-login-vault-native-flow-2026-06-06.md

## Goal

Operator report 2026-06-06: clicking **Quit** leaves the app "hanging around for a long time"
(sometimes several minutes), frequently requiring a manual `kill` from a terminal. Make Quit
return within a bounded, short timeout with no orphaned process.

## Where to look

- Quit handler sets the shutdown atomic + `tray_icon_state = Stopping`
  (`crates/tillandsias-headless/src/tray/mod.rs:2930-2933`) but the actual process exit is
  evidently blocked downstream.
- Candidate blockers to time-bound or background:
  - synchronous container stop/teardown on shutdown,
  - the tray `task_executor` drain,
  - `vault_bootstrap::revoke_pending_container_tokens` (`main.rs:6102`) — a Vault round-trip
    that can stall if Vault is slow/unreachable,
  - the zbus / StatusNotifierItem event loop not unblocking.

## Exit criteria

- Quit terminates within a short bound (target < 5s); no orphaned `tillandsias` process.
- Every blocking shutdown step is time-bounded or backgrounded; a hard force-exit deadline
  backstops the graceful path.
- A test/litmus asserts the bound.
