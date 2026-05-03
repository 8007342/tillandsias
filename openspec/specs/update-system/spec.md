<!-- @trace spec:update-system -->
## Status

status: active

## MODIFIED Requirements

### Requirement: Platform-appropriate artifact selection
The updater SHALL select the correct artifact for the current platform and handle platform-specific execution constraints.

#### Scenario: Platform-appropriate artifact selection
- **WHEN** an update is available and the updater downloads the update bundle
- **THEN** it selects the artifact matching the current platform (AppImage for Linux, .dmg/.app for macOS, .exe for Windows)

#### Scenario: AppImage on immutable OS without FUSE
- **WHEN** the application runs as an AppImage on an immutable operating system (e.g., Fedora Silverblue, SteamOS) where FUSE is unavailable or restricted
- **THEN** the application sets the `APPIMAGE_EXTRACT_AND_RUN=1` environment variable to enable AppImage execution via extraction fallback instead of FUSE mounting

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:update-system" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
