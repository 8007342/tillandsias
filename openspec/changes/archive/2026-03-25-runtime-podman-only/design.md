## Context

The forge and web container images are built by `nix build` inside a Nix environment. Previously, this environment was a persistent `tillandsias-builder` Fedora toolbox with Nix installed via `ensure-builder.sh`. Toolbox is Fedora-specific, making the runtime non-portable.

The `nixos/nix:latest` OCI image already contains a fully configured Nix installation with flakes support. Using `podman run --rm` with this image gives us the same build capability without any platform-specific dependency.

## Goals / Non-Goals

**Goals:**
- Runtime image builds work on any OS where podman is available (Linux, macOS, Windows)
- Zero persistent builder state — ephemeral containers only
- No toolbox dependency at runtime (toolbox is dev-only)
- Identical build output — same `nix build` command, same tarball

**Non-Goals:**
- Nix store caching across builds (ephemeral container means fresh store each time; Nix's content-addressed caching inside a single build is still effective)
- Changing the flake.nix structure or image definitions
- Modifying the development build script (`build.sh`)

## Decisions

### D1: Ephemeral podman container replaces persistent toolbox

Instead of:
```
ensure-builder.sh → toolbox create tillandsias-builder + install Nix
build-image.sh → toolbox run -c tillandsias-builder nix build ...
```

Now:
```
build-image.sh → podman run --rm nixos/nix:latest nix build ...
```

The builder container is created, used, and destroyed in a single `podman run --rm` invocation. No persistent state to manage, no `ensure-builder.sh` needed.

### D2: Source mounting and output extraction

The source tree (flake.nix, flake.lock, images/) is mounted read-only into the ephemeral container at `/src`. An output volume is mounted at `/output` for the tarball.

```
podman run --rm \
  -v <source_dir>:/src:ro \
  -v <output_dir>:/output \
  nixos/nix:latest \
  bash -c 'nix --extra-experimental-features "nix-command flakes" \
    build /src#<attr> --print-out-paths --no-link \
    | xargs -I{} cp {} /output/result.tar.gz'
```

This avoids the complexity of piping from a running container or using `podman cp`. The tarball lands on the host filesystem via the output volume, then `podman load` reads it directly.

### D3: Flakes enabled via CLI flag

The `nixos/nix:latest` image may or may not have flakes enabled in its Nix config. We pass `--extra-experimental-features "nix-command flakes"` on every invocation to guarantee flakes work regardless of the image's default configuration.

### D4: Nix store is ephemeral

Unlike the toolbox approach where `/nix/store` persisted across builds, the ephemeral container starts with a fresh Nix store each time. This means:
- First builds download dependencies (same as before on first toolbox creation)
- Subsequent builds also download dependencies (slower than cached toolbox)
- Trade-off accepted: portability and simplicity outweigh cache performance
- Future optimization: mount a named volume for `/nix` to enable cross-build caching

### D5: Build flow

```
tillandsias attach-here (or tillandsias init)
  -> handlers.rs: run_build_image_script("forge")
    -> embedded.rs: write_image_sources() to temp
    -> build-image.sh forge
      -> staleness check (same as before)
      -> podman run --rm nixos/nix:latest nix build /src#forge-image
      -> cp tarball to /output volume
      -> podman load < tarball
      -> tag as tillandsias-forge:latest
    -> embedded.rs: cleanup_image_sources()
```
