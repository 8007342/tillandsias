# macOS App Launch Environment & DMG Behavior

## How macOS Apps Get Their Environment

| Launch method | PATH source | Inherits shell profile | Inherits terminal env |
|---|---|---|---|
| Double-click .app (Finder / Dock) | `/etc/paths` + `/etc/paths.d/*` only | No | No |
| `open -a Foo.app` from terminal | Same as Finder (sandboxed) | No | No |
| `./Foo.app/Contents/MacOS/Foo` direct | Terminal's env (full PATH) | Yes | Yes |
| Login item / Launch Agent | Minimal `/usr/bin:/bin:/usr/sbin:/sbin` | No | No |
| Spotlight launch | Same as Finder | No | No |

**Critical**: Homebrew (`/opt/homebrew/bin`), MacPorts (`/opt/local/bin`), and user-installed tools are **invisible** to GUI-launched apps. This is why `find_podman_path()` must check absolute paths, not rely on PATH.

## DMG / .app Bundle Gotchas

- **Code signing**: unsigned apps trigger Gatekeeper. Users need `xattr -cr App.app` on first run.
- **Translocation**: macOS silently moves unsigned apps to a random `/private/var/` path on first launch if downloaded from the internet. `Bundle.main.bundlePath` returns the translocated path, not the original. This breaks relative path lookups.
- **Quarantine flag**: `com.apple.quarantine` xattr set on download. `xattr -d com.apple.quarantine App.app` removes it.
- **Environment isolation**: `.app` bundles do NOT inherit `~/.zshrc`, `~/.bash_profile`, or any shell config. Environment variables set in `.zshenv` are also not available.
- **launchd scope**: GUI apps run in the Aqua session, not a terminal session. `launchctl setenv` can inject env vars into the GUI session but requires logout/login.

## Subprocess Spawning from .app

When a Tauri/Electron/native app spawns a subprocess:

```
App (.app bundle, minimal env)
  └─ std::process::Command::new("some-tool")
       └─ Inherits the app's minimal env, NOT the user's shell env
```

**Implications for Tillandsias**:
- `podman` won't be in PATH → use absolute paths (`find_podman_path()`)
- `osascript` is always at `/usr/bin/osascript` → safe to call by name
- `which <terminal>` works because `/usr/bin/which` is in the minimal PATH and searches `/usr/bin:/bin:/usr/sbin:/sbin` plus `/etc/paths.d` entries — but Homebrew-installed terminals may need absolute path checks too
- Environment variables like `DOCKER_HOST`, `SSH_AUTH_SOCK` won't be set → must be explicitly configured

## Terminal Detection on macOS

Unlike Linux where terminals are always CLI binaries, macOS terminals come in two flavors:

| Terminal | Type | Detection | Launch method |
|---|---|---|---|
| Ghostty | CLI binary (Homebrew) | `which ghostty` | `ghostty --title T -e bash -c CMD` |
| Kitty | CLI binary (Homebrew) | `which kitty` | `kitty --title T bash -c CMD` |
| Alacritty | CLI binary (Homebrew) | `which alacritty` | `alacritty --title T -e bash -c CMD` |
| WezTerm | CLI binary (Homebrew) | `which wezterm` | `wezterm start -- bash -c CMD` |
| iTerm2 | .app only | `/Applications/iTerm.app` exists | AppleScript `tell app "iTerm2"` |
| Terminal.app | .app only (system) | Always present | AppleScript `tell app "Terminal"` |

**Rule**: prefer CLI terminals over AppleScript terminals. CLI spawn is reliable and doesn't depend on the fragile AppleScript inter-app messaging bridge. AppleScript can break when:
- The target app updates its scripting dictionary
- macOS tightens automation permissions (TCC)
- The user hasn't granted Automation permission in System Settings → Privacy
- Another terminal has registered as the handler for the AppleScript `"Terminal"` name

## Default Terminal on macOS

macOS has no single "default terminal" concept like Linux's `x-terminal-emulator`. The closest is:
- `open -a` uses Launch Services to pick the registered handler
- URL schemes (`x-terminal://`) are not standardized
- AppleScript `tell app "Terminal"` always means Terminal.app specifically — it does NOT follow "default terminal" preferences

**Tillandsias approach**: don't try to detect "default terminal". Instead, use a deterministic fallback chain (ghostty → kitty → alacritty → wezterm → iTerm2 → Terminal.app) and let users override via config if needed.

## TCC (Transparency, Consent, Control) Permissions

AppleScript-based terminal launch requires Automation permission:
- First attempt triggers a system dialog: "Tillandsias wants to control Terminal.app"
- If denied, osascript fails silently with error `-1743` (not authorized)
- Permission is per-app-pair: Tillandsias→Terminal.app, Tillandsias→iTerm2, etc.
- Users manage this in System Settings → Privacy & Security → Automation
- CLI terminals (ghostty, kitty) don't need Automation permission — they're spawned as subprocesses
