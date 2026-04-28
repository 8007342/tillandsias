---
tags: [wsl, windows, systemd, daemon, process-management, boot, init]
languages: [bash]
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://learn.microsoft.com/en-us/windows/wsl/wsl-config
  - https://learn.microsoft.com/en-us/windows/wsl/systemd
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# WSL daemon patterns

@trace spec:wsl-daemon-orchestration
@cheatsheet runtime/systemd-socket-activation.md

**Version baseline**: WSL2 with systemd enabled (Windows 11 22H2+, `[boot] systemd=true` in `/etc/wsl.conf`)
**Use when**: running long-lived background services (daemons, proxies, routers) inside WSL2; coordinating startup with the host; managing socket locations across Windows/Linux boundaries.

## Provenance

- WSL configuration (.wslconfig, /etc/wsl.conf) — boot options, systemd enablement, interop settings: <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>
- WSL systemd integration — automatic init, service management, unit loading from /etc/systemd/system: <https://learn.microsoft.com/en-us/windows/wsl/systemd>
- systemd.service(5) — service unit syntax, Type=notify, Restart= semantics, environment variable loading: <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- **Last updated:** 2026-04-27

## Quick reference

| Step | Action | File / Command |
|---|---|---|
| **Enable systemd** | Add boot config | `/etc/wsl.conf`: `[boot]` section with `systemd=true` |
| **Reload WSL** | Restart the distribution | `wsl --terminate <distro>` from PowerShell (force restart) |
| **Create unit** | Write service definition | `/etc/systemd/system/<daemon>.service` |
| **Enable unit** | Auto-start on WSL boot | `systemctl enable <daemon>` (inside WSL) |
| **Start unit** | Launch immediately | `systemctl start <daemon>` |
| **Monitor** | Follow logs | `journalctl -u <daemon> -f` (inside WSL) |
| **Debug** | Check status | `systemctl status <daemon>` |

## Common patterns

### Pattern 1 — Enable systemd in WSL

**`/etc/wsl.conf` (inside the WSL2 distribution):**

```ini
[boot]
systemd=true

[interop]
enabled=true
appendWindowsPath=true

[interop]
mode=drive  # enables access to Windows drives at /mnt/c, /mnt/d, etc.
```

Restart the distribution: `wsl --terminate <DistroName>` from PowerShell. On next `wsl` invocation, systemd starts as PID 1.

### Pattern 2 — Daemon with socket activation

**`/etc/systemd/system/tillandsias-router.service`:**

```ini
[Unit]
Description=Tillandsias Router Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/tillandsias-router --wsl-mode
Restart=always
RestartSec=1s
StandardOutput=journal
StandardError=journal
WatchdogSec=10s
TimeoutStartSec=30s
Environment="RUST_BACKTRACE=1"
Environment="TILLANDSIAS_WORKSPACE=/mnt/c/Users/bullo/src/tillandsias"

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable tillandsias-router
sudo systemctl start tillandsias-router
```

The daemon starts automatically when WSL boots.

### Pattern 3 — Socket location strategy (WSL paths)

```bash
# AVOID: /tmp or /var/run (ephemeral, cleared on restart)
# AVOID: /root/.something (root-owned, not accessible from Windows)
# PREFER: /run/user/1000/<name> (per-user, persistent across boots)
# PREFER: /mnt/c/Users/<USER>/.tillandsias/sockets/ (shared with Windows)
```

In a service unit:

```ini
[Service]
RuntimeDirectory=tillandsias
# Creates /run/user/1000/tillandsias (TMPFS but persistent across reboots)

ExecStart=/usr/local/bin/my-daemon --socket=/run/user/1000/tillandsias/router.sock
```

Or bind to a mounted Windows path:

```ini
[Service]
ExecStart=/usr/local/bin/my-daemon --socket=/mnt/c/Users/bullo/.tillandsias/sockets/router.sock
```

### Pattern 4 — Monitor from Windows (PowerShell)

```powershell
# Check WSL service status from PowerShell
wsl -d <DistroName> systemctl status tillandsias-router

# Stream logs from WSL
wsl -d <DistroName> journalctl -u tillandsias-router -f

# Stop/start daemon
wsl -d <DistroName> systemctl stop tillandsias-router
wsl -d <DistroName> systemctl start tillandsias-router
```

No need to enter the WSL shell; commands execute directly.

### Pattern 5 — Coordinated startup (Windows host → WSL daemon)

**Windows batch/PowerShell:**

