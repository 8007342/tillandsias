#!/usr/bin/env bash
# Automated post-provision enclave assertion for macOS.
#
# Launches the tray, boots the VM, and waits for the headless agent to report
# phase=Ready podman_ready=true within a bounded timeout. Fails loudly if the
# VM stays Failed or times out.
#
# Designed to run unattended as a gate so the macOS tray cannot silently
# regress to "VM Failed" (the original m8 finding).
#
# Exit codes:
#   0 — enclave is Ready
#   2 — degraded (VM booted but headless did not reach Ready within timeout)
#   1 — hard failure (tray binary not found)
#
# @trace plan/steps/49-macos-in-vm-enclave.md (49e)
# @trace plan/issues/macos-m8-interactive-smoke-failures-2026-06-16.md

set -euo pipefail

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BOLD=''; RESET=''
fi

WRITE_CHECK_PREFIX=""
write_check() {
    local label="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "true" ]]; then
        printf "${WRITE_CHECK_PREFIX}${GREEN}PASS${RESET} %s" "$label"
    else
        printf "${WRITE_CHECK_PREFIX}${RED}FAIL${RESET} %s" "$label"
    fi
    if [[ -n "$detail" ]]; then
        printf ": %s" "$detail"
    fi
    printf "\n"
}

IMAGE_ROOT="$HOME/Library/Application Support/tillandsias"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

resolve_tray_exe() {
    if [[ -n "${TILLANDSIAS_TRAY_EXE:-}" ]]; then
        if [[ -x "$TILLANDSIAS_TRAY_EXE" ]]; then
            echo "$TILLANDSIAS_TRAY_EXE"
            return
        fi
        echo "error: TILLANDSIAS_TRAY_EXE not executable: $TILLANDSIAS_TRAY_EXE" >&2
        exit 1
    fi
    local user_installed="$HOME/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray"
    local sys_installed="/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray"
    if [[ -x "$user_installed" ]]; then
        echo "$user_installed"
        return
    fi
    if [[ -x "$sys_installed" ]]; then
        echo "$sys_installed"
        return
    fi
    if command -v tillandsias-tray >/dev/null 2>&1; then
        command -v tillandsias-tray
        return
    fi
    for prof in release debug; do
        local candidate="$SCRIPT_DIR/../target/$prof/tillandsias-tray"
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done
    echo "error: tillandsias-tray not found" >&2
    exit 1
}

trap 'printf "\n${RED}ABORTED${RESET} — enclave assertion interrupted\n"' INT TERM

exe="$(resolve_tray_exe)"

printf "${BOLD}macOS enclave readiness assertion${RESET}\n"
printf "========================================\n"
printf "Using exe:  %s\n" "$exe"
printf "Image root: %s\n\n" "$IMAGE_ROOT"

# Pre-check: rootfs.img must exist (provisioned)
if [[ ! -f "$IMAGE_ROOT/rootfs.img" ]]; then
    write_check "Precondition: rootfs.img present" "false" "run --provision first"
    printf "\n${RED}FAIL${RESET} — VM not provisioned. Run \`%s --provision\` first.\n" "$exe"
    exit 1
fi
write_check "Precondition: rootfs.img present" "true"

# Launch the tray, capture its log
LOG_FILE=$(mktemp /tmp/tillandsias-enclave-diag-XXXXXX.log)
trap 'rm -f "$LOG_FILE"; printf "\n${RED}ABORTED${RESET} — enclave assertion interrupted\n"' INT TERM

printf "\nLaunching tray (log: %s) ...\n" "$LOG_FILE"
"$exe" > "$LOG_FILE" 2>&1 &
TRAY_PID=$!

# Poll for Ready or Failed
TIMEOUT_SEC=120
READY_SEEN=false
FAILED_SEEN=false
for ((i=0; i<TIMEOUT_SEC; i++)); do
    if grep -q 'phase=Ready.*podman_ready=true' "$LOG_FILE" 2>/dev/null; then
        READY_SEEN=true
        READY_AT=$i
        break
    fi
    if grep -q 'phase=Failed' "$LOG_FILE" 2>/dev/null; then
        FAILED_SEEN=true
        FAILED_AT=$i
        break
    fi
    sleep 1
done

# Kill tray
kill "$TRAY_PID" 2>/dev/null || true
wait "$TRAY_PID" 2>/dev/null || true
printf "\n"

if [[ "$READY_SEEN" == "true" ]]; then
    write_check "Enclave reached Ready" "true" "phase=Ready podman_ready=true at ~${READY_AT}s"
    rm -f "$LOG_FILE"
    trap - INT TERM
    printf "\n${GREEN}PASS${RESET} — enclave is ready. The macOS tray is fully functional.\n"
    exit 0
fi

if [[ "$FAILED_SEEN" == "true" ]]; then
    write_check "Enclave not Ready" "false" "phase=Failed at ~${FAILED_AT}s (podman not available or enclave failed to start)"
    echo ""
    grep 'vm-status' "$LOG_FILE" 2>/dev/null || true
    printf "\n${RED}DEGRADED${RESET} — enclave entered Failed state. See $LOG_FILE for details.\n"
    exit 2
fi

write_check "Enclave not Ready" "false" "timeout after ${TIMEOUT_SEC}s (headless did not report Ready or Failed)"
printf "\n${YELLOW}DEGRADED${RESET} — timeout waiting for enclave state. See $LOG_FILE for details.\n"
exit 2
