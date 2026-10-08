# The installer may ask a HARD reset's per-run question for a reset that cannot

@trace order:1559-sqzp, order:1437-3iux, spec:host-state-lifecycle

## Why

`host-state-lifecycle` (amended 1443-bs9z) requires a HARD reset to ask, on a
TTY, `HARD reset destroys the guest, its Vault store and every sign-in. Type
HARD to continue:` and says the prompt "is shown by the reset itself". The
Windows tray is a GUI-subsystem binary with no console: `AttachConsole` was
tried and reverted (`crates/tillandsias-windows-tray/src/main.rs`), so on
Windows the reset cannot show the prompt. Requiring
`TILLANDSIAS_HARD_RESET_APPROVED=1` at a console instead would turn a per-run
approval into a standing one, which is strictly worse than the ruling asks.

Coordinator ruling, 2026-10-08, on PR #247 (1559-sqzp): the installer shows
the reset's exact prompt and forwards a typed `HARD` as `--approve-hard-reset`
to that one invocation; it never sets `TILLANDSIAS_HARD_RESET_APPROVED`. The
spec's intent, a human at a console typing HARD for THIS invocation, is met.
This change makes that interpretation explicit so the spec and the code agree.

## What Changes

- **ADDED** to `host-state-lifecycle`: the HARD prompt may be shown by the
  reset, or by the installer that invokes it with `--approve-hard-reset`
  scoped to that invocation; the installer never sets the approval variable
  and never carries an answer past that invocation.

No other requirement changes. The SOFT/HARD semantics, the approval variable,
the refusal strings and the forge strip are unchanged. Independent of the
pending `hot-upgrade-live-stack` change, which modifies the SOFT tier only.

## Impact

- Code: `scripts/install-windows.ps1` (the `BEGIN-RESET-KIND` block), already on
  this PR; fixture `scripts/test-installer-reset-kind.sh`, gate step
  `770-1559-sqzp`.
- No change to the tray, core, or any other platform.
