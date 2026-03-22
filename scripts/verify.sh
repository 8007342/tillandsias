#!/usr/bin/env bash
# Verify a Tillandsias release artifact using Cosign keyless signatures.
#
# Usage: ./scripts/verify.sh <artifact>
#
# Prerequisites:
#   - cosign installed (https://github.com/sigstore/cosign/releases)
#   - The artifact's .cosign.sig and .cosign.cert files in the same directory
#
# Example:
#   ./scripts/verify.sh tillandsias_0.1.0_amd64.AppImage
#
# The script expects these files alongside the artifact:
#   <artifact>.cosign.sig   - Cosign signature
#   <artifact>.cosign.cert  - Fulcio signing certificate
#
# Note: Tauri also produces Ed25519 .sig files for auto-update bundles.
# Those are separate from the Cosign .cosign.sig files used here.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CERTIFICATE_IDENTITY_REGEXP="https://github.com/.*/tillandsias/"
CERTIFICATE_OIDC_ISSUER="https://token.actions.githubusercontent.com"

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

if [ $# -lt 1 ]; then
  echo "Usage: $0 <artifact>" >&2
  echo "" >&2
  echo "Example:" >&2
  echo "  $0 tillandsias-v0.1.0-linux-x86_64.AppImage" >&2
  exit 1
fi

ARTIFACT="$1"

if [ ! -f "${ARTIFACT}" ]; then
  echo "Error: artifact not found: ${ARTIFACT}" >&2
  exit 1
fi

SIG_FILE="${ARTIFACT}.cosign.sig"
CERT_FILE="${ARTIFACT}.cosign.cert"

if [ ! -f "${SIG_FILE}" ]; then
  echo "Error: Cosign signature file not found: ${SIG_FILE}" >&2
  echo "Download it from the same GitHub Release as the artifact." >&2
  exit 1
fi

if [ ! -f "${CERT_FILE}" ]; then
  echo "Error: Cosign certificate file not found: ${CERT_FILE}" >&2
  echo "Download it from the same GitHub Release as the artifact." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check for cosign
# ---------------------------------------------------------------------------

if ! command -v cosign &>/dev/null; then
  echo "Error: cosign is not installed." >&2
  echo "" >&2
  echo "Install cosign:" >&2
  echo "  macOS:         brew install cosign" >&2
  echo "  Debian/Ubuntu: sudo apt-get install cosign" >&2
  echo "  Fedora:        sudo dnf install cosign" >&2
  echo "  Arch Linux:    sudo pacman -S cosign" >&2
  echo "  Other:         https://github.com/sigstore/cosign/releases" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

echo "Verifying: ${ARTIFACT}"
echo "  Signature:   ${SIG_FILE}"
echo "  Certificate: ${CERT_FILE}"
echo ""

cosign verify-blob \
  --certificate "${CERT_FILE}" \
  --signature "${SIG_FILE}" \
  --certificate-identity-regexp "${CERTIFICATE_IDENTITY_REGEXP}" \
  --certificate-oidc-issuer "${CERTIFICATE_OIDC_ISSUER}" \
  "${ARTIFACT}"

echo ""
echo "Verification succeeded. The artifact was signed by the Tillandsias CI pipeline."
