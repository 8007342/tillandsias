## ADDED Requirements

### Requirement: Build-time SVG rendering
The icon pipeline SHALL render all SVG source assets into PNG format at compile time using `build.rs`. No SVG rendering SHALL occur at runtime.

#### Scenario: All 32 genus/lifecycle combinations rendered
- **WHEN** `cargo build` runs
- **THEN** `build.rs` renders `assets/icons/<genus>/<state>.svg` for all 8 genera and 4 lifecycle states (bud, bloom, dried, pup), producing 32 PNGs in `OUT_DIR/icons/<genus>/<state>.png`

#### Scenario: Tray icon variants rendered
- **WHEN** `cargo build` runs
- **THEN** `build.rs` renders `assets/icons/ionantha/bud.svg`, `bloom.svg`, and `dried.svg` as `OUT_DIR/icons/tray/base.png`, `building.png`, and `decay.png` at 32x32 pixels

#### Scenario: Window icon variants rendered
- **WHEN** `cargo build` runs
- **THEN** `build.rs` renders per-genus, per-lifecycle window icons at 48x48 pixels into `OUT_DIR/icons/window/<genus>/<state>@48.png`

#### Scenario: Generated PNGs not checked in
- **WHEN** the repository is inspected
- **THEN** no PNG files exist under `OUT_DIR/icons/`; all generated PNGs are transient build artifacts

### Requirement: Static PNG lookup map
The `tillandsias-core::icons` module SHALL expose compile-time-embedded PNG bytes for all icons via typed lookup functions. No runtime filesystem I/O SHALL be used to load icons.

#### Scenario: Per-genus, per-lifecycle icon lookup
- **WHEN** code calls `icons::icon_png(TillandsiaGenus::Ionantha, PlantLifecycle::Bloom, IconSize::S32)`
- **THEN** the function returns `&'static [u8]` containing valid PNG bytes for that combination

#### Scenario: Tray icon lookup by state
- **WHEN** code calls `icons::tray_icon_png(TrayIconState::Building)`
- **THEN** the function returns `&'static [u8]` for the Ionantha bloom 32x32 PNG

#### Scenario: All combinations non-empty
- **WHEN** tests run
- **THEN** every combination of genus, lifecycle, and size returns a `&'static [u8]` slice that is non-empty and begins with the PNG magic bytes (`\x89PNG`)

### Requirement: TrayIconState enum
The `tillandsias-core::genus` module SHALL define a `TrayIconState` enum mapping overall system state to a specific tray icon, independent of the per-environment `TillandsiaGenus` and `PlantLifecycle` types.

#### Scenario: Base state (idle or projects detected, none running)
- **WHEN** `TrayIconState::Base` is used
- **THEN** it maps to Ionantha bud (small plant, no environments running)

#### Scenario: Building state (at least one environment starting or running)
- **WHEN** `TrayIconState::Building` is used
- **THEN** it maps to Ionantha bloom (active, healthy environment)

#### Scenario: Decay state (environments present but all stopped or stopping)
- **WHEN** `TrayIconState::Decay` is used
- **THEN** it maps to Ionantha dried (faded, no active environment)

### Requirement: Existing SVG lookup preserved
The existing `tillandsias_core::genus::icons::icon_svg(genus, lifecycle)` function SHALL remain unchanged and continue to return the raw SVG bytes embedded from `assets/icons/`.

#### Scenario: SVG bytes still accessible
- **WHEN** code calls `icons::icon_svg(TillandsiaGenus::Aeranthos, PlantLifecycle::Bud)`
- **THEN** the function returns `&'static [u8]` containing the original SVG source, identical to before this change

### Requirement: Tray icon sourced from pipeline
The system tray icon displayed in the desktop environment SHALL be loaded from the SVG pipeline output rather than from the static procedural PNG.

#### Scenario: Tray icon at startup
- **WHEN** the application starts
- **THEN** the tray icon is the Ionantha bud PNG produced by the SVG pipeline (`TrayIconState::Base`)

#### Scenario: No dependency on static tray-icon.png
- **WHEN** `src-tauri/icons/tray-icon.png` is absent
- **THEN** the build still succeeds because the tray icon bytes come from `OUT_DIR` via `include_bytes!`
