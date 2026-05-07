---
tags: [podman, containers, images, cli, runtime]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://docs.podman.io/
  - https://podman.io/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman

@trace spec:agent-source-of-truth

**Version baseline**: podman 5.0.0 (Fedora 43)  
**Use when**: Managing containers, images, and enclaves; building images with Containerfile

## Provenance

- https://docs.podman.io/ — Podman documentation (canonical reference)
- https://podman.io/ — Podman official site
- **Last updated:** 2026-04-27

## Quick reference

| Task | Command |
|------|---------|
| Run container | `podman run -d --name myapp image` |
| Interactive | `podman run -it --rm image /bin/bash` |
| List running | `podman ps` |
| List all | `podman ps -a` |
| Stop | `podman stop <name>` |
| Remove | `podman rm <name>` |
| Logs | `podman logs <name>` or `-f` (follow) |
| Execute in container | `podman exec -it <name> /bin/bash` |
| Copy files | `podman cp src <name>:/dst` |
| Pull image | `podman pull image:tag` |
| Build image | `podman build -t myimage:tag .` |
| Push image | `podman push myimage:tag` |
| Watch events | `podman events --filter type=container` |

## Common patterns

**Run with Tillandsias security flags:**
```bash
podman run -d \
  --name app \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --userns=keep-id \
  --rm \
  image
```

**Map ports and volumes:**
```bash
podman run -d -p 8080:8080 -v /host/path:/container/path image
```

**Pass environment variables:**
```bash
podman run -d -e API_KEY=secret -e LOG_LEVEL=debug image
```

**Build and tag:**
```bash
podman build -t myrepo/myapp:0.1.0 .
podman tag myrepo/myapp:0.1.0 myrepo/myapp:latest
```

**Multi-stage build (Containerfile):**
```dockerfile
FROM rust:latest AS builder
WORKDIR /src
COPY . .
RUN cargo build --release

FROM scratch
COPY --from=builder /src/target/release/app /app
ENTRYPOINT ["/app"]
```

## Common pitfalls

- **Rootless networking**: By default, rootless podman only sees 127.0.0.1. Use `--network=slirp4netns` or socket exposure.
- **Volume permission issues**: Volumes mount as-is. Use `--userns=keep-id` to avoid permission errors.
- **Image tag confusion**: No tag = `latest`. Always tag explicitly: `podman build -t name:v1.0`.
- **Detached vs interactive**: `-d` runs in background; `-it` is interactive. Use `podman logs` for detached output.
- **Entrypoint vs CMD**: ENTRYPOINT is the command; CMD is args. Override with `podman run image arg1 arg2`.
- **Cleanup**: Stopped containers and unused images consume disk. Run `podman system prune`.
- **Events lag**: `podman events` is a stream; new listeners only see future events, not history.

## See also

- `runtime/forge-container.md` — Tillandsias forge container runtime environment
- `runtime/networking.md` — Container networking in enclaves