```powershell
# Ensure WSL distribution is running
wsl -d Fedora -e true

# Wait for the router socket to appear
$socketPath = "$env:USERPROFILE\.tillandsias\sockets\router.sock"
$maxWait = 30  # seconds
$elapsed = 0
while (-not (Test-Path $socketPath) -and $elapsed -lt $maxWait) {
    Start-Sleep -Seconds 1
    $elapsed += 1
}

if (Test-Path $socketPath) {
    Write-Host "Router socket ready at $socketPath"
} else {
    Write-Host "Timeout waiting for router socket"
    exit 1
}
```

This ensures the Windows app doesn't try to connect to the router until it's fully started in WSL.

## Common pitfalls

- **Forgetting to enable systemd** — if `/etc/wsl.conf` is missing `[boot] systemd=true`, units won't auto-start. Verify with `wsl -d <distro> systemctl --version` (should show systemd version, not an error).
- **Socket paths in /tmp** — `/tmp` is backed by TMPFS and is cleared on every WSL restart. Use `/run/user/1000/` for per-user sockets, or `/mnt/c/Users/<USER>/` to share with Windows.
- **Not reloading daemon after unit edits** — after editing `.service` files, run `systemctl daemon-reload` before `systemctl start`. Missing this step loads the old unit definition.
- **Missing `After=network-online.target`** — if your daemon needs network (e.g., to fetch credentials), add `After=network-online.target` and `Wants=network-online.target` to ensure the network is up before the service starts.
- **Mixing absolute Windows paths with relative Linux paths** — use `/mnt/c/Users/...` for Windows paths inside WSL, never `C:\Users\...`. The backslashes don't escape in bash.
- **Root-owned socket, non-root daemon** — if a service runs as a regular user but the socket is created by root, the user won't have permission to write to it. Use `User=<username>` in the service unit to set ownership, or create sockets in `/run/user/1000/` (per-user TMPFS).
- **Daemon hangs during boot, blocking WSL initialization** — if a daemon has `Type=notify` but never calls `sd_notify("READY=1")`, systemd will wait `TimeoutStartSec` (default 90s) before killing it, holding up the entire WSL boot. Always send the notification or use `Type=simple` instead.
- **Journalctl from Windows PowerShell is slow** — `wsl -e journalctl -f` has a ~1s latency per line. For real-time monitoring, SSH into WSL or use the host-side podman container logs instead.

## Debugging

```bash
# Inside WSL
systemctl status tillandsias-router          # show service state + last 10 log lines
journalctl -u tillandsias-router -n 50      # show last 50 lines
journalctl -u tillandsias-router -f         # follow live (tail -f)
systemctl restart tillandsias-router         # restart the service
systemctl enable --now tillandsias-router    # enable + start immediately

# From Windows PowerShell
wsl -d <distro> systemctl is-active tillandsias-router
wsl -d <distro> systemctl is-enabled tillandsias-router
```

## See also

- `runtime/systemd-socket-activation.md` — sd_notify protocol, WatchdogSec, socket-per-connection patterns
- `runtime/unix-socket-ipc.md` — socket creation, permissions, credential passing across processes
- `runtime/container-health-checks.md` — alternative: health checks in podman containers instead of systemd
- `runtime/event-driven-monitoring.md` — systemd event subscriptions, journal queries
- `build/cargo.md` — building Rust daemons that target WSL

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: WSL is a Windows-specific feature; the forge runs on Linux. These docs are referenced during Windows development (outside the forge).
> See `cheatsheets/license-allowlist.toml` for per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the pull cache by following the recipe below.

### Source

- **Upstream URL(s):**
  - `https://learn.microsoft.com/en-us/windows/wsl/wsl-config`
  - `https://learn.microsoft.com/en-us/windows/wsl/systemd`
  - `https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html`
- **Archive type:** `single-html`
- **Expected size:** `~2.5 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/microsoft-wsl-systemd-docs/`
- **License:** Microsoft Learn (CC-BY-SA), freedesktop.org (CC0 1.0 Universal)
- **License URL:** https://learn.microsoft.com/en-us/legal/content-license

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/microsoft-wsl-systemd-docs"
mkdir -p "$TARGET_DIR"
for URL in \
  "https://learn.microsoft.com/en-us/windows/wsl/wsl-config" \
  "https://learn.microsoft.com/en-us/windows/wsl/systemd" \
  "https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html"; do
  FILENAME=$(basename "$URL")
  curl --fail --silent --show-error "$URL" -o "$TARGET_DIR/$FILENAME"
done
echo "Cached to $TARGET_DIR"
```

### Generation guidelines (after pull)

1. Read the pulled files to understand WSL boot config, systemd integration, and Windows/WSL interop.
2. If your project runs daemons on WSL (e.g., tillandsias-router), generate a project-contextual cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/wsl-daemon-patterns.md` using `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.
