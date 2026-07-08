---
status: claimed
owner_host: macos
capability_tags: [ui, rust]
events:
  - type: claim
    ts: "2026-07-07T10:15:00Z"
    agent_id: "macos-tlatoani-antigravity-2026-07-07T101500Z"
    host: "macos"
    lease_id: "tray-dynamic-build-steps"
---
# UI Enhancement: Dynamic Build Progress States in Tray

## The Problem
Right now, the tray UI displays `🏁 Setting up...` (or just defaults to `Ready tillandsias-in-vm`) during the entire container image build phase. Since building the forge, proxy, browser, and inference images takes several minutes, this static string provides no real feedback to the user on what is actually happening. It feels like a silent hang.

## Proposal
Instead of a static "Setting up..." string, the tray should subscribe to the JSONL telemetry stream emitted by idiomatic `podman build` (which writes to `build-*-progress.jsonl`). As the different container layers and images are processed, the tray should cycle through curated, user-friendly step names.

### Curated Step Names Mapping
When `tillandsias --init` is building specific images, the tray will cycle through these clever names:
- **`forge`**: "Building Forge"
- **`chromium`**: "Polishing Chromium"
- **`chromium-dev`**: "Tinkering Chromium Dev"
- **`inference`**: "Loading Inference"
- **`proxy`**: "Wiring the Proxy"
- **`vault`**: "Securing the Vault"
- **`git`**: "Initializing Git"

### Implementation Steps
1. **Telemetry Streaming**: The headless `tillandsias` process inside the VM (or host) currently records `podman build` events to a `.jsonl` file. We will emit these events over the control wire (vsock) to the macOS tray.
2. **State Updates**: `TrayState::active_builds` will be updated dynamically with the current image being built (or current layer).
3. **UI Rendering**: The `status_text` function in the tray will map the currently active image name to the curated strings above, rather than a generic "Building..." fallback.

This creates a lively, transparent setup experience that assures the user the system is actively working.
