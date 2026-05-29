---
tags: [podman, containers, images, runtime, cli]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-12
sources:
  - https://podman.io/docs
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman Cheatsheet

## Provenance

- **URL**: https://podman.io/docs
- **Last updated**: 2026-04-29

## Source-backed notes

- Rootless Podman defaults to `${XDG_RUNTIME_DIR}/podman/podman.sock` for the service socket.
- `podman --remote` can connect over Unix sockets, SSH, or TCP endpoints.
- Rootless Podman stores temporary configuration data under `${XDG_RUNTIME_DIR}/containers`.

## Basic Commands

### Image Management

```bash
# List images
podman images

# Remove image
podman rmi <image_name>

# Build image
podman build -t <tag> -f Containerfile .

# View build logs
podman logs <container_id>
```

### Container Management

```bash
# List running containers
podman ps

# List all containers (including stopped)
podman ps -a

# Stop container
podman stop <container_id>

# Remove container
podman rm <container_id>
```

### Troubleshooting

```bash
# Check podman system info
podman system info

# View container logs
podman logs <container_id>

# Check disk usage
podman system df
```

## Sources of Truth

- `docs/cross-platform-builds.md` — Cross-platform build strategy
- `openspec/specs/init-command/spec.md` — Init command specification
- `test/podman-testing.md` — how to split Podman-related tests between fake subprocess checks and real runtime checks
- `runtime/podman-service-testing.md` — how to test the Podman API / socket seam
