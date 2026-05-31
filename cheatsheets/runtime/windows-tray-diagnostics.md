---
tags: [windows, tray, diagnostics, json, support, wsl2]
languages: [rust, powershell]
since: 2026-05-28
last_verified: 2026-05-30
sources:
  - internal
authority: internal
status: current
tier: bundled
---

# Windows tray diagnostics

@trace spec:windows-native-tray

**Version baseline**: `tillandsias-tray` v0.1.0+ on the windows-next platform branch.
**Use when**: an installed Tillandsias tray on a Windows host is misbehaving and you need to figure out which leg (host, distro, control wire, headless) is degraded — or you need a machine-readable health report to feed a support tool.

## Provenance

- `crates/tillandsias-windows-tray/src/notify_icon.rs` — the four diagnostic entry points are defined here.
- `scripts/tray-diagnose.ps1` — the canonical PowerShell consumer of `--diagnose --json`.
- `scripts/diagnose-windows.ps1` — distinct pre-tray host-facts diagnostic (no `--diagnose` involvement).
- **Last updated:** 2026-05-28 (commits `20fb9d1f` `c4908438` `e96d1fc8`).

## Quick reference

A single binary, four diagnostic modes. Each is non-GUI, exits with a code suitable for scripting.

| Mode                       | What it does                                                                                | Exit codes              |
|----------------------------|---------------------------------------------------------------------------------------------|-------------------------|
| `--provision-once`         | Run `provision_via_recipe` to completion: fetch + verify + import + boot + handshake.       | `0` Ready / `1` failed  |
| `--status-once`            | Connect to the live control wire, request `VmStatus`, print phase / `podman_ready` / `last_event`. | `0` Ready / `2` reachable-not-Ready / `1` unreachable |
| `--status-once --json`     | Same status as a structured JSON object on stdout (StatusReport, see below).                | (same as `--status-once`) |
| `--diagnose`               | Bundled human-readable health report (8 sections — see below).                              | `0` healthy / `2` degraded / `1` hard fail |
| `--diagnose --json`        | Same report as a structured JSON object on stdout.                                          | (same as `--diagnose`)  |
| `--logs [--tail N]`        | Dump the tray log file (`%LOCALAPPDATA%\tillandsias\logs\tray.log`) to stdout; `--tail N` for last N lines. | `0` readable / `1` missing |
| `--help` / `-h`            | Print full usage with all CLI modes + exit-code contracts + stdio note + ENVIRONMENT vars.  | `0`                     |
| `--version` / `-V`         | Print `tillandsias-tray <workspace VERSION> (<build_commit>)` on one line.                  | `0`                     |

GUI mode also accepts `--no-provision` to skip WSL bootstrap (clean local-dev menu without provisioning). Equivalent: set `TILLANDSIAS_NO_PROVISION` env var.

### Environment variables

| Variable                       | Purpose                                                                          |
|--------------------------------|----------------------------------------------------------------------------------|
| `RUST_LOG`                     | Log filter for the tray's file logger. Default `info`. e.g. `debug,tillandsias_windows_tray=trace`. |
| `TILLANDSIAS_NO_PROVISION`     | Set to any value to skip WSL bootstrap (alias for `--no-provision`).            |
| `BUILD_COMMIT_SHA_OVERRIDE`    | Overrides build.rs's `git rev-parse` during builds (CI / reproducible-source). Bakes at compile time, not runtime. |

GUI mode (no flags) launches the tray itself.

## Common patterns

### Run from the shell, eyeball the output

```powershell
& "$env:LOCALAPPDATA\Programs\Tillandsias\tillandsias-tray.exe" --diagnose
```

### Tooling consumer (the canonical pattern)

```powershell
scripts\tray-diagnose.ps1
# auto-discovers the exe in install path / PATH / target/{release,debug}
```

The script invokes `--diagnose --json`, parses with `ConvertFrom-Json`, prints colorized PASS/FAIL per check, and exits 0 / 2 / 1 mirroring the tray.

### Parse the JSON yourself

```powershell
$report = & tillandsias-tray.exe --diagnose --json | ConvertFrom-Json
if ($report.wire.reachable -and $report.wire.phase -eq 'Ready' -and $report.wire.podman_ready) {
    Write-Host "VM is healthy: $($report.wire.last_event)" -ForegroundColor Green
}
```

### Reach into a paused VM cheaply

```powershell
# Wake the utility VM briefly so --status-once / --diagnose can connect.
Start-Process wsl.exe -ArgumentList "-d","tillandsias","--exec","sleep","45" -WindowStyle Hidden
& tillandsias-tray.exe --status-once
```

## `--diagnose --json` schema (pinned)

The JSON shape is pinned by unit tests in `notify_icon::tests::diagnose_json_*` and `exit_code_provisioned_zero_degraded_two`. Renaming a field breaks the build, not silently the support tooling.

