## Context

The forge image is built via `build-image.sh` which calls `nix build` inside the `tillandsias-builder` toolbox, then `podman load`. This takes 1-5 minutes on first run (Nix cache download) and ~15s on subsequent rebuilds. Currently, the build only triggers when a user tries to attach to a project and the image doesn't exist.

## Goals / Non-Goals

**Goals:**
- Zero-wait first experience: images pre-built before user opens tray
- `tillandsias init` as an explicit CLI command for manual pre-building
- Installer triggers init as background task
- Prevent duplicate concurrent builds via lock file
- Tray app waits for in-progress build instead of starting a new one

**Non-Goals:**
- Streaming build progress to the tray UI (future work)
- Pre-pulling base images (Nix handles this internally)
- Building project-specific images (only the standard forge image)

## Decisions

### Decision 1: `tillandsias init` as a CLI mode

**Choice**: Add `CliMode::Init` alongside `Tray` and `Attach`. When invoked, it runs the embedded `build-image.sh` for each image type (forge, web), reports progress, and exits.

### Decision 2: Build lock file

**Choice**: Before starting a build, write a lock file at `$XDG_RUNTIME_DIR/tillandsias/build-<image>.lock` containing the PID. Any other process (tray or CLI) that wants to build checks this lock first:
- Lock exists + PID alive → wait for it (poll every 2s)
- Lock exists + PID dead → stale lock, take over
- No lock → acquire and build

This reuses the same pattern as the singleton guard.

### Decision 3: Installer background init

**Choice**: At the end of `install.sh`, after printing "Run: tillandsias", spawn `tillandsias init &` as a background process. The user can start using the tray immediately — if the init hasn't finished, the tray waits for it.

### Decision 4: Tray startup check

**Choice**: On tray startup, if the forge image doesn't exist:
1. Check if a build lock is active (init running in background)
2. If yes, show "Preparing environment..." in the menu and poll until done
3. If no, trigger the build ourselves (same as today, but with lock)

## Risks / Trade-offs

- **[Init runs Nix build]** → Requires the builder toolbox. On a fresh install without the toolbox, init creates it first (same as today's build flow).
- **[Background init may fail silently]** → Mitigated: the tray app will detect the missing image and retry. Init failure is logged but doesn't block the user.
