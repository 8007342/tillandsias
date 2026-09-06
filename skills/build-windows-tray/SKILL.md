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

### 2. Stage the guest binary the tray EMBEDS (order 1059-ry6t)

**Do this before the build, or the tray you install cannot inject a guest.**

`crates/tillandsias-windows-tray/src/wsl_lifecycle.rs` embeds the Linux guest
binary with `include_bytes!` and injects it into the distro at provision time.
The asset lives at:

```
crates/tillandsias-windows-tray/assets/tillandsias-headless-x86_64-unknown-linux-musl
```

`build.rs` writes an **empty placeholder** there when it is absent, so
`cargo check` compiles on a host that will never package. That is deliberate —
and it means **a fresh checkout's default state embeds a zero-byte guest**. It
was 0 bytes on esmeraldinha since 2026-08-23 and on yolanda since 2026-08-22,
two of two Windows hosts checked, and nothing said so until 1059-ry6t.

Check it first — a zero-byte asset is the failure:

```powershell
Get-Item crates\tillandsias-windows-tray\assets\tillandsias-headless-*-unknown-linux-musl |
    Select-Object Name, Length
```

Stage a real one (built on the Linux lane, e.g. the `tillandsias-build` WSL2
distro):

```bash
./build.sh --ci-full --install
cp target/x86_64-unknown-linux-musl/release/tillandsias-headless \
   crates/tillandsias-windows-tray/assets/tillandsias-headless-x86_64-unknown-linux-musl
```

**Then touch a `.rs` file before rebuilding.** Cargo does not rebuild when only
the asset changes, so a rebuild after restaging embeds the PREVIOUS bytes while
reporting success — a sibling trap recorded in `build.rs` and measured
2026-08-15.

The build now tells you either way: `build.rs` emits a cargo warning naming the
path whenever the asset is 0 bytes, and `scripts/build-windows-tray.ps1`
REFUSES rather than printing `Built:`. Neither existed before 1059-ry6t, which
is why the silent case ran for two weeks.

### 3. Release build

As of 2026-05-30, `scripts/build-windows-tray.ps1` locally relaxes
`$ErrorActionPreference` around the cargo invocation, so its stderr writes
("Compiling …", "Finished …") no longer trip the Stop trap as
`NativeCommandError`. Either path works:

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
# Either invoke the wrapper (preferred — same path users hit):
& scripts\build-windows-tray.ps1
# OR invoke cargo directly (still works, useful for ad-hoc):
cargo build -p tillandsias-windows-tray --release
```

Verify the artifact exists with a fresh `LastWriteTime`:

```powershell
Get-ChildItem target\release\tillandsias-tray.exe |
  Format-Table Name, Length, LastWriteTime -AutoSize
```

Expected size: ~6 MB (release-optimized GUI-subsystem binary).

### 4. Stop any running tray

```powershell
Get-Process tillandsias-tray -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.Id -Force }
Start-Sleep -Seconds 2
```

The 2 s sleep is important — Windows can keep the .exe file handle briefly
after the process exits, and `Copy-Item -Force` will fail with `IOException`
("file in use") if you proceed immediately.

### 5. Install

As of 2026-05-30, `scripts/install-windows.ps1` runs end-to-end (the
build-subscript stderr-wrap issue that previously aborted it mid-install was
fixed in the same 2026-05-30 build-windows-tray.ps1 tuning). Prefer the
script — it handles shortcut creation, autostart, and the Layer 1 (`--version`)
+ Layer 2 (`--diagnose --json`) post-install verification you'd otherwise
re-implement here:

```powershell
& scripts\install-windows.ps1
```

The script rebuilds via the (now-safe) build subscript, copies to
`%LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe`, creates a Start
Menu shortcut, and runs the two-layer post-install sanity check. Direct
copy is still fine if you want to skip the rebuild:

```powershell
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\Tillandsias'
New-Item -ItemType Directory -Force $installDir | Out-Null
Copy-Item target\release\tillandsias-tray.exe `
  (Join-Path $installDir 'tillandsias-tray.exe') -Force
```

### 6. Post-install `--diagnose` sanity check

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

### 7. Findings file

Mirrors macOS's `/build-macos-tray` ledger pattern (commit `0375ee1a`): one
file per day, **append a new section per run** rather than overwrite. Path:

```
plan/issues/windows-build-findings-YYYY-MM-DD.md
```

Living in `plan/issues/` (not `plan/diagnostics/`) so cross-host work-queue
greps see it. Sibling hosts grep `SECTION_KIND` to see whether the Windows
build is green on a given day.

If the file does not yet exist, prepend this header:

```markdown
# Windows tray build findings — YYYY-MM-DD

Generated by `/build-windows-tray`. One section per build run. Sibling hosts
should grep `SECTION_KIND` to see whether the Windows build is green on a
given day; section bodies surface anything that affects cross-host work
(rare unattended regressions, install-script edge cases, smoke surprises).

trace: skills/build-windows-tray/SKILL.md (the skill that wrote this)
       plan/steps/windows-next-thin-tray.md (the windows tray v0.0.1 ledger)
```

