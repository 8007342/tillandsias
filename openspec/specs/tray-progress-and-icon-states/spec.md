<!-- @trace spec:tray-progress-and-icon-states -->
# tray-progress-and-icon-states Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-26-tray-progress-and-icon-states/
annotation-count: 5

## Purpose

Replace the comma-joined, fragmentary status chip with an additive, emoji-based progress indicator that grows as each subsystem comes online. Give the user at-a-glance visibility into "checklist in progress, X done so far" and add an `Unhealthy` stage that collapses the menu when any subsystem fails instead of showing a disabled menu full of items.

## Requirements

### Requirement: Additive Progress Chip

The status chip MUST be a single-line, additive string composed of: @trace spec:tray-progress-and-icon-states

1. A constant `✅` prefix
2. Per-completed-subsystem emoji in deterministic order:
   - `🧭` (browser runtime via `host-chromium-on-demand`)
   - `🕸️` (enclave networking)
   - `🛡️` (proxy container)
   - `🧠` (inference container)
   - `🔀` (router container)
   - `🪞` (git mirror container)
   - `🔨` (forge container)
3. Tail action: `Building <name> …` while a subsystem is building, or `<name> OK` for a 2-second flash after completion
4. Optional append: ` · GitHub unreachable — using cached list` when `Stage::NetIssue` is active

#### Scenario: Cold start with all images needing build
- **WHEN** tray starts with no cached images
- **THEN** chip MUST show `✅ Verifying environment …`
- **AND** as each subsystem builds, its emoji MUST be appended: `✅🧭 Building enclave ...`
- **AND** user SHOULD see progress accumulate without menu flicker

#### Scenario: All subsystems online
- **WHEN** all images finish building and start running
- **THEN** chip MUST show `✅🧭🕸️🛡️🧠🔀🪞🔨 OK`
- **AND** this transition SHOULD complete in under 30 seconds (typical subsequent starts)

### Requirement: Unhealthy Stage

A new `Stage::Unhealthy` variant MUST signal that at least one subsystem has failed and no concurrent retry is in progress. When detected:

1. The entire menu MUST collapse to a single item: `🥀 Unhealthy environment`
2. The subsystem divider, sign-in options, project list, and other menu items MUST be hidden
3. A signature line (`version` / `— by Tlatoāni` / `Quit`) MUST remain below the unhealthy indicator
4. Detail of which subsystem failed MUST be ONLY in the log (per "single line, detail in logs" preference)

#### Scenario: Forge build fails
- **WHEN** forge container build encounters an error
- **THEN** menu MUST transition to `🥀 Unhealthy environment` / divider / signature / Quit
- **AND** no retry SHOULD be in flight
- **AND** detailed error MUST be in the log (user can inspect with --log-forge or UI log viewer)

### Requirement: Cold-Start Baseline

When the tray starts and NO subsystem has yet reported a build status, AND the stage is `Booting`, the chip MUST read:

- `✅ Verifying environment …` (instead of empty or null)

This ensures the menu reads "loading / checking" instead of "ostensibly empty" during the first few seconds of startup.

#### Scenario: First-time user, cold start
- **WHEN** tray starts for the first time (no cache)
- **THEN** immediately SHOULD show `✅ Verifying environment …`
- **AND** user SHOULD see the tray is responsive (not hung or broken)

### Requirement: Locale Keys for Chip

The tray MUST add the following locale keys (en, de, es):

- `menu.status.verifying_environment` → "Verifying environment …"
- `menu.status.ready_one` → "<name> OK" (1-subsystem flash)
- `menu.build.chip_browser_runtime` → "browser runtime"
- `menu.build.chip_proxy` → "proxy"
- `menu.build.chip_router` → "router"
- (and any other subsystem names that appear in build output)

Locale-parity tests (`every_en_key_exists_in_es`, `every_en_key_exists_in_de`) MUST enforce that all three locales have entries for every key.

### Requirement: Sign-In Label Rename

The "Sign in to GitHub" menu item MUST be renamed:

- Old label: `Sign in to GitHub`
- New label: `🔑 GitHub Login` (shorter, matches user UX terminology)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee` — progress chip state transitions and menu collapsing on failure

Gating points:
- Status chip starts with `✅ Verifying environment …` on cold start
- Emoji appended in deterministic order as each subsystem completes
- All subsystems report completion within 30 seconds typical
- Menu collapses to single `🥀 Unhealthy environment` item when any subsystem fails
- Unhealthy stage does not retry automatically (detail only in logs)
- Locale keys enforced across en/de/es with parity tests

## Sources of Truth

- Project memory: `feedback_design_philosophy` — single line, detail in logs
