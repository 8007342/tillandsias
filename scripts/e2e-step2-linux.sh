#!/bin/bash
set -e
LOG_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TILLANDSIAS_SMOKE_LOCK_LOG="$LOG_DIR/00-smoke-lock.log" \
  "$SCRIPT_DIR/with-smoke-lock.sh" --name build-install-smoke-e2e -- \
  podman system reset --force 2>&1 | tee "$LOG_DIR/02-reset.log"
RESET_RC=${PIPESTATUS[0]}; printf 'reset_exit=%s\n' "$RESET_RC" | tee "$LOG_DIR/02-reset-exit.txt"
test "$RESET_RC" -eq 0
CONTAINERS="$(podman ps -aq)"; VOLUMES="$(podman volume ls -q)"; IMAGES="$(podman images -q)"
printf '[containers]\n%s\n[volumes]\n%s\n[images]\n%s\n' "$CONTAINERS" "$VOLUMES" "$IMAGES" \
  | tee "$LOG_DIR/02-empty-store.txt"
test -z "$CONTAINERS"; test -z "$VOLUMES"; test -z "$IMAGES"

# ORDER 900-z3kv — THE STORE IS NOT THE WHOLE ROOM. `podman system reset
# --force` empties containers, volumes and images (asserted immediately above)
# and reaches NONE of the host-side state the guest Vault's identity lives in:
# the keychain items, the fallback_* files, and the host vault-data directory.
# So `--init` recovered a months-old Shamir share and logged "preserving
# existing data volume", and the keychain-volume resync path this smoke claims
# to exercise had not run on Linux since at least 2026-06 — measured on four
# hosts with differently-aged shares, which is what made it a property of the
# lane rather than one host's dirt.
#
# The clearer is the Linux sibling of clear-vault-host-credentials.ps1
# (803-49re/804-ckst). It preserves the installation anchor deliberately:
# clearing `installation-uuid-v1` would make the next vault UNDERIVABLE rather
# than merely re-initialised.
#
# BEST-EFFORT, like its Windows sibling: a credential that is absent is the
# desired end state, and a failure is reported rather than fatal, because a
# purge that aborts halfway leaves more stale state than one that finishes
# noisily. Its verdict is teed so a run can say which state produced it.
"$SCRIPT_DIR/clear-vault-host-credentials.sh" 2>&1 | tee "$LOG_DIR/02-clear-credentials.log" || true

# Record the resulting credential state in the findings, the way the Windows leg
# records its hashes (900-z3kv criterion 2). Metadata only — never the secret.
"$SCRIPT_DIR/probe-credential-cold-state.sh" 2>&1 | tee "$LOG_DIR/02-credential-state.txt" || true
# Order 386: the full stack teardown above must leave zero straggling host
# processes — no tray-parented zombies, no orphaned terminal launchers. The
# probe exits nonzero on any straggler and fails the lane loud.
"$SCRIPT_DIR/container-teardown-straggler-probe.sh" 2>&1 | tee "$LOG_DIR/02-straggler-probe.log"
test "${PIPESTATUS[0]}" -eq 0
