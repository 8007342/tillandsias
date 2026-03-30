---
id: sigstore-cosign
title: Sigstore & Cosign Binary Signing
category: ci/signing
tags: [sigstore, cosign, signing, rekor, fulcio, oidc, transparency-log, keyless]
upstream: https://docs.sigstore.dev/
version_pinned: "2.x"
last_verified: "2026-03-30"
authority: official
---

# Sigstore & Cosign Binary Signing

## Ecosystem

| Component | Role |
|-----------|------|
| **Cosign** | CLI for signing and verifying artifacts (containers, blobs, binaries) |
| **Fulcio** | Certificate authority -- issues short-lived signing certs from OIDC tokens |
| **Rekor** | Append-only transparency log -- stores signed metadata and inclusion proofs |
| **policy-controller** | Kubernetes admission controller enforcing signature policies |

## Keyless Signing Flow

```
OIDC Provider (GitHub, Google, Microsoft)
    |
    v  (id-token)
  Fulcio  -->  short-lived X.509 cert (identity bound)
    |
    v
  Cosign  -->  signs artifact with ephemeral key
    |
    v
  Rekor   -->  records signature + cert + inclusion proof
```

No long-lived keys. Identity proven via OIDC; cert expires in minutes.

## Installation

```bash
# Homebrew
brew install cosign

# Go install
go install github.com/sigstore/cosign/v2/cmd/cosign@latest

# Binary release
curl -sSL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o cosign
chmod +x cosign && sudo mv cosign /usr/local/bin/
```

## Key-Based Signing

```bash
# Generate a key pair (encrypts private key with passphrase)
cosign generate-key-pair
# Produces: cosign.key (private), cosign.pub (public)

# Sign a container image
cosign sign --key cosign.key ghcr.io/org/image@sha256:abc123

# Verify
cosign verify --key cosign.pub ghcr.io/org/image@sha256:abc123
```

## Keyless Signing (OIDC)

```bash
# Sign -- opens browser for OIDC auth (interactive)
cosign sign ghcr.io/org/image@sha256:abc123

# Sign -- non-interactive (CI), skip confirmation
cosign sign --yes ghcr.io/org/image@sha256:abc123

# Verify -- must specify expected identity and issuer
cosign verify ghcr.io/org/image@sha256:abc123 \
  --certificate-identity=user@example.com \
  --certificate-oidc-issuer=https://accounts.google.com

# Verify with regex matching
cosign verify ghcr.io/org/image@sha256:abc123 \
  --certificate-identity-regexp='.*@example\.com' \
  --certificate-oidc-issuer=https://accounts.google.com
```

## Blob Signing

```bash
# Sign a file (keyless, bundle output -- recommended)
cosign sign-blob myfile.tar.gz --bundle myfile.sigstore.json --yes

# Sign a file (key-based)
cosign sign-blob --key cosign.key myfile.tar.gz --bundle myfile.sigstore.json

# Verify blob (keyless)
cosign verify-blob myfile.tar.gz --bundle myfile.sigstore.json \
  --certificate-identity=user@example.com \
  --certificate-oidc-issuer=https://accounts.google.com

# Verify blob (key-based)
cosign verify-blob --key cosign.pub myfile.tar.gz --bundle myfile.sigstore.json

# Legacy: separate signature + certificate outputs (not recommended)
cosign sign-blob myfile.tar.gz \
  --output-signature myfile.sig \
  --output-certificate myfile.cert --yes
```

## Bundle Format

The `.sigstore.json` bundle (recommended) contains:

- **Signature** -- the artifact signature
- **Certificate** -- Fulcio-issued short-lived cert with identity
- **Timestamp** -- signed timestamp from Rekor
- **Inclusion proof** -- cryptographic proof the entry exists in the transparency log

Single file replaces the older separate `.sig` + `.cert` pattern.

## GitHub Actions OIDC Integration

```yaml
jobs:
  sign:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write          # Required for keyless signing
      packages: write          # If pushing to GHCR

    steps:
      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: 'v2.4.1'    # Pin version

      - name: Sign container image
        run: cosign sign --yes ghcr.io/org/image@${{ steps.build.outputs.digest }}

      - name: Sign release binary
        run: |
          cosign sign-blob --yes \
            --bundle myapp.sigstore.json \
            myapp-linux-amd64

      - name: Verify
        run: |
          cosign verify ghcr.io/org/image@${{ steps.build.outputs.digest }} \
            --certificate-identity=https://github.com/org/repo/.github/workflows/release.yml@refs/tags/v1.0.0 \
            --certificate-oidc-issuer=https://token.actions.githubusercontent.com
```

