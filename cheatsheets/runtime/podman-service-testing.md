---
tags: [podman, api, service, socket, rootless, testing]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-service.1.md
  - https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-connection.1.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman service testing

## Provenance

- Podman service man page: <https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-service.1.md> - describes the API service, socket activation, rootless default socket path, and security model.
- Podman connection man page: <https://github.com/containers/podman/blob/main/docs/source/markdown/podman-system-connection.1.md> - describes how clients record service destinations and point at Podman sockets.
- **Last updated:** 2026-05-06

## Use when

You need to test a client or wrapper that talks to Podman through the service socket instead of shelling out to `podman run` directly.

## Quick reference

| Seam | Default path | Why it matters |
|---|---|---|
| Rootless API socket | `$XDG_RUNTIME_DIR/podman/podman.sock` | The service can be activated on demand and stays user-scoped |
| Rootful API socket | `/run/podman/podman.sock` | The service can be exposed on a system socket for rootful control-plane tests |
| Connection registry | `~/.config/containers/podman-connections.json` | Podman tracks named service destinations here |

## Testing guidance

- Use `podman system service --time 0 unix:///path/to.sock` when you need a persistent local API endpoint.
- Use `systemctl --user start podman.socket` or the equivalent system socket when you want socket activation instead of a long-lived daemon.
- Use `podman system connection list` to confirm the client is pointing at the intended destination.
- Do not treat the service socket as a safety boundary. The API gives broad control over the user's Podman authority.

## See also

- `test/podman-testing.md` - upstream Podman test strata and our mock-vs-real split
- `runtime/unix-socket-ipc.md` - socket IPC basics
- `runtime/systemd-socket-activation.md` - when the socket should be activated on demand
