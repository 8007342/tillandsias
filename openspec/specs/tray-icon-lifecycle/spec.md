<!-- @trace spec:tray-icon-lifecycle -->
## Status

active

## Requirements

### Requirement: Five-state tray icon lifecycle
- **ID**: tray-icon-lifecycle.icon.five-state-enum@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-icon-lifecycle.invariant.five-states-exactly, tray-icon-lifecycle.invariant.lifecycle-mapping-complete]
The `TrayIconState` enum SHALL define exactly five variants mapping the full tillandsia plant lifecycle to the system tray icon. Each variant maps to a specific Ionantha SVG asset rendered at build time.

#### Scenario: Pup state at app launch
- **WHEN** the application starts
- **THEN** the tray icon is set to `TrayIconState::Pup` immediately, before any podman or forge checks
- **AND** the icon displays the Ionantha pup PNG (tiny sprout — initializing)

#### Scenario: Mature state when ready
- **WHEN** podman is available and the forge image is confirmed present (or build completes)
- **THEN** the tray icon transitions to `TrayIconState::Mature`
- **AND** the icon displays the Ionantha bud PNG (healthy mature rosette — at rest)

#### Scenario: Building state during active builds
- **WHEN** one or more image or container builds are in progress
- **THEN** the tray icon is `TrayIconState::Building`
- **AND** the icon displays the Ionantha bloom PNG (flowering — activity)

#### Scenario: Blooming state when build completes
- **WHEN** all builds have completed successfully and no builds are in progress
- **AND** at least one completed build is still within the 10-second fadeout window
- **THEN** the tray icon is `TrayIconState::Blooming`
- **AND** the icon displays the Ionantha bloom PNG (same flower — something new is ready)

#### Scenario: Blooming to Mature on user acknowledgment
- **WHEN** the tray icon is in `Blooming` state
- **AND** the user opens the tray menu (clicks the tray icon)
- **THEN** the tray icon transitions to `TrayIconState::Mature`

#### Scenario: Dried state on unrecoverable error
- **WHEN** podman is not available
- **THEN** the tray icon is set to `TrayIconState::Dried`
- **AND** the icon displays the Ionantha dried PNG (withered — unrecoverable)

### Requirement: Build-time tray icon rendering for all 5 states
- **ID**: tray-icon-lifecycle.build.icon-rendering-pipeline@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-icon-lifecycle.invariant.five-pngs-generated, tray-icon-lifecycle.invariant.icon-dimensions-32x32, tray-icon-lifecycle.invariant.svg-to-png-mapping]
The `build.rs` icon pipeline SHALL render 5 tray icon PNGs from Ionantha SVG sources, one per `TrayIconState` variant.

#### Scenario: Five tray PNGs generated
- **WHEN** `cargo build` runs
- **THEN** `build.rs` produces `OUT_DIR/icons/tray/{pup,mature,building,blooming,dried}.png` at 32x32 pixels
- **AND** pup.png is from `ionantha/pup.svg`, mature.png from `ionantha/bud.svg`, building.png from `ionantha/bloom.svg`, blooming.png from `ionantha/bloom.svg`, dried.png from `ionantha/dried.svg`

#### Scenario: All tray PNGs valid
- **WHEN** tests run
- **THEN** `tray_icon_png()` returns non-empty bytes starting with PNG magic for all five `TrayIconState` variants

### Requirement: compute_icon_state reflects full lifecycle
- **ID**: tray-icon-lifecycle.state.compute-icon-state-logic@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-icon-lifecycle.invariant.blooming-fadeout-window, tray-icon-lifecycle.invariant.mature-idle-condition]
The `TrayState::compute_icon_state()` method SHALL return the correct `TrayIconState` based on the current application state, including the new `Blooming` transition.

#### Scenario: Blooming when builds recently completed
- **WHEN** `has_podman` is true
- **AND** no builds have `InProgress` status
- **AND** at least one build has `Completed` status with `completed_at` within `BUILD_CHIP_FADEOUT`
- **THEN** `compute_icon_state()` returns `TrayIconState::Blooming`

#### Scenario: Mature when idle
- **WHEN** `has_podman` is true
- **AND** no builds are in progress
- **AND** no builds have recently completed
- **THEN** `compute_icon_state()` returns `TrayIconState::Mature`

### Requirement: TrayIconState enum variants renamed
- **ID**: tray-icon-lifecycle.enum.variant-renames@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-icon-lifecycle.invariant.base-renamed-to-mature, tray-icon-lifecycle.invariant.decay-renamed-to-dried]
The `TrayIconState` enum variant names SHALL use plant lifecycle terminology instead of generic state names.

#### Scenario: Base renamed to Mature
- **WHEN** code previously referenced `TrayIconState::Base`
- **THEN** it SHALL reference `TrayIconState::Mature`

#### Scenario: Decay renamed to Dried
- **WHEN** code previously referenced `TrayIconState::Decay`
- **THEN** it SHALL reference `TrayIconState::Dried`

