#!/usr/bin/env bash
# scripts/check-convergence-velocity.sh — Shell entry point for checking
# convergence velocity and proximity thresholds.
#
# @trace spec:observability-convergence
# @cheatsheet runtime/plan-discipline.md

set -euo pipefail

# This script was previously backed by a Python checker.
# It is currently a stub while the Rust replacement is being integrated
# into the tillandsias-metrics or tillandsias-logging crate.
# Tlatoani has approved the temporary removal of the Python implementation.

echo "WARN: check-convergence-velocity is currently a no-op (Python retired)" >&2
exit 0
