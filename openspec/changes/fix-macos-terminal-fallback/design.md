## Context

The Linux `open_terminal()` path already implements a fallback chain: it checks `which` for each terminal binary in order and spawns the first one found. The macOS path was written assuming Terminal.app is always the right choice, using AppleScript `do script` to open a window.

AppleScript's inter-app messaging bridge is fragile — it depends on TCC Automation permissions, the target app's scripting dictionary, and macOS version compatibility. Error `-2740` ("A property can't go after this identifier") indicates the scripting dictionary interaction failed, likely because Terminal.app was not in the expected state when a third-party terminal (Ghostty, Kitty) is the user's primary terminal.

## Goals / Non-Goals

**Goals:**
- macOS tray launch works regardless of which terminal emulator is installed
- Failed terminal launches are detected, logged, and trigger fallback to the next option
- CLI terminals preferred over AppleScript terminals (more reliable, no TCC dance)

**Non-Goals:**
- User-configurable terminal preference (future work — the fallback chain is sufficient for now)
- Windows terminal fallback (single `cmd` path works)
- Changing the Linux fallback chain

## Decisions

### CLI terminals before AppleScript

CLI terminals (ghostty, kitty, alacritty, wezterm) are spawned directly via `std::process::Command`. This avoids AppleScript entirely — no TCC permissions dialog, no scripting dictionary fragility, no Automation privacy settings.

### `.output()` for AppleScript, `.spawn()` for CLI

CLI terminals: `.spawn()` is sufficient. If `which` found the binary, the spawn will work. We can't easily detect if the terminal window actually rendered, but the process started.

AppleScript terminals: `.output()` blocks until osascript finishes, giving us the exit code and stderr. This is essential for the fallback to work — without it, a failed AppleScript silently succeeds and no fallback happens (the original bug).

### Detection methods

| Terminal | Detection | Rationale |
|---|---|---|
| ghostty, kitty, alacritty, wezterm | `which <binary>` | Homebrew adds to `/etc/paths.d`, so `which` works even in GUI-app minimal PATH |
| iTerm2 | `/Applications/iTerm.app` exists | iTerm2 doesn't install a CLI binary by default |
| Terminal.app | Always present | System app, no detection needed |

### Fallback order

ghostty → kitty → alacritty → wezterm → iTerm2 → Terminal.app

Rationale: CLI terminals first (reliable), then AppleScript terminals. Terminal.app is always last because it's the universal fallback.

## Scope

### Files changed:
- `src-tauri/src/handlers.rs` — `open_terminal()` macOS `#[cfg]` block

### Files created:
- `openspec/knowledge/cheatsheets/infra/macos-app-launch-env.md`
- `openspec/knowledge/cheatsheets/infra/terminal-fallback-chain.md`
