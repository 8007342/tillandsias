---
tags: [powershell, windows, scripting, build]
languages: [powershell]
since: 7.4
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/powershell/scripting/overview
  - https://learn.microsoft.com/en-us/powershell/scripting/lang-spec/chapter-01
  - https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell
authority: high
status: current
tier: pull-on-demand
---

# PowerShell — Windows scripting for forge & host builds

@trace spec:cross-platform, spec:windows-wsl-runtime
@cheatsheet runtime/windows-native-dev-build.md, runtime/wsl-on-windows.md

**Version baseline**: PowerShell 7.4+ preferred; Windows PowerShell 5.1 ships with the OS and is the lowest common denominator.
**Use when**: writing or invoking `*.ps1` scripts on a Windows host (e.g. `build-local.ps1`), spawning native exes from a calling shell, or troubleshooting WSL interop output.

## Provenance

- "PowerShell Documentation Overview" — <https://learn.microsoft.com/en-us/powershell/scripting/overview> — canonical entry point. Confirms PS 7.x is cross-platform, built on .NET, distinct from Windows PowerShell 5.1 which is Windows-only on .NET Framework.
- "PowerShell Language Specification — Chapter 1" — <https://learn.microsoft.com/en-us/powershell/scripting/lang-spec/chapter-01> — formal grammar; load-bearing for operator semantics (`&`, `&&`, `||`, `-and`, etc.) and the call operator.
- "Installing PowerShell on Windows" — <https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell> — install paths, side-by-side with 5.1, version-detection guidance.
- **Last updated**: 2026-04-28

## Versions at a glance

| Edition | Binary | .NET | Pipeline chain `&&`/`||` | Default file encoding |
|---|---|---|---|---|
| Windows PowerShell 5.1 | `powershell.exe` | .NET Framework 4.x | NOT supported (parser error) | UTF-16 LE w/ BOM |
| PowerShell 7.x | `pwsh.exe` | .NET 8/9 | Supported | UTF-8 (no BOM) |

Detect at runtime: `$PSVersionTable.PSVersion.Major` (5 vs 7).

## Quick reference

| Pattern | Effect |
|---|---|
| `$var = "value"` | Variable assignment (sigil required on read AND write) |
| `& "C:\path\app.exe" arg1 arg2` | Call operator — runs an exe whose path has spaces / is in a variable |
| `Invoke-Expression $cmd` | Parse a STRING as PowerShell code (last resort; injection risk) |
| `$LASTEXITCODE` | Exit code of the most recent native exe (NOT cmdlet) |
| `$?` | Boolean: did the last command succeed (cmdlets AND natives) |
| `$ErrorActionPreference = 'Stop'` | Cmdlet errors become terminating (catchable) |
| `Stop-Process -Id $pid -Force` | Native kill, no console flash |
| `Start-Process -WindowStyle Hidden` | Launch detached, no new window |
| `[System.Text.Encoding]::Unicode` | UTF-16 LE — what `wsl.exe --list` outputs |

## Calling scripts without popping a new window

The CALLING terminal already hosts a shell — do NOT spawn a new console. From `cmd.exe`, batch, or another PS:

```powershell
# RIGHT — runs in current console, inherits stdin/stdout
pwsh -NoProfile -ExecutionPolicy Bypass -File .\build-local.ps1 -Release
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-local.ps1

# WRONG — Start-Process spawns a detached window by default
Start-Process pwsh -ArgumentList '-File','.\build-local.ps1'

# RIGHT — if you MUST detach but stay invisible:
Start-Process pwsh -ArgumentList '-NoProfile','-File','.\worker.ps1' `
  -WindowStyle Hidden -NoNewWindow
```

Flags every script invocation should set:
- `-NoProfile` — skip user `$PROFILE`, ~50ms faster, deterministic
- `-ExecutionPolicy Bypass` — only for THIS process, not persistent
- `-File` — execute a script (vs `-Command` which evaluates a string)

## `&` (call operator) vs `Invoke-Expression`

```powershell
# & runs a command/exe/scriptblock with arguments as separate tokens. SAFE.
$exe = "C:\Program Files\Foo\foo.exe"
& $exe --flag $arg          # arguments are NOT re-parsed

