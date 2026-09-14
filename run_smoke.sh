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

# ORDER 900-z3kv — the reset empties the podman store and reaches NONE of the
# host-side state the guest Vault's identity lives in: the keychain items, the
# fallback_* files, and the host vault-data directory. Without this, `--init`
# below RECOVERS a pre-existing Shamir share instead of re-initialising, and the
# keychain-volume resync path this smoke exists to exercise does not run — which
# is what every Linux "clean room" pass silently carried since at least 2026-06.
#
# This script is the SECOND destroy path. The first (scripts/e2e-step2-linux.sh)
# was wired in the same commit; this one was found by the guard rather than by
# enumeration, which is the whole reason 803-49re built a guard instead of
# making careful edits. Best-effort, like its Windows sibling: absent is the
# desired end state and a failure is reported rather than fatal.
scripts/clear-vault-host-credentials.sh 2>&1 | tee target/smoke-e2e/02-clear-credentials.log || true

# Record which state this run actually started in (criterion 2), metadata only.
scripts/probe-credential-cold-state.sh 2>&1 | tee target/smoke-e2e/02-credential-state.txt || true

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

