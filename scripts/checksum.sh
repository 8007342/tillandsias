#!/usr/bin/env bash
# Generate SHA256 checksums for all release artifacts in a directory.
#
# Usage: ./scripts/checksum.sh <artifact-directory>
#
# Produces a SHA256SUMS file inside the artifact directory containing
# one line per file in the standard `sha256sum` format:
#   <hash>  <filename>
#
# Verify with: sha256sum -c SHA256SUMS

set -euo pipefail

ARTIFACT_DIR="${1:?Usage: $0 <artifact-directory>}"

if [ ! -d "${ARTIFACT_DIR}" ]; then
  echo "Error: '${ARTIFACT_DIR}' is not a directory" >&2
  exit 1
fi

CHECKSUMS_FILE="${ARTIFACT_DIR}/SHA256SUMS"

# Remove any pre-existing checksums file so it is not included in its own output
rm -f "${CHECKSUMS_FILE}"

# Collect all files (non-directories) in the artifact directory
FILES=()
for f in "${ARTIFACT_DIR}"/*; do
  [ -f "$f" ] && FILES+=("$f")
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "Error: no artifacts found in '${ARTIFACT_DIR}'" >&2
  exit 1
fi

# Generate checksums using only the basename (not full path) so that
# verification works regardless of download location
(
  cd "${ARTIFACT_DIR}"
  sha256sum -- * > SHA256SUMS
)

echo "SHA256SUMS generated with ${#FILES[@]} entries:"
cat "${CHECKSUMS_FILE}"
