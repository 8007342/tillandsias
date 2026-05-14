#!/usr/bin/env bash
# @trace spec:binary-signing
# Verify a Tillandsias release artifact using Cosign keyless signatures.
#
# Usage: ./scripts/verify.sh <artifact>
#
# Prerequisites:
#   - cosign v3.0+ installed (https://github.com/sigstore/cosign/releases)
#   - The artifact's .cosign.bundle file in the same directory
#
# Example:
#   ./scripts/verify.sh Tillandsias-linux-x86_64.AppImage
#
# The script expects this file alongside the artifact:
#   <artifact>.cosign.bundle  - Sigstore bundle (signature, cert, timestamp)
#
# Note: Tauri also produces Ed25519 .sig files for auto-update bundles.
# Those are separate from the Cosign .cosign.bundle files used here.

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
  echo "  $0 Tillandsias-linux-x86_64.AppImage" >&2
  exit 1
fi

ARTIFACT="$1"

if [ ! -f "${ARTIFACT}" ]; then
  echo "Error: artifact not found: ${ARTIFACT}" >&2
  exit 1
fi

BUNDLE_FILE="${ARTIFACT}.cosign.bundle"

if [ ! -f "${BUNDLE_FILE}" ]; then
  echo "Error: Cosign bundle file not found: ${BUNDLE_FILE}" >&2
  echo "Download it from the same GitHub Release as the artifact." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Check for cosign
# ---------------------------------------------------------------------------

if ! command -v cosign &>/dev/null; then
  echo "Error: cosign is not installed." >&2
  echo "" >&2
  echo "Install cosign v3.0+:" >&2
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
echo "  Bundle: ${BUNDLE_FILE}"
echo ""

cosign verify-blob \
  --bundle "${BUNDLE_FILE}" \
  --certificate-identity-regexp "${CERTIFICATE_IDENTITY_REGEXP}" \
  --certificate-oidc-issuer "${CERTIFICATE_OIDC_ISSUER}" \
  "${ARTIFACT}"

echo ""
echo "Verification succeeded. The artifact was signed by the Tillandsias CI pipeline."
