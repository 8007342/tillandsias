## ADDED Requirements

### Requirement: A HARD reset's per-run question may be asked by the installer that invokes it

The HARD prompt SHALL be shown by the reset, or by the installer that invokes
it with `--approve-hard-reset` scoped to that invocation. An installer that asks
SHALL show the reset's exact prompt, SHALL forward only the exact typed word
`HARD`, SHALL pass the approval as `--approve-hard-reset` on that one
invocation, SHALL NOT set `TILLANDSIAS_HARD_RESET_APPROVED`, and SHALL NOT
carry the answer to any later invocation. This exists for a reset that cannot
show a prompt itself: the Windows tray is a GUI-subsystem binary with no
console (coordinator ruling 2026-10-08, order 1559-sqzp).

@trace spec:host-state-lifecycle, order:1559-sqzp, order:1437-3iux

#### Scenario: The Windows installer asks the HARD question at a console
- **WHEN** `scripts/install-windows.ps1` runs with `TILLANDSIAS_INSTALL_RESET=hard`
  or `-HardReset` at an interactive console, and the operator types `HARD`
- **THEN** it SHALL run the tray with `--reset-guest --approve-hard-reset` for
  that invocation only, with stdin from NUL
- **AND** it SHALL NOT assign `TILLANDSIAS_HARD_RESET_APPROVED` anywhere
- **AND** any other answer, or no console and no variable, SHALL refuse with
  `reset: HARD requires per-run approval (TILLANDSIAS_HARD_RESET_APPROVED=1 or --approve-hard-reset)`
  and exit 1 before anything is downloaded or destroyed.
- Pre-fix result: FAILS — the installer offered no reset kind and ran
  `--reset-state`, which was HARD on Windows, with no approval of any kind.