### Requirement: Initial tray state is Pup
- **ID**: tray-icon-lifecycle.initialization.pup-on-startup@v2
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [tray-icon-lifecycle.invariant.initial-state-is-pup]
The `TrayState::new()` constructor SHALL initialize `tray_icon_state` to `TrayIconState::Pup` instead of the previous `TrayIconState::Base`.

## UX Guidelines

### Icons are the primary communication channel
The tray icon is the sole visual indicator of system health. Users MUST be able to understand the app's state at a glance from the plant lifecycle metaphor without reading text.

### Plant lifecycle maps to app lifecycle
| Plant Stage | App Meaning | User Perception |
|-------------|-------------|-----------------|
| Pup (sprout) | Starting up, checking dependencies | "Waking up" |
| Mature (rosette) | Ready, everything healthy | "All good" |
| Blooming (flower) | Something just finished | "Something new" |
| Building (flower) | Work in progress | "Busy" |
| Dried (withered) | Broken, needs attention | "Something wrong" |

### No container terminology in user-facing context
Users MUST never see the words "container", "pod", "image", or "runtime" in any tray menu item, tooltip, or notification associated with these icon states.

## Invariants

### Invariant: Exactly five TrayIconState variants
- **ID**: tray-icon-lifecycle.invariant.five-states-exactly
- **Expression**: `TrayIconState enum HAS_EXACTLY [Pup, Mature, Building, Blooming, Dried]`
- **Measurable**: true

### Invariant: Lifecycle mapping is complete
- **ID**: tray-icon-lifecycle.invariant.lifecycle-mapping-complete
- **Expression**: `each_state MAPS_TO plant_lifecycle_stage && has_visual_asset`
- **Measurable**: true

### Invariant: Five PNGs generated
- **ID**: tray-icon-lifecycle.invariant.five-pngs-generated
- **Expression**: `cargo_build => OUT_DIR/icons/tray/{pup,mature,building,blooming,dried}.png_all_exist`
- **Measurable**: true

### Invariant: Icon dimensions are 32x32
- **ID**: tray-icon-lifecycle.invariant.icon-dimensions-32x32
- **Expression**: `all_generated_pngs HAVE width=32 && height=32 && valid_png_magic`
- **Measurable**: true

### Invariant: SVG to PNG mapping
- **ID**: tray-icon-lifecycle.invariant.svg-to-png-mapping
- **Expression**: `pup.png<=ionantha/pup.svg && mature.png<=ionantha/bud.svg && building.png<=ionantha/bloom.svg && blooming.png<=ionantha/bloom.svg && dried.png<=ionantha/dried.svg`
- **Measurable**: true

### Invariant: Blooming fadeout window
- **ID**: tray-icon-lifecycle.invariant.blooming-fadeout-window
- **Expression**: `compute_icon_state => Blooming_IFF(has_podman && NO_InProgress_builds && EXISTS_Completed_within_BUILD_CHIP_FADEOUT)`
- **Measurable**: true

### Invariant: Mature on idle
- **ID**: tray-icon-lifecycle.invariant.mature-idle-condition
- **Expression**: `compute_icon_state => Mature_IFF(has_podman && NO_InProgress_builds && NO_recent_Completed)`
- **Measurable**: true

### Invariant: Base renamed to Mature
- **ID**: tray-icon-lifecycle.invariant.base-renamed-to-mature
- **Expression**: `all_code_references TrayIconState::Base => TrayIconState::Mature`
- **Measurable**: true

### Invariant: Decay renamed to Dried
- **ID**: tray-icon-lifecycle.invariant.decay-renamed-to-dried
- **Expression**: `all_code_references TrayIconState::Decay => TrayIconState::Dried`
- **Measurable**: true

### Invariant: Initial state is Pup
- **ID**: tray-icon-lifecycle.invariant.initial-state-is-pup
- **Expression**: `TrayState::new().tray_icon_state == TrayIconState::Pup`
- **Measurable**: true

## Litmus Tests

The following litmus tests validate tray-icon-lifecycle requirements:

- `litmus-tray-icon-five-state-enum.yaml` — Validates five-state enum definition (Req: tray-icon-lifecycle.icon.five-state-enum@v1)
- `litmus-icon-png-generation.yaml` — Validates build-time icon rendering pipeline (Req: tray-icon-lifecycle.build.icon-rendering-pipeline@v1)
- `litmus-icon-state-computation.yaml` — Validates state transitions and lifecycle logic (Req: tray-icon-lifecycle.state.compute-icon-state-logic@v1)
- `litmus-tray-icon-initialization.yaml` — Validates initial Pup state and variant renames (Req: tray-icon-lifecycle.initialization.pup-on-startup@v2, tray-icon-lifecycle.enum.variant-renames@v2)

See `openspec/litmus-bindings.yaml` for full binding definitions.

## Sources of Truth

- `cheatsheets/architecture/event-driven-basics.md` — Event Driven Basics reference and patterns
- `cheatsheets/runtime/container-health-checks.md` — Container Health Checks reference and patterns

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:tray-icon-lifecycle" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
