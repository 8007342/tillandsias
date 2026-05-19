# Tillandsias

*Create. Work. Run. Stop.*

A portable Linux binary that makes software appear — safely, locally, reproducibly. Runs headless (CLI/automation) or with optional native GTK tray.

> **Linux only.** Tillandsias v0.2 is Linux-native (musl-static, rootless podman, GTK4 tray). macOS and Windows wrappers are planned — see [Platform support](#platform-support) below.

## Install

**Linux** (Fedora, Ubuntu, Debian, Arch, etc.)
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

The binary is fully portable (musl-static) and runs on any x86_64 Linux system without external dependencies.

<details>
<summary>Direct download</summary>

| Download |
|----------|
| [tillandsias-linux-x86_64](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-linux-x86_64) |

</details>

## Run

**Desktop (with tray UI, requires GTK4 runtime):**
```bash
tillandsias
```
A tray icon appears. Click to view projects and container status. Right-click → pick a project → Attach Here.

**Headless (CLI/automation):**
```bash
tillandsias --headless /path/to/project
```
No UI. Emits JSON events on stdout for scripting. Perfect for CI/CD, automation, and remote servers.

The binary auto-detects your environment and chooses the appropriate mode.

## OpenCode: Analyze Code with LLM

Analyze a project with local LLM inference (no cloud, no credentials sent):

```bash
tillandsias /path/to/project --opencode --prompt "What is the main purpose?"
```

Or in a CI/automation context:
```bash
tillandsias --headless /path/to/project --opencode --prompt "Analyze the architecture" --debug
```

What happens:
1. **Project mounting**: Source code mounted read-only into isolated container
2. **Enclave**: Proxy (security), Git mirror (auth), Inference (ollama), Forge (analysis) all run locally
3. **LLM analysis**: Your prompt sent to local LLM model (no external API calls)
4. **Response**: Tokens streamed and printed as they arrive

Emits JSON events for integration with CI/observability systems. See [OPENCODE-INTEGRATION-COMPLETED.md](docs/OPENCODE-INTEGRATION-COMPLETED.md) for full details.

## OpenCode Web: Full Browser-Based Session

Open a sandboxed Chromium window pointed at the OpenCode UI for the project, with per-window OTP session, isolated container, and forge integration:

```bash
tillandsias --opencode-web /path/to/project --debug --tray
```

A Chromium window opens with the OpenCode UI authenticated to your project. The browser runs in a locked-down container (no host filesystem access beyond the profile dir, no credentials, no network outside the enclave).

## Uninstall

```bash
tillandsias-uninstall
```

<details>
<summary>Uninstall + wipe everything</summary>

```bash
tillandsias-uninstall --wipe
```

Removes the binary, caches, container images, and all Tillandsias data.

</details>

## Requirements

**Required:**
- **Linux** (x86_64) — Fedora, Ubuntu, Debian, Arch, or any distro with podman
- [Podman](https://podman.io) (rootless) — `sudo dnf install podman` or `sudo apt install podman`

**For Tray Mode (optional):**
- GTK4 runtime — usually pre-installed on desktop systems
- For GNOME: [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/) for system tray

**Note**: Headless mode requires no GTK or display server. Tray mode is optional and auto-disabled if GTK is unavailable.

## Platform support

### Linux

First-class. Everything in this README applies as-is. The Linux binary is the source of truth for behavior, security model, and the test matrix.

### macOS

**Coming soon.**

Planned as a thin platform wrapper around the same Rust core, delegating container runtime to Podman Desktop or Docker Desktop. The tray will use the native macOS status bar API.

### Windows

**Coming soon.**

Planned via WSL2: the Linux musl-static binary runs inside WSL, with a thin Windows-side wrapper handling system tray (Win32 NotifyIcon) and lifecycle. Container runtime via Podman Desktop or Docker Desktop.

## All Downloads

See the [latest release](https://github.com/8007342/tillandsias/releases/latest) for all platform binaries, checksums, and Cosign signatures.

| File | Description |
|------|-------------|
| [SHA256SUMS](https://github.com/8007342/tillandsias/releases/latest/download/SHA256SUMS) | Checksums for all artifacts |
| [VERIFICATION.md](docs/VERIFICATION.md) | Signature verification instructions |

## Learn More

See [README-ABOUT.md](README-ABOUT.md) for architecture, configuration, and development docs.

## License

GPL-3.0-or-later
