#!/usr/bin/env bash
# @trace spec:proxy-container, spec:user-runtime-lifecycle, spec:litmus-framework
# Compatibility wrapper for the canonical image build engine.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/scripts/build-image.sh" proxy "$@"
