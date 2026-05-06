# user-runtime-lifecycle: Build Architecture

## Status

status: draft
created: 2026-05-05

## Purpose

Define the three-layer build system that separates concerns between Nix (binary compilation), podman (container image construction), and shell scripts (integration testing). This architecture enables reproducible, deterministic builds while keeping the test harness lightweight and atomic.

## Overview

Tillandsias uses a three-layer build architecture:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: Nix → Rust Binary                                       │
│ ─────────────────────────────────────────────────────────────────│
│ Command: cargo build --workspace (via build.sh)                  │
│ Input: src-tauri/, crates/                                       │
│ Output: ./target/debug|release/tillandsias (binary)              │
│ Embedded: Containerfiles (text, baked into binary)               │
│ Nix builds ONLY the binary. Never touches container images.      │
└─────────────────────────────────────────────────────────────────┘
              │
              └─► tillandsias binary (with embedded Containerfiles)
                      │
                      │
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: Podman → OCI Images                                     │
│ ─────────────────────────────────────────────────────────────────│
│ Trigger: tillandsias --init (tray app) or ./build.sh --init     │
│ Process:                                                          │
│   1. Binary extracts embedded Containerfile to temp dir          │
│   2. Calls podman build -f <Containerfile> -t <image-tag>       │
│   3. Distro-aware cache mounting (dnf/apt/apk) for performance  │
│   4. Staleness detection: hash Containerfile sources, skip if    │
│      unchanged and image exists locally                          │
│ Output: OCI image in podman storage                              │
│         (tillandsias-forge:vX.Y.Z, tillandsias-git:vX.Y.Z, etc) │
└─────────────────────────────────────────────────────────────────┘
              │
              └─► tillandsias-<service>:v<version> (OCI image)
                      │
                      │
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3: Test Harness → Litmus Integration                       │
│ ─────────────────────────────────────────────────────────────────│
│ Scripts: scripts/build-git.sh, build-forge.sh, etc              │
│ (NOT image builders — they are test harnesses)                   │
│ Process:                                                          │
│   1. Invoke Layer 2 code path (podman build)                     │
│   2. Capture: exact podman call made (args, mounts, env)         │
│   3. Exercise: run container with known inputs                   │
│   4. Assert: output matches expected (health check, file tree)   │
│   5. Report: PASS/FAIL + metrics to litmus framework             │
│ Output: Test results that feed convergence loop                  │
│         (litmus centicolon bindings)                             │
└─────────────────────────────────────────────────────────────────┘
```

## Three-Layer Separation

### Layer 1: Nix → Rust Binary

**Responsibility**: Compile Rust code, embed Containerfiles as text, produce AppImage or binary artifact.

**What Nix does**:
- Runs `cargo build --workspace`
- Embeds `images/*/Containerfile` as const strings in `src-tauri/src/embedded.rs`
- Produces: `target/release/tillandsias` binary (or AppImage via Tauri bundler)

**What Nix does NOT do**:
- Does not call `podman build`
- Does not create container images
- Does not run containers

**Exit condition**: Binary artifact ready for Layer 2.

**File references**:
- `src-tauri/src/embedded.rs` — Containerfile embedding (const strings, write helpers)
- `scripts/build-image.sh` — Layer 2 entry point (called by binary at runtime)

---

### Layer 2: Podman → OCI Images

**Responsibility**: Extract embedded Containerfiles, invoke `podman build`, cache smartly, tag consistently.

**What podman build does**:
1. Detects base distro from `FROM` line (Fedora/Debian/Alpine)
2. Mounts distro-specific package cache (`dnf`, `apt`, `apk`)
3. Builds with `podman build -f <Containerfile> -t <tag> <context-dir>`
4. Caches build artifacts in `~/.cache/tillandsias/packages/`

**What Layer 2 does NOT do**:
- Does not use Nix to build images
- Does not compile anything (binaries come from Layer 1)
- Does not run integration tests (that's Layer 3)

**Staleness detection** (@trace spec:forge-staleness):
- Compute SHA256 hash of Containerfile + support scripts in `images/`
- Compare to stored hash in `~/.cache/tillandsias/build-hashes/`
- Skip rebuild if unchanged and image exists in podman storage

**Exit condition**: OCI image in podman (`podman image exists <tag>`).

**Key entry points**:
- `scripts/build-image.sh forge|proxy|git|inference` — CLI (dev/manual)
- `PodmanClient::build_image()` in `crates/tillandsias-podman/src/client.rs` — Async Rust API (tray app)
- `--init` flag in tray launcher — Triggered on user request

---

### Layer 3: Test Harness → Litmus Integration

**Responsibility**: Exercise Layer 2 code, capture podman calls, assert output correctness, feed convergence loop.

**What test scripts do**:
```bash
# Example: scripts/build-git.sh
set -euo pipefail

# 1. Invoke Layer 2 build (same code path as --init uses)
IMAGE_NAME="git"
PODMAN_CALL=$("$SCRIPT_DIR/build-image.sh" "$IMAGE_NAME" --verbose 2>&1)

# 2. Capture: check exact podman command was issued
if ! echo "$PODMAN_CALL" | grep -q "podman build"; then
    echo "FAIL: podman build not invoked"
    exit 1
fi

# 3. Exercise: run the image with known inputs
CONTAINER=$("$PODMAN" run -d --rm "tillandsias-${IMAGE_NAME}:latest" sleep 300)

# 4. Assert: health checks pass
if ! "$PODMAN" exec "$CONTAINER" git --version | grep -q "^git version"; then
    echo "FAIL: git not available in image"
    "$PODMAN" kill "$CONTAINER"
    exit 1
fi

# 5. Report: emit litmus marker
echo "PASS: tillandsias-git image builds and boots correctly"
```

**What test scripts do NOT do**:
- Do NOT build images themselves (they call Layer 2)
- Do NOT modify Containerfiles (they test, not implement)
- Do NOT skip Layer 2 — they must exercise the real code path

**Litmus binding**:
- Each test script returns PASS/FAIL
- Bindings in `methodology/litmus-centicolon-wiring.yaml` route results to convergence metrics
- Falsifiable: clear exit codes, clear assertions

**Exit condition**: Test result (0 = PASS, non-zero = FAIL).

---

## Requirements

### Requirement: Nix builds ONLY the binary, never container images

```yaml
Description: >
  Nix flake (flake.nix) SHALL invoke only `cargo build` and
  the Tauri bundler. It SHALL NOT call `podman build`, pull
  images, or modify podman storage.
Pattern: MUST NOT
Rationale: >
  Container image construction is a runtime, user-facing step.
  Embedding the build logic in the binary (Layer 1) creates
  reproducible, portable artifacts that work identically
  across dev/cloud/user machines. Nix's role is to compile
  the orchestrator, not to orchestrate itself.
Scope: build.sh, flake.nix, src-tauri/
```

### Scenario: Layer 2 rebuild is skipped when sources unchanged

- **GIVEN** a prior build of `tillandsias-forge:v0.1.170.100` completed
- **AND** the stored hash in `~/.cache/tillandsias/build-hashes/` equals the current `images/default/Containerfile` hash
- **WHEN** the tray calls `PodmanClient::build_image("forge", "tillandsias-forge:v0.1.170.100")`
- **THEN** the build is skipped (debug log: "Image is up to date")
- **AND** `podman build` is never invoked
- **AND** the image is verified to exist via `podman image exists`

### Scenario: Layer 3 test harness reuses Layer 2 build logic

- **GIVEN** a test harness `scripts/build-git.sh` is invoked
- **WHEN** it calls `"$SCRIPT_DIR/build-image.sh" git`
- **THEN** the same `build-image.sh` code path used by Layer 2 (tray app) is exercised
- **AND** the test captures the exact podman invocation (args, mounts, env)
- **AND** the test asserts the container boots and health-check passes
- **THEN** the test emits a PASS/FAIL that feeds litmus convergence

### Requirement: Containerfiles are embedded as const strings in the binary

```yaml
Description: >
  All Containerfiles (images/*/Containerfile) SHALL be baked into
  the binary as const byte strings at compile time. At runtime,
  the binary extracts them to a temp directory for podman build.
