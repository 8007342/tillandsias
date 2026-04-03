## Why

When a user installs a non-default terminal emulator on macOS (Ghostty, Kitty, etc.), clicking "Attach Here" from the system tray could silently fail due to AppleScript interaction with non-standard terminals.

The original approach added a multi-terminal fallback chain (Ghostty → Kitty → Alacritty → WezTerm → iTerm2 → Terminal.app). This was overengineered and fragile — each third-party terminal has its own CLI quirks and update cadence that can break our launch path at any time.

**Revised approach**: Use Terminal.app exclusively on macOS. It ships with every Mac, never breaks, and needs no detection logic. Remove all third-party terminal detection and fallback code.

## What Changes

- Remove Ghostty detection and `open -na` launch path
- Remove CLI terminal detection loop (kitty, alacritty, wezterm)
- Remove iTerm2 AppleScript path
- Keep only Terminal.app AppleScript launch — clean, simple, always works
- Update error message to reflect Terminal.app-only strategy

## Capabilities

### New Capabilities

(none)

### Changed Capabilities

- `open_terminal()` macOS path: multi-terminal fallback chain → Terminal.app only

## Risks

- Users with strong terminal preferences (Ghostty, iTerm2) won't get their preferred terminal. Acceptable trade-off: reliability over preference. They can still use their terminal manually.
