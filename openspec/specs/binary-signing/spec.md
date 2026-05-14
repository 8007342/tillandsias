<!-- @trace spec:binary-signing -->
## Status

active

## Requirements

### Requirement: Cosign bundle artifacts
Each signable release binary MUST have a corresponding `.cosign.bundle` file published alongside it in the GitHub Release. The bundle MUST contain the signature, Fulcio certificate, timestamp, and Rekor inclusion proof produced by Cosign keyless signing.

#### Scenario: Artifact naming for bundles
- **WHEN** a binary named `Tillandsias-linux-x86_64.AppImage` is signed
- **THEN** the bundle MUST be published as `Tillandsias-linux-x86_64.AppImage.cosign.bundle`

#### Scenario: All artifacts signed
- **WHEN** a release contains artifacts for Linux, macOS, and Windows
- **THEN** each platform's binary MUST have its own `.cosign.bundle` file
- **AND** the release MUST still include `SHA256SUMS`

#### Scenario: Bundle files uploaded to release
- **WHEN** the GitHub Release is created
- **THEN** all `.cosign.bundle` files MUST be included as release assets alongside the binaries and `SHA256SUMS`

### Requirement: Cosign signing produces verifiable bundles
All signable release artifacts MUST be signed with Cosign keyless mode and MUST be verifiable locally using the bundle format. The release workflow and verification docs MUST use `.cosign.bundle` for the release artifact contract.

#### Scenario: Successful local verification
- **WHEN** a signed artifact and its `.cosign.bundle` file are downloaded
- **THEN** `cosign verify-blob --bundle` MUST succeed with the correct identity and OIDC issuer

#### Scenario: Tampered artifact fails verification
- **WHEN** a downloaded artifact is modified (e.g., a byte appended)
- **THEN** `cosign verify-blob --bundle` MUST fail and report signature mismatch

#### Scenario: Rekor transparency log entry exists
- **WHEN** a Cosign-signed artifact is released
- **THEN** the signature MUST be recorded in the Rekor transparency log and searchable by artifact hash

#### Scenario: Verification on clean machine
- **WHEN** the release notes verification instructions are followed on a machine with no prior Cosign state
- **THEN** the verification MUST succeed without additional configuration

### Requirement: Release verification instructions stay bundle-based
The repository's release verification instructions MUST tell users to download the artifact together with its `.cosign.bundle` file and run `cosign verify-blob --bundle`. The verification helper script MUST enforce the same contract.

#### Scenario: Verification script expects bundle format
- **WHEN** `scripts/verify.sh` is invoked
- **THEN** it MUST require `<artifact>.cosign.bundle`
- **AND** it MUST run `cosign verify-blob --bundle`

#### Scenario: Release notes mention bundle verification
- **WHEN** the release workflow generates release notes
- **THEN** the verification section MUST instruct users to verify `<ARTIFACT>.cosign.bundle`
- **AND** MUST mention Cosign keyless signing and Rekor

## Sources of Truth

- `knowledge/cheatsheets/ci/sigstore-cosign.md` — Sigstore Cosign reference and patterns
- `docs/VERIFICATION.md` — Release verification instructions and artifact contract
- `.github/workflows/release.yml` — Release workflow implementation and asset publishing
- `scripts/verify.sh` — Local verification helper implementation

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:release-artifact-integrity`

Gating points:
- `release.yml` publishes `.cosign.bundle` files for all signable artifacts
- `scripts/verify.sh` requires `.cosign.bundle` and uses `cosign verify-blob --bundle`
- `docs/VERIFICATION.md` tells users to verify the bundle alongside the artifact

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:binary-signing" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
