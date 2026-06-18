#!/usr/bin/env bash

# @tombstone obsolete:cheatsheet-source-layer
# @trace spec:cheatsheets-license-tiered, spec:cheatsheet-source-layer
#
# This script is RETIRED. Refresh moves to build-time --refresh-sources for
# bundled tier and agent-driven materialization for pull-on-demand. Calling it
# exits early with a notice.
set -euo pipefail

echo "[$(basename "$0")] @tombstone obsolete:cheatsheet-source-layer - script is retired." >&2
echo "  Reason: refresh moves to build-time --refresh-sources for bundled tier and agent-driven materialization for pull-on-demand" >&2
echo "  See openspec/changes/cheatsheets-license-tiered/ for the replacement." >&2
exit 0
