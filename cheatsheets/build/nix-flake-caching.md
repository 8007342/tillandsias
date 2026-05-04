---
title: Nix Flake Caching Strategies
since: "2026-05-03"
last_verified: "2026-05-03"
tags: [nix, flake, caching, build-optimization, incremental-builds]
tier: bundled
bundled_into_image: true
summary_generated_by: hand-curated
---

# Nix Flake Caching Strategies

**Version baseline**: Nix 2.18+ with flakes enabled (builtin in Tillandsias forge)  
**Use when**: Optimizing build times in Nix flakes, sharing build artifacts between developer machines, persisting build caches across container restarts, speeding up CI/CD builds.

## Provenance

- https://nix.dev/concepts/caching — Nix Foundation guide to caching and artifact storage
- https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-store.html — Nix store operations and garbage collection
- https://github.com/nix-community/cachix — Cachix community binary cache
- https://nixos.org/manual/nix/stable/command-ref/conf-file.html — Nix configuration (stores, substituters, trust)
- https://ttuegel.github.io/nix-darwin/#sec-nix-daemon — Nix daemon and multi-user store (if applicable)
- **Last updated:** 2026-05-03

## Quick reference: Nix Store and Caching

| Component | Purpose | Default Location |
|-----------|---------|-------------------|
| **Nix store** | Immutable artifact storage (build inputs + outputs) | `/nix/store/` (single-user) or system-wide (multi-user) |
| **Substituter** | Remote binary cache (avoids rebuilds) | `https://cache.nixos.org` (default) |
| **Local cache** | Host build artifacts | `~/.cache/nix/` (build temp) + `/nix/store/` (final) |
| **Realisation DB** | Maps derivations to built outputs | `/nix/var/nix/db/` |

### Cache Hit Basics

```bash
# Build a derivation (cached)
nix build .#myapp
# Output: /nix/store/abc123-myapp-1.0

# Build again (cache hit)
nix build .#myapp
# /nix/store/abc123-myapp-1.0 already exists; skipped
# Time: <0.1s (cache hit) vs. 30s+ (rebuild)
```

**Cache hits occur when:**
1. Source files haven't changed (hash matches prior derivation)
2. Dependencies haven't changed
3. Build output (in `/nix/store/`) still exists
4. Derivation hash remains the same

## Local Caching Strategies

### Strategy 1: Persistent `/nix/store` Volume (Containers)

In Tillandsias forge, the Nix store is mounted as a persistent volume to survive container restarts.

```dockerfile
# In Containerfile or podman run
podman run -d \
  --name tillandsias-forge \
  --volume /nix/store:/nix/store \
  tillandsias-forge
```

**Benefits:**
- Build outputs persist across container stop/start cycles
- Incremental rebuilds much faster (second run uses cache)
- Shared cache if multiple projects mount same `/nix/store`

**Trade-offs:**
- `/nix/store` grows unbounded (gigabytes over time)
- Manual pruning required: `nix store gc` or `nix flake check --update-all && nix store gc`

### Strategy 2: Flake Lock File for Determinism

Commit `flake.lock` to version control to ensure every build uses identical input versions.

```bash
# Initial setup: generate flake.lock
nix flake update

# Subsequent builds: use locked inputs
nix build
# Uses pinned nixpkgs, tool versions, etc. from flake.lock
```

**Effect on caching:**
- Changing `flake.lock` invalidates all downstream derivations
- Same `flake.lock` = identical derivation hashes = guaranteed cache hits
- Dev machines and CI see identical build plans

```toml
# flake.lock (auto-generated, commit to git)
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "lastModified": 1722643789,
        "narHash": "sha256-...",
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "2ab...",
        "type": "github"
      }
    }
  }
}
```

### Strategy 3: Binary Cache (`cachix` or Custom)

Pre-build and upload derivations to a remote binary cache to avoid repeated local builds.

#### Cachix (Community Cache)

```bash
# Install cachix (one-time)
nix-env -iA cachix -f https://cachix.org/api/v1/install

# Create a cache (free tier available)
cachix authtoken <token>

# Push built artifacts to cache
nix build .#myapp
cachix push my-cache /nix/store/abc123-myapp-1.0

# Other developers pull from cache (faster than rebuilding)
cachix use my-cache
nix build .#myapp  # Uses binary from cache; no rebuild
```

#### Custom HTTP Binary Cache

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: {
    devShells.default = nixpkgs.mkShell {
      buildInputs = [ nixpkgs.go ];
    };
  };
}

