#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-help}"

case "$MODE" in
  check-live-cache)
    if [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
      echo "SKIP: no GH_TOKEN available (run in CI or export GH_TOKEN to check live cache size)"
      exit 0
    fi
    REPO="8007342/tillandsias"
    TOTAL_BYTES=$(gh api --paginate "/repos/${REPO}/actions/caches?per_page=100" \
      --jq '[.actions_caches[] | select(.key | contains("nix")) | .size_in_bytes] | add // 0' 2>/dev/null || echo "0")
    THRESHOLD_BYTES=$((8 * 1024 * 1024 * 1024))
    echo "nix cache total: ${TOTAL_BYTES} bytes (threshold: ${THRESHOLD_BYTES})"
    if [ "${TOTAL_BYTES}" -gt "${THRESHOLD_BYTES}" ]; then
      echo "WARN: nix cache exceeds 80% of LRU limit — trigger nix-cache-warm.yml to purge"
      exit 1
    fi
    echo "nix cache size ok"
    ;;
  help|*)
    echo "Usage: $0 {check-live-cache}"
    exit 2
    ;;
esac
