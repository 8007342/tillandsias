---
tags: [systemd, socket-activation, service-management, process-supervision, unix-sockets, systemd-notify]
languages: [rust]
since: 2026-04-27
last_verified: 2026-04-27
sources:
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html
  - https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html
  - https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
authority: high
status: current

# v2 — tier classification (cheatsheets-license-tiered)
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# systemd socket activation

@trace spec:container-health, spec:wsl-daemon-orchestration
@cheatsheet runtime/unix-socket-ipc.md

**Version baseline**: systemd 250+ (freedesktop.org standard)
**Use when**: building a daemon (like tillandsias-router) that systemd should supervise; coordinating startup readiness with health checks; implementing socket handoff for lazy startup.

## Provenance

- systemd.service(5) — service unit configuration, Type=notify, WatchdogSec, StandardOutput/StandardError redirection: <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html>
- systemd.socket(5) — socket unit syntax, Accept=, socket-per-connection vs. single-instance modes: <https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html>
- sd_notify(3) — Rust crate bindings, notification protocol (READY=1, RELOADING=1, STOPPING=1, STATUS=<msg>, ERRNO=<errno>): <https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html>
- **Last updated:** 2026-04-27

## Quick reference

| systemd feature | Purpose | Use case |
|---|---|---|
| `Type=notify` | Service must call `sd_notify("READY=1")` to signal readiness | daemon bootstrapping, health gating |
| `WatchdogSec=5s` | Restart if daemon doesn't call `sd_watchdog_enabled()` + `sd_notify("WATCHDOG=1")` every N sec | liveness probe, automatic restart on hang |
| `Restart=always` | Always restart on exit (any code). Pair with `RestartSec=0.1s` for tight retry loop | resilient long-lived daemons |
| `StandardOutput=journal` | Send stdout → systemd journal (`journalctl -u <service>`) | centralized logging |
| `StandardError=journal` | Send stderr → journal (separate stream) | error observability |
| `ExecStartPost=` | Run command after main daemon starts; fail the service if it exits non-zero | health check gates |

## Common patterns

### Pattern 1 — Rust daemon with sd_notify

```rust
use sd_notify::notify;

fn main() {
    // ... setup ...
    
    // Signal readiness to systemd (Type=notify service)
    if let Err(e) = notify(true, &[NotifyState::Ready]) {
        eprintln!("failed to notify systemd: {}", e);
        // continue anyway; systemd will timeout
    }
    
    // main event loop
    loop {
        // ... handle connections, process work ...
        
        // Periodic watchdog ping (if WatchdogSec is set in unit)
        if let Err(e) = notify(true, &[NotifyState::Watchdog]) {
            eprintln!("watchdog ping failed: {}", e);
        }
    }
}
```

Call `sd_notify` early in `main()` (after listening on sockets, before accepting work) to avoid systemd timeout during slow initialization.

### Pattern 2 — socket-activated systemd unit pair

**`/etc/systemd/system/my-daemon.socket`:**

```ini
[Unit]
Description=My daemon socket

[Socket]
ListenStream=127.0.0.1:5555
Accept=no

[Install]
WantedBy=sockets.target
```

**`/etc/systemd/system/my-daemon.service`:**

```ini
[Unit]
Description=My daemon
Requires=my-daemon.socket
After=my-daemon.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/my-daemon
Restart=always
StandardOutput=journal
StandardError=journal
WatchdogSec=10s
TimeoutStopSec=5s

[Install]
WantedBy=multi-user.target
```

systemd passes the socket FD as `LISTEN_FD=3` (or higher) and `LISTEN_PID=$PID`. The daemon calls `sd_listen_fds()` to claim inherited sockets, then `sd_notify("READY=1")` to go live.

### Pattern 3 — Readiness gate with ExecStartPost

```ini
[Service]
Type=notify
ExecStart=/usr/local/bin/my-daemon
ExecStartPost=curl --fail http://localhost:5555/health
Restart=always
RestartSec=0.5s
```

If the health check fails, the unit enters failed state. systemd will retry after RestartSec.

### Pattern 4 — Watchdog with timeout

```ini
[Service]
Type=notify
ExecStart=/usr/local/bin/my-daemon
WatchdogSec=5s
TimeoutStartSec=30s
```