Key points:
- `id-token: write` permission is mandatory for OIDC token generation
- GitHub Actions OIDC issuer: `https://token.actions.githubusercontent.com`
- Certificate identity for workflows: the full workflow ref URI
- `--yes` bypasses interactive confirmation in CI

## Certificate Extensions

Fulcio certificates include X.509v3 extensions:

| Extension OID | Meaning |
|---------------|---------|
| `1.3.6.1.4.1.57264.1.1` | OIDC Issuer (e.g. `https://token.actions.githubusercontent.com`) |
| `1.3.6.1.4.1.57264.1.2` | GitHub Workflow Trigger |
| `1.3.6.1.4.1.57264.1.3` | GitHub Workflow SHA |
| `1.3.6.1.4.1.57264.1.4` | GitHub Workflow Name |
| `1.3.6.1.4.1.57264.1.5` | GitHub Workflow Repository |
| `1.3.6.1.4.1.57264.1.6` | GitHub Workflow Ref |
| Subject | Email or workflow URI (the signing identity) |

Inspect a certificate:

```bash
cosign verify ghcr.io/org/image@sha256:abc123 \
  --certificate-identity-regexp='.*' \
  --certificate-oidc-issuer-regexp='.*' \
  | jq '.[].optional.Bundle.Payload.body' | base64 -d | jq .
```

## Rekor Transparency Log

```bash
# Search by artifact hash
rekor-cli search --sha sha256:abc123def...

# Search by email identity
rekor-cli search --email user@example.com

# Get a specific entry
rekor-cli get --uuid <entry-uuid>

# Get inclusion proof
rekor-cli get --uuid <entry-uuid> --format json | jq '.verification'

# Verify offline (using stored bundle)
cosign verify-blob myfile.tar.gz --bundle myfile.sigstore.json --offline \
  --certificate-identity=user@example.com \
  --certificate-oidc-issuer=https://accounts.google.com
```

Rekor public instance: `https://rekor.sigstore.dev`
Rekor v2 (2025+): supports `hashedrekord` and `dsse` entry types.

## Custom Sigstore Endpoints

```bash
cosign sign --yes \
  --oidc-issuer "https://oauth2.example.com/auth" \
  --fulcio-url "https://fulcio.example.com" \
  --rekor-url "https://rekor.example.com" \
  ghcr.io/org/image@sha256:abc123
```

## Policy Controller (Kubernetes)

Admission controller that blocks unsigned or policy-violating images.

```bash
# Install via Helm
helm repo add sigstore https://sigstore.github.io/helm-charts
helm install policy-controller sigstore/policy-controller \
  -n cosign-system --create-namespace

# Opt-in a namespace
kubectl label namespace default policy.sigstore.dev/include=true

# Define a ClusterImagePolicy
cat <<'EOF' | kubectl apply -f -
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: require-signed-images
spec:
  images:
    - glob: "ghcr.io/org/**"
  authorities:
    - keyless:
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subject: https://github.com/org/repo/.github/workflows/release.yml@refs/heads/main
EOF
```

Supports CUE and Rego policies against attestations.

## Common CI Patterns

**Sign release artifacts after build:**

```bash
for f in dist/*; do
  cosign sign-blob --yes --bundle "${f}.sigstore.json" "$f"
done
```

**Verify before deploy:**

```bash
cosign verify ghcr.io/org/image@sha256:${DIGEST} \
  --certificate-identity=https://github.com/org/repo/.github/workflows/release.yml@refs/tags/${TAG} \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  || { echo "Signature verification failed"; exit 1; }
```

**Attach and verify SBOMs:**

```bash
# Attach SBOM
cosign attach sbom --sbom sbom.spdx.json ghcr.io/org/image@sha256:abc123

# Sign the SBOM attachment
cosign sign --yes ghcr.io/org/image:sha256-abc123.sbom
```

## Quick Reference

| Task | Command |
|------|---------|
| Generate keys | `cosign generate-key-pair` |
| Sign image (keyless) | `cosign sign --yes <image>` |
| Sign image (keyed) | `cosign sign --key cosign.key <image>` |
| Verify image | `cosign verify --certificate-identity=ID --certificate-oidc-issuer=ISS <image>` |
| Sign blob | `cosign sign-blob --yes --bundle out.sigstore.json <file>` |
| Verify blob | `cosign verify-blob --bundle out.sigstore.json --certificate-identity=ID --certificate-oidc-issuer=ISS <file>` |
| Inspect cert | `cosign verify ... \| jq` |
| Search Rekor | `rekor-cli search --sha <hash>` |
