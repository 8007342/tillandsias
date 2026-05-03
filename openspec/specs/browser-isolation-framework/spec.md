# Browser Isolation Framework Spec

@trace spec:browser-isolation-framework
@trace spec:versioning

## Status

status: active

## Image Versioning

The `chromium-framework` image MUST use versioned tags that match the Tillandsias binary version:

- Tag format: `tillandsias-chromium-framework:v<Major>.<Minor>.<ChangeCount>.<Build>`
- Tags are derived from the `VERSION` file at the project root
- NO `:latest` tags are allowed

## Image Hierarchy

The `chromium-framework` image MUST extend `chromium-core` using the same version tag:

```dockerfile
ARG CHROMIUM_CORE_TAG
FROM tillandsias-chromium-core:${CHROMIUM_CORE_TAG}
```

This ensures the framework and core images are version-locked together.

## Security Model

Inherits the `chromium-core` security model (read-only root, no external network, no credentials, reduced capabilities) and adds framework-specific browser isolation layers.

## Build

The image is built using:

```
images/chromium/Containerfile.framework
```

Build is invoked via `scripts/build-image.sh chromium-framework` which resolves the core tag and passes it as a build argument.

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
