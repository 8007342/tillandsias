#!/usr/bin/env bash
# @trace order:1933-ysbq
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-nix-cache-installer-compatible.sh"
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
printf '      - uses: DeterminateSystems/nix-installer-action@abc # v22\n      - uses: nix-community/cache-nix-action@v7\n' >"$d/bad.yml"
printf '      - uses: cachix/install-nix-action@abc # v31\n      - uses: nix-community/cache-nix-action@v7\n' >"$d/good.yml"
printf '      - uses: DeterminateSystems/nix-installer-action@abc\n' >"$d/nocache.yml"
if "$CHECK" "$d/bad.yml" >/dev/null; then echo "FAIL: incompatible installer accepted"; exit 1; fi
"$CHECK" "$d/good.yml" >/dev/null || { echo "FAIL: compatible installer refused"; exit 1; }
"$CHECK" "$d/nocache.yml" >/dev/null || { echo "FAIL: workflow without cache-nix-action refused"; exit 1; }
"$CHECK" || { echo "FAIL: repository workflows"; exit 1; }
echo "ok:test-check-nix-cache-installer-compatible"