# Invoke-Expression runs a STRING through the parser. DANGEROUS.
$cmd = "foo.exe --flag $userInput"
Invoke-Expression $cmd       # $userInput could contain ; rm -rf /
```

Rule: reach for `&` 99% of the time. `Invoke-Expression` is for dynamic code generation only — never for "I have a path with spaces."

For arguments containing `-`, `@`, or operators PowerShell wants to interpret, use the stop-parsing token `--%`:

```powershell
git log --% --format=%H --since="2026-01-01"
```

## Running cargo / native exes and capturing exit codes

```powershell
$ErrorActionPreference = 'Stop'

& cargo build --release --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) {
    throw "cargo build failed with exit code $LASTEXITCODE"
}

# Capture stdout AND check exit code
$output = & cargo metadata --format-version 1
if ($LASTEXITCODE -ne 0) { throw "cargo metadata failed: $output" }
$json = $output | ConvertFrom-Json
```

`$LASTEXITCODE` is set ONLY by native exes. Cmdlets use `$?` and exception flow. NEVER chain native calls with `;` and then check `$?` — `$?` reflects whether PowerShell could LAUNCH the process, not its exit code.

Avoid `2>&1` on native exes in 5.1: it wraps every stderr line in a `NativeCommandError` ErrorRecord and flips `$?` to `$false` even on exit 0. Stderr is already merged into the host stream — don't redirect.

## Stopping processes natively (no console flash)

```powershell
# By PID — instant, no UI
Stop-Process -Id $pid -Force

# By name — kills ALL matching, careful
Get-Process -Name "tillandsias" -ErrorAction SilentlyContinue |
    Stop-Process -Force

# Graceful first, then hard kill after timeout
$proc = Get-Process -Id $pid -ErrorAction SilentlyContinue
if ($proc) {
    $proc.CloseMainWindow() | Out-Null
    if (-not $proc.WaitForExit(5000)) { $proc.Kill() }
}
```

Do NOT shell out to `taskkill.exe` — it spawns a new conhost briefly (visible flash on some Windows builds) and is slower.

## Reading UTF-16 LE output (e.g. `wsl.exe --list --quiet`)

`wsl.exe` writes UTF-16 LE; piping it directly to PowerShell's text pipeline produces garbage interspersed with NUL bytes. Decode explicitly:

```powershell
# WRONG — visible NULs, broken matching
$distros = wsl.exe --list --quiet
$distros -contains "Ubuntu"   # always $false

# RIGHT — capture raw bytes, decode, split
$bytes    = & wsl.exe --list --quiet | Out-String -Stream
# Out-String already loses encoding — use the byte path:

$tmp = New-TemporaryFile
& wsl.exe --list --quiet > $tmp
$text = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::Unicode)
Remove-Item $tmp
$distros = $text -split "`r?`n" | Where-Object { $_ -ne '' }

# OR: ask wsl for a parseable encoding via WSL_UTF8
$env:WSL_UTF8 = "1"
$distros = (& wsl.exe --list --quiet) -split "`r?`n" | Where-Object { $_ }
```

Setting `WSL_UTF8=1` (WSL ≥ 0.64.0) forces UTF-8 output — preferred when available. Always test on the lowest WSL version you support.

## Writing files for other tools to consume

PowerShell 5.1's `Out-File` / `Set-Content` default to UTF-16 LE with BOM, which breaks every Unix tool. Force UTF-8:

```powershell
# 5.1: -Encoding utf8 still adds a BOM. Use .NET to skip it:
[System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))

# 7.x: utf8 = no BOM, utf8BOM = with BOM. Default is utf8.
$content | Set-Content -Path $path -Encoding utf8
```

## Catching errors

```powershell
$ErrorActionPreference = 'Stop'   # script-wide — make cmdlet errors fatal