# ~/.config/nix/nix.conf (or /etc/nix/nix.conf for system-wide)
substituters = [ "https://my-cache.example.com" "https://cache.nixos.org" ]
trusted-public-keys = [
  "my-cache.example.com-1:key..."
  "cache.nixos.org-1:6NCHdD59X431o0gWypQDvCou9KwWCXc1PqMPSStFAI="
]
```

## Incremental Build Optimization

### Pattern 1: Source Hash Pinning

Pin source files to force rebuilds only when they change.

```nix
# flake.nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in {
      packages.x86_64-linux.myapp = pkgs.buildRustPackage {
        pname = "myapp";
        version = "0.1.0";
        src = ./.;
        cargoLock.lockFile = ./Cargo.lock;
      };
    };
}
```

**Hash computation:**
- Nix hashes `src = ./.` (entire working tree)
- If any source file changes, hash changes → **cache miss** → rebuild
- If sources unchanged, hash unchanged → **cache hit** → reuse artifact

### Pattern 2: Layered Builds (Rust Example)

Separate build into dep layer + source layer for incremental caching.

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    naersk.url = "github:nix-community/naersk";
  };

  outputs = { self, nixpkgs, naersk }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      naersk' = naersk.lib.x86_64-linux;
    in {
      packages.x86_64-linux.default = naersk'.buildPackage {
        src = ./.;

        # Cache deps separately from source
        # (no rebuild of deps unless Cargo.lock changes)
        cargoLock.lockFile = ./Cargo.lock;
      };
    };
}
```

**Effect:**
- First build: build deps (slow) + build source code (slow)
- Change source code only: deps reused (from cache) + rebuild source (fast)
- Change Cargo.lock: both layers rebuild (slow)

### Pattern 3: Disk Space Awareness

Limit Nix store size and auto-prune old builds.

```bash
# Check store size
du -sh /nix/store

# Run garbage collection (removes unused outputs)
nix store gc

# Remove specific outputs
nix store delete /nix/store/abc123-myapp-1.0

# Set auto-prune in nix.conf
max-free = 1000000000  # Delete oldest outputs when free space < 1GB
min-free = 100000000   # Stop deletion when free space > 100MB
```

## Tillandsias-Specific Caching

### Forge Image Build Cache

The forge image is built once via Nix and tagged. Subsequent builds reuse the image layer cache.

```bash
# scripts/build-image.sh (simplified)
nix build ./images#forge-image
HASH=$(nix eval --raw ./images#forge-image.imageTag)

podman load < result
podman tag tillandsias-forge:$HASH tillandsias-forge:latest
```

**Cache hierarchy:**
1. **Image layer cache** (Nix build): Each RUN/ADD/COPY is a layer; unchanged layers = cache hit
2. **Artifact cache** (Nix store): Pre-built tools, libraries land in `/opt/` inside image
3. **Per-project cache** (RW volume): Project-specific deps, build output (ephemeral on container stop)

### Model Cache (Inference)

Ollama model cache (`~/.ollama/models/`) is persisted across container restarts.

```bash
# Host-side
~/.ollama/models/
  ├── manifests/
  │   └── [model metadata]
  └── blobs/
      └── [model weights, cached on first pull]

# Container sees via bind mount
podman run -v ~/.ollama/models:/ollama/models tillandsias-inference
```

**Cache behavior:**
- Pull once → model cached forever (unless manually deleted)
- Second pull → manifest checked; skip if already cached
- No re-download of multi-GB model files

## Build Debugging: Cache Misses

```bash
# Verbose build log (shows cache hit/miss reasons)
nix build .#myapp -vv 2>&1 | grep -i "cache\|skip\|rebuild"

# Check derivation hash
nix eval .#myapp.drvPath

# Compare hashes before/after source change
nix eval --raw .#myapp.drvPath > /tmp/hash1
# [edit source]
nix eval --raw .#myapp.drvPath > /tmp/hash2
diff /tmp/hash1 /tmp/hash2

# If different: cache miss (rebuild required)
# If same: cache hit (reuse output)
```

## Common pitfalls

- **Uncommitted `flake.lock`** — `flake.lock` not in git; every developer sees different dependency versions; cache hits are inconsistent. **ALWAYS** commit `flake.lock`.
- **`nix flake update` in CI without testing** — updates all inputs to latest; may break builds. Instead: manually test `nix flake lock --update-input <one>`, then commit.
- **Store disk space unchecked** — `/nix/store` grows to gigabytes; performance degrades. Run `nix store gc` monthly or set `max-free` in `nix.conf`.
- **Binary cache not trusted** — `substituters` config exists but signatures don't verify; falls back to local rebuild. Verify `trusted-public-keys` match cache provider.
- **Mixing `nix-shell` and `nix develop`** — different cache paths; cache misses between them. Stick with `nix develop` (flakes) for new projects.
- **Source hash includes `.git/`** — if building in a git repo, `.git/` is hashed; pull/push operations change hash → cache miss. Use `src = builtins.filterSource` to exclude.

## See also

- `build/cargo.md` — Rust build caching via `target/` directory
- `build/nix-flake-basics.md` — Nix flake fundamentals and devShell patterns
- https://nix.dev/concepts/caching — Official Nix caching concepts
- https://cachix.org — Cachix binary cache service
