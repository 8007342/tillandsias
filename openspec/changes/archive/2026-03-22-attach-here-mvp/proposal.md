## Why

The tray app detects projects and shows menus, but "Attach Here" doesn't actually do anything yet. The MVP needs to launch a real development environment — a Fedora Minimal container with OpenCode, OpenSpec, and Nix pre-installed — so a user can click one button and start working on any project.

The container image is built and cached locally by Tillandsias itself. No external image registry is needed for the default experience. The forge project provides the pattern but Tillandsias ships its own minimal image definition.

## What Changes

- **New Containerfile** at `images/default/Containerfile` — Fedora Minimal with OpenCode, OpenSpec, Nix, and essential dev tools
- **New entrypoint** at `images/default/entrypoint.sh` — bootstraps environment, starts OpenCode as foreground process
- **Image build/cache logic** in `tillandsias-podman` — build image on first "Attach Here", cache for subsequent launches
- **Wire "Attach Here" handler** in the tray app — build image if needed, start container with mounts and security flags, open terminal
- **Terminal launch** — open host terminal with `podman attach` or `podman exec` into the running container

## Capabilities

### New Capabilities
- `default-image`: Fedora Minimal container image with OpenCode, OpenSpec, and Nix

### Modified Capabilities
- `environment-runtime`: Wire Attach Here to actually launch containers
- `podman-orchestration`: Add image build/cache logic

## Impact

- New files: `images/default/Containerfile`, `images/default/entrypoint.sh`, `images/default/opencode.json`
- Modified: `crates/tillandsias-podman/src/client.rs` (add build_image), `src-tauri/src/handlers.rs` (wire attach)
- First "Attach Here" takes ~60s (image build), subsequent launches are <5s
