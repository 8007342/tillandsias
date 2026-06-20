#!/usr/bin/env bash
# NanoClawV2 orchestration entrypoint
# @trace spec:nanoclawv2-orchestration
set -euo pipefail

cd /home/forge/src

PROJECT="${TILLANDSIAS_PROJECT_PATH:-$(pwd)}"
BRANCH="${TILLANDSIAS_PROJECT_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}"

echo "[nanoclawv2] Starting orchestration for ${PROJECT} (${BRANCH})"
echo "[nanoclawv2] Allowed actions: advance-work-from-plan, build, service-launch, forge-delegate, status"

exec /usr/local/bin/opencode run \
  --dangerously-skip-permissions \
  --prompt "Use the /advance-work-from-plan skill to advance work for the project at ${PROJECT}"
