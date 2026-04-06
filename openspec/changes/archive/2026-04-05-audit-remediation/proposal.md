## Why

Full spec-vs-code audit revealed 5 critical divergences, 9 warnings, 7 orphaned code areas, and 6 forgotten specs. Trivial fixes applied immediately; this change tracks the remaining non-trivial items that need design decisions.

## What Changes

- **C5: SHA-pin CI actions** — Pin all GitHub Actions in release.yml by commit SHA (ci.yml already pinned)
- **W2/F1: Tray icon state** — Decide: implement dynamic tray icon or remove from spec (32 SVGs exist but are unused)
- **W5: Destroy hold UX** — Current 5s server-side sleep ≠ spec's "hold button" UX. Decide: keep sleep or implement proper hold
- **W6/W7: Update notifications** — Tauri updater emits events but tray menu never shows "Update available". Wire it up or descope
- **F3: Artifact detection** — Start/Rebuild actions specified but never shown in menu. Decide: implement or remove from spec
- **F4: WASM isolation** — Specified but no WASM in codebase. Remove from spec (aspirational, not MVP)
- **O5: detect_host_os duplication** — Extract to shared module

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `ci-release`: SHA-pin all actions
- `tray-app`: Clarify tray icon state scope, update notification
- `app-lifecycle`: Remove WASM requirement, clarify destroy UX

## Impact

- **Modified files**: `.github/workflows/release.yml`, `openspec/specs/app-lifecycle/spec.md`, `openspec/specs/tray-app/spec.md`, `openspec/specs/artifact-detection/spec.md`
