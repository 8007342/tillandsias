#!/usr/bin/env bash
# validate-spec-cheatsheet-binding-fast.sh — thin wrapper around the full binding audit.
#
# The previous approximation drifted from the real validator. We keep this
# entrypoint for CI compatibility, but delegate to the authoritative checker
# so the reported coverage matches the actual spec/citations graph.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/validate-spec-cheatsheet-binding.sh" --threshold 90
