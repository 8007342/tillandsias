#!/usr/bin/env bash

# @tombstone obsolete:cheatsheet-source-layer
# @trace spec:cheatsheets-license-tiered, spec:cheatsheet-source-layer
#
# This script is RETIRED. It is superseded by build-time meta side-channel
# injection in build-image.sh. Calling it exits early with a notice.
set -euo pipefail

echo "[$(basename "$0")] @tombstone obsolete:cheatsheet-source-layer - script is retired." >&2
echo "  Reason: superseded by build-time meta side-channel injection in build-image.sh" >&2
echo "  See openspec/changes/cheatsheets-license-tiered/ for the replacement." >&2
exit 0
