# Browser Isolation Core Spec

@trace spec:browser-isolation-core
@trace spec:versioning

## Status

active

## Requirements

### Requirement: Security model for chromium-core image

The `chromium-core` image MUST enforce the following security properties:

- **Read-only root filesystem** — the image MUST prevent runtime modification of system files
- **No credentials** — the image MUST contain zero secrets, tokens, or keys
- **Reduced capabilities** — the image MUST use minimal kernel capabilities via `--cap-drop=ALL`

### Requirement: Content-hash image identity with human aliases

The `chromium-core` image MUST use a content-hash tag derived from the image source set as its canonical identity:

- Canonical tag MUST be `tillandsias-chromium-core:<CONTENT_HASH>`
- The hash MUST be computed from the image source set by `scripts/build-image.sh`
- Human-facing `v<Major>.<Minor>.<YYMMDD>.<Build>` and `:latest` tags MAY exist only as aliases to the canonical hash tag

### Requirement: Build invocation via build-image.sh

The image build MUST be invoked via `scripts/build-image.sh chromium-core` which:

- MUST read the VERSION file and apply the appropriate tag
- MUST use `images/chromium/Containerfile.core` as the build definition

## Security Model

The `chromium-core` image provides the base isolated browser environment:

- **Read-only root filesystem** — prevents runtime modification of system files
- **No credentials** — zero secrets, tokens, or keys in the image
- **Reduced capabilities** — minimal kernel capabilities via `--cap-drop=ALL`

## Image Identity

The `chromium-core` image MUST use a content-hash canonical tag derived from the image source set.

- Canonical tag: `tillandsias-chromium-core:<CONTENT_HASH>`
- Human-facing `v<Major>.<Minor>.<YYMMDD>.<Build>` and `:latest` tags are aliases only and MAY be refreshed on rebuild

## Build

The image is built using:

```
images/chromium/Containerfile.core
```

Build is invoked via `scripts/build-image.sh chromium-core` which reads the VERSION file, computes the content hash, applies the canonical hash tag, and refreshes the human aliases.

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
