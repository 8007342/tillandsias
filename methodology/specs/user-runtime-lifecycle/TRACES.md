# TRACES.md

Trace annotations for spec: user-runtime-lifecycle

## Code References

Traces referencing this spec can be found with:

```bash
grep -rn "@trace spec:user-runtime-lifecycle" \
  src-tauri/ scripts/ crates/ images/ \
  --include="*.rs" --include="*.sh" --include="*.md"
```

## Primary Implementation Points

| Location | Purpose |
|----------|---------|
| `scripts/build-image.sh` | Layer 2 entry point (distro detection, cache mounting, podman build invocation) |
| `crates/tillandsias-core/src/image_builder.rs` | Layer 2 Rust API (ImageBuilder trait + implementations) |
| `crates/tillandsias-podman/src/client.rs::build_image()` | Podman CLI wrapper (executes prepared calls) |
| `src-tauri/src/embedded.rs` | Layer 1 (Containerfile embedding) |
| `scripts/build-git.sh`, etc. | Layer 3 test harnesses (exercise Layer 2, capture calls, assert output) |

## Related Specs

- `appimage-build-pipeline` — Layer 1 artifact handling (Nix → AppImage)
- `default-image` — Layer 2 image construction (staleness, caching)
- `podman-orchestration` — Podman API abstraction
- `forge-staleness` — Staleness detection and hash management

## Test Harness Conventions

Test harnesses (scripts/build-*.sh) should:

1. Call `"$SCRIPT_DIR/build-image.sh" <image_name>` (reuse Layer 2)
2. Capture output for assertion
3. Exercise the resulting image with health checks
4. Emit PASS/FAIL with spec reference

Example pattern:

```bash
#!/usr/bin/env bash
# @trace spec:user-runtime-lifecycle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="git"

# 1. Invoke Layer 2 (same code path as tray uses)
if ! "$SCRIPT_DIR/build-image.sh" "$IMAGE_NAME" --verbose; then
    echo "FAIL: build-image.sh failed"
    exit 1
fi

# 2. Health check in the image
PODMAN="${PODMAN:-podman}"
CONTAINER=$("$PODMAN" run -d --rm "tillandsias-${IMAGE_NAME}:latest" sleep 300)
if ! "$PODMAN" exec "$CONTAINER" git --version >/dev/null; then
    "$PODMAN" kill "$CONTAINER"
    echo "FAIL: health check failed"
    exit 1
fi
"$PODMAN" kill "$CONTAINER"

echo "PASS: ${IMAGE_NAME} image builds and boots"
```
