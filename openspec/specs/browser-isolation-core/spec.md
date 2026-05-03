# Browser Isolation Core Spec

@trace spec:browser-isolation-core
@trace spec:versioning

## Status: active

## Requirements

### Requirement: Security model for chromium-core image

The `chromium-core` image MUST enforce the following security properties:

- **Read-only root filesystem** — the image MUST prevent runtime modification of system files
- **No external network** — the browser container MUST NOT access external networks directly
- **No credentials** — the image MUST contain zero secrets, tokens, or keys
- **Reduced capabilities** — the image MUST use minimal kernel capabilities via `--cap-drop=ALL`

### Requirement: Image versioning with explicit tags

The `chromium-core` image MUST use versioned tags derived from the `VERSION` file:

- Tag format MUST be `tillandsias-chromium-core:v<Major>.<Minor>.<ChangeCount>.<Build>`
- NO `:latest` tags ARE allowed — all references MUST be version-explicit
- The tag MUST be computed at runtime from the VERSION file by `scripts/build-image.sh`

### Requirement: Build invocation via build-image.sh

The image build MUST be invoked via `scripts/build-image.sh chromium-core` which:

- MUST read the VERSION file and apply the appropriate tag
- MUST use `images/chromium/Containerfile.core` as the build definition

## Security Model

The `chromium-core` image provides the base isolated browser environment:

- **Read-only root filesystem** — prevents runtime modification of system files
- **No external network** — browser cannot access external networks directly
- **No credentials** — zero secrets, tokens, or keys in the image
- **Reduced capabilities** — minimal kernel capabilities via `--cap-drop=ALL`

## Image Versioning

The `chromium-core` image MUST use versioned tags in `vX.Y.Z.B` format, derived from the `VERSION` file at the project root.

- Tag format: `tillandsias-chromium-core:v<Major>.<Minor>.<ChangeCount>.<Build>`
- NO `:latest` tags are allowed — all references must be version-explicit

## Build

The image is built using:

```
images/chromium/Containerfile.core
```

Build is invoked via `scripts/build-image.sh chromium-core` which reads the VERSION file and applies the appropriate tag.

## Sources of Truth

- `cheatsheets/runtime/chromium-isolation.md` — Chromium Isolation reference and patterns
- `cheatsheets/security/owasp-top-10-2021.md` — Owasp Top 10 2021 reference and patterns

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
grep -rn "@trace spec:browser-isolation-core" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
