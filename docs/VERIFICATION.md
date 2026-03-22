# Verifying Tillandsias Release Artifacts

Every Tillandsias release artifact is cryptographically signed using [Sigstore Cosign](https://docs.sigstore.dev/) in **keyless mode**. This means:

- No persistent signing keys exist -- there is nothing to steal or rotate.
- The signer's identity is the GitHub Actions CI pipeline, proven via OIDC.
- Every signature is recorded in the [Rekor transparency log](https://rekor.sigstore.dev/), creating a public, immutable, timestamped record.

Verification is optional for normal use, but recommended for anyone who wants to confirm that a binary was produced by the official Tillandsias CI pipeline and has not been tampered with.

## What you need

For each artifact you want to verify, download three files from the GitHub Release:

| File | Purpose |
|------|---------|
| `<artifact>` | The binary (e.g., `.AppImage`, `.dmg`, `.exe`) |
| `<artifact>.cosign.sig` | Cosign signature |
| `<artifact>.cosign.cert` | Fulcio signing certificate |

> **Note:** Tauri also produces `.sig` files for auto-update bundles (Ed25519 signatures). Those are separate from the `.cosign.sig` files used for Cosign verification.

## Install Cosign

### macOS

```bash
brew install cosign
```

### Linux (Debian / Ubuntu)

```bash
sudo apt-get install cosign
```

### Linux (Fedora)

```bash
sudo dnf install cosign
```

### Linux (Arch)

```bash
sudo pacman -S cosign
```

### Windows

Download the latest release from [github.com/sigstore/cosign/releases](https://github.com/sigstore/cosign/releases) and add it to your PATH.

### Other

See the [Cosign installation docs](https://docs.sigstore.dev/cosign/system_config/installation/).

## Verify an artifact

### Using the verification script

The repository includes a helper script that wraps the verification command:

```bash
./scripts/verify.sh tillandsias_0.1.0_amd64.AppImage
```

The script checks that the `.cosign.sig` and `.cosign.cert` files are present alongside the artifact and runs the appropriate `cosign verify-blob` command.

### Manual verification

Run `cosign verify-blob` directly with the certificate identity and OIDC issuer flags:

**Linux (AppImage)**

```bash
cosign verify-blob \
  --certificate tillandsias_0.1.0_amd64.AppImage.cosign.cert \
  --signature tillandsias_0.1.0_amd64.AppImage.cosign.sig \
  --certificate-identity-regexp "https://github.com/.*/tillandsias/" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  tillandsias_0.1.0_amd64.AppImage
```

**macOS (DMG)**

```bash
cosign verify-blob \
  --certificate Tillandsias_0.1.0_aarch64.dmg.cosign.cert \
  --signature Tillandsias_0.1.0_aarch64.dmg.cosign.sig \
  --certificate-identity-regexp "https://github.com/.*/tillandsias/" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  Tillandsias_0.1.0_aarch64.dmg
```

**Windows (EXE)**

```bash
cosign verify-blob \
  --certificate Tillandsias_0.1.0_x64-setup.exe.cosign.cert \
  --signature Tillandsias_0.1.0_x64-setup.exe.cosign.sig \
  --certificate-identity-regexp "https://github.com/.*/tillandsias/" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  Tillandsias_0.1.0_x64-setup.exe
```

Replace the filenames with the actual artifact names from your release. The exact names vary by version.

### Expected output

On success:

```
Verified OK
```

On failure (tampered artifact or wrong certificate):

```
Error: verifying blob [artifact]: ...
```

## Verify SHA256 checksums

Each release also includes a `SHA256SUMS` file. After downloading:

```bash
sha256sum -c SHA256SUMS
```

On macOS, use `shasum -a 256 -c SHA256SUMS` instead.

## Offline verification

If Rekor (the transparency log) is temporarily unavailable, you can still verify using the certificate and signature alone by adding the `--insecure-ignore-tlog` flag:

```bash
cosign verify-blob \
  --certificate <artifact>.cosign.cert \
  --signature <artifact>.cosign.sig \
  --certificate-identity-regexp "https://github.com/.*/tillandsias/" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  --insecure-ignore-tlog \
  <artifact>
```

This skips the transparency log check. The signature and certificate still provide cryptographic proof of origin, but without the timestamped log entry, you lose the non-repudiation guarantee. Use this only when Rekor is unavailable.

## Searching the Rekor transparency log

Every signing event is recorded in the public Rekor log. You can search for an artifact's entry by its SHA256 hash:

```bash
HASH=$(sha256sum <artifact> | cut -d' ' -f1)
rekor-cli search --sha "${HASH}"
```

Or use the [Rekor web interface](https://search.sigstore.dev/) to search by hash.

## How it works

When a release is built in GitHub Actions:

1. GitHub generates an OIDC token proving the workflow's identity (repository, workflow file, git ref).
2. Cosign sends the OIDC token to **Fulcio** (Sigstore's certificate authority).
3. Fulcio issues a short-lived signing certificate binding the workflow identity to an ephemeral key.
4. Cosign signs the artifact with the ephemeral key.
5. The signature, certificate, and artifact hash are recorded in **Rekor** (the transparency log).
6. The ephemeral key is discarded -- it cannot be recovered or reused.
7. The `.cosign.sig` and `.cosign.cert` files are uploaded alongside the binary in the GitHub Release.

When you verify, Cosign checks that:
- The signature matches the artifact content (integrity).
- The certificate was issued by Fulcio for the expected identity (authenticity).
- The signing event exists in the Rekor log (non-repudiation).

## Minisign fallback

[Minisign](https://jedisct1.github.io/minisign/) is documented as a fallback strategy for environments where Cosign or Sigstore infrastructure is unavailable.

**When to use minisign:**
- Sigstore is experiencing an outage during a critical release.
- Your environment cannot reach Sigstore services (air-gapped networks).

**How minisign differs from Cosign keyless:**
- Minisign uses a **static key pair** -- a long-lived private key signs artifacts, and a public key verifies them.
- There is **no transparency log** -- you trust whoever holds the private key.
- Key management is required: the private key must be stored securely, and compromise means all past and future signatures are untrustworthy until the key is rotated.

**Why Cosign keyless is preferred:**
- No key management burden (no rotation, storage, or revocation).
- Identity is tied to the CI pipeline, not a human or a key file.
- The transparency log prevents backdating or covert signing.
- No single point of compromise (an attacker cannot steal a key that does not exist).

Minisign implementation is deferred until Sigstore reliability proves insufficient. If minisign is ever activated, the public key will be published in this repository and verification instructions will be added to release notes.
