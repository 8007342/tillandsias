---
id: nix-reproducibility
title: Nix Reproducibility & Content-Addressed Builds
category: packaging/nix
tags: [nix, reproducibility, content-addressed, determinism, binary-cache, sandbox]
upstream: https://nixos.org/guides/how-nix-works
version_pinned: "2.28"
last_verified: "2026-03-30"
authority: official
---

# Nix Reproducibility & Content-Addressed Builds

## The Nix Store Model

Every store object lives under `/nix/store/<hash>-<name>`. The hash encodes
either the inputs used to build the derivation (input-addressed) or the content
of the output itself (content-addressed). This gives two guarantees:

- **Immutability** — a store path never changes once written.
- **Deduplication** — identical content produces the same hash, so it is stored
  once regardless of how many derivations reference it.

A **closure** is a store path plus every transitive dependency it references.
`nix-store -qR /nix/store/<hash>-foo` lists the full closure. Closures are the
unit of deployment: copying a closure to another machine gives it everything
needed to run.

## Input-Addressed vs Content-Addressed Derivations

| Property | Input-addressed (default) | Content-addressed (experimental) |
|---|---|---|
| Output path derived from | All declared inputs (source hash, deps, builder) | The actual build output |
| Rebuild propagation | Changing any input changes the output path of every downstream dependent | Only propagates if the output bytes actually change |
| Feature gate | Stable | `experimental-features = ca-derivations` |

Content-addressed derivations solve the **rebuild amplification** problem. If a
fetchurl for glibc changes URL but produces identical bytes, input-addressing
forces a rebuild of the entire dependency cone. Content-addressing recognizes
the output is unchanged and stops propagation.

Enable with:

```nix
# In flake.nix or nix.conf
experimental-features = nix-command flakes ca-derivations
```

## Sandbox Build Isolation

Nix builds run inside a sandbox (Linux namespaces / macOS `sandbox-exec`):

- **No network** — disabled by default to prevent non-determinism.
- **Minimal filesystem** — only declared inputs are mounted.
- **No access to `/nix/store` beyond declared deps** — prevents undeclared
  dependency leaks.
- **Private `/tmp`, `/dev`** — each build gets its own.

Control via `nix.conf`:

```ini
sandbox = true                  # default on Linux; relaxed on macOS
extra-sandbox-paths = /etc/ssl  # escape hatch for TLS certs if needed
```

## Determinism Guarantees and Known Exceptions

Nix provides a strong *framework* for reproducibility but does not guarantee
bit-for-bit identical output. Known sources of non-determinism:

- **Timestamps** — compilers/archivers embedding build time.
- **Parallelism** — non-deterministic ordering in parallel make.
- **Filesystem ordering** — readdir order varies across runs.
- **ASLR / memory addresses** — leaked into debug info.
- **Unsigned integers wrapping differently** — rare, compiler-specific.

Verify with `--rebuild` (new CLI) or `--check` (legacy):

```bash
nix build --rebuild .#package       # builds twice, compares outputs
nix-build --check '<nixpkgs>' -A hello
```

For systematic checking, set a diff hook in `nix.conf`:

```ini
diff-hook = /path/to/diff-script
run-diff-hook = true
```

Use `--option repeat N` to build N+1 times and reject if outputs differ.

## Fixed-Output Derivations (FODs)

FODs are the **one** exception where network access is allowed during build.
The contract: you declare the expected hash up front; Nix verifies it after
download.

```nix
fetchurl {
  url = "https://example.com/source-1.0.tar.gz";
  sha256 = "0abc123...";  # must match or build fails
}
```

Properties:
- Network access **enabled** inside the sandbox.
- Output path is derived from the declared hash, not from inputs.
- Changing the URL but keeping the same hash produces the same store path.
- If upstream content changes, the hash mismatch fails the build immediately.

## The `__impure` Flag

Impure derivations (`__impure = true`) disable the sandbox entirely. They have
network access, can read host files, and their output is never cached. Use only
for things that are inherently non-reproducible (e.g., fetching a `latest` tag).

