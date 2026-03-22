## 1. Workflow Permissions

- [x] 1.1 Add `id-token: write` to the release workflow permissions in `.github/workflows/release.yml` alongside existing `contents: write`
- [x] 1.2 Verify OIDC token generation works by adding a diagnostic step that requests a token and logs the issuer (remove after verification)

## 2. Cosign Installation

- [x] 2.1 Add `sigstore/cosign-installer` action step (SHA-pinned with version comment) to the release/signing job
- [x] 2.2 Add a `cosign version` verification step to confirm successful installation

## 3. Signing Integration

- [x] 3.1 Add signing loop in the release job: after artifacts are collected, iterate over each binary and run `cosign sign-blob --yes --oidc-issuer https://token.actions.githubusercontent.com --output-signature {artifact}.sig --output-certificate {artifact}.cert {artifact}`
- [x] 3.2 Ensure signing uses `--yes` flag for non-interactive mode (no browser prompt in CI)
- [x] 3.3 Verify that each signing operation produces both `.sig` and `.cert` files alongside the binary
- [x] 3.4 Add failure handling: if any `cosign sign-blob` command fails, the entire job fails (preventing unsigned releases)

## 4. Release Asset Upload

- [x] 4.1 Update the GitHub Release creation step to include `.sig` and `.cert` files for each artifact alongside the binaries and `SHA256SUMS`
- [x] 4.2 Verify the release contains the correct number of assets: 3 binaries + 3 `.sig` + 3 `.cert` + `SHA256SUMS` = 10 files

## 5. Verification Instructions

- [x] 5.1 Add a verification command template to the release notes body, automatically populated with the correct artifact names and repository identity for each release
- [x] 5.2 Template should include `cosign verify-blob` with `--certificate`, `--signature`, `--certificate-identity-regexp`, and `--certificate-oidc-issuer` flags
- [x] 5.3 Add a `VERIFYING.md` document to the repository root explaining how to install Cosign and verify artifacts, with examples for all three platforms

## 6. Minisign Fallback Documentation

- [x] 6.1 Document minisign as a fallback strategy in `VERIFYING.md`: when to use it (Sigstore outage), how it works (static key pair), and why Cosign keyless is preferred
- [x] 6.2 Note that minisign implementation is deferred until Sigstore reliability proves insufficient

## 7. Verification Testing

- [ ] 7.1 Test the full signing flow by pushing a release candidate tag (`v0.1.0-rc.2`) and verifying all artifacts are signed
- [ ] 7.2 Download a signed artifact and run `cosign verify-blob` locally to confirm verification succeeds
- [ ] 7.3 Modify a downloaded artifact (e.g., append a byte) and verify that `cosign verify-blob` fails
- [ ] 7.4 Verify Rekor entries exist by searching for the artifact hash in the transparency log
- [ ] 7.5 Test the verification instructions from the release notes on a clean machine (no prior Cosign state)
