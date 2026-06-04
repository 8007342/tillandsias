# Tillandsias

*Create. Work. Run. Stop.*

A portable Linux binary that makes software appear — safely, locally, reproducibly. Runs headless (CLI/automation) or with optional native GTK tray.

> **Linux only.** Tillandsias v0.2 is Linux-native (musl-static, rootless podman, GTK4 tray). macOS and Windows wrappers are planned — see [Platform support](#platform-support) below.

## Install

**Fedora Silverblue / Kinoite / uBlue and other x86_64 Linux desktops**
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install.sh | bash
```

The installer downloads the musl-static `tillandsias-linux-x86_64` binary to a user-owned bin directory, usually `~/.local/bin/tillandsias`. When that directory is not on your shell `PATH`, the installer adds an idempotent PATH block to your shell startup files and prints the absolute command you can run immediately.

It does not layer packages, install Chromium, install GTK/WebKit, require a toolbox, or require a Tillandsias source checkout. Podman is the only runtime dependency. The released binary carries the runtime image sources it needs and materializes them under your user data directory on first use.

On Fedora Silverblue-family systems, Podman is usually already present. If it is missing:

```bash
sudo rpm-ostree install podman
systemctl reboot
```

<details>
<summary>Direct download</summary>

| Download |
|----------|
| [tillandsias-linux-x86_64](https://github.com/8007342/tillandsias/releases/latest/download/tillandsias-linux-x86_64) |

</details>

## Run

Initialize the local runtime images after installing:

```bash
tillandsias --init --debug
```

If your current shell has not reloaded the installer PATH update yet, use the absolute path printed by the installer, for example `~/.local/bin/tillandsias --init --debug`.

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
- [Podman](https://podman.io) (rootless). The curl installer only checks for it and prints the distro-specific install command when it is missing.

No Tillandsias checkout, Rust toolchain, Nix, toolbox, or host Chromium install is required for the installed user runtime.

**For Tray Mode (optional):**
- GTK4 runtime — usually pre-installed on desktop systems
- For GNOME: [AppIndicator extension](https://extensions.gnome.org/extension/615/appindicator-support/) for system tray

**Note**: Headless mode requires no GTK or display server. Tray mode is optional and auto-disabled if GTK is unavailable.

## Platform support

### Linux

First-class. Everything in this README applies as-is. The Linux binary is the source of truth for behavior, security model, and the test matrix.

### macOS

**Coming soon / Beta.** Native AppKit menu-bar tray around a Fedora-hosted
VM via Apple's Virtualization.framework. The VM runs the same headless
tillandsias + podman enclave as Linux; the tray surfaces project actions
through the macOS status bar and Terminal.app.

**Install** (experimental):
```bash
curl -fsSL https://github.com/8007342/tillandsias/releases/latest/download/install-macos.sh | bash
```

**Requirements**: macOS 14+ (Sonoma/Sequoia) on Apple Silicon (M1/M2/M3).
Uses virtio-vsock for host-guest communication.

### Windows

**Beta** (since `v0.2.260530.1`, 2026-05-30). Native Win32 NotifyIcon tray
around a WSL2-hosted Fedora utility VM. The VM runs the same headless
tillandsias + podman enclave as Linux; the tray surfaces project actions
(Open Shell, GitHub login, agent selection) through Windows Terminal +
`wsl.exe`.

**Install** (from an unzipped
[`tillandsias-tray-<version>-windows-x64.zip`](https://github.com/8007342/tillandsias/releases/latest)
on the releases page):

```powershell
scripts\install-windows.ps1 -Launch                # menu-only dev mode
scripts\install-windows.ps1 -Provision -Launch     # real WSL provisioning
scripts\install-windows.ps1 -Uninstall             # minimal removal
scripts\install-windows.ps1 -Purge                 # full cleanup (wsl --unregister + caches)
```

**Requirements**: Windows 10/11 with WSL2 (`wsl --install` then reboot).

**Diagnostics**: every tray binary surface mirrors the Linux + macOS
behavior. `tillandsias-tray.exe --diagnose --json` emits a bundled health
report (16 keys + wire sub-object); `--help` documents all CLI modes +
env vars + the GUI-subsystem stdio-capture pattern. Two PowerShell
consumers ship alongside: `scripts\tray-diagnose.ps1` (live-runtime
health check) and `scripts\diagnose-windows.ps1` (pre-tray host facts).
See `cheatsheets/runtime/windows-tray-diagnostics.md` for the full
diagnose JSON schema + canonical consumer patterns.

**Contributing**: see [`docs/CONTRIBUTING-WINDOWS.md`](docs/CONTRIBUTING-WINDOWS.md)
for the dev-cycle commands, the 3-layer test pyramid, the drift-protection
checklist (what to update when a `DiagnoseReport` field gets added), and
the common Windows-specific pitfalls (PowerShell stderr-wrap, ASCII-only
scripts, GUI-subsystem stdio quirks).

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
