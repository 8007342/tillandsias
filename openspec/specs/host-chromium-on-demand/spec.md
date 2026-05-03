<!-- @trace spec:host-chromium-on-demand -->
# host-chromium-on-demand Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-26-host-chromium-on-demand/
annotation-count: 25

## Purpose

Provide an isolated, on-demand Chromium runtime for tray-launched browser windows. Downloads Chrome for Testing into a shared host cache on first launch, verifies integrity via SHA-256, and launches windows with per-session incognito profiles isolated from the user's daily browser. Enables CDP (remote debugging protocol) for programmatic browser control without interference.

## Requirements

### Requirement: Download and Verify Bundled Chromium

On tray initialization, the host SHALL check if `~/.cache/tillandsias/chromium/<pinned-version>/chrome` exists and is current. If missing or stale (version bumped in a Tillandsias release), it SHALL:

1. Fetch the Chrome for Testing download manifest from `googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json`
2. Verify SHA-256 checksum of the downloaded binary against the manifest
3. Surface progress via the additive status chip (`✅🧭 Downloading browser runtime...`)
4. Update the `~/.cache/tillandsias/chromium/current` symlink to point to the new version

#### Scenario: First-launch download
- **WHEN** tray starts and `~/.cache/tillandsias/chromium/<version>/chrome` does not exist
- **THEN** download begins automatically; status chip shows progress; user sees the tray responding with the download emoji
- **AND** old cached versions are cleaned up after one full release cycle

### Requirement: Launch Windows with Ephemeral Profiles

Each tray-launched browser window SHALL use:

- `--app=<url>` to open in standalone app mode
- `--user-data-dir=$(mktemp -d)` to create a temporary, random profile directory
- `--incognito` mode to disable history/cookies across launches
- `--no-first-run --no-default-browser-check` to suppress browser initialization prompts
- `--remote-debugging-port=<random-high-port>` to enable programmatic CDP control
- Automatic cleanup of the temporary profile directory on window close

#### Scenario: User clicks "Launch" in the tray
- **WHEN** user selects "Launch" for a project
- **THEN** Chromium starts with a brand-new, isolated profile
- **AND** the profile is destroyed on window close
- **AND** CDP is available on the assigned debugging port for MCP integration

### Requirement: Browser Detection

The `browser.rs::detect_browser()` function SHALL return `BundledChromium { bin: ~/.cache/tillandsias/chromium/<version>/chrome }` unconditionally. Legacy browser detection paths (Safari, Firefox, OS default) MAY be kept as tombstoned code for three releases but are NOT invoked at runtime.

#### Scenario: Cross-platform launch
- **WHEN** the tray attempts to launch a browser window on any platform (Linux, macOS, Windows)
- **THEN** the bundled Chromium is used exclusively
- **AND** fallback browser detection is not triggered

### Requirement: Download Telemetry

The host SHALL emit telemetry on first-launch download per the `forge-cache-architecture` spec:

- Event: `category="download", source="host-tray", target="~/.cache/tillandsias/chromium/<version>/"`
- Timestamp and binary size (bytes downloaded) are recorded
- The event is logged but NEVER blocks the browser launch

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:browser-ephemeral` — Verify browser instance is launched without blocking tray

Gating points:
- Browser launch request returns immediately without waiting for download to complete
- Download progress is logged asynchronously; tray continues responding to user input
- Downloaded binary is verified against SHA-256 digest from Chrome for Testing manifest
- Binary is cached at `~/.cache/tillandsias/chromium/<version>/` and reused on subsequent launches
- Telemetry event emitted with download timestamp, size, and target path
- Each browser instance (opened via `browser.open`) is independent and ephemeral

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms `~/.cache/tillandsias/chromium/` is host-managed shared state, never bind-mounted into forge
- Chrome for Testing official channel: `googlechromelabs.github.io/chrome-for-testing/` — the canonical download manifest and SHA-256 verification reference
