---
tags: [podman, registries, images, short-name, configuration]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-06
sources:
  - https://docs.podman.io/en/latest/markdown/podman.1.html#registries-configuration-file
  - https://github.com/containers/image/blob/main/docs/containers-registries.conf.5.md
  - https://docs.podman.io/en/latest/markdown/podman.1.html#short-name-aliasing
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman Registries Configuration

**Use when**: Configuring which registries podman searches for image names, handling short-name resolution, or managing local vs. remote images.

## Provenance

- [Podman Documentation: Registries Configuration](https://docs.podman.io/en/latest/markdown/podman.1.html#registries-configuration-file) — official reference for registries.conf format and behavior
- [Containers/image Library Documentation](https://github.com/containers/image/blob/main/docs/containers-registries.conf.5.md) — canonical source for registries.conf format (shared by Podman, Skopeo, Buildah)
- [Podman Short-Name Resolution](https://docs.podman.io/en/latest/markdown/podman.1.html#short-name-aliasing) — how podman resolves unqualified image names
- **Last updated:** 2026-05-05

## Problem: Short-Name Resolution TTY Prompts

When you use an image name like `tillandsias-git:v0.1.x` (unqualified, no registry prefix):

```
podman run tillandsias-git:v0.1.x ...
```

Podman's short-name resolution behavior:

1. **If image exists locally** → uses it immediately (no prompt)
2. **If image does NOT exist locally** → tries to pull from registries
3. **Multiple possible registries** → prompts user to choose (INTERACTIVE, requires TTY)

This causes `Error: short-name resolution enforced but cannot prompt without a TTY` in non-interactive contexts (build scripts, CI, systemd services).

## Solution: registries.conf

The `registries.conf` file tells podman:
- Which registries to search (and in what order)
- Whether to allow unqualified searches
- Which registries are local vs. remote

**Key file location**: `/etc/containers/registries.conf` (system-wide) or `~/.config/containers/registries.conf` (user)

## Example: Tillandsias registries.conf

```toml
# Local images are stored at localhost (podman's default local storage)
[[registry]]
location = "localhost"
insecure = true

# External registries
[[registry]]
location = "docker.io"
insecure = false

[[registry]]
location = "quay.io"
insecure = false

# Disable short-name resolution to prevent TTY prompts
# With this set, unqualified names are searched in registry order without prompting
short-name-mode = "disabled"
```

**Result**: 
- `podman run tillandsias-git:v0.1.x` → searches registries in order, finds in localhost (local storage), no TTY prompt
- `podman run docker.io/library/squid:6.1` → explicit registry, skips search
- `podman run unknown:v1` → searches all registries, fails with clear error (no prompt)

## Registry Configuration Directives

| Directive | Purpose | Example |
|-----------|---------|---------|
| `unqualified-search-registries` | Which registries to search for short names | `["docker.io", "quay.io"]` |
| `[[registry]]` | Define a specific registry | `location = "docker.io"` |
| `prefix` | Image prefix mapping | `prefix = "docker.io"` |
| `insecure` | Allow unencrypted HTTP | `insecure = true` (for localhost registries) |
| `short-name-mode` | How to handle short names | `"enforcing"` or `"disabled"` |

## Tillandsias Image Lifecycle

**Build time** (local, bare names):
```
tillandsias-forge:v0.1.260505.11
tillandsias-git:v0.1.260505.11
tillandsias-proxy:v0.1.260505.11
```

**Runtime** (local, from podman storage):
```bash
podman run tillandsias-git:v0.1.260505.11 ...
# Podman checks local storage first (registries.conf with unqualified-search-registries = [])
# No pull attempted, no TTY prompt
```

**Dev proxy** (external, explicit registry):
```bash
podman run docker.io/library/squid:6.1 ...
# Fully-qualified name → always pulls from docker.io
# No ambiguity, no short-name resolution needed
```

## Testing registries.conf

```bash
# Verify configuration is loaded
podman info | grep -A5 "registries:"

# Test unqualified search (should not prompt if configured correctly)
podman pull tillandsias-git:v0.1.x 2>&1

# Test external registry (should work)
podman pull docker.io/library/squid:6.1
```

## Gotchas

1. **"localhost/" is NOT the same as local image** — `localhost/tillandsias-git` is treated as a registry name, not a local image identifier
2. **registries.conf only affects pull/search** — `podman run` with a local image works regardless of config
3. **Fully-qualified names bypass short-name resolution** — `docker.io/library/squid:6.1` doesn't need registries.conf, works directly
4. **Empty unqualified-search-registries disables all short-name searches** — use this for Tillandsias to prevent accidental external pulls
