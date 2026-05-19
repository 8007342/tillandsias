---
tags: [linux, podman, systemd, logind, rootless, runtime, desktop]
languages: [bash]
since: 2026-05-17
last_verified: 2026-05-17
sources:
  - https://www.freedesktop.org/software/systemd/man/pam_systemd.html
  - https://www.freedesktop.org/software/systemd/man/loginctl.html
  - https://docs.podman.io/en/latest/markdown/podman.1.html
  - https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
  - https://docs.podman.io/en/v5.0.3/markdown/podman-system-service.1.html
authority: high
status: current
tier: pull-on-demand
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
pull_recipe: see-section-pull-on-demand
---

# Linux user-session Podman runtime

@trace spec:environment-runtime, spec:podman-orchestration, spec:browser-isolation-tray-integration, spec:cli-mode
@cheatsheet runtime/podman-idiomatic-patterns.md, runtime/systemd-socket-activation.md

**Use when**: documenting the Linux runtime boundary for Tillandsias on a real desktop session or in a supervised headless service account.

## Provenance

- `pam_systemd` creates the logind-owned user runtime directory and sets `XDG_RUNTIME_DIR`.
- `loginctl enable-linger` keeps a user manager alive after logout when a background service must persist.
- Podman rootless mode uses user-owned storage and sockets; the runtime should not fake `/run/user/<uid>`.
- `podman system service` and Podman user units are the standard way to supervise long-lived container services.

## Runtime lanes

### 1. Desktop user session

This is the normal Fedora Workstation case:

- the user logs in through a real desktop session;
- `systemd --user` and logind own the runtime state;
- `XDG_RUNTIME_DIR` exists and is writable;
- Tillandsias launches rootless Podman directly as the logged-in user.

If that session is missing, the launcher should fail with an actionable error instead of inventing runtime state.

### 2. Headless service account

Use this lane only when the install is meant to be supervised as a background service:

- create a dedicated `tillandsias` user and group;
- manage the runtime with `systemd --user`;
- enable linger if the service must stay up after logout;
- keep Podman rootless and user-owned;
- keep service-account state separate from the desktop user's session.

### 3. Dev/test runtime

Use shell wrappers and litmuses to isolate storage and fake Podman when needed:

- good for fast reproducible tests;
- not valid as a production runtime model;
- must not leak into user-facing launch paths.

## Common checks

```bash
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
test -n "$XDG_RUNTIME_DIR" && test -w "$XDG_RUNTIME_DIR"
podman info --format '{{.Host.Security.Rootless}}'
loginctl show-user "$USER" -p Linger
```

## Failure meanings

| Symptom | Likely meaning | First fix |
|---|---|---|
| `chmod /run/user/.../libpod: read-only file system` | The runtime is not backed by a writable logind user session | Use a real desktop login session or a supervised user service |
| `short-name resolution enforced but cannot prompt without a TTY` | The image tag is missing locally and Podman is trying to ask interactively | Preflight the image or use a fully resolved local tag |
| rootless container launch fails in a service | Missing subuid/subgid, linger, or user-service ownership | Repair the user account/service model |

## See also

- `cheatsheets/runtime/podman-idiomatic-patterns.md`
- `cheatsheets/runtime/systemd-socket-activation.md`
- `cheatsheets/runtime/container-health-checks.md`

## Pull on Demand

> This cheatsheet is intentionally not bundled into the forge image.
> It documents host-runtime ownership and service-account supervision that
> depend on the local Linux session model and should be read from the repo.

### Source

- **Upstream URL(s):**
  - `file://cheatsheets/runtime/linux-user-session-podman.md`
- **Archive type:** `directory-recursive`
- **Expected size:** `~1 MB extracted`
- **Cache target:** `~/.cache/tillandsias/cheatsheets-pulled/$PROJECT/local/linux-user-session-podman`
- **License:** project-docs
- **License URL:** `https://opensource.org/licenses/MIT`

### Materialize recipe (agent runs this)

```bash
set -euo pipefail
TARGET="$HOME/.cache/tillandsias/cheatsheets-pulled/$PROJECT/local/linux-user-session-podman"
mkdir -p "$TARGET"
cp cheatsheets/runtime/linux-user-session-podman.md "$TARGET/index.md"
```

### Generation guidelines (after pull)

1. Treat this cheat sheet as a runtime ownership reference, not a bundled
   library document.
2. Keep the three runtime lanes distinct in any downstream project notes:
   desktop user session, headless service account, dev/test wrapper.
3. Update the linked specs and methodology notes if the runtime ownership
   contract changes again.