```nix
# Requires: experimental-features = impure-derivations
derivation {
  __impure = true;
  # ...
}
```

Impure derivations are **never substituted** from a binary cache and are
**rebuilt every time** they are evaluated.

## Binary Caches

### Default Substituter

`cache.nixos.org` is the default binary cache. Nix checks it before building
locally. If a store path exists in the cache with a valid signature, Nix
downloads instead of building.

### Custom Substituters

```ini
# nix.conf
substituters = https://cache.nixos.org https://my-cache.example.com
trusted-public-keys = cache.nixos.org-1:6NCH... my-cache:ABCD...
```

### `nix copy` and `nix store push`

```bash
# Copy a closure to a binary cache (S3, HTTP, SSH, local path)
nix copy --to s3://my-bucket ./result

# Copy from one store to another
nix copy --from ssh://builder --to file:///cache /nix/store/<hash>-foo

# Push to a cache with signing
nix store sign --key-file /path/to/secret-key ./result
nix copy --to https://my-cache.example.com ./result
```

**Important:** `nix copy` does not create GC roots. If you copy to a local
store, create a root explicitly or the next garbage collection will remove it.

## Garbage Collection

Nix never mutates store paths, so unused paths accumulate. The garbage collector
removes any store path not reachable from a **GC root**.

### GC Roots

Roots live as symlinks under `/nix/var/nix/gcroots/`. Common roots:

- `/nix/var/nix/gcroots/auto/` — auto-registered by `nix-env`, profiles.
- `result` symlinks — `nix-build` creates `./result -> /nix/store/...` and
  registers it as a root via an indirect GC root.
- Profiles — each generation is a GC root.

### Commands

```bash
# Delete unreferenced store paths
nix-collect-garbage

# Also delete old profile generations (older than 30 days)
nix-collect-garbage --delete-older-than 30d

# New CLI equivalent
nix store gc

# List what would be deleted (dry run)
nix-collect-garbage --dry-run

# Check why a path is alive (trace to GC root)
nix-store --query --roots /nix/store/<hash>-foo
```

### Protect paths from GC

```bash
# Create an indirect GC root
nix-store --add-root /nix/var/nix/gcroots/my-root -r /nix/store/<hash>-foo

# Or simply keep a `result` symlink pointing into the store
```

## Quick Reference

| Task | Command |
|---|---|
| Build and check reproducibility | `nix build --rebuild .#pkg` |
| Show closure size | `nix path-info -rSh ./result` |
| Query runtime deps | `nix-store -qR ./result` |
| Copy closure to remote | `nix copy --to ssh://host ./result` |
| Sign a store path | `nix store sign --key-file key ./result` |
| Garbage collect (keep 30d) | `nix-collect-garbage --delete-older-than 30d` |
| Find GC roots for a path | `nix-store --query --roots /nix/store/...` |
| Verify a substituter | `nix store ping --store https://cache.example.com` |

## Sources

- [Content-Addressed Derivation Outputs — Nix 2.28 Manual](https://nix.dev/manual/nix/2.28/store/derivation/outputs/content-address.html)
- [Verifying Build Reproducibility — Nix Manual](https://nixos.org/manual/nix/stable/advanced-topics/diff-hook.html)
- [Binary Cache — NixOS Wiki](https://wiki.nixos.org/wiki/Binary_Cache)
- [Garbage Collector Roots — Nix 2.28 Manual](https://nix.dev/manual/nix/2.28/package-management/garbage-collector-roots.html)
- [The Garbage Collector — Nix Pills](https://nixos.org/guides/nix-pills/11-garbage-collector.html)
- [Configure Custom Binary Cache — nix.dev](https://nix.dev/guides/recipes/add-binary-cache.html)
- [RFC 0062: Content-Addressed Paths](https://github.com/NixOS/rfcs/blob/master/rfcs/0062-content-addressed-paths.md)
- [NixOS Reproducible Builds Tracker](https://reproducible.nixos.org/)
