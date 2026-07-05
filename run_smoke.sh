#!/bin/bash
set -ex

mkdir -p target/smoke-e2e

TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  bash -c 'curl -fsSL http://localhost:8000/install.sh | bash' 2>&1 \
  | tee target/smoke-e2e/01-install.log

hash -r
~/.local/bin/tillandsias --version | tee target/smoke-e2e/01-version.txt

TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  podman system reset --force 2>&1 | tee target/smoke-e2e/02-reset.log

TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  ~/.local/bin/tillandsias --debug --init 2>&1 | tee target/smoke-e2e/03-init.log

INIT_RC=${PIPESTATUS[0]}
echo "init exit: $INIT_RC"
if [ "$INIT_RC" -ne 0 ]; then
  exit 1
fi

TILLANDSIAS_SMOKE_LOCK_LOG=target/smoke-e2e/00-smoke-lock.log \
  scripts/with-smoke-lock.sh --name release-smoke-e2e -- \
  env TILLANDSIAS_NO_TRAY=1 ~/.local/bin/tillandsias . --opencode --prompt "Use the /meta-orchestration skill" 2>&1 \
  | tee target/smoke-e2e/04-opencode.log