```jsonc
{
  "version":                "0.2.260528.1", // string — workspace VERSION baked at build (was CARGO_PKG_VERSION pre-2026-05-30; see build.rs)
  "build_commit":           "a963c16d",     // string — short git SHA the binary was built from, or "unknown" if git unavailable
  "log_path":               "C:\\...\\tray.log", // string  — fixed %LOCALAPPDATA%\tillandsias\logs\tray.log
  "log_exists":             true,          // bool
  "wt_present":             true,          // bool    — Windows Terminal on PATH (Open Shell prefers it)
  "distro":                 "tillandsias", // string  — wsl.exe -d <distro> target
  "distro_registered":      true,          // bool    — `wsl -l -q` listed `distro`
  "release_tag":            "v0.2.260526.1", // string  — embedded RECIPE_RELEASE_TAG
  "manifest_pin_x86_64_tar": "a28cabe7c9df", // string | null — first 12 hex of the x86_64.tar SHA-256 pin
  "wire": {
    "reachable":   true,                   // bool    — open + handshake succeeded
    "phase":       "Ready",                // string | null — Debug-formatted VmPhase
    "podman_ready": true,                  // bool   | null
    "last_event":  "tillandsias-in-vm",    // string | null — free-form headless event
    "error":       null                    // string | null — failure cause when reachable=false
  },
  "recent_log_tail": [                     // array of string — last 20 lines of tray.log
    "2026-05-28T... INFO ..."
  ]
}
```

### `--status-once --json` schema

A leaner JSON for the live-wire check — same fields the human mode prints,
plus a pre-computed `exit_code` so consumers don't re-derive the matrix
from phase + reachable. All seven keys are always present (None on the
unreachable path becomes JSON `null`).

```jsonc
{
  "reachable":    true,                    // bool   — handshake succeeded
  "wire_version": 1,                       // u16    | null — negotiated WIRE_VERSION
  "phase":        "Ready",                 // string | null — Debug-formatted VmPhase
  "podman_ready": true,                    // bool   | null
  "last_event":   "tillandsias-in-vm",     // string | null
  "error":        null,                    // string | null — failure cause on the not-OK path
  "exit_code":    0                        // i32    — 0/2/1 per the table above
}
```

## Common pitfalls

- **Stale installed binary**: `scripts/tray-diagnose.ps1`'s search order finds `%LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe` first. If that's older than your repo build (e.g. an old install missing `--json`), pass `-ExePath target\debug\tillandsias-tray.exe` or re-install via `scripts\install-windows.ps1`.
- **Idle WSL utility VM**: WSL2 powers the VM down when no host-side `wsl` session holds it open. `--status-once` and `--diagnose` will report "unreachable" until you wake it (`wsl -d tillandsias --exec true` or the tray itself running with its keepalive). The error string in `wire.error` will start with `hvsocket open: …` in that case.
- **"🔴 Wire unreachable" in the live chip**: the 30s `refresh_vm_status` poll updates the chip to a red wire-unreachable indicator (and clears `podman_ready` so per-project actions re-gate off) whenever the handshake or `VmStatusRequest` fails. Without this, a mid-session wire failure (headless crash, VM terminated externally, etc.) would leave the chip showing the last-known "Ready" state forever. The next successful poll restores the phase chip naturally.
- **AF_HYPERV, not AF_VSOCK**: the host reaches the in-VM Linux AF_VSOCK listener through Hyper-V sockets (`(VmId, ServiceId)` GUIDs). Resolved via `hcsdiag list`. See `crates/tillandsias-windows-tray/src/hvsocket.rs`.
- **`.ps1` ASCII-only**: PowerShell 5.1 mis-renders non-BOM Unicode in scripts on the default ANSI code page. Keep `scripts/*.ps1` ASCII-only — use `--` instead of em-dash. Caught + enforced in commit `5d310bf4`.
- **`cargo build` and PowerShell stderr-wrapping**: `cargo` writes "Compiling" / "Finished" to stderr; when a PowerShell tool consumer redirects with `2>&1` and `$ErrorActionPreference = 'Stop'`, those lines can trigger `NativeCommandError` even on success. Inspect `$LASTEXITCODE`, not the PowerShell exception.
- **GUI-subsystem stdout capture from PowerShell is unreliable**: the release tray is a GUI-subsystem binary, and PowerShell's direct stdout capture (`$x = & exe`, `& exe > $tmp`) silently drops large writes from `println!` (small per-line writes from `--diagnose` human mode usually work; the big single `--diagnose --json` write often doesn't). The robust pattern is `cmd.exe`'s redirect: `& cmd /c "exe --diagnose --json > out.json 2>nul"`. cmd handles native stdio directly. `AttachConsole(ATTACH_PARENT_PROCESS)` is NOT a fix — it attaches the binary to the visible parent console, *bypassing* PowerShell's pipe entirely, so scripted captures see nothing. `scripts/tray-diagnose.ps1` and `scripts/install-windows.ps1`'s post-install sanity check both use the cmd-redirect pattern.
- **Exit code 2 ≠ failure**: `--diagnose` exits 2 when the report ran end-to-end but at least one check failed (e.g. distro not registered yet). Don't `set -e` around it — use the exit code as a tri-state.
- **JSON schema change is a tooling break**: bumping a key in `DiagnoseReport` fails `diagnose_json_top_level_keys_pinned`. If you genuinely intend the change, update `tests::baseline_diagnose_report` AND the consumer script in the same commit, and bump the cheatsheet "Last updated" line above.

## See also

- `runtime/agent-startup-skills.md`
- `windows-installer-prereqs.md`
- `windows-native-dev-build.md`
- `runtime/socket-enclave-diagnostics.md`
