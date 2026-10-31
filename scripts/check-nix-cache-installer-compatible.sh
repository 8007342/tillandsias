#!/usr/bin/env bash
# @trace order:1933-ysbq
# Every workflow that uses nix-community/cache-nix-action must install Nix with
# an installer that action lists as compatible. nix-installer-action is not on
# that list, and with it the cache save's tar exits 2, so the cache is never written.
# Usage: check-nix-cache-installer-compatible.sh [workflow.yml ...]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -eq 0 ]]; then set -- "$ROOT"/.github/workflows/*.yml; fi
compatible='nixbuild/nix-quick-install-action|cachix/install-nix-action|DeterminateSystems/determinate-nix-action'
bad=0
for wf in "$@"; do
    grep -Eq '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*nix-community/cache-nix-action@' "$wf" || continue
    installers=$(grep -Eo '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[^[:space:]#@]+' "$wf" | sed -E 's/.*uses:[[:space:]]*//' | grep -i 'nix' | grep -i 'install' || true)
    if [[ -z "$installers" ]]; then
        echo "fail:nix-cache-installer:$wf:no-nix-installer-step"; bad=1; continue
    fi
    while IFS= read -r inst; do
        if [[ "$inst" =~ ^($compatible)$ ]]; then
            echo "ok:nix-cache-installer:$wf:$inst"
        else
            echo "fail:nix-cache-installer:$wf:$inst is not a cache-nix-action compatible installer"; bad=1
        fi
    done <<<"$installers"
done
exit "$bad"