Then APPEND a section per run:

```markdown
---

### YYYYMMDDTHHMMSSZ — <SECTION_KIND>

- agent_id: <agent_id e.g. windows-bullo-claude-opus-YYYYMMDDTHHMMSSZ>
- head_sha: <short SHA after FF>
- version: <workspace VERSION>
- build_run_id: YYYYMMDDTHHMMSSZ

**Build**:
- duration: <N s wall-clock>
- exe: target/release/tillandsias-tray.exe (<size> bytes)

**Autonomous smoke** (post-install diagnose):
- `--diagnose --json` exit: <0 | 2 | 1>
- `--diagnose --json` keys present: [<comma-list>] — all **16 schema keys**
  per `litmus:windows-tray-diagnose-cli-surface` (count grows over time;
  check the cheatsheet § `--diagnose --json` schema for the current list).
- version: <workspace VERSION from JSON>
- build_commit: <short SHA from JSON>
- install_path: <path from JSON>
- distro registered / running: <bool> / <bool>
- WSL / OS: <wsl_version> / <os_version>
- control wire reachable: <bool> (phase=<phase>, podman_ready=<bool>)
- last_event: <string | null>

**Install**:
- target: %LOCALAPPDATA%\Programs\Tillandsias\tillandsias-tray.exe
- backup made: <yes (prior bundle at <size>, <date>) | no — first install>
- post-install diagnose schema match: <yes | no — diff>

**Findings** (free-form; what regressed, what surprised, what to investigate):
- <one line per issue, reproducer if non-obvious>

**Cross-host visibility note**: <text | N/A (SECTION_KIND=ok)>

**Next iteration ask**: <text | N/A (SECTION_KIND=ok)>
```

`SECTION_KIND` values:
- `ok` — Build + install + autonomous-smoke all green (exit 0 or 2 is ok; exit 1
  is not).
- `regression` — Something previously-green broke. Surface immediately.
- `degraded` — Build/install green but smoke partial (e.g. wire unreachable
  AND distro un-registered, where the latter would be unexpected).

### 8. Commit + push

```bash
git add plan/issues/windows-build-findings-YYYY-MM-DD.md
git commit -m "chore(windows-build-findings): YYYYMMDDTHHMMSSZ <SECTION_KIND>"
git push origin windows-next
```

### 9. Report

Print a 5-line summary back to the user covering: the FF outcome, build status,
install bytes/timestamp delta, `--diagnose --json` exit code + phase, and any
findings worth surfacing.

## Tuning log

Edit this section over time. Each entry: date + what changed + why.

- **2026-05-29:** initial. Direct cargo invocation (not the wrapper script).
  Documents the PowerShell-stderr-wrap, copy-after-stop-sleep, and
  cmd-redirect requirements drawn from the real loop's experience.
- **2026-05-30:** `scripts/build-windows-tray.ps1` now locally relaxes
  `$ErrorActionPreference` around the cargo call (with try/finally to
  restore on exit), so cargo's stderr writes no longer trip the Stop trap.
  The wrapper + `scripts/install-windows.ps1` both run end-to-end without
  the bypass. Skill body switched to prefer the script for builds + install
  while still showing the direct-cargo path for ad-hoc use.
- **2026-05-31:** large session of windows-tray surface enrichment
  shipped — too much to list per-commit, but the steady-state v0.2.260531.1
  era windows-tray now has: 7 CLI modes (`--provision-once`,
  `--status-once [--json]`, `--diagnose [--json]`, `--logs [--tail N] [--bak]`,
  `--help`, `--version`, GUI); 16-key DiagnoseReport (5 binary identity +
  2 host versions + 4 host facts + 1 manifest pin + 1 wire sub-object +
  1 log array, see cheatsheet for the full schema); 4 Win11 toasts
  (provisioning success/failure + wire degraded/recovered); 4 operator
  env vars (`RUST_LOG`, `TILLANDSIAS_NO_PROVISION`, `BUILD_COMMIT_SHA_OVERRIDE`,
  workspace VERSION via `build.rs`); install-windows.ps1 grew `-Purge`
  mode with `wsl --unregister` + cache cleanup; tray.log size-rotation
  at 5 MiB threshold with 1-bak ring; cli_integration test suite
  exercising the real binary end-to-end (4 tests in
  `tests/cli_integration.rs`). Schema-key claim in section 6 above
  bumped 10 → 16 to match; `--diagnose` JSON keys grow over time and
  the cheatsheet is the source of truth for the current set. Section
  6 template enriched with `version` / `build_commit` / `install_path`
  rows reflecting the new schema. Duplicate `### 7.` numbering fixed
  (Report is `### 8.` now). No daily-flow changes — `install-windows.ps1`
  end-to-end already exercises everything.