Pattern: MUST
Rationale: >
  Containerfiles are not mutable — they're specs. Embedding them
  in the binary makes the binary self-contained, reproducible, and
  portable. No external files needed for Layer 2.
Scope: >
  src-tauri/src/embedded.rs (const strings),
  crates/tillandsias-core/src/ (write helpers)
```

### Scenario: Containerfile extraction works offline

- **GIVEN** the binary is copied to an air-gapped machine with no network
- **AND** podman is available (with pre-downloaded base images)
- **WHEN** the user runs `tillandsias --init`
- **THEN** the Containerfiles are extracted from the binary
- **AND** podman build proceeds (no network needed)

### Requirement: Distro-aware cache mounting in Layer 2

```yaml
Description: >
  podman build SHALL detect the base distro from the Containerfile's
  FROM line and mount the appropriate package cache:
    - Fedora: -v ~/.cache/tillandsias/packages:/var/cache/dnf/packages
    - Debian/Ubuntu: -v ~/.cache/tillandsias/packages:/var/cache/apt/archives
    - Alpine: -v ~/.cache/tillandsias/packages:/var/cache/apk
Pattern: MUST
Rationale: >
  Package cache persistence reduces network usage and build time on
  developer machines. Cache is distro-specific and must be mounted
  to the correct path or package managers fail silently.
Scope: scripts/build-image.sh (detection), PodmanClient::build_image
```

---

## Data Flow & Test Integration Points

**Layer 1 → Layer 2**:
- Binary contains embedded Containerfiles
- At init time, binary extracts files and invokes Layer 2 entry point

**Layer 2 → Layer 3**:
- Test harness calls same `build-image.sh` code path
- Captures podman args for assertion
- Exercise/assert cycle validates Layer 2 output

**Layer 3 → Convergence**:
- Test PASS/FAIL → litmus binding → centicolon metric
- Convergence loop monitors test failures over time
- Spec drift = repeated test failures = alert

---

## Sources of Truth

- `cheatsheets/build/podman.md` — Podman build semantics and cache mounting
- `cheatsheets/build/nix-flake-basics.md` — Nix build inputs and outputs
- `methodology/litmus-framework.yaml` — Litmus test integration patterns

## Observability

Annotations referencing this spec:

```bash
grep -rn "@trace spec:user-runtime-lifecycle" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```

Key trace points:
- `scripts/build-image.sh` — Layer 2 entry (distro detection, cache mounting, podman build call)
- `PodmanClient::build_image()` — Layer 2 Rust API
- Test harnesses — Layer 3 integration
