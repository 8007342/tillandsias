---
name: build-windows-tray
description: Build + install the windows-tray release binary on the local Windows host, post-install --diagnose verify, and file findings in ./plan/ for future fixing.
---

# /build-windows-tray

A canonical, fine-tunable workflow for the **windows host's** daily build+install
loop (scheduled via /loop 24h). Treat this file as the source of truth; tune it
between iterations as the build flow evolves.

## Why this exists

Cargo+install can only run on the actual Windows host (cloud schedules can't
drive `wsl.exe` or write to `%LOCALAPPDATA%`). This skill encapsulates the
exact, known-working steps so they stay consistent across daily fires and so
the workflow is reviewable + improvable.

## Working dir

`C:/Users/bullo/src/tillandsias`

## Steps

Execute every step. Capture findings into a per-day file in `plan/diagnostics/`
named `build-windows-tray-YYYY-MM-DD.md` so other hosts can audit them.

### 1. Sync working tree

```bash
git fetch --all -q
B=$(git branch --show-current)
[ "$B" = "windows-next" ] || { echo "WRONG BRANCH: $B"; exit 1; }
# FF to current linux-next if possible (the loop's integration target).
git merge --ff-only origin/linux-next 2>&1 | tail -2
```

If FF fails (e.g. non-fast-forward because of local commits), DO NOT force
or rebase silently — note the divergence in the day's findings file and
continue building from current HEAD.

### 2. Release build

Invoke cargo directly, NOT the `scripts/build-windows-tray.ps1` wrapper, because
PowerShell tool invocations wrap cargo's stderr ("Compiling …", "Finished …")
as `NativeCommandError` when `$ErrorActionPreference = 'Stop'` is set inside
the wrapper. Direct cargo invocation tolerates the stderr stream correctly:

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
cargo build -p tillandsias-windows-tray --release
```

Verify the artifact exists with a fresh `LastWriteTime`:

```powershell
Get-ChildItem target\release\tillandsias-tray.exe |
  Format-Table Name, Length, LastWriteTime -AutoSize
```

Expected size: ~6 MB (release-optimized GUI-subsystem binary).

### 3. Stop any running tray

```powershell
Get-Process tillandsias-tray -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep -Seconds 2
```

The 2 s sleep is important — Windows can keep the .exe file handle briefly
after the process exits, and `Copy-Item -Force` will fail with `IOException`
("file in use") if you proceed immediately.

### 4. Install

Direct copy to the install path (`scripts/install-windows.ps1` rebuilds first,
which re-trips the cargo-stderr wrapping issue):

```powershell
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Tillandsias'
New-Item -ItemType Directory -Force $installDir | Out-Null
Copy-Item target\release\tillandsias-tray.exe `
  (Join-Path $installDir 'tillandsias-tray.exe') -Force
```

A future tuning pass MAY make `install-windows.ps1` tolerate the stderr-wrap
issue (e.g. via a `-SkipBuild` flag that this skill could then use), at which
point this skill SHOULD switch back to the script as the single source of
truth for install semantics (shortcut creation, autostart, etc.).

### 5. Post-install `--diagnose` sanity check

ALWAYS via `cmd /c` redirect to a file — PowerShell's direct stdout capture
of the release (GUI-subsystem) binary silently drops large `println!` writes
(see `cheatsheets/runtime/windows-tray-diagnostics.md` and commit
`d7bfcdd9`):

```powershell
$installed = Join-Path $env:LOCALAPPDATA 'Programs\Tillandsias\tillandsias-tray.exe'
$tmp = "$env:TEMP\build-windows-tray-diag.json"
& cmd /c "`"$installed`" --diagnose --json > `"$tmp`" 2>nul"
$diagExit = $LASTEXITCODE
$report = Get-Content $tmp | ConvertFrom-Json
Remove-Item $tmp -ErrorAction SilentlyContinue
```

Expected diagExit:
- `0` — fully healthy (distro registered AND wire reachable AND phase Ready)
- `2` — degraded (binary works but VM is idled / not provisioned; expected
  in the daily loop unless the VM was kept warm)
- `1` — hard failure (install bits broken — record + escalate)

### 6. Findings file

Write `plan/diagnostics/build-windows-tray-YYYY-MM-DD.md`:

```markdown
# build-windows-tray — YYYY-MM-DD

**Branch:** <branch> @ <short SHA>
**FF result:** <pulled N commits | already current | divergence note>
**Build:** <Finished in Ns | error excerpt>
**Install:** <size before -> size after, LastWriteTime>
**--diagnose --json exit:** <0 | 2 | 1>
**Version:** <report.version>
**Manifest pin:** <report.manifest_pin_x86_64_tar>
**Distro registered:** <bool>
**Wire reachable:** <bool> (phase=<phase>, podman_ready=<bool>)
**Findings:** <one line per issue surfaced, with reproducer if non-obvious>
```

Commit the file to windows-next so other hosts can audit:

```bash
git add plan/diagnostics/build-windows-tray-YYYY-MM-DD.md
git commit -m "diagnostics(windows-next): build-windows-tray YYYY-MM-DD"
git push origin windows-next
```

### 7. Report

Print a 5-line summary back to the user covering: the FF outcome, build status,
install bytes/timestamp delta, `--diagnose --json` exit code + phase, and any
findings worth surfacing.

## Tuning log

Edit this section over time. Each entry: date + what changed + why.

- **2026-05-29:** initial. Direct cargo invocation (not the wrapper script).
  Documents the PowerShell-stderr-wrap, copy-after-stop-sleep, and
  cmd-redirect requirements drawn from the real loop's experience.
