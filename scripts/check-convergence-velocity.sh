#!/usr/bin/env bash
# scripts/check-convergence-velocity.sh — Shell entry point for checking
# convergence velocity and proximity thresholds.
#
# @trace spec:observability-convergence
# @cheatsheet runtime/plan-discipline.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_CHECKER="${SCRIPT_DIR}/check-convergence-velocity.py"

if [[ -f "${PYTHON_CHECKER}" ]]; then
    python3 "${PYTHON_CHECKER}" "$@"
else
    echo "ERROR: Python checker script not found at ${PYTHON_CHECKER}" >&2
    exit 2
fi
