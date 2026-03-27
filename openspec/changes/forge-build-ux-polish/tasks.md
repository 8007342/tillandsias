## 1. State Tracking

- [x] 1.1 Add `forge_available: bool` to `TrayState` (default `false`)
- [x] 1.2 Set `forge_available = true` when forge image check passes at launch (image already present)
- [x] 1.3 Set `forge_available = true` when forge build completes successfully
- [x] 1.4 Set `forge_available = false` when forge rebuild is triggered (image stale)

## 2. Build Chip Messages

- [x] 2.1 Detect whether image existed before triggering the build
- [x] 2.2 First-time build (image absent): send `BuildProgressEvent::Started { image_name: "Building Forge".to_string() }`
- [x] 2.3 Update build (image stale): send `BuildProgressEvent::Started { image_name: "Building Updated Forge".to_string() }`

## 3. Menu Disabling

- [x] 3.1 Top-level "Attach Here" (~/src/ — Attach Here): `enabled(false)` when `!state.forge_available`
- [x] 3.2 Top-level "🛠️ Root": `enabled(false)` when `!state.forge_available`
- [x] 3.3 Per-project "Attach Here" / "Blooming": `enabled(false)` when `!state.forge_available`
- [x] 3.4 Per-project "Maintenance": `enabled(false)` when `!state.forge_available`
- [x] 3.5 GitHub Login: `enabled(false)` when `!state.forge_available`
- [x] 3.6 "Quit Tillandsias": always `enabled(true)`
- [x] 3.7 Settings submenu: stays enabled (does not require forge)
- [x] 3.8 Pass `forge_available` into `build_inactive_projects_submenu` for per-project disabling

## 4. Enable on Completion

- [x] 4.1 On `BuildProgressEvent::Completed` for forge image name variants, set `forge_available = true` in shared state and rebuild menu

## 5. Verification

- [x] 5.1 `./build.sh --check` passes with no errors
- [ ] 5.2 On launch with no forge image: menu items are disabled, chip shows "Building Forge..."
- [ ] 5.3 On launch with stale forge image: menu items are disabled, chip shows "Building Updated Forge..."
- [ ] 5.4 After build completes: all items re-enable automatically
- [ ] 5.5 "Quit Tillandsias" remains clickable at all times
