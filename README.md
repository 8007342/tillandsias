```text
  ____________    __    ___    _   ______  _____ _______   _____
 /_  __/  _/ /   / /   /   |  / | / / __ \/ ___//  _/   | / ___/
  / /  / // /   / /   / /| | /  |/ / / / /\__ \ / // /| | \__ \
 / / _/ // /___/ /___/ ___ |/ /|  / /_/ /___/ // // ___ |___/ /
/_/ /___/_____/_____/_/  |_/_/ |_/_____//____/___/_/  |_/____/
```

The Tlatoāni recommends Tillandsias as a safe runtime for your agents.
Fedora Silverblue is our favorite OS but you can use whatever you want;
we'll channel its inner Podman ;)

The install commands below track the **stable channel**: they resolve the
latest *promoted* release. Daily builds keep shipping as
[pre-releases](https://github.com/8007342/tillandsias/releases) — grab one
of those only if you want the bleeding edge.

## RELEASE LEDGER

For humans and agents alike: what each release set out to do, what it
actually shipped, and what broke and got fixed along the way. Agents doing
smoke curl-installs or jumpstarting work read the recent rows first; rows
age into semantic distillation (detail lives with the most recent releases;
see `plan/issues/` for the full evidence trail of any row).
The release skill appends a row per release; STABLE marks channel promotions.

<details>
<summary>Release ledger (newest first)</summary>

| RELEASE | INTENDED FEATURES | BUGFIXES |
|---|---|---|
| v0.3.260716.1 (daily) | Order 363: agent-reachable MCP publish tunnel (dedicated NDJSON `mcp.sock`, forge-mounted, SO_PEERCRED project gate) — implementation complete, live-publish e2e pending (order 374). FRESHNESS methodology rung 1 + packets 370-372. Order 225 litmus-stdlib `mf_*` migration batch. Windows order 238 credential research merged. Next-release milestone filed: web containers → one-prompt public share (orders 373-381). | Litmus runner: file-capture step execution + TERM→KILL ladder at the real site (dead `execute_test_command` decoy tombstoned); `tls-test-server.c` SA_RESTART SIGTERM immunity (wedged 3 gate runs); podman sqlite lock-stall cascade root-caused + ENV-FAIL preflight; `environment-isolation` allowlist caught up to `NODE_USE_SYSTEM_CA`; pre-restart fixture recovery (image-tag fallback + `ss` port-probe). |
| v0.3.260715.2 (daily) | Windows order 312 (release-gating standard-user wire), macOS orders 331/332, cross-host integration. | Clippy-strict repair forward from windows lane; stable-Rust SO_PEERCRED via nix. |
| v0.3.260714.1 (daily) | Forge runtime CA-trust convergence (one system bundle for Git/curl/Node/Python); order 320 parity checkpoint; vsock handshake litmus v2. | Six duplicate entrypoint CA blocks removed; stale v1 probe assertions replaced. |
| v0.3.260712.1 (**STABLE**) | Promoted to the stable channel — the curl-install commands above resolve here. | — |

*Older releases: distilled; see git tags and `plan/loop_status.md` history.*

</details>

## LINUX INSTRUCTIONS

We prefer Fedora Silverblue.

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

## MACOS INSTRUCTIONS — MANUAL INSTALL

Download **[Tillandsias.dmg](https://github.com/8007342/tillandsias/releases/latest/download/Tillandsias.dmg)**, open it, and drag Tillandsias into Applications.

## MACOS INSTRUCTIONS — AUTO INSTALL

```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
```

## WINDOWS INSTRUCTIONS

```powershell
irm https://github.com/8007342/tillandsias/releases/latest/download/install-windows.ps1 | iex
```

Each installer provisions the local runtime on first run:
- **Linux**: runs `tillandsias --init` inline in your terminal.
- **macOS**: launches the tray, which provisions a Fedora VM automatically.
- **Windows**: launches the tray, which provisions a Fedora WSL2 distro automatically.

Podman is the only host dependency on Linux (auto-detected). macOS and Windows
provision a lightweight Fedora-based utility VM; no host Podman required.

## Run

**Desktop (Tray Mode):**
The installer launches the tray automatically. A tray icon appears in your
system menu bar / notification area. Click it to view projects and container status.

**Headless (CLI/Automation — Linux only):**
```bash
tillandsias --headless /path/to/project
```

## How it Works: The Fedora Pivot

Tillandsias v0.3.0 introduced the "Fedora Pivot" architecture:
- **Official Images**: Instead of shipping custom rootfs tarballs, we pull official, signed images directly from the Fedora Project (WSL2 for Windows, Cloud Base for macOS).
- **Runtime Bootstrap**: The tray application provisions the VM, installs the `tillandsias-headless` agent, and materializes your local development environment on demand.
- **Zero-Drift**: All three platforms now share the exact same Fedora-based runtime environment for your projects.

## OpenCode: Analyze Code with LLM

Analyze a project with local LLM inference (no cloud, no credentials sent):

```bash
tillandsias /path/to/project --opencode --prompt "What is the main purpose?"
```

## Platform support

### Linux
First-class support for x86_64 and aarch64. musl-static binary requires only rootless podman.

### macOS
Native AppKit tray for Apple Silicon. Uses Apple's Virtualization.framework to run a Fedora-based utility VM. Supports high-performance virtio-vsock communication and native Terminal.app integration.

### Windows
Native Win32 NotifyIcon tray. Uses WSL2 to run a Fedora-based utility VM. Supports Windows Terminal and `wsl.exe` integration.

## All Downloads

See the [latest release](https://github.com/8007342/tillandsias/releases/latest) for all platform binaries, checksums, and Cosign signatures.
Release operators should run the [local release gate](docs/RELEASING.md) before dispatching the hosted signing and publishing workflow.

| File | Description |
|------|-------------|
| [SHA256SUMS](https://github.com/8007342/tillandsias/releases/latest/download/SHA256SUMS) | Checksums for all artifacts |
| [VERIFICATION.md](docs/VERIFICATION.md) | Signature verification instructions |

## Learn More

See [README-ABOUT.md](README-ABOUT.md) for architecture, configuration, and development docs.

## License

GPL-3.0-or-later
