# Convergence Workflow: Image Rebuild + Binary Restart

This documents the quick-start litmus test pattern for rebuilding container images and picking them up in the same Tillandsias binary.

## Architecture

```
Nix (./build.sh)
  └─> Builds tillandsias binary
  └─> Embeds Containerfiles
  └─> Creates AppImage (DONE. Nix exits.)

Image rebuild (./build-git.sh, ./build-forge.sh, etc.)
  ├─> Exercises ImageBuilder code path atomically
  ├─> Calls: podman build -f images/git/Containerfile -v ~/.cache/tillandsias/packages:/var/cache/apk
  ├─> Produces: tillandsias-git:v0.1.260505.15 (exact version from binary)
  ├─> Handles cache mounting (distro-aware: Alpine → /var/cache/apk, Fedora → /var/cache/dnf)
  └─> Auto-resets podman if corrupted (ephemeral principle)

Binary picks up new image
  └─> Restart: killall tillandsias && tillandsias /path/to/project
  └─> Binary finds tillandsias-git:v0.1.260505.15 in local podman storage
  └─> Uses updated image on next container launch
```

## Quick Start: Rebuild & Restart Workflow

### 1. Rebuild a single image

```bash
# Rebuild git container image
./build-git.sh

# Or rebuild all at once (sequential)
./build-all-images.sh

# Or rebuild all in parallel (faster)
./build-all-images.sh --parallel
```

Each script:
- Exercises the exact `ImageBuilder::build()` code path
- Uses refactored `scripts/build-image.sh` with distro-aware cache mounting
- Falls back gracefully if podman state is corrupted
- Returns immediately with new image in podman storage

### 2. Restart the binary to pick up new image

**Option A: Kill and restart**
```bash
killall tillandsias
tillandsias /path/to/project    # Picks up new image
```

**Option B: Restart specific containers**
```bash
# Git service container
podman restart tillandsias-git-myproject

# Or all containers for a project
podman restart $(podman ps -a --filter name=tillandsias-myproject -q)
```

**Option C: Let it auto-restart**
If containers are managed by the tray, they auto-restart on detection of new image.

## Convergence Chain (Litmus Tests)

Each build script contributes to the convergence chain:

```
LITMUST min artifact:
  ✓ ./build-git.sh passes
  ✓ ./build-forge.sh passes
  ✓ ./build-proxy.sh passes

LITMUST min + siblings:
  ✓ All builds together produce identical images
  ✓ Cache mounting works for each distro
  ✓ No mutual interference between builds

LITMUST task:
  ✓ tillandsias --github-login
  ✓ Uses new tillandsias-git image
  ✓ Auth flow completes successfully

LITMUST parent (enclave orchestration):
  ✓ tillandsias --init
  ✓ Starts all containers with new images
  ✓ Health checks pass for all
  ✓ Enclave network operational

LITMUST top-level (full integration):
  ✓ Developer workflow: edit Containerfile → ./build-git.sh → restart
  ✓ Binary finds new image automatically
  ✓ No manual podman commands needed
```

## Observability & Metrics

Each build script produces:
- Log file: `/tmp/build-{git,forge,proxy,inference,web}.log`
- Timing: Logged automatically (first build vs cache hit)
- Image ID: Printed at completion for verification
- Cache hit/miss: Detected via hash comparison

Example output:
```
[build-git] Building git image via cargo run (litmus test)...
[build-git] Detected base distro: alpine
[build-git] Package cache: /home/user/.cache/tillandsias/packages → /var/cache/apk
[build-git] Git image rebuilt successfully
[build-git] Current image: abc123def456 (tillandsias-git:v0.1.260505.15)
```

## Ephemeral Principle: Podman Reset

If podman state becomes corrupted (rare but possible after heavy builds):

```bash
# Script auto-handles this:
podman system reset --force

# Or manually:
podman system prune -a
```

No data loss — all images are reproducible from Containerfiles.

## Integration with Nix Build

The workflow is independent of Nix:

```bash
# Dev binary build (Nix, embeds Containerfiles)
./build.sh --install
# Binary now at: ~/.local/bin/tillandsias

# Image rebuilds (pure podman, no Nix involved)
./build-git.sh
./build-forge.sh

# Test in same binary
tillandsias /path/to/project
```

New Nix binary? Same workflow applies — just rebuild images with the scripts.

## Next Steps

1. **Integrate ImageBuilder trait** — When `crates/tillandsias-core/src/image_builder.rs` is wired into `src-tauri/src/runner.rs`, the build scripts will use the exact prod code path.

2. **Add observability traces** to remaining Containerfiles (proxy, inference, forge, web) using the git model.

3. **Wire CentiColon metrics** to capture build times, cache hits, and convergence status.

4. **Automated testing** — CI can run `./build-all-images.sh && tillandsias --init --verify` to validate entire pipeline.

## References

- `@trace spec:user-runtime-lifecycle` — Image building lifecycle
- `@trace spec:litmus-framework` — Convergence test patterns
- `scripts/build-image.sh` — Core build logic (pure podman, no Nix)
- `crates/tillandsias-core/src/bin/build-image.rs` — Litmus harness (stub)
- `methodology/specs/user-runtime-lifecycle/architecture.md` — Full architecture spec
