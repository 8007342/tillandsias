#!/bin/bash
set -e

# @trace spec:meta-orchestration
# e2e_eligibility_verdict: structured host-capability probe for the E2E Gates.
#
# Emits exactly one line on stdout: `eligible` or `skip:<reason>`. This replaces
# the per-cycle prose re-derivation of "no /run/user => no podman user session
# => skip" that recurred across many meta-orchestration cycles (see
# plan/issues/meta-orch-enhancement-opportunities-2026-06-20.md candidate 1).
#
# Verdict grammar (falsifiable): ^(eligible|skip:[a-z0-9-]+)$
#   skip:no-podman-binary       podman not on PATH
#   skip:no-podman-user-session no rootless runtime dir (XDG_RUNTIME_DIR / /run/user/<uid>)
#   skip:smoke-lock-held        another local-build smoke owns the host lock
#   skip:podman-not-functional  runtime dir present but `podman info` fails
#   eligible                    rootless podman is usable for local-build e2e
smoke_lock_is_held() {
  local runtime lock_root lock_name lock_file lock_dir fd
  runtime="$1"
  lock_root="${TILLANDSIAS_SMOKE_LOCK_ROOT:-$runtime/tillandsias-locks}"
  lock_name="${TILLANDSIAS_SMOKE_LOCK_NAME:-build-install-smoke-e2e}"
  lock_file="$lock_root/$lock_name.lock"
  lock_dir="$lock_root/$lock_name.lockdir"

  mkdir -p "$lock_root"
  if command -v flock >/dev/null 2>&1; then
    exec {fd}>"$lock_file"
    if ! flock -n "$fd"; then
      eval "exec ${fd}>&-"
      return 0
    fi
    flock -u "$fd"
    eval "exec ${fd}>&-"
    return 1
  fi

  [ -d "$lock_dir" ]
}

e2e_eligibility_verdict() {
  if ! command -v podman >/dev/null 2>&1; then
    echo "skip:no-podman-binary"
    return 0
  fi
  local uid runtime
  uid="$(id -u)"
  runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"
  if [ ! -d "$runtime" ]; then
    echo "skip:no-podman-user-session"
    return 0
  fi
  if smoke_lock_is_held "$runtime"; then
    echo "skip:smoke-lock-held"
    return 0
  fi
  if ! podman info >/dev/null 2>&1; then
    echo "skip:podman-not-functional"
    return 0
  fi
  echo "eligible"
  return 0
}

# Standalone verdict mode: `e2e-preflight.sh eligibility` prints only the verdict
# and exits 0. The E2E Gates consult this instead of re-deriving the verdict in
# prose; the loop branches on the string (eligible vs skip:*), not the exit code.
if [ "${1:-}" = "eligibility" ]; then
  e2e_eligibility_verdict
  exit 0
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="target/build-install-smoke-e2e/$RUN_ID"
mkdir -p "$LOG_DIR"
OS="$(uname -s)"
case "$OS" in
  Linux)  HOST_BRANCH=linux-next  ; HOST_KIND=linux   ;;
  Darwin) HOST_BRANCH=osx-next    ; HOST_KIND=macos   ;;
  *)      HOST_BRANCH=windows-next; HOST_KIND=windows ;;
esac
echo "host_kind=$HOST_KIND host_branch=$HOST_BRANCH" | tee "$LOG_DIR/00-host.txt"
git rev-parse HEAD       | tee "$LOG_DIR/00-commit.txt"
git status --short       | tee "$LOG_DIR/00-status.txt"
cat VERSION 2>/dev/null  | tee "$LOG_DIR/00-version.txt"
# Record the e2e-eligibility verdict once per run (structured, not re-derived prose).
e2e_eligibility_verdict | tee "$LOG_DIR/00-e2e-eligibility.txt"
test -x ./build.sh
echo "$LOG_DIR"
