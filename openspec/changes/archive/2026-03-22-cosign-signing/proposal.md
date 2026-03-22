## Why

SHA256 checksums (Phase 1) prove that a downloaded file matches what was uploaded, but they don't prove who uploaded it. If an attacker compromises the GitHub Release assets or performs a MITM attack, they can replace both the binary and its checksum. Users have no way to distinguish a legitimate release from a tampered one.

Cosign (Sigstore) keyless signing solves this by tying each signature to the GitHub Actions workflow identity via OIDC. The signing key is ephemeral -- generated per run, never stored -- and every signature is recorded in the Rekor transparency log. Anyone can verify that a binary was signed by the Tillandsias CI pipeline in a specific repository, on a specific commit, with no possibility of backdating or forgery. This is free, requires no key management, and works without any user-side tooling beyond a single `cosign verify-blob` command.

This is Phase 2 of the release strategy defined in TILLANDSIAS-RELEASE.md. It adds integrity verification on top of the CI/CD pipeline established in Phase 1 (release-pipeline) and provides the trust foundation that Phase 3 (auto-updater) relies on for safe automatic updates.

## What Changes

- **Cosign signing step** added to the release workflow after artifact builds, signing each binary using keyless mode with GitHub OIDC identity
- **Signature and certificate artifacts** (`.sig` and `.cert` files) uploaded alongside each binary in the GitHub Release
- **Verification instructions** published in the release notes, enabling users to verify signatures via `cosign verify-blob`
- **OIDC token permissions** added to the GitHub Actions workflow for Sigstore identity federation
- **Minisign fallback documentation** for environments where Cosign is unavailable

## Capabilities

### New Capabilities
- `binary-signing`: Cosign keyless signing of release artifacts -- GitHub OIDC identity federation, ephemeral key generation, Rekor transparency log recording, per-artifact `.sig` and `.cert` files, public verification via `cosign verify-blob`, minisign fallback strategy

### Modified Capabilities
<!-- Depends on ci-release from release-pipeline but does not modify it; adds signing steps after build -->

## Impact

- **Modified files**: `.github/workflows/release.yml` (add signing job/steps after build)
- **New artifacts per release**: `{artifact}.sig` and `{artifact}.cert` for each binary
- **GitHub configuration**: Workflow needs `id-token: write` permission for OIDC token generation (Sigstore keyless flow)
- **External dependency**: Cosign CLI installed in CI (via `sigstore/cosign-installer` action, SHA-pinned)
- **No code changes**: Only CI and release metadata are affected
- **User impact**: Power users can verify downloads; average users are unaffected (verification is optional in Phase 2, mandatory in Phase 3 auto-updater)
