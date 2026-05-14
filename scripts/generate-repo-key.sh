#!/usr/bin/env bash
# Legacy GPG key generation helper for historical APT/RPM repo signing.
# This script is not part of the active Cosign bundle release contract.
# Run once, then store private key as REPO_GPG_PRIVATE_KEY GitHub secret
#
# Usage:
#   ./scripts/generate-repo-key.sh
#
# After running:
#   1. Commit repo-key.gpg to the repository
#   2. Store repo-key-private.gpg as GitHub secret REPO_GPG_PRIVATE_KEY
#   3. DELETE repo-key-private.gpg from disk immediately
#
set -euo pipefail

gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: Tillandsias Release
Name-Email: releases@tillandsias.dev
Expire-Date: 0
%commit
EOF

# Export
gpg --armor --export "Tillandsias Release" > repo-key.gpg
gpg --armor --export-secret-keys "Tillandsias Release" > repo-key-private.gpg
echo "Public key: repo-key.gpg (commit to repo)"
echo "Private key: repo-key-private.gpg (store as GitHub secret REPO_GPG_PRIVATE_KEY)"
echo "DELETE repo-key-private.gpg after storing as secret!"
