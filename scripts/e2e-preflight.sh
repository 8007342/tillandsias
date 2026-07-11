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
#   skip:no-podman-binary       podman not on PATH (Linux/Windows path)
#   skip:no-podman-user-session no rootless runtime dir (XDG_RUNTIME_DIR / /run/user/<uid>)
#   skip:smoke-lock-held        another local-build smoke owns the host lock
#   skip:podman-not-functional  runtime dir present but `podman info` fails
#   skip:no-macos-hypervisor    Darwin host without Hypervisor.framework support
#   eligible                    host substrate is usable for local-build e2e
#
# Darwin note: the macOS local-build e2e substrate is the Virtualization.framework
# VM, not rootless Podman, so the Darwin branch probes kern.hv_support instead of
# /run/user/<uid> (which never exists on macOS and used to permanently mis-verdict
# macOS hosts as skip:no-podman-user-session). An explicitly-set XDG_RUNTIME_DIR
# is still honored on Darwin so the deterministic no-session and smoke-lock litmus
# pins hold on every platform.
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
  # Windows (Git Bash / MSYS): the local-build e2e substrate is the WSL2
  # distro — podman lives INSIDE it, so probing for a host podman binary is
  # meaningless here (it made every Windows host emit skip:no-podman-binary
  # and unconditionally skip an eligible gate; see
  # plan/issues/build-install-smoke-e2e-findings-2026-07-09-windows.md,
  # smoke-finding/e2e-preflight-not-windows-aware). Probe wsl.exe instead.
  # The XDG_RUNTIME_DIR override branch mirrors Darwin's so the litmus
  # no-session/smoke-lock steps stay deterministic on every platform.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      local runtime
      if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        if [ ! -d "$XDG_RUNTIME_DIR" ]; then
          echo "skip:no-podman-user-session"
          return 0
        fi
        runtime="$XDG_RUNTIME_DIR"
      else
        runtime="${TEMP:-/tmp}"
      fi
      if smoke_lock_is_held "$runtime"; then
        echo "skip:smoke-lock-held"
        return 0
      fi
      if ! command -v wsl.exe >/dev/null 2>&1; then
        echo "skip:no-wsl"
        return 0
      fi
      echo "eligible"
      return 0
      ;;
  esac
  if [ "$(uname -s)" = "Darwin" ]; then
    local runtime
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      if [ ! -d "$XDG_RUNTIME_DIR" ]; then
        echo "skip:no-podman-user-session"
        return 0
      fi
      runtime="$XDG_RUNTIME_DIR"
    else
      runtime="${TMPDIR:-/tmp}"
    fi
    if smoke_lock_is_held "$runtime"; then
      echo "skip:smoke-lock-held"
      return 0
    fi
    if [ "$(sysctl -n kern.hv_support 2>/dev/null)" != "1" ]; then
      echo "skip:no-macos-hypervisor"
      return 0
    fi
    echo "eligible"
    return 0
  fi
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
