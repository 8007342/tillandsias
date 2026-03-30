# binary-signing Specification

## Purpose
TBD - created by archiving change cosign-signing. Update Purpose after archive.
## Requirements
### Requirement: Cosign keyless signing of release artifacts
Every release artifact SHALL be signed using Cosign in keyless mode via GitHub Actions OIDC identity. No persistent signing keys SHALL be used.

#### Scenario: Successful signing
- **WHEN** a release build completes and artifacts are collected
- **THEN** each binary artifact is signed with Cosign keyless mode, producing a `.sig` (signature) and `.cert` (certificate) file per artifact

#### Scenario: OIDC identity binding
- **WHEN** Cosign signs an artifact in GitHub Actions
- **THEN** the signing certificate contains the GitHub Actions workflow identity (repository, workflow file path, git ref) as the subject claim

#### Scenario: Ephemeral key lifecycle
- **WHEN** a signing operation completes
- **THEN** the ephemeral signing key is discarded and cannot be recovered or reused

### Requirement: Transparency log recording
Every signing operation SHALL be recorded in the Rekor transparency log, creating a public, immutable, timestamped record of the signing event.

#### Scenario: Rekor entry created
- **WHEN** an artifact is signed
- **THEN** a corresponding entry is created in the Rekor transparency log linking the artifact hash, signature, and signing identity

#### Scenario: Rekor entry is publicly queryable
- **WHEN** a Rekor entry is created for a signed artifact
- **THEN** anyone can query the Rekor log to find the entry by artifact hash without authentication

### Requirement: Signature and certificate artifacts
Each signed binary SHALL have its signature and certificate published as separate files alongside the binary in the GitHub Release. Signature files use the `.sig` extension and certificate files use the `.cert` extension.

#### Scenario: Artifact naming for signatures
- **WHEN** a binary named `tillandsias-v0.1.0-linux-x86_64.AppImage` is signed
- **THEN** the signature is published as `tillandsias-v0.1.0-linux-x86_64.AppImage.sig` and the certificate as `tillandsias-v0.1.0-linux-x86_64.AppImage.cert`

#### Scenario: All artifacts signed
- **WHEN** a release contains artifacts for Linux, macOS, and Windows
- **THEN** each platform's binary has its own `.sig` and `.cert` files (six additional files total)

#### Scenario: Signature files uploaded to release
- **WHEN** the GitHub Release is created
- **THEN** all `.sig` and `.cert` files are included as release assets alongside the binaries and `SHA256SUMS`

### Requirement: Public verification
Users SHALL be able to verify any downloaded artifact using `cosign verify-blob` with the published certificate and signature, without needing access to any private key.

#### Scenario: Successful verification
- **WHEN** a user downloads an artifact, its `.sig`, and its `.cert`, then runs `cosign verify-blob` with the correct identity and issuer flags
- **THEN** verification succeeds and outputs confirmation that the artifact was signed by the Tillandsias CI pipeline

#### Scenario: Tampered artifact detection
- **WHEN** a user downloads an artifact that has been modified after signing, then runs `cosign verify-blob`
- **THEN** verification fails with a clear error indicating the artifact does not match the signature

#### Scenario: Wrong certificate detection
- **WHEN** a user attempts verification with a certificate from a different release or a different project
- **THEN** verification fails because the certificate identity does not match the expected repository and workflow

#### Scenario: Verification without Rekor access
- **WHEN** a user has the artifact, `.sig`, and `.cert` files but Rekor is temporarily unavailable
- **THEN** verification can still succeed using `--insecure-ignore-tlog` flag (with appropriate warning), since the certificate and signature contain sufficient information for basic verification

### Requirement: Verification instructions in releases
Each GitHub Release SHALL include verification commands in the release body, enabling users to verify artifacts without consulting external documentation.

#### Scenario: Release notes contain verification command
- **WHEN** a GitHub Release is published
- **THEN** the release body includes a verification command block showing the exact `cosign verify-blob` invocation with correct flags for that release's artifacts

#### Scenario: Repository identity in verification
- **WHEN** the verification command is published
- **THEN** the `--certificate-identity-regexp` flag matches the Tillandsias repository and the `--certificate-oidc-issuer` is set to `https://token.actions.githubusercontent.com`

### Requirement: CI workflow permissions for signing
The release workflow SHALL request only the minimum additional permissions needed for Cosign keyless signing.

#### Scenario: OIDC token permission
- **WHEN** the release workflow runs with signing enabled
- **THEN** the workflow has `id-token: write` permission to request GitHub OIDC tokens for Sigstore identity federation

#### Scenario: No other elevated permissions
- **WHEN** the signing steps execute
- **THEN** no permissions beyond `contents: write` (for releases) and `id-token: write` (for OIDC) are granted

### Requirement: Signing failure handling
A signing failure SHALL prevent the release from being published. Artifacts without signatures MUST NOT be released.

#### Scenario: Cosign failure blocks release
- **WHEN** Cosign signing fails for any artifact (e.g., Sigstore outage, OIDC token error)
- **THEN** the release job fails and no GitHub Release is created

#### Scenario: Partial signing failure
- **WHEN** signing succeeds for some artifacts but fails for others
- **THEN** the release job fails and no GitHub Release is created (all or nothing)

### Requirement: Cosign installation hardening
The Cosign CLI used in CI SHALL be installed via a SHA-pinned action to prevent supply chain attacks on the signing tool itself.

#### Scenario: Cosign installer pinning
- **WHEN** Cosign is installed in the CI workflow
- **THEN** the `sigstore/cosign-installer` action is referenced by full commit SHA with a version comment

### Requirement: Cosign signing produces verifiable signatures
All release artifacts SHALL be signed with Cosign keyless mode and verifiable locally. Signature and certificate files use `.sig` and `.cert` extensions (not `.cosign.sig`/`.cosign.cert`).

#### Scenario: Successful local verification
- **WHEN** a signed artifact and its `.sig` and `.cert` files are downloaded
- **THEN** `cosign verify-blob` succeeds with the correct identity and OIDC issuer

#### Scenario: Tampered artifact fails verification
- **WHEN** a downloaded artifact is modified (e.g., a byte appended)
- **THEN** `cosign verify-blob` fails and reports signature mismatch

#### Scenario: Rekor transparency log entry exists
- **WHEN** a Cosign-signed artifact is released
- **THEN** the signature is recorded in the Rekor transparency log and searchable by artifact hash

#### Scenario: Verification on clean machine
- **WHEN** the release notes verification instructions are followed on a machine with no prior Cosign state
- **THEN** the verification succeeds without additional configuration

