#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

cargo build --quiet -p tillandsias-policy
exec target/debug/tillandsias-policy check-no-python-scripts
