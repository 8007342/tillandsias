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
| v0.3.260724.1 (daily, PRE) | First daily carrying the full 07-23/24 stability wave: git-mirror Vault Agent auto-auth (48h relay survives token max-TTL without restart, order 424 slice), codex worker state persistence + digest-stable instance identity (ends the 281s first-run replay), WSL probe timeouts non-destructive (one bounded recovery, damage requires proof), OpenCode credential-free vault auth (431), delegated-result channel authoritative capture (429 slice), diagnostics no-spill closure (453) | Squid fail-closed cache policy (DONT_VERIFY_PEER removed — bumped traffic now verifies origin; single release-asset CDN bump target); harness warm-launch byte-cheap + cold-miss download lock; order 463 soak fixes staged (enclave-URL vault endpoint in-VM); ledger: dup-462 renumber, 465-477 filed |
| v0.3.260723.1 (daily, PRE) | The order-455 PASS-candidate (first published build >= 58b58322, cut on the Windows lane's coordinator ask): Windows v0.4 lane CODE-COMPLETE — WSL-absent runtime as a first-class state with curated background `wsl --install` (windows-260722-1), app identity + single Installed-Software entry (windows-260722-3), headless --github-login CA-bundle mount, curated connection chips; first complete live Windows full-stack chain (host tray -> WSL2 -> podman -> forge -> in-forge opencode meta-orchestration) validated at ~5% infra overhead | Two P1s from the 455 smoke: shipped .ps1 saved-then-run parsed into a DIFFERENT program (BOM-less UTF-8 em-dash -> CP-1252 smart quote; all .ps1 pure-ASCII + whole-file litmus) and rootfs download quantized to ~40 KB/s by the 100ms GUI-pump executor (4 MiB BufWriter + dedicated bg runtime; A/B 25min-DNF -> 2.9s, wipe-to-VM-ready 72s); 313 SOLVED (root-owned models-mount EACCES, not proxy warm-up); mirror readiness gate waits for SEEDED not merely reachable; forge-HOME/container-HOME test collision |
| v0.3.260722.1 (daily, PRE) | v0.4 stability-bundle candidate for the order-455 cross-platform smokes: 3 drain waves (9 packets — vault unseal gates, guest crashloop detection on all platforms, 3-state login, ephemeral guest reset via CLI, 443 shared-stack refcount COMPLETE), UX curation governance (Tlatoani-gated, tray-ux spec) with the unapproved reset-guest leaf removed, order-459 official curl-install harness channel | first release PR gated by real CI (fmt/workspace + NEW windows/macos cfg-typecheck lanes — caught 4 latent type errors on maiden run); review hardening: podman-ps failure now leak-not-destroy; 313 CA/path pins; stale-ledger flips (281) |
| v0.3.260721.1 (daily, PRE) | v0.4 stabilization pre-release for cross-platform curl-install smoke (order 455): committed bootstrap for all harnesses (AGENTS.md + skills-farm repair), ./repeat --model delegation passthrough, coordinator triage tightening v0.4 to the Linux stability bundle | order 454 mirror unborn-HEAD (every-harness checkout crash) + 452 slice 2 launch readiness gate + reused-mirror re-reconcile; 449 periodic mirror reconcile (host direct-push stranding); 447 stale-staging litmus false-red; 444 launch-artifact guard; receive-pack blocker closed (450) |
| v0.3.260719.1 (daily) | Windows crash-loop class closed at the host tier (operator field report 2026-07-18: fresh iex install reached the Fedora download then crash-looped with flashing terminals and zero diagnostics): windows-event-logging spec REACTIVATED as a real Event Log relay (all INFO/WARN/ERROR; the archived Tauri impl never called ReportEventW), order 417 bounded keepalive respawn (backoff + give-up + tray surfacing), order 418 registered-distro exec probe + one-shot ephemeral self-heal, order 419 launch-failure taxonomy (kernel-update / 0x80370102 / disk-full classification, pre-import host disk gate) + graceful-launch-failure spec requirement + litmus, order 420 auto-captured redacted diagnostics bundle. | Singleton guard: fs2 busy-lock misclassified as hard error on Windows (pre-existing test failing at HEAD) + forever-blocking second-instance hang → bounded deadline poll; three --diagnose spawns flashing consoles (CREATE_NO_WINDOW); fixed-5s connect loops → capped exponential backoff; order-413 ledger duplicate `events:` key merged (416 criterion 1). |
| v0.3.260716.7 (daily) | Windows-lane unblock set: order 382 (guest gitdir handed to forge uid), order 350 root cause (git-less guest push channel), windows-260716-2 (refuse credential-less mirror, fail-loud mint), vault as structural forge-lane prerequisite, router/web on-demand ensure. Orders 383 (vault generate-root seam) + 374 litmus shaped. First macOS in-forge meta-orchestration smoke PASS in the range. | Three nested-runtime panics (tray tools/call, order-235 backoff sleep, vault_bootstrap runtime seam — one RuntimeOrHandle cure); tray dead-on-arrival stale snapshot + silent launch refusals; clippy attribute displaced by merge. Evidence: ci-full 16/17 — single fail is host-local vault root-token skew (order 383), same code green on the macOS lane same day. |
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
