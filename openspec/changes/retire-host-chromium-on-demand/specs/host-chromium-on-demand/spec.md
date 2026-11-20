## REMOVED Requirements

### Requirement: Download and Verify Bundled Chromium
**Reason**: Nothing downloads Chrome for Testing any more: windows run in the tillandsias-chromium-framework container (1649-xqet), and scripts/install-chromium.sh is deleted (2118-fk3w).
**Migration**: None; the container engine is the only browser path (host-browser-mcp, and browser-window-modes when open-it-browser lands).

### Requirement: Launch Windows with Ephemeral Profiles
**Reason**: There is no host Chromium process to launch. The ephemeral profile is now host-browser-mcp's "Process-per-window with ephemeral profile", and litmus:browser-ephemeral is rebound there.
**Migration**: None; the container engine is the only browser path (host-browser-mcp, and browser-window-modes when open-it-browser lands).

### Requirement: Browser Detection
**Reason**: browser.rs::detect_browser() no longer resolves a host binary: browser.open launches only the engine container (host-browser-mcp, "Browser provider is bundled Chromium only").
**Migration**: None; the container engine is the only browser path (host-browser-mcp, and browser-window-modes when open-it-browser lands).

### Requirement: Download Telemetry
**Reason**: With no download there is no download telemetry.
**Migration**: None; the container engine is the only browser path (host-browser-mcp, and browser-window-modes when open-it-browser lands).
