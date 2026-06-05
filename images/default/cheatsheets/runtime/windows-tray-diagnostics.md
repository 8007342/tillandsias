---
tags: [windows, tray, diagnostics, json, support, wsl2]
languages: [rust, powershell]
since: 2026-05-28
last_verified: 2026-05-31
sources:
  - internal
authority: internal
status: current
tier: bundled
---

# Windows tray diagnostics

@trace spec:windows-native-tray

**Version baseline**: `tillandsias-tray` 0.2.260530.1+ (workspace VERSION;
on releases `v0.2.260530.1` and later). Reported by `--version`,
`--diagnose --json` `version` field, tray menu footer, and Win11 toast
on Ready transition — all routed through the same `WORKSPACE_VERSION`
env var `build.rs` bakes from the repo-root `VERSION` file.
**Use when**: an installed Tillandsias tray on a Windows host is misbehaving and you need to figure out which leg (host, distro, control wire, headless) is degraded — or you need a machine-readable health report to feed a support tool.

## Provenance

- `crates/tillandsias-windows-tray/src/notify_icon.rs` — every CLI mode + the
  Win32 GUI entry points are defined here. `git log notify_icon.rs` shows the
  per-feature history; the schema-pin unit tests (`diagnose_json_top_level_keys_pinned`,
  `status_once_json_keys_pinned`, `help_text_documents_all_cli_modes`,
  `first_line_handles_all_cases`, `should_rotate_log_at_threshold_boundary`,
  `compose_tooltip_includes_version_and_status`, `select_log_tail_handles_all_cases`)
  pin the operator-facing contracts.
- `scripts/tray-diagnose.ps1` — the canonical PowerShell consumer of
  `--diagnose --json`. Surfaces version + build_commit + install_path +
  recent log activity.
- `scripts/diagnose-windows.ps1` — distinct pre-tray host-facts diagnostic
  (no `--diagnose` involvement). Reports WSL2 / distro / cache layout /
  installed-tray identity via `--version`.
- `scripts/install-windows.ps1` — installer with `-Launch`, `-Startup`,
  `-Provision`, `-DebugBuild`, `-Uninstall`, `-Purge`. Two-layer
  post-install verification (`--version` preflight + `--diagnose --json`).

## Quick reference

A single binary, **seven CLI modes** (six diagnostic + GUI) + four
operator-facing env vars. Every mode is non-GUI, exits with a code
suitable for scripting.

| Mode                       | What it does                                                                                | Exit codes              |
|----------------------------|---------------------------------------------------------------------------------------------|-------------------------|
| `--provision-once`         | Run `provision_via_recipe` to completion: fetch + verify + import + boot + handshake.       | `0` Ready / `1` failed  |
| `--status-once`            | Connect to the live control wire, request `VmStatus`, print phase / `podman_ready` / `last_event` + a `Status: READY/REACHABLE-NOT-READY/UNREACHABLE (exit N)` self-summarizing footer. | `0` Ready / `2` reachable-not-Ready / `1` unreachable |
| `--status-once --json`     | Same status as a structured JSON object on stdout (StatusReport, see below).                | (same as `--status-once`) |
| `--diagnose`               | Bundled human-readable health report (~13 rows in 5 grouped sections: binary identity, logs, host software, WSL distro + rootfs, control wire — followed by recent log tail and a `Status: HEALTHY/DEGRADED (exit N)` self-summarizing footer). | `0` healthy / `2` degraded / `1` hard fail |
| `--diagnose --json`        | Same report as a structured JSON object on stdout (17 top-level keys, see schema below).    | (same as `--diagnose`)  |
| `--logs [--tail N] [--bak]` | Dump the tray log to stdout; `--tail N` for last N lines, `--bak` for the rotation backup `tray.log.bak`. | `0` readable / `1` missing |
| `--help` / `-h`            | Print full usage with all CLI modes + exit-code contracts + stdio note + ENVIRONMENT vars.  | `0`                     |
| `--version` / `-V`         | Print `tillandsias-tray <workspace VERSION> (<build_commit>)` on one line.                  | `0`                     |

GUI mode also accepts `--no-provision` to skip WSL bootstrap (clean local-dev menu without provisioning). Equivalent: set `TILLANDSIAS_NO_PROVISION` env var.

### Environment variables

| Variable                       | Purpose                                                                          |
|--------------------------------|----------------------------------------------------------------------------------|
| `RUST_LOG`                     | Log filter for the tray's file logger. Default `info`. e.g. `debug,tillandsias_windows_tray=trace`. |
| `TILLANDSIAS_NO_PROVISION`     | Set to any value to skip WSL bootstrap (alias for `--no-provision`).            |
| `BUILD_COMMIT_SHA_OVERRIDE`    | Overrides build.rs's `git rev-parse` during builds (CI / reproducible-source). Bakes at compile time, not runtime. |

### Log file rotation

`tray.log` is bounded at **5 MiB**: at tray startup, if the existing file
exceeds that size, it's renamed to `tray.log.bak` (overwriting any prior
backup) and a fresh `tray.log` starts. Disk-usage upper bound: ~10 MiB
per log directory (live + one historical backup). The default `--logs`
reads the live file; pass `--logs --bak` to read the rotation backup
(combine with `--tail N` to limit lines).

### Tray toast notifications

In GUI mode, the tray fires Win11 Action Center toasts on **four**
state-transition events. All are edge-triggered (no spam on
steady-state polls) and all reach the user without requiring tray
interaction.

| Event                          | Title                                              | Severity |
|--------------------------------|----------------------------------------------------|----------|
| Provisioning success           | `Tillandsias <workspace VERSION> — ready`          | Info     |
| Provisioning failure           | `Tillandsias — provisioning failed`                | Error    |
| Wire degraded (mid-session)    | `Tillandsias — wire degraded`                      | Warning  |
| Wire recovered from degradation | `Tillandsias — wire recovered`                    | Info     |

The wire-degraded → wire-recovered pair is edge-triggered via
`WIRE_DEGRADED_NOTIFIED` atomic flag: at most 1 degraded-toast + 1
recovered-toast per degradation episode, not 1 toast per 30s poll
while the wire stays down.

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
  "install_path":           "C:\\...\\tillandsias-tray.exe", // string — std::env::current_exe(), or "(unknown)" on rare failure
  "exit_code":              2,             // i32    — pre-computed `--diagnose` exit (0 healthy / 2 degraded); mirrors StatusReport.exit_code so JSON consumers can read the verdict without process-exit capture
  "log_path":               "C:\\...\\tray.log", // string  — fixed %LOCALAPPDATA%\tillandsias\logs\tray.log
  "log_exists":             true,          // bool
  "log_size_bytes":         16384,         // u64 | null — size of the live tray.log (null if missing); pairs with TRAY_LOG_MAX_BYTES = 5 MiB rotation threshold
  "wsl_version":            "WSL version: 2.7.3.0", // string | null — first non-empty line of `wsl --version` stdout (locale-as-is); null if wsl.exe absent or command fails
  "os_version":             "Microsoft Windows [version 10.0.26200.8524]", // string | null — first line of `cmd /c ver`; null if cmd.exe absent or command fails
  "wt_present":             true,          // bool    — Windows Terminal on PATH (Open Shell prefers it)
  "distro":                 "tillandsias", // string  — wsl.exe -d <distro> target
  "distro_registered":      true,          // bool    — `wsl -l -q` listed `distro`
  "distro_running":         false,         // bool    — `wsl -l --running -q` listed `distro` (WSL2 idles VMs down; flips frequently)
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
