---
tags: [cmd, windows, batch, scripting]
languages: [batch]
since: 10
last_verified: 2026-04-28
sources:
  - https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/windows-commands
  - https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmd
  - https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/taskkill
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
---

# cmd.exe

@trace spec:cross-platform

**Use when**: scripting against legacy `.bat` files, driving older Windows
system tooling, killing processes without spawning a console window, or
writing the smallest possible startup wrapper. PowerShell is preferred for
anything new; cmd.exe is pinned where startup latency, `.bat` interop, or
ancient tooling demands it.

## Provenance

- <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/windows-commands> — canonical command reference (every built-in and tool with usage, exit codes, examples).
- <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/cmd> — `cmd.exe` itself: switches (`/c`, `/k`, `/d`, `/u`, `/e:on`), quoting rules, exit-code semantics.
- <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/taskkill> — `taskkill` switches, image-name vs PID matching, tree kills, filters.
- **Last updated:** 2026-04-28

## When to use cmd.exe vs PowerShell

| Situation | Choose |
|---|---|
| Driving a legacy `.bat` / `.cmd` file | **cmd.exe** |
| Tiny wrapper where startup latency matters (cmd starts in ~10ms vs PowerShell's ~200ms cold start) | **cmd.exe** |
| Old system tooling that emits cmd-style quoting (`netsh`, `sc`, `wmic`, `bcdedit`) | **cmd.exe** |
| New scripts, anything object-oriented, structured data, JSON, REST | **PowerShell** |
| Anything `WSL` or `wsl.exe` glue | either, but PowerShell handles UTF-16 output cleanly |
| Cross-platform shell parity (with bash) | **PowerShell Core** (`pwsh`), not cmd |

## Quick reference — built-ins and common tools

| Command | Effect |
|---|---|
| `where <cmd>` | resolve executable on PATH (cmd's `which`); prints all matches |
| `taskkill /F /IM <exe>` | force-kill all processes by image name (no console flash) |
| `taskkill /F /PID <n>` | force-kill by PID |
| `taskkill /F /IM <exe> /T` | kill process **tree** (parent + children) |
| `tasklist /FI "IMAGENAME eq <exe>"` | list matching processes |
| `set` | print all env vars |
| `set FOO=bar` | set var for current shell session only |
| `setx FOO bar` | persist var to registry (HKCU); takes effect in **new** shells |
| `setx FOO bar /M` | persist machine-wide (HKLM); requires elevation |
| `echo %FOO%` | read env var (cmd-style; PowerShell uses `$env:FOO`) |
| `cmd /c <line>` | run command and **exit** (use in scripts that shell out to cmd) |
| `cmd /k <line>` | run command and **keep shell open** (interactive use only) |
| `start "" "<exe>" <args>` | launch detached process; the empty `""` is the **window title** |
| `start /B <exe>` | launch in same console (no new window) |
| `start /WAIT <exe>` | block until child exits |
| `cd /d <path>` | change drive **and** directory in one go |
| `dir /b` | bare listing (just names; useful in scripts) |
| `del /F /Q <file>` | force-delete, no prompt |
| `rmdir /S /Q <dir>` | recursively delete dir, no prompt |
| `type <file>` | print file (cmd's `cat`) |
| `findstr /R <regex> <file>` | regex grep |
| `more <file>` | paged output |

## Pipes, redirects, exit codes

| Form | Effect |
|---|---|
| `a \| b` | pipe stdout of `a` to stdin of `b` |
| `a > out.txt` | redirect stdout (truncate) |
| `a >> out.txt` | redirect stdout (append) |
| `a 2> err.txt` | redirect stderr |
| `a > out.txt 2>&1` | merge stderr into stdout, then redirect |
| `a 2>&1 \| b` | pipe both streams |
| `a && b` | run `b` only if `a` succeeded (exit 0) |
| `a \|\| b` | run `b` only if `a` failed (exit ≠ 0) |
| `a & b` | run `b` after `a` regardless |
| `echo %ERRORLEVEL%` | last exit code (cmd-only — PowerShell uses `$LASTEXITCODE`) |
| `exit /b <n>` | exit batch script with code `n` (without `/b`, exits the whole shell) |

## Concrete examples

### Kill a process without spawning a console

```bat
taskkill /F /IM tillandsias.exe /T 2>nul
```

`/F` = force, `/IM` = image name, `/T` = tree, `2>nul` swallows the
"process not found" stderr message. Use this from a wrapper instead of
spawning a transient window.

### Find an executable on PATH

```bat
where podman
:: C:\Program Files\RedHat\Podman\podman.exe
where /Q podman && echo "podman installed" || echo "missing"
```

`/Q` = quiet, only sets `%ERRORLEVEL%`; useful for conditional logic.

### Launch detached, no console window

```bat
start "" /B "C:\Program Files\Tillandsias\tillandsias.exe" --tray
```

The empty `""` is mandatory — `start` interprets the **first** quoted
argument as the new console window title. Without it, `start "C:\Path\..."`
would consume your exe path as a title and silently do nothing.

### Minimal batch file template

```bat
@echo off
setlocal EnableDelayedExpansion

:: --- usage / arg check ----------------------------------------------------
if "%~1"=="" (
    echo Usage: %~nx0 ^<input^>
    exit /b 1
)

set INPUT=%~1
set OUTPUT=%INPUT%.out

:: --- main -----------------------------------------------------------------
where mytool >nul 2>&1 || (
    echo error: mytool not found on PATH 1>&2
    exit /b 2
)

mytool "%INPUT%" > "%OUTPUT%" || (
    echo error: mytool failed with exit %ERRORLEVEL% 1>&2
    exit /b %ERRORLEVEL%
)

echo wrote %OUTPUT%
endlocal
exit /b 0
```

`@echo off` silences command echoing. `setlocal` scopes env-var changes
to the script. `%~1` strips surrounding quotes from arg 1; `%~nx0`
expands to the script's name+extension. `1>&2` writes to stderr.

### Persist a PATH addition

```bat
:: User-level (no UAC), affects new shells only:
setx PATH "%PATH%;C:\Users\bullo\.cargo\bin"

:: Machine-wide (requires elevated cmd):
setx PATH "%PATH%;C:\Program Files\MyTool" /M
```

Beware: `setx` truncates at **1024 chars**. For long PATHs, edit via
`SystemPropertiesAdvanced.exe` → Environment Variables, or use the
PowerShell `[Environment]::SetEnvironmentVariable(...)` API.

## Common pitfalls

- **`%PATH%` pollution** — `setx PATH "%PATH%;..."` reads the **merged** (User+System) PATH but writes only the User scope. Repeated invocations duplicate the System portion into User and the variable balloons. Always read the **scoped** value via `reg query "HKCU\Environment" /v Path` before appending. **Last updated: 2026-04-28**.
- **MAX_PATH (260 chars)** — cmd.exe and many built-ins still respect the legacy 260-char path limit even when the OS has long-path support enabled. `dir`, `del`, `rmdir` may fail on deeply nested `node_modules`. Workarounds: `\\?\C:\very\long\path` prefix, or use PowerShell which honours the long-path manifest.
- **Quoting differs from PowerShell** — cmd uses **only double quotes** (`"..."`); single quotes are literal. Inside double quotes, `%VAR%` still expands. To pass a literal `%`, double it: `100%%`. PowerShell's single-quoted literals do not exist in cmd.
- **Case-insensitive but not always** — file names and env-var names are case-insensitive, but `findstr` is case-sensitive by default (use `/I` for insensitive). `if "%FOO%"=="bar"` is case-sensitive on the value side.
- **`start` and the title argument** — `start "C:\path\with spaces.exe"` does NOT launch the exe; it opens a new cmd window titled `C:\path\with spaces.exe`. Always pass an empty title first: `start "" "C:\path.exe"`.
- **`cmd /c` vs `cmd /k`** — `/c` runs the command and exits (right for scripting); `/k` keeps the shell open after (right for interactive launchers from Run dialog or shortcuts). Confusing them in a scheduled task leaves orphaned shells.
- **`%ERRORLEVEL%` is captured at expansion, not evaluation** — inside a parenthesised block (`if`, `for`), `%ERRORLEVEL%` is expanded **once at parse time**. Use `setlocal EnableDelayedExpansion` and `!ERRORLEVEL!` to read it dynamically.
- **`taskkill` matches first hit by default** — without `/F`, `taskkill` sends a polite WM_CLOSE that GUI apps may ignore. Always `/F` for daemons. `/IM <name>` matches the **image** (basename); use `/PID` if multiple instances exist and you only want one.

## See also

- `runtime/admin-console.md` — when and how to elevate from cmd or PowerShell.
- `runtime/windows-native-dev-build.md` — building Tillandsias on Windows; uses cmd-style env vars in a few wrappers.
- `runtime/wsl-on-windows.md` — invoking `wsl.exe` from cmd vs PowerShell.