Daemon must call `sd_notify("WATCHDOG=1")` at least every 5 seconds or systemd sends SIGKILL. `TimeoutStartSec=30s` means if READY is not signaled within 30s, the unit fails.

### Pattern 5 — Multiple socket units per service

```ini
# /etc/systemd/system/my-daemon.socket
[Socket]
ListenStream=127.0.0.1:5555
ListenUnixSocket=/run/my-daemon/socket
Accept=no
```

The daemon receives BOTH sockets. Call `sd_listen_fds()` to iterate; return value is the count. The first is always `LISTEN_FD=3`.

## Common pitfalls

- **Forgetting `sd_notify("READY=1")`** — systemd waits `TimeoutStartSec` (default 90s) for the notification, then kills the process. Set Type=simple if you don't need readiness gating, or add the notify call.
- **Not handling `LISTEN_PID`** — after fork/exec in some runtimes, the PID changes. Verify `LISTEN_PID` matches current PID before claiming sockets via `sd_listen_fds()`.
- **Watchdog pings too infrequent** — if WatchdogSec=5s, ping at least every 5s (safer: every 2–3s). Missing a deadline causes SIGKILL. Log each ping for debugging.
- **ExecStartPost blocking the entire unit** — if your health check runs for 10s and fails once then succeeds, the unit will restart during the wait. Make checks fast (<1s) or move them into a separate `ExecStartCheck` hook (systemd 247+).
- **Ignoring SIGTERM before readiness** — systemd may SIGTERM a starting daemon if the system is shutting down. Catch SIGTERM, log gracefully, and exit quickly even during initialization.
- **Socket `/run/` paths missing parent dir** — for `ListenUnixSocket=/run/my-daemon/socket`, manually mkdir and set perms on `/run/my-daemon/` (or use `RuntimeDirectory=my-daemon` in the service unit).
- **Mixing Type=notify and Type=forking** — pick ONE. Type=notify is simpler for Rust; Type=forking is for legacy daemons that double-fork. systemd modern defaults are notify.

## See also

- `runtime/unix-socket-ipc.md` — socket creation, credential passing, abstract vs. path-based sockets
- `runtime/container-health-checks.md` — liveness/readiness patterns in podman containers
- `runtime/event-driven-monitoring.md` — systemd journal querying, event subscriptions
- `languages/rust.md` — Rust idioms, tokio async patterns, error handling

## Pull on Demand

> This cheatsheet's underlying source is NOT bundled into the forge image.
> Reason: upstream is freedesktop.org (standards body, high authority) but bundling full HTML docs exceeds image size targets.
> See `cheatsheets/license-allowlist.toml` for per-domain authority.
>
> When you need depth beyond the summary above, materialize the source into
> the per-project pull cache by following the recipe below. The proxy
> (HTTP_PROXY=http://proxy:3128) handles fetch transparently — no credentials
> required.

### Source

- **Upstream URL(s):**
  - `https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html`
  - `https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html`
  - `https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html`
- **Archive type:** `single-html`
- **Expected size:** `~2 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/freedesktop.org/systemd-docs/`
- **License:** freedesktop.org (CC0 1.0 Universal — permissive)
- **License URL:** https://www.freedesktop.org/wiki/Licensing/

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET_DIR="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/freedesktop.org/systemd-docs"
mkdir -p "$TARGET_DIR"
for URL in \
  "https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html" \
  "https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html" \
  "https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html"; do
  FILENAME=$(basename "$URL")
  curl --fail --silent --show-error "$URL" -o "$TARGET_DIR/$FILENAME"
done
echo "Cached to $TARGET_DIR"
```

### Generation guidelines (after pull)

1. Read the pulled files to understand systemd unit syntax, sd_notify protocol, and socket-activation mechanics.
2. If your project extensively uses systemd (e.g., tillandsias-router on WSL or Linux), generate a project-contextual cheatsheet at `<project>/.tillandsias/cheatsheets/runtime/systemd-socket-activation.md` using `cheatsheets/TEMPLATE.md` as the skeleton.
3. The generated cheatsheet MUST set frontmatter: `tier: pull-on-demand`, `summary_generated_by: agent-generated-at-runtime`, `committed_for_project: true`.
4. Cite the pulled sources under `## Provenance` with `local: <cache target above>`.
