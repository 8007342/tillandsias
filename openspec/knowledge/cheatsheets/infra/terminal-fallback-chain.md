# Terminal Fallback Chain

## Architecture

`open_terminal(command, title)` in `handlers.rs` opens a native terminal window running a podman command. Each platform has an ordered fallback chain — the first terminal found and successfully launched wins.

## Why Fallback Matters

- Users install different terminal emulators (Ghostty, Kitty, iTerm2, etc.)
- No cross-platform "default terminal" API exists
- AppleScript-based launch is fragile (TCC permissions, scripting dictionary changes)
- AppImage/Flatpak on Linux may strip PATH or LD_LIBRARY_PATH

## Platform Chains

### Linux

```
ptyxis → gnome-terminal → konsole → xterm
```

Detection: `which <binary>` with `LD_LIBRARY_PATH` and `LD_PRELOAD` removed (AppImage isolation).

All terminals: `<term> [title-args] [exec-flag] bash -c "<command>"`

### macOS

```
ghostty → kitty → alacritty → wezterm → iTerm2 → Terminal.app
```

**Phase 1 — CLI terminals** (preferred): detected via `which`, spawned directly. No AppleScript, no TCC permissions needed.

**Phase 2 — AppleScript terminals** (fallback): iTerm2 detected via `/Applications/iTerm.app`, Terminal.app always available. Uses `osascript` with `.output()` to capture errors and fall through on failure.

### Windows

```
cmd /c start "<title>" cmd /k <command>
```

Single path — Windows Terminal / cmd.exe.

## Error Detection

| Method | Can detect failure? | Blocks? |
|---|---|---|
| `.spawn()` | Only if binary missing | No |
| `.output()` | Yes (exit code + stderr) | Yes (brief) |

- CLI terminals: `.spawn()` is sufficient — if `which` found it, spawn works
- AppleScript terminals: `.output()` required — osascript can start fine but the script itself can fail (error `-2740`, `-1743`, etc.)
- On failure, log the error and continue to the next terminal in the chain

## Common AppleScript Errors

| Code | Meaning | Cause |
|---|---|---|
| `-2740` | Property can't go after this identifier | Scripting dictionary mismatch or Terminal.app not responding |
| `-1743` | Not authorized to send Apple events | User denied Automation permission in System Settings |
| `-600` | Application isn't running | Target app not installed or crashed |
| `-609` | Connection invalid | Target app quit during scripting |

## Adding a New Terminal

1. Add to the appropriate platform section in `open_terminal()`
2. CLI terminals: add to the `cli_terminals` array with a closure that builds args
3. AppleScript terminals: add between iTerm2 and Terminal.app
4. Detection: `which` for CLI, `/Applications/*.app` for macOS-only apps
5. Test: build with `./build-osx.sh`, click Attach Here from tray

## Invariants

- Terminal.app is ALWAYS the last macOS fallback (it's a system app, always present)
- The `command` parameter is a pre-quoted shell string — pass it as a single arg to `bash -c`
- Title is best-effort — some terminals ignore it, and that's fine
- `LD_LIBRARY_PATH` / `LD_PRELOAD` must be removed on Linux (AppImage isolation)
- The fallback chain must NEVER silently succeed when no terminal opened — `.spawn()` alone is not enough for AppleScript paths
