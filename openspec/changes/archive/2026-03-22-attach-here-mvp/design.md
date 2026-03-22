## Context

The forge project builds a full-featured container image with Nix flakes. For Tillandsias MVP, we need something simpler — a Containerfile-based Fedora Minimal image that can be built locally with `podman build`. The image must include OpenCode (AI coding agent), OpenSpec (spec-driven workflow), and Nix (reproducible builds).

## Goals / Non-Goals

**Goals:**
- "Attach Here" builds image on first use, caches it, and launches container
- Container runs OpenCode as the primary interface (terminal-based)
- User sees a terminal window with OpenCode ready to work on their project
- Zero configuration needed — works with defaults

**Non-Goals:**
- Custom image from registry (default is local-build)
- Ollama/local inference (future — needs GPU passthrough testing)
- Web UI for OpenCode (terminal-first MVP)
- Multiple image tiers (one Fedora Minimal image for now)

## Decisions

### D1: Containerfile-based build (not Nix)

Simpler for MVP. `podman build` is available everywhere podman is. Nix-based images come later as an optimization.

### D2: Fedora Minimal base

`registry.fedoraproject.org/fedora-minimal:latest` — small (~100MB), glibc-based (OpenCode and Ollama work), good package coverage via `microdnf`.

### D3: Image name and caching

Image name: `tillandsias-forge:latest`. Built once with `podman build`, cached in local image store. Rebuilt only on `--toolbox-reset` or explicit rebuild.

### D4: Container launch opens terminal

"Attach Here" starts the container detached, then opens the user's default terminal emulator running `podman exec -it <name> /usr/local/bin/entrypoint.sh`. This gives the user a real terminal with OpenCode.

On Linux: detect terminal via `$TERMINAL`, `x-terminal-emulator`, or fall back to known terminals (gnome-terminal, konsole, xfce4-terminal, alacritty, kitty, foot).

### D5: User UID mapping

Container user `forge` (UID 1000) maps to host user via `--userns=keep-id`. Volume permissions work without chown.

### D6: Mount strategy

| Host | Container | Purpose |
|------|-----------|---------|
| `~/src/<project>` | `/home/forge/src` | Project directory (rw) |
| `~/.cache/tillandsias` | `/home/forge/.cache/tillandsias` | Shared cache (nix, settings) |

### D7: Entrypoint behavior

1. Create cache dirs if missing
2. Install OpenSpec if not present (deferred install)
3. Show welcome banner with project name
4. Launch OpenCode in the project directory
5. On exit, container dies (--rm)
