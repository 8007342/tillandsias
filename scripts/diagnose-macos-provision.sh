#!/usr/bin/env bash
# Autonomous smoke test for the macOS first-run provisioning pipeline.
#
# Verifies the full headless provisioning flow (m13) without booting the VM:
#   1. Clean the image root (remove any stale rootfs.img).
#   2. Run `tillandsias-tray --provision` — headless download + qcow2→raw
#      conversion + SHA-verify — and parse its JSON-line output.
#   3. Confirm rootfs.img exists and is non-zero.
#   4. Re-verify the downloaded qcow2's SHA-256 against the manifest pin.
#
# Does NOT boot the VM. Designed to run unattended.
#
# Exit codes:
#   0 — provisioning smoke passed
#   2 — degraded (provision failed, image missing, or SHA mismatch)
#   1 — hard failure (tray binary not found, manifest unavailable)
#   3 — no JSON processor available; a TOOLING gap on this machine, not a
#       provisioning fault. Distinct from 1 on purpose (order 799-tb7q).
#
# @trace plan/issues/osx-next-work-queue-2026-05-25.md (m12)

set -euo pipefail

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

IMAGE_ROOT="$HOME/Library/Application Support/tillandsias"
ROOTFS_QCow2="$IMAGE_ROOT/rootfs.qcow2"
ROOTFS_IMG="$IMAGE_ROOT/rootfs.img"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_FILE="$SCRIPT_DIR/../images/vm/manifest.toml"

resolve_tray_exe() {
    if [[ -n "${TILLANDSIAS_TRAY_EXE:-}" ]]; then
        if [[ -x "$TILLANDSIAS_TRAY_EXE" ]]; then
            echo "$TILLANDSIAS_TRAY_EXE"
            return
        fi
        echo "error: TILLANDSIAS_TRAY_EXE not executable: $TILLANDSIAS_TRAY_EXE" >&2
        exit 1
    fi
    local installed="/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray"
    if [[ -x "$installed" ]]; then
        echo "$installed"
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
    echo "error: tillandsias-tray not found. Install via scripts/install-macos.sh, build via scripts/build-macos-tray.sh, or set TILLANDSIAS_TRAY_EXE." >&2
    exit 1
}

write_check() {
    local label="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "true" ]]; then
        printf "  ${GREEN}PASS${RESET} %s" "$label"
    else
        printf "  ${RED}FAIL${RESET} %s" "$label"
    fi
    if [[ -n "$detail" ]]; then
        printf ": %s" "$detail"
    fi
    printf "\n"
}

trap 'printf "\n${RED}ABORTED${RESET} — smoke test interrupted\n"' INT TERM

# ORDER 799-tb7q — same rule as tray-diagnose.sh: a shipped diagnostic must not
# tell an end user to install a developer tool, and must not report a missing
# PARSER as a failure of the thing under diagnosis. Dispatch is host jq ->
# toolbox jq -> degrade with the reason named.
#
# WHY THIS DISPATCH IS INLINE AND NOT scripts/lib/tool-dispatch.sh — A DECISION,
# NOT AN OVERSIGHT (order 799-tb7q). That lib exists and 46 dev-host callers use
# it; these two diagnostics deliberately do not.
#
# THIS SCRIPT SHIPS. It runs on an end-user machine, and its whole job is to work
# where nothing else does. Sourcing a sibling file would give it a dependency
# that may be absent exactly there — and a diagnostic that fails to source its
# helper fails at the moment its output is needed, with a failure that LOOKS LIKE
# the thing it was sent to investigate. That is strictly worse than no
# diagnostic.
#
# So: two justified copies beat one fragile abstraction. If you are sweeping
# callers onto the lib, SKIP THIS FILE. scripts/test-shipped-diagnostic-tool-dispatch.sh
# and scripts/test-tool-dispatch-lib.sh both FAIL if this file starts sourcing it.
TILLANDSIAS_JQ=""
if command -v jq >/dev/null 2>&1; then
    TILLANDSIAS_JQ="jq"
