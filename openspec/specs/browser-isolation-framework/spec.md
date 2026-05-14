# Browser Isolation Framework Spec

@trace spec:browser-isolation-framework
@trace spec:versioning

## Status

active

## Requirements

### Requirement: Content-hash image identity with human aliases

The `chromium-framework` image MUST use a content-hash tag derived from the image source set as its canonical identity:

- Canonical tag MUST be `tillandsias-chromium-framework:<CONTENT_HASH>`
- The hash MUST be computed from the image source set by `scripts/build-image.sh`
- Human-facing `v<Major>.<Minor>.<YYMMDD>.<Build>` and `:latest` tags MAY exist only as aliases to the canonical hash tag

### Requirement: Image hierarchy locked to chromium-core

The `chromium-framework` image MUST extend `chromium-core` using the same canonical hash identity:

- The Dockerfile MUST use an ARG that carries the resolved local core image reference
- The FROM statement MUST resolve that reference directly, currently `FROM ${CHROMIUM_CORE_IMAGE}` in Podman builds
- The build script SHOULD pass the canonical chromium-core hash tag so the hierarchy stays content-addressed

### Requirement: Security model inheritance and framework-specific isolation

The image MUST inherit the `chromium-core` security model (read-only root, no external network, no credentials, reduced capabilities) AND add framework-specific browser isolation layers.

### Requirement: Build invocation via build-image.sh

The image build MUST be invoked via `scripts/build-image.sh chromium-framework` which:

- MUST resolve the core tag and pass it as a build argument
- MUST use `images/chromium/Containerfile.framework` as the build definition

## Image Identity

The `chromium-framework` image MUST use a content-hash canonical tag derived from the image source set.

- Canonical tag: `tillandsias-chromium-framework:<CONTENT_HASH>`
- Human-facing `v<Major>.<Minor>.<YYMMDD>.<Build>` and `:latest` tags are aliases only and MAY be refreshed on rebuild

## Image Hierarchy

The `chromium-framework` image MUST extend `chromium-core` using the same canonical hash identity:

```dockerfile
ARG CHROMIUM_CORE_IMAGE
FROM ${CHROMIUM_CORE_IMAGE}
```

This ensures the framework and core images remain content-addressed together while human aliases remain available for operators.

## Security Model

Inherits the `chromium-core` security model (read-only root, no external network, no credentials, reduced capabilities) and adds framework-specific browser isolation layers.

## Build

The image is built using:

```
images/chromium/Containerfile.framework
```

Build is invoked via `scripts/build-image.sh chromium-framework` which resolves the core canonical hash tag and passes it as a build argument.

## Sources of Truth

- `cheatsheets/runtime/chromium-seccomp.md` — Chromium Seccomp reference and patterns
- `cheatsheets/runtime/chromium-isolation.md` — Chromium Isolation reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:browser-ephemeral`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:browser-isolation-framework" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
