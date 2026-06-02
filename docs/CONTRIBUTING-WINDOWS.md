# Contributing to `tillandsias-windows-tray`

A focused dev guide for the **windows-tray crate** + its supporting scripts
+ docs. Assumes you already cloned the repo and have Rust + WSL2
installed; if not, see the [Windows section of the
README](../README.md#windows) for prerequisites.

This document is intentionally short — it points at existing
authoritative resources rather than reproducing their content. The
canonical docs are:

- **`cheatsheets/runtime/windows-tray-diagnostics.md`** — the operator
  + dev runtime reference (`--diagnose` JSON schema, env vars, log
  rotation, Win11 toasts, all 7 CLI modes, common pitfalls).
- **`skills/build-windows-tray/SKILL.md`** — the daily-cron build+install
  runbook (8 steps).
- **`plan/steps/windows-next-thin-tray.md`** — the windows-tray v0.0.1
  step ledger + remaining w-level items.
- **`crates/tillandsias-windows-tray/src/notify_icon.rs`** — the
  implementation. `git log notify_icon.rs` shows the per-feature history.

## Quick dev cycle

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"

# Build + install + verify in one shot (preferred — covers the full
# 2-layer post-install sanity check):
& scripts\install-windows.ps1

# OR: cargo direct (ad-hoc, no install):
cargo build -p tillandsias-windows-tray --release

# Run the full test suite (49 tests across 3 layers):
cargo test -p tillandsias-windows-tray --release

# Lint:
cargo fmt -p tillandsias-windows-tray -- --check
cargo clippy -p tillandsias-windows-tray --release --tests --no-deps -- -D warnings

# Litmus drift-protection (the contract pins):
scripts/run-litmus-test.sh windows-native-tray --phase pre-build --size instant --compact
```

## Test pyramid

Three layers, all run by `cargo test -p tillandsias-windows-tray --release`:

| Layer | Path                                                   | Count | Purpose                                                                 |
|-------|--------------------------------------------------------|-------|-------------------------------------------------------------------------|
| 1     | inline in `src/notify_icon.rs::tests`                  | 41    | Pure functions + schema-pin against `baseline_diagnose_report()` helper |
| 2     | `tests/cli_integration.rs`                              | 5     | End-to-end against the real binary via `CARGO_BIN_EXE_tillandsias-tray` |
| 3     | `tests/portable_smoke.rs`                               | 3     | Shared host-shell crate's pure surface (runs from Linux too)            |

When adding a feature: prefer Layer 1 for unit-level coverage; add a
Layer 2 test if the feature touches the binary's CLI argv parsing or
the JSON output shape; Layer 3 only for cross-host-shared logic.

## Operator-facing surface coverage

Whenever you add a field to `DiagnoseReport` or a new CLI mode, you
**must** update all of these to stay drift-protected:

1. `crates/tillandsias-windows-tray/src/notify_icon.rs` — implementation
   + an inline pin test (extend `diagnose_json_top_level_keys_pinned`
   or add a dedicated `fn`).
2. `cheatsheets/runtime/windows-tray-diagnostics.md` — schema block +
   any quick-reference table updates.
3. `scripts/tray-diagnose.ps1` — surface the field in the human-readable
   health check.
4. `scripts/install-windows.ps1` (if relevant at install-time) —
   surface in the post-install one-liner.
5. `openspec/litmus-tests/litmus-windows-tray-diagnose-cli-surface.yaml`
   — extend the relevant pin step's grep predicate.

Miss any of these and the litmus catches it pre-build. The cost is real
but so is the contract stability.

## Common pitfalls

These are bugs I learned the hard way. See the cheatsheet's "Common
pitfalls" section for the full list; the highlights:

- **GUI-subsystem stdout capture from PowerShell is unreliable**. Use
  `cmd /c "exe --mode > out.txt 2>nul"` for any large stdout.
- **PowerShell 5.1 mojibakes non-BOM Unicode**. Keep `scripts/*.ps1`
  ASCII-only — use `--` instead of em-dash.
- **`cargo build` stderr-wrap**: `$ErrorActionPreference = 'Stop'` +
  `cargo` together trip `NativeCommandError` on stderr writes. The
  build subscript handles this via a local `'Continue'` override
  around the cargo call.
- **`std::fs::rename` on Windows fails if destination exists**. The
  log rotation calls `remove_file` first; do likewise elsewhere.
- **`str::trim` does NOT strip U+FEFF (BOM)**. WSL's UTF-16 output
  needs explicit `trim_start_matches('\u{FEFF}')` before whitespace
  trim. Pinned by `first_line_handles_all_cases`.
- **Cross-tray pins**: `RECIPE_RELEASE_TAG` is byte-identical between
  windows-tray + macos-tray + the litmus YAML. Bumping requires
  updating all three in lockstep (see
  `openspec/litmus-tests/litmus-recipe-release-tag-symmetric.yaml`).

## Scripts vs binary modes

Two layers of CLI surface:

- **Binary** (`tillandsias-tray.exe`): 7 CLI modes (`--provision-once`,
  `--status-once [--json]`, `--diagnose [--json]`,
  `--logs [--tail N] [--bak]`, `--help`, `--version`, GUI). Cross-
  platform-style flags, contract-pinned via the schema + exit-code
  litmus tests.
- **PowerShell scripts** (`scripts/*.ps1`): higher-level operator
  workflows that consume the binary's JSON. The canonical consumers
  are `tray-diagnose.ps1` (live runtime health) +
  `diagnose-windows.ps1` (pre-tray host facts) +
  `install-windows.ps1` (lifecycle: `-Launch`, `-Startup`,
  `-Provision`, `-DebugBuild`, `-Uninstall`, `-Purge`).

Prefer adding a new binary mode (with tests, cheatsheet, litmus) over
a new script — the binary modes are easier to test end-to-end and
provide a stable contract for any consumer.

## CI considerations

The integration loop (linux-next) runs `./build.sh --check` and
`./build.sh --test` on every windows-next merge. These exercise the
Linux-portable surface (`portable_smoke.rs` + the shared host-shell
crate). The Windows-only paths (`#[cfg(target_os = "windows")]`) are
NOT exercised in CI; they're verified on the local windows-bullo host
via the daily `/build-windows-tray` cron + the integration loop's
post-merge smoke.

When you commit, the integration loop's next 2h cycle will pick up
your work and run the Linux-portable layer. The cli_integration suite
(Windows-only) only runs on a Windows host — currently the daily cron
fires it.

## See also

- [README § Windows](../README.md#windows) — user-facing install
  instructions.
- [`cheatsheets/runtime/windows-tray-diagnostics.md`](../cheatsheets/runtime/windows-tray-diagnostics.md)
  — operator + dev reference.
- [`skills/build-windows-tray/SKILL.md`](../skills/build-windows-tray/SKILL.md)
  — daily cron runbook.
- [`plan/issues/tray-convergence-coordination.md`](../plan/issues/tray-convergence-coordination.md)
  — cross-host coordination notes.
- [`plan/steps/windows-next-thin-tray.md`](../plan/steps/windows-next-thin-tray.md)
  — windows-tray v0.0.1 step ledger.