elif command -v toolbox >/dev/null 2>&1 \
     && toolbox run --container tillandsias-builder jq --version >/dev/null 2>&1; then
    TILLANDSIAS_JQ="toolbox run --container tillandsias-builder jq"
else
    echo "note: no JSON processor available (no host \`jq\`, no tillandsias-builder" >&2
    echo "      toolbox). This script needs one to read the manifest; that is a" >&2
    echo "      TOOLING gap on this machine, not a provisioning fault (799-tb7q)." >&2
    echo "      Install jq to run this diagnostic." >&2
    exit 3
fi

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "error: manifest not found at $MANIFEST_FILE" >&2
    exit 1
fi
pin_qcow2=$(grep -E '^\s*"aarch64\.qcow2"\s*=' "$MANIFEST_FILE" \
    | sed -E 's/.*"([0-9a-f]{64})".*/\1/' || true)
if [[ -z "$pin_qcow2" ]]; then
    echo "error: could not parse aarch64.qcow2 SHA from manifest" >&2
    exit 1
fi

exe="$(resolve_tray_exe)"

printf "${BOLD}macOS provisioning smoke test${RESET}\n"
printf "================================\n"
printf "Using exe:  %s\n" "$exe"
printf "Image root: %s\n\n" "$IMAGE_ROOT"

# Step 1: clean image root
printf "Cleaning image root...\n"
rm -f "$ROOTFS_QCow2" "$ROOTFS_IMG"
write_check "Clean image root" "true" "removed any stale rootfs artifacts"
printf "\n"

# Step 2: run --provision
printf "Running: %s --provision\n\n" "$exe"
set +e
"$exe" --provision 2>&1 | tee "$IMAGE_ROOT/provision-smoke.log"
provision_exit=${PIPESTATUS[0]}
set -e
printf "\n"
write_check "Provision exit 0" "$([[ $provision_exit -eq 0 ]] && echo "true" || echo "false")" "exit code $provision_exit"
if [[ $provision_exit -ne 0 ]]; then
    printf "\n${RED}DEGRADED${RESET} — provisioning exited $provision_exit. See $IMAGE_ROOT/provision-smoke.log\n"
    exit 2
fi

# Step 3: verify rootfs.img exists and is non-zero
if [[ ! -f "$ROOTFS_IMG" ]]; then
    write_check "rootfs.img present" "false"
    printf "\n${RED}DEGRADED${RESET} — rootfs.img not found after successful provision exit\n"
    exit 2
fi
img_bytes=$(stat -f%z "$ROOTFS_IMG" 2>/dev/null || stat -c%s "$ROOTFS_IMG" 2>/dev/null || echo "0")
if [[ "$img_bytes" -gt 0 ]]; then
    human_size=$(numfmt --to=iec "$img_bytes" 2>/dev/null || echo "$img_bytes bytes")
    write_check "rootfs.img non-zero" "true" "$human_size"
else
    write_check "rootfs.img non-zero" "false" "0 bytes"
    printf "\n${RED}DEGRADED${RESET} — rootfs.img is empty\n"
    exit 2
fi

# Step 4: verify qcow2 SHA matches manifest pin
if [[ ! -f "$ROOTFS_QCow2" ]]; then
    write_check "qcow2 SHA match" "false" "rootfs.qcow2 not found (may have been cleaned up)"
else
    actual_sha=$(shasum -a 256 "$ROOTFS_QCow2" | cut -d' ' -f1)
    if [[ "$actual_sha" == "$pin_qcow2" ]]; then
        write_check "qcow2 SHA matches manifest" "true" "${pin_qcow2:0:12}..."
    else
        write_check "qcow2 SHA matches manifest" "false" "expected ${pin_qcow2:0:12}..., got ${actual_sha:0:12}..."
        printf "\n${RED}DEGRADED${RESET} — SHA-256 mismatch on rootfs.qcow2\n"
        exit 2
    fi
fi

printf "\n${GREEN}PASS${RESET} — provisioning smoke passed. The macOS tray is ready to boot the VM.\n"
exit 0
