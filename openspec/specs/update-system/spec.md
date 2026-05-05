<!-- @trace spec:update-system -->
## Status

status: active

## Requirements

### Requirement: Platform-appropriate artifact selection
- **ID**: update-system.artifact.platform-selection@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [update-system.invariant.platform-correct-artifact, update-system.invariant.appimage-fuse-handling]
The updater SHALL select the correct artifact for the current platform and handle platform-specific execution constraints.

#### Scenario: Platform-appropriate artifact selection
- **WHEN** an update is available and the updater downloads the update bundle
- **THEN** it selects the artifact matching the current platform (AppImage for Linux, .dmg/.app for macOS, .exe for Windows)

#### Scenario: AppImage on immutable OS without FUSE
- **WHEN** the application runs as an AppImage on an immutable operating system (e.g., Fedora Silverblue, SteamOS) where FUSE is unavailable or restricted
- **THEN** the application sets the `APPIMAGE_EXTRACT_AND_RUN=1` environment variable to enable AppImage execution via extraction fallback instead of FUSE mounting

## Invariants

### Invariant: Correct artifact selected by platform
- **ID**: update-system.invariant.platform-correct-artifact
- **Expression**: `platform == linux => AppImage_selected && platform == macos => [.dmg OR .app]_selected && platform == windows => .exe_selected`
- **Measurable**: true

### Invariant: AppImage FUSE fallback enabled on immutable OS
- **ID**: update-system.invariant.appimage-fuse-handling
- **Expression**: `platform == linux && immutable_os && APPIMAGE_EXTRACT_AND_RUN=1 => extraction_fallback_enabled`
- **Measurable**: true

## Litmus Tests

The following litmus tests validate update-system requirements:

- `litmus-update-artifact-selection.yaml` — Validates platform-appropriate artifact download and FUSE handling (Req: update-system.artifact.platform-selection@v1)

See `openspec/litmus-bindings.yaml` for full binding definitions.

## Sources of Truth

- `cheatsheets/runtime/podman.md` — Podman reference and patterns
- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:update-system" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
