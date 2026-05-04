## Why

Codex is a powerful agent for code analysis, understanding, and generation. Currently, users access it only through secondary flows. Adding 🏗 Codex as a first-class tray menu button (alongside Claude and OpenCode) provides direct access and reinforces the agent-centric design philosophy of the platform. This brings Codex to parity with other agents in the UI and makes it discoverable without additional steps.

## What Changes

- Add **🏗 Codex** button to the tray menu for each project (alongside OpenCode, OpenCode Web, Claude, Terminal, Serve)
- Wire Codex launch to spawn a codex container with the standard container stack (proxy, git mirror, inference)
- Pre-install Codex in the forge image so it's available immediately
- Allowlist Codex egress rules (if Codex requires external connectivity for code analysis)
- Document in specifications with `@trace` annotations

## Capabilities

### New Capabilities

- `codex-tray-launcher`: Tray menu integration for launching Codex agent. Includes button placement, launch handler, container orchestration, and menu state management.
- `codex-container-image`: Codex container image definition and build process. Pre-baked into forge to avoid runtime pulls.

### Modified Capabilities

- `tray-app`: Adding a new agent menu button alongside Claude, OpenCode, Terminal, etc. Menu structure updated to include Codex in the action row.
- `enclave-network`: Codex container joins the enclave and accesses proxy/git/inference services like other agents.
- `forge-hot-cold-split`: Codex pre-installed in the forge image (cold layer), reducing startup time.

## Impact

- **UI/UX**: One new menu button per project. Menu becomes 5 actions (OpenCode, OpenCode Web, Claude, Codex, Terminal, Serve) — may need layout optimization on small screens.
- **Container Lifecycle**: Codex container follows the same orchestration as Claude (launch, monitor, stop/destroy).
- **Forge Build Time**: Adding Codex to forge image increases build time (~2-5 min estimated).
- **Network**: Codex accesses proxy for external dependencies (if needed); egress allowlist must be configured.
- **Specs Affected**: `tray-app`, `tray-ux`, `enclave-network`, `forge-hot-cold-split`, `forge-image-building`.

## References

- Similar agent integrations: Claude tray launcher (existing), OpenCode web launcher
- Container orchestration: `enclave-network` spec (proxy, git service, inference)
- Image management: `forge-hot-cold-split`, `tools-overlay-fast-reuse`
