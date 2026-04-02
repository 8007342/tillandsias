## Why

When a user installs a non-default terminal emulator on macOS (Ghostty, Kitty, etc.), clicking "Attach Here" from the system tray silently fails. The terminal window never opens, but the tray reports success. The log shows:

```
845:861: syntax error: A property can't go after this identifier. (-2740)
```

Two bugs compound:

1. **Hardcoded Terminal.app** — the macOS path uses AppleScript `tell app "Terminal"` with no fallback chain, unlike Linux which tries ptyxis → gnome-terminal → konsole → xterm.
2. **Silent failure** — `open_terminal()` uses `.spawn()` which returns Ok as soon as the `osascript` process starts. The AppleScript itself fails, but the handler logs "Terminal opened with OpenCode" and proceeds as if everything worked.

## What Changes

Replace the single Terminal.app AppleScript with a fallback chain matching the Linux pattern:

- **Phase 1 — CLI terminals** (preferred): ghostty → kitty → alacritty → wezterm. Detected via `which`, spawned directly. No AppleScript, no TCC Automation permissions needed.
- **Phase 2 — AppleScript terminals** (fallback): iTerm2 → Terminal.app. Uses `.output()` instead of `.spawn()` to capture errors and fall through on failure.

Add two knowledge cheatsheets:
- `macos-app-launch-env.md` — DMG launch behavior, environment isolation, TCC permissions
- `terminal-fallback-chain.md` — per-platform chain architecture, error detection, how to add terminals

## Capabilities

### New Capabilities

- macOS tray launch works with Ghostty, Kitty, Alacritty, WezTerm, iTerm2, and Terminal.app
- Failed terminal launches are detected and logged with the specific error before trying the next terminal

### Changed Capabilities

- `open_terminal()` macOS path: single AppleScript → ordered fallback chain
- AppleScript paths now block briefly (`.output()`) to detect failure instead of fire-and-forget (`.spawn()`)

## Risks

- `.output()` for AppleScript paths blocks the event loop briefly (~1-2s worst case). Acceptable because the image build already uses `spawn_blocking` for longer.
- `which` detection depends on `/etc/paths.d` being populated (Homebrew does this). If a terminal is installed but not in PATH, it won't be found — but the chain falls through gracefully.
