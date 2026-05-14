---
tags: [podman, systemd, service-account, unix-socket, rootless, security, fedora, silverblue]
languages: [bash]
since: 2026-05-08
last_verified: 2026-05-08
sources:
  - https://docs.podman.io/en/stable/markdown/podman-system-service.1.html
  - https://docs.podman.io/en/v4.3/markdown/podman.1.html
  - https://www.freedesktop.org/software/systemd/man/systemd-sysusers.html
  - https://www.freedesktop.org/software/systemd/man/systemd-tmpfiles.html
  - https://www.freedesktop.org/software/systemd/man/loginctl.html
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Dedicated service account Podman

## Provenance

- Podman system service: <https://docs.podman.io/en/stable/markdown/podman-system-service.1.html>
- Podman rootless mode: <https://docs.podman.io/en/v4.3/markdown/podman.1.html>
- systemd-sysusers: <https://www.freedesktop.org/software/systemd/man/systemd-sysusers.html>
- systemd-tmpfiles: <https://www.freedesktop.org/software/systemd/man/systemd-tmpfiles.html>
- `loginctl enable-linger`: <https://www.freedesktop.org/software/systemd/man/loginctl.html>
- **Last updated:** 2026-05-08

## Use when

You want Tillandsias to own a dedicated rootless Podman runtime under a service
account instead of sharing the login user’s Podman state.

## Why this is a sane Unix boundary

- Rootless Podman is explicitly user-scoped.
- `podman system service` exposes a Unix socket and is designed to work with
  systemd socket activation.
- `systemd-sysusers` is the documented way to allocate a system user and group.
- `loginctl enable-linger` keeps the user manager alive after logout so the
  service account can keep long-running services available.
- `systemd-tmpfiles` is the documented way to create and clean runtime
  directories and transient files.

## Recommended shape

| Concern | Recommended mechanism | Notes |
|---|---|---|
| Account creation | `systemd-sysusers` or distro package user creation | Create one dedicated `tillandsias` user/group |
| Rootless Podman API | `podman system service` on `unix://$XDG_RUNTIME_DIR/podman/podman.sock` | Use socket activation, not a permanent daemon |
| Runtime lifetime | `loginctl enable-linger tillandsias` | Keeps the user manager available after logout |
| Runtime cleanup | `systemd-tmpfiles` | Clean service-owned temp/state paths on uninstall or boot |
| Host exposure | Unix socket permissions only | Avoid TCP unless mTLS is mandatory |
| Policy hardening | SELinux on Fedora, AppArmor where applicable | Keep policy local to the service account boundary |

## Practical rules

- Do not mount or expose the socket over the network unless TLS/mTLS is part of
  the contract.
- Do not use the login user’s `libpod` state if the intent is a dedicated
  service account.
- Keep container ownership, socket ownership, and runtime directories all under
  the same service account.
- Use subordinate UID/GID ranges for rootless container user namespaces.

## Example service-account flow

```bash
# System admin creates the service account once
sudo systemd-sysusers --cat-config | sed -n '1,80p'

# Enable lingering so the user manager survives logout
sudo loginctl enable-linger tillandsias

# Start the rootless Podman socket for that account
sudo -u tillandsias systemctl --user enable --now podman.socket

# Client uses the dedicated socket
export CONTAINER_HOST=unix:///run/user/<tillandsias-uid>/podman/podman.sock
```

### Foreground service model

The Tillandsias headless orchestrator should stay in the foreground and let
systemd supervise it. Do not double-fork or self-daemonize the binary.

```ini
# ~/.config/systemd/user/tillandsias.service
[Unit]
Description=Tillandsias Headless Orchestrator
After=podman.socket
Wants=podman.socket

[Service]
Type=simple
Environment="TILLANDSIAS_PODMAN_REMOTE_URL=unix://%t/podman/podman.sock"
ExecStart=%h/.local/bin/tillandsias --headless %h/src/tillandsias
Restart=always
RestartSec=1s

[Install]
WantedBy=default.target
```

## Cleanup model

- Uninstall should remove the system user or disable the unit, depending on
  whether the account is distro-owned or app-owned.
- Temporary files belong in systemd-managed runtime or tmpfiles-managed paths
  so uninstall can remove them deterministically.
- Service-owned state should not be mixed with the login user’s default
  Podman storage unless the app is explicitly running in developer mode.

## Tillandsias inference

For this project, a dedicated service account is the right boundary for the
installed runtime if the goal is isolation and repeatable Unix permissions.
Developer builds can still use the existing user-owned toolbox path, but the
installed runtime should be able to target a dedicated socket with no shared
login-user Podman state.
