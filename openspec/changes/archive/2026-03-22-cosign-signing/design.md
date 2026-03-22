## Context

The release-pipeline change (Phase 1) establishes a GitHub Actions CI/CD pipeline that builds multi-platform Tauri binaries and publishes them to GitHub Releases with SHA256 checksums. Phase 2 adds cryptographic signing to these artifacts using Sigstore Cosign in keyless mode.

Cosign keyless signing uses short-lived certificates issued by Sigstore's Fulcio CA, with the signer's identity attested via OIDC. In GitHub Actions, the identity is the workflow itself -- bound to a specific repository, workflow file, and ref. Signatures are recorded in Rekor, Sigstore's immutable transparency log, making it impossible to sign a binary and later deny it.

**Constraints:**
- No persistent signing keys (keyless mode is mandatory per TILLANDSIAS-RELEASE.md)
- Signing must happen in CI, never locally
- Verification must work offline (once certificate and signature are downloaded)
- Must not break existing Phase 1 workflow; adds steps, doesn't replace them

## Goals / Non-Goals

**Goals:**
- Sign every release artifact with Cosign keyless mode via GitHub OIDC
- Publish `.sig` and `.cert` files alongside each artifact
- Record all signatures in the Rekor transparency log
- Provide clear verification commands in release notes
- Document minisign as a fallback strategy

**Non-Goals:**
- macOS notarization or Windows Authenticode signing (Phase 4)
- Integrating signature verification into the Tauri auto-updater (Phase 3)
- Requiring users to install Cosign to use the application
- Building a custom signature format or verification tool
- Signing container images (only desktop binaries are signed)

## Decisions

### D1: Keyless Mode via GitHub OIDC

**Choice:** Cosign keyless mode exclusively. No persistent key pairs.

The signing flow in CI:
1. GitHub Actions generates an OIDC token proving the workflow identity
2. Cosign sends the OIDC token to Fulcio (Sigstore CA)
3. Fulcio issues a short-lived signing certificate binding the workflow identity
4. Cosign signs the artifact with an ephemeral key
5. The signature and certificate are uploaded to Rekor (transparency log)
6. The `.sig` and `.cert` files are saved as release artifacts

**Identity claims in the certificate:**
- Issuer: `https://token.actions.githubusercontent.com`
- Subject: `https://github.com/<owner>/tillandsias/.github/workflows/release.yml@refs/tags/<version>`
- Repository: `<owner>/tillandsias`

**Why over persistent keys:**
- No key management burden (no rotation, no storage, no revocation)
- No single point of compromise (an attacker can't steal a key that doesn't exist)
- Identity is tied to the CI pipeline, not a human
- Transparency log prevents backdating or covert signing

**Alternatives considered:**
- GPG signing with stored key -- requires secrets management, key rotation, and is opaque to verification (who owns the key?)
- minisign with static key -- simpler but requires key storage, no transparency log, identity is just "whoever has the key"

### D2: Signing Granularity

**Choice:** Sign each individual artifact separately. One `.sig` and one `.cert` per binary.

Release assets:
```
tillandsias-v0.1.0-linux-x86_64.AppImage
tillandsias-v0.1.0-linux-x86_64.AppImage.sig
tillandsias-v0.1.0-linux-x86_64.AppImage.cert
tillandsias-v0.1.0-macos-aarch64.dmg
tillandsias-v0.1.0-macos-aarch64.dmg.sig
tillandsias-v0.1.0-macos-aarch64.dmg.cert
tillandsias-v0.1.0-windows-x86_64.exe
tillandsias-v0.1.0-windows-x86_64.exe.sig
tillandsias-v0.1.0-windows-x86_64.exe.cert
SHA256SUMS
```

**Why over signing only the checksum file:** Signing individual artifacts means users can verify any single binary without downloading all of them. It also means each artifact carries its own proof of origin. Signing only `SHA256SUMS` creates a single point of trust that doesn't work if a user downloads just one binary.

### D3: Signing Job Placement in Workflow

**Choice:** Add signing as a step within the existing checksum/release job, after artifacts are collected and before release creation.

```
Build (matrix: linux, macos, windows)
  ↓
Collect artifacts + generate checksums + sign each artifact
  ↓
Create GitHub Release with all assets
```

**Why not a separate signing job:** Signing needs access to all artifacts (same as checksum generation). Running it in the same job avoids an additional artifact upload/download round-trip. The signing step is idempotent -- if it fails, no release is created.

### D4: Cosign Installation in CI

**Choice:** Install Cosign via `sigstore/cosign-installer` action, pinned by commit SHA.

```yaml
- uses: sigstore/cosign-installer@<sha>  # v3.x.x
```

**Why the official installer action:** It handles platform detection, version management, and checksum verification of the Cosign binary itself. SHA-pinning prevents supply chain attacks on the installer.

### D5: Verification Command Pattern

**Choice:** Publish verification commands in every GitHub Release body and in the repository documentation.

```bash
cosign verify-blob \
  --certificate tillandsias-v0.1.0-linux-x86_64.AppImage.cert \
  --signature tillandsias-v0.1.0-linux-x86_64.AppImage.sig \
  --certificate-identity-regexp "https://github.com/.*/tillandsias/" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  tillandsias-v0.1.0-linux-x86_64.AppImage
```

**Why `--certificate-identity-regexp`:** The exact identity URL includes the tag version, which changes per release. A regexp matching the repository path is stable across releases while still restricting verification to the correct repository's workflows.

### D6: Minisign Fallback Strategy

**Choice:** Document minisign as a fallback for environments where Cosign or Sigstore infrastructure is unavailable, but do not implement it in Phase 2.

**Rationale:** Cosign keyless depends on Sigstore infrastructure (Fulcio, Rekor). If Sigstore has an outage during a release, a minisign fallback with a static key pair could sign the release. However, this adds key management complexity that Phase 2 should avoid. Document the fallback; implement only if Sigstore reliability proves insufficient.

## Risks / Trade-offs

**[Sigstore infrastructure dependency]** The signing flow requires Fulcio (CA) and Rekor (transparency log) to be available at signing time. Sigstore is operated by the Linux Foundation and has high availability, but a total outage during a release would block signing. Mitigation: releases can proceed without signing in emergency (manual override), and the minisign fallback is documented.

**[Certificate expiry]** Fulcio certificates are short-lived (minutes). Verification uses the Rekor transparency log timestamp to prove the signature was created while the certificate was valid. Users verifying years later depend on Rekor's availability. Mitigation: Rekor is append-only and publicly archived; the risk of data loss is minimal.

**[OIDC token scope]** The `id-token: write` permission grants the workflow the ability to request OIDC tokens from GitHub. This is scoped to the workflow run and cannot be used outside it. The risk is low, but it is an additional permission beyond Phase 1's `contents: write`.

**[Verification complexity for users]** `cosign verify-blob` requires installing Cosign and understanding the flags. Most users will not verify signatures manually. Mitigation: verification is optional for humans (the auto-updater in Phase 3 will verify automatically). Power users who want to verify have the commands in the release notes.

## Resolved Questions

- **Sign artifacts or checksum file?** Sign individual artifacts. Reasoning in D2.
- **Separate job or inline step?** Inline step in the release job. Reasoning in D3.

## Open Questions

- **Should the `SHA256SUMS` file also be signed?** It's redundant (individual artifacts are signed), but signing the checksum file is a common convention that some users expect. Low cost to add.
- **Rekor log search instructions:** Should we publish the Rekor entry URLs in release notes so users can inspect the transparency log directly? Adds transparency but also adds complexity to release notes.
