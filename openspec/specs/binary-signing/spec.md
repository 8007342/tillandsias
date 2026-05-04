<!-- @trace spec:binary-signing -->
## Status

active

## Requirements

### Requirement: Signature and certificate artifacts
Each signed binary MUST have its signature and certificate published as separate files alongside the binary in the GitHub Release. Signature files MUST use the `.sig` extension and certificate files MUST use the `.cert` extension.

#### Scenario: Artifact naming for signatures
- **WHEN** a binary named `tillandsias-v0.1.0-linux-x86_64.AppImage` is signed
- **THEN** the signature MUST be published as `tillandsias-v0.1.0-linux-x86_64.AppImage.sig` and the certificate as `tillandsias-v0.1.0-linux-x86_64.AppImage.cert`

#### Scenario: All artifacts signed
- **WHEN** a release contains artifacts for Linux, macOS, and Windows
- **THEN** each platform's binary MUST have its own `.sig` and `.cert` files (six additional files total)

#### Scenario: Signature files uploaded to release
- **WHEN** the GitHub Release is created
- **THEN** all `.sig` and `.cert` files MUST be included as release assets alongside the binaries and `SHA256SUMS`

### Requirement: Cosign signing produces verifiable signatures
All release artifacts MUST be signed with Cosign keyless mode and MUST be verifiable locally. Signature and certificate files MUST use `.sig` and `.cert` extensions (not `.cosign.sig`/`.cosign.cert`).

#### Scenario: Successful local verification
- **WHEN** a signed artifact and its `.sig` and `.cert` files are downloaded
- **THEN** `cosign verify-blob` MUST succeed with the correct identity and OIDC issuer

#### Scenario: Tampered artifact fails verification
- **WHEN** a downloaded artifact is modified (e.g., a byte appended)
- **THEN** `cosign verify-blob` MUST fail and report signature mismatch

#### Scenario: Rekor transparency log entry exists
- **WHEN** a Cosign-signed artifact is released
- **THEN** the signature MUST be recorded in the Rekor transparency log and searchable by artifact hash

#### Scenario: Verification on clean machine
- **WHEN** the release notes verification instructions are followed on a machine with no prior Cosign state
- **THEN** the verification MUST succeed without additional configuration

## Sources of Truth

- `cheatsheets/utils/gh-cli.md` — Gh Cli reference and patterns
- `cheatsheets/security/owasp-top-10-2021.md` — Owasp Top 10 2021 reference and patterns

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Observable ephemeral guarantee: resources created during initialization are destroyed on shutdown
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked resources, persistence) are detectable

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:binary-signing" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
