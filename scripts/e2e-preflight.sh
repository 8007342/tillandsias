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

# Detect a live Tillandsias runtime (forge + shared stack) that THIS smoke run
# did not itself launch. A destructive e2e gate's first step is
# `podman system reset --force`, which would wipe a live operator/agent forge
# and any in-flight cycles inside it. The smoke-lock probe only sees competing
# SMOKE runs, not a human- or agent-launched forge, so we must look for the
# stack containers directly. Returns 0 (present) / 1 (absent).
#
# Matches: any container whose name looks like a Tillandsias forge or a shared
# service (git-mirror, vault, proxy, router, inference). The operator may force
# the reset with TILLANDSIAS_DESTRUCTIVE_RESET_OK=1 for a THIS-invocation only.
live_runtime_is_present() {
  local ps_out
  if ! command -v podman >/dev/null 2>&1; then
    return 1
  fi
  # 723-fndi criterion 1: REACHABILITY BEFORE INFERENCE. `podman ps` erroring
  # used to mean PRESENT, which is only sound when the error means "the daemon
  # is there and unhappy". On macOS podman is a client for a machine VM that is
  # usually NOT running, so `podman ps` errors on a host with no containers at
  # all — and the leak-not-destroy convention then reported a live runtime that
  # does not exist. Measured on this host 2026-08-17: podman installed,
  # `podman-machine-default` LAST UP Never, and the verdict was
  # skip:live-runtime-present with nothing running.
  #
  # An UNREACHABLE runtime is ABSENT, not present: there is nothing to leak. The
  # leak-not-destroy convention still applies once the runtime ANSWERS — that is
  # the case it was written for, and the `|| return 0` below preserves it.
  if ! podman info >/dev/null 2>&1; then
    return 1
  fi
  # an errored listing counts as PRESENT (leak-not-destroy, 443-review convention)
  ps_out="$(podman ps --format '{{.Names}}' 2>/dev/null)" || return 0
  [ -z "$ps_out" ] && return 1
  # A forge itself, or any of the shared-stack services the forge brings up.
  # DEV-ENVIRONMENT containers (tillandsias-dev-*) are excluded: they are
  # idempotent, self-relaunching services (the dev cache squid, the 760-3mh8
  # dev-inference lane) that every consumer re-ensures at start — a reset
  # costs one re-ensure, never in-flight work. Without this exclusion the
  # always-on dev-inference container suppressed the destructive e2e gate on
  # every dev host permanently (order 769-g2wr).
  printf '%s\n' "$ps_out" | grep -viE '^tillandsias-dev-' | grep -qiE '^tillandsias-|git-service' && return 0
  return 1
}

# 723-fndi criterion 2. Is a Virtualization.framework guest live RIGHT NOW?
#
# The signal is an open file handle on the VM's backing disk. That is the one
# thing that is true if and only if a VM is actually running, and it was
# measured directly: during a live `--exec-guest` boot on 2026-08-17,
# `lsof rootfs.img` showed `com.apple ... 268435456000 .../rootfs.img`, and
# nothing held it before or after.
#
# NOT `pgrep -f tillandsias-tray`, which is the obvious choice and is WRONG:
# `-f` matches the whole command line, so it fires on ANY process that merely
# mentions the string — an editor, a grep, a CI shell, or the agent command
# that is running this very check. That is not hypothetical: the first draft of
# this probe reported PRESENT against its own invoking shell during the same
# 2026-08-17 boot, before the lsof arm was consulted.
#
# TILLANDSIAS_VZ_IMAGE_OVERRIDE exists so the fixture can point this at a file
# it controls; it defaults to the real path, so a real run is unchanged.
vz_guest_is_live() {
  local img
  img="${TILLANDSIAS_VZ_IMAGE_OVERRIDE:-$HOME/Library/Application Support/tillandsias/rootfs.img}"
  [ -f "$img" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -- "$img" >/dev/null 2>&1
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
      # Fail safe: refuse to wipe a live forge/shared stack the smoke run
      # did not launch, unless the operator FORCES it for THIS invocation.
      if live_runtime_is_present && [ "${TILLANDSIAS_DESTRUCTIVE_RESET_OK:-}" != "1" ]; then
        echo "skip:live-runtime-present"
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
    # Fail safe: refuse to wipe a live forge/shared stack the smoke run
    # did not launch, unless the operator FORCES it for THIS invocation.
    #
    # 723-fndi criterion 2: on Darwin the runtime substrate is the
    # Virtualization.framework guest, NOT podman — podman here is a client for a
    # machine VM this project does not use. Asking podman produced a verdict that
    # carried NO INFORMATION: measured on this host 2026-08-17, `eligibility`
    # printed skip:live-runtime-present BOTH with nothing running AND with a live
    # VM. A constant is not a probe.
    if vz_guest_is_live && [ "${TILLANDSIAS_DESTRUCTIVE_RESET_OK:-}" != "1" ]; then
      echo "skip:live-runtime-present"
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
  # Fail safe: refuse to wipe a live forge/shared stack the smoke run
  # did not launch, unless the operator FORCES it for THIS invocation.
  if live_runtime_is_present && [ "${TILLANDSIAS_DESTRUCTIVE_RESET_OK:-}" != "1" ]; then
    echo "skip:live-runtime-present"
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

# 723-fndi fixture. Pins the property the packet actually cares about: the
# Darwin probe must CARRY INFORMATION. Before this fix it printed
# skip:live-runtime-present in BOTH states — with nothing running and with a
# live VM — measured on this host 2026-08-17 during a real --exec-guest boot.
# A constant verdict is not a probe, and "it no longer says skip" is satisfiable
# by a probe that is constant the other way, which would silently disarm the
# guard that stops an e2e wiping a live stack. So all three transitions are
# asserted, not just the one the packet's criterion 3 names.
if [ "${1:-}" = "fixture" ]; then
  _fx_fail=0
  _fx_dir="$(mktemp -d)"
  _fx_img="$_fx_dir/rootfs.img"
  echo x > "$_fx_img"

  _fx_expect() {
    _n="$1"; _want="$2"
    _got="$(TILLANDSIAS_VZ_IMAGE_OVERRIDE="$_fx_img" bash "$0" eligibility 2>/dev/null)"
    if [ "$_got" = "$_want" ]; then
      echo "ok: $_n ($_got)"
    else
      echo "FAIL: $_n expected '$_want', got '$_got'"
      _fx_fail=1
    fi
  }

  # 1. A backing image with NOTHING holding it is not a live runtime.
  _fx_expect "unheld-image-is-not-a-live-runtime" "eligible"

  # 2. THE SAFETY PROPERTY. A held image IS a live runtime and must refuse —
  #    without this, a probe hard-wired to "eligible" passes every other case
  #    while disarming the guard that keeps an e2e from wiping a live stack.
  ( exec 9< "$_fx_img"; sleep 6 ) &
  _fx_holder=$!
  sleep 1
  _fx_expect "held-image-refuses" "skip:live-runtime-present"
  wait "$_fx_holder" 2>/dev/null

  # 3. And it must RECOVER — a probe that latches PRESENT once would pass 1+2.
  _fx_expect "released-image-is-eligible-again" "eligible"

  # 4. No image at all is not a live runtime (a fresh host, never provisioned).
  rm -f "$_fx_img"
  _fx_expect "absent-image-is-not-a-live-runtime" "eligible"

  rm -rf "$_fx_dir"
  if [ "$_fx_fail" -eq 0 ]; then
    echo "ok: e2e-preflight-darwin-liveness 4/4"
    exit 0
  fi
  echo "FAIL: e2e-preflight-darwin-liveness had failures"
  exit 1
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
