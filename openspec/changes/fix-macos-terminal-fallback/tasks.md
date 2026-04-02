## 1. Replace macOS `open_terminal()` with fallback chain

- [x] 1.1 Add CLI terminal detection loop (ghostty, kitty, alacritty, wezterm) via `which` + direct `.spawn()`
- [x] 1.2 Add iTerm2 AppleScript fallback with `.output()` error capture
- [x] 1.3 Change Terminal.app AppleScript from `.spawn()` to `.output()` with error propagation
- [x] 1.4 Add `tracing::debug`/`tracing::warn` logging for terminal selection and failures

## 2. Knowledge cheatsheets

- [x] 2.1 Create `macos-app-launch-env.md` — DMG launch env, PATH isolation, TCC permissions
- [x] 2.2 Create `terminal-fallback-chain.md` — per-platform chain architecture, error detection

## 3. Verify

- [x] 3.1 `cargo check --package tillandsias-tray` — no new warnings
- [ ] 3.2 Build and test tray launch with Ghostty installed
- [ ] 3.3 Verify fallback to Terminal.app when no CLI terminal found (optional — remove ghostty from PATH temporarily)
