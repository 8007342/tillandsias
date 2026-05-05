# Spec: Podman Registries Configuration

**Trace**: `@trace spec:podman-registries-config`

## Intent

Eliminate TTY prompts and image resolution ambiguity by configuring podman's registry search behavior. Local Tillandsias images use bare names without registry prefixes; external images use fully-qualified names. The `registries.conf` file enforces this discipline.

## Problem

When podman encounters an unqualified image name (e.g., `tillandsias-git:v0.1.x`):

1. **If image exists locally** → uses it
2. **If image doesn't exist** → searches registered external registries
3. **If multiple registries match** → **prompts user to choose** (interactive, requires TTY)

This breaks non-interactive contexts:
- CI/CD pipelines
- Build scripts running in containers
- Systemd services
- Cronjobs

**Root cause**: Short-name resolution with interactive prompts.

**Historical error**: Adding `localhost/` prefix was attempted but wrong:
- `localhost/tillandsias-git` is interpreted as a Docker registry name
- Podman tries HTTPS access to `localhost:443`
- Fails with "connection refused" errors

## Solution

**registries.conf** (`/etc/containers/registries.conf` or `~/.config/containers/registries.conf`):

```toml
# Disable short-name resolution for local images
unqualified-search-registries = []

# External images require explicit registry prefix
short-name-mode = "disabled"

# Define external registries explicitly
[[registry]]
location = "docker.io"
```

**Image naming discipline**:

| Image Type | Name Format | Example | Resolution |
|----------|----------|---------|-----------|
| **Local, built** | Bare name | `tillandsias-git:v0.1.x` | Local storage only (no search) |
| **External, stable** | Fully-qualified | `docker.io/library/squid:6.1` | Explicit registry, no ambiguity |

## Behavior After Implementation

**Local image** (during enclave runtime):
```bash
podman run tillandsias-git:v0.1.260505.11
# Looks in local storage only (registries.conf disables external search)
# No pull attempt, no TTY prompt
```

**External image** (dev proxy during build):
```bash
podman run docker.io/library/squid:6.1
# Fully-qualified → goes directly to docker.io
# No ambiguity, no search, no prompt
```

**Unknown image** (typo or missing):
```bash
podman run typo-image:v1
# Error: image not found (fails fast, no search)
# Better than prompting or searching multiple registries
```

## Implementation

### 1. Create registries.conf

**Location**: `~/.config/containers/registries.conf` (user) or `/etc/containers/registries.conf` (system)

**File content**: See cheatsheets/utils/podman-registries.md

### 2. Update code (handlers.rs)

Use bare image names (already correct after reverting localhost/ prefix):
```rust
pub(crate) fn git_image_tag() -> String {
    format!("tillandsias-git:v{}", env!("TILLANDSIAS_FULL_VERSION"))
}
```

### 3. Dev proxy (scripts/build.sh)

Explicitly use fully-qualified name:
```bash
proxy_image="docker.io/library/squid:6.1"
podman run "$proxy_image"
```

### 4. Document in cheatsheets

- `cheatsheets/utils/podman-registries.md` — Configuration and short-name resolution
- `cheatsheets/runtime/image-lifecycle.md` — Complete image build/run/cleanup cycle

## Evidence & Validation

### Litmus Tests

**Test 1: Bare name uses local image** 
```bash
# Build a local image
podman build -t tillandsias-test:v1 .

# Run without registries.conf pulling
podman run tillandsias-test:v1
# Expected: Uses local image (no pull, no prompt)
```

**Test 2: Fully-qualified name works**
```bash
podman run docker.io/library/alpine:latest
# Expected: Pulls from docker.io (no prompt, no ambiguity)
```

**Test 3: Unknown name fails fast**
```bash
podman run unknown-image:v1
# Expected: Error immediately (no search, no prompt)
```

### Verification

After deploying registries.conf:
```bash
# Verify configuration loaded
podman info | grep -A10 "registries:"

# Confirm short-name mode
podman info | grep short-name-mode
# Expected: "disabled"

# Test --github-login (uses tillandsias-git bare name)
tillandsias --github-login
# Expected: No TTY prompt, image found in local storage
```

## Sources of Truth

- `cheatsheets/utils/podman-registries.md` — Podman registries configuration mechanics
- `cheatsheets/runtime/image-lifecycle.md` — Tillandsias image build/run/cleanup lifecycle

## Related Specs

- `spec:proxy-container` — Proxy image build and deployment
- `spec:git-mirror-service` — Git service image build and deployment
- `spec:default-image` — Forge image build process
- `spec:inference-container` — Inference image build process