try {
    Get-Item C:\does-not-exist
} catch [System.Management.Automation.ItemNotFoundException] {
    Write-Host "missing: $($_.Exception.Message)"
} catch {
    Write-Host "unexpected: $_"
    throw
} finally {
    # cleanup always runs
}
```

For native exes, errors come via `$LASTEXITCODE`, not exceptions — wrap manually:

```powershell
function Invoke-Native {
    param([string]$Exe, [string[]]$Args)
    & $Exe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe exited $LASTEXITCODE"
    }
}
```

## Conditional execution & parameter binding

```powershell
param(
    [switch]$Release,
    [string]$Target = "x86_64-pc-windows-msvc",
    [ValidateSet('debug','info','warn')]
    [string]$LogLevel = 'info'
)

if ($Release) {
    $profile = 'release'
} elseif ($env:CI -eq 'true') {
    $profile = 'release'
} else {
    $profile = 'dev'
}

# Splat args to a native exe
$cargoArgs = @('build', '--target', $Target)
if ($Release) { $cargoArgs += '--release' }
& cargo @cargoArgs
```

`[switch]` parameters: `-Release` sets `$Release` to `$true`, absence = `$false`. `[ValidateSet(...)]` rejects bad input at bind time.

## Pipeline chain operators — PS 7+ only

```powershell
# Works in 7.x; PARSE ERROR in 5.1
cargo build && cargo test
cargo build || throw "build failed"

# 5.1-compatible equivalent
cargo build
if ($?) { cargo test }            # any prior cmd succeeded
cargo build; if ($LASTEXITCODE -ne 0) { throw "build failed" }
```

If a script must support 5.1, NEVER use `&&` / `||` — even guarded by a version check, the whole script fails to parse.

## WSL interop from PowerShell

```powershell
# Run a Linux command in the default WSL distro
& wsl.exe --exec bash -lc "uname -a"

# Specific distro + user
& wsl.exe -d Ubuntu -u podman --exec systemctl --user status podman.socket

# Translate paths
$winPath   = "C:\Users\bullo\src\tillandsias"
$linuxPath = & wsl.exe wslpath -a $winPath        # /mnt/c/Users/bullo/...

# Pipe Windows stdout into a Linux process
Get-Content .\file.txt | & wsl.exe -- grep error
```

`wsl.exe` exit code propagates as `$LASTEXITCODE`. Stdout is whatever the Linux command emits (usually UTF-8) — but `--list` and other meta-commands emit UTF-16 (see above).

## Common pitfalls

- **`$LASTEXITCODE` is stale across cmdlets** — calling any cmdlet between `& exe` and the check is fine (cmdlets don't touch it), but explicit `try`/`catch` around the cmdlet can re-enter and confuse you. Capture immediately: `& exe; $rc = $LASTEXITCODE`.
- **`2>&1` flips `$?` to false on success** — see "Running cargo" above. Do NOT redirect native stderr in 5.1.
- **`-File` vs `-Command`** — `-Command` re-parses the argv as a script; `-File` runs a script file with positional args bound to `param()`. Use `-File` for `.ps1`.
- **CRLF in heredocs** — `@'...'@` and `@"..."@` use the file's line endings. Save scripts as LF if Linux tools will read them; PS happily executes either.
- **Execution policy** — `RemoteSigned` is the default. Pass `-ExecutionPolicy Bypass` per-invocation; do NOT `Set-ExecutionPolicy Unrestricted` machine-wide.
- **`Get-Content -Raw` vs default** — default reads line-by-line as a string array; `-Raw` returns one string. Cross-platform diffs hate the array form.
- **Profile slowdown** — user `$PROFILE` runs on every interactive launch. Always pass `-NoProfile` from build scripts; saves 50–500ms.
- **`Write-Host` vs `Write-Output`** — `Write-Output` (or bare `$x`) goes to the pipeline; `Write-Host` writes directly to the host (NOT capturable). Use `Write-Host` for human progress, `Write-Output` to return values.

## See also

- `runtime/windows-native-dev-build.md` — `build-local.ps1` invocation context
- `runtime/wsl-on-windows.md` — WSL distro lifecycle from PowerShell
- `languages/bash.md` — counterpart for the Linux side of the same build pipelines
