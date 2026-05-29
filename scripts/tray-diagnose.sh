#!/usr/bin/env bash
# One-shot Tillandsias.app health check consuming `tillandsias-tray
# --diagnose --json`. Mirrors scripts/tray-diagnose.ps1 (windows) for
# macOS operators.
#
# Runs the installed (or local-build) tray with `--diagnose --json`,
# parses the machine-readable report via jq, and prints a colorized
# PASS / FAIL line per check. Demonstrates the JSON schema's utility
# — the same JSON can be uploaded to a support endpoint or piped
# into a richer dashboard.
#
# Distinct from `--diagnose` alone (human-formatted report). This
# script assumes the tray binary exists and queries its own
# `--diagnose --json` rather than re-implementing the checks.
#
# Search order for tillandsias-tray binary (first match wins):
#   1. $TILLANDSIAS_TRAY_EXE env var (if set).
#   2. /Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray
#      (the path the install-macos.sh installer drops to).
#   3. `command -v tillandsias-tray` (PATH).
#   4. <repo>/target/release/tillandsias-tray (dev build).
#   5. <repo>/target/debug/tillandsias-tray   (dev build).
#
# Exit codes mirror the tray's --diagnose contract:
#   0 - image-root provisioned (rootfs.img + vmlinuz + initramfs.img all present).
#   2 - degraded (the tool ran end-to-end but at least one check failed).
#   1 - could not locate or invoke tillandsias-tray, or jq missing.
#
# Usage:
#   scripts/tray-diagnose.sh
#   TILLANDSIAS_TRAY_EXE=/path/to/tray scripts/tray-diagnose.sh
#
# @trace spec:macos-native-tray.diagnose@v1

set -euo pipefail

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    BOLD=''
    RESET=''
fi

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
    local repo_root
    repo_root="$(cd "$(dirname "$0")/.." && pwd)"
    for prof in release debug; do
        local candidate="$repo_root/target/$prof/tillandsias-tray"
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done
    echo "error: tillandsias-tray not found. Install via scripts/install-macos.sh, build via scripts/build-macos-tray.sh, or set TILLANDSIAS_TRAY_EXE." >&2
    exit 1
}

if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq required for JSON parsing — \`brew install jq\`" >&2
    exit 1
fi

exe="$(resolve_tray_exe)"
printf "${BOLD}tillandsias-tray health check${RESET}\n"
printf "==============================\n"
printf "Using exe: %s\n\n" "$exe"

# The tray emits JSON on stdout AND a meaningful exit code:
# 0 = provisioned, 2 = degraded, 1 = hard failure. We must not
# treat the degraded-exit-2 case as a script failure — the JSON
# body is still valid and our PASS/FAIL rendering uses it.
set +e
json="$("$exe" --diagnose --json 2>&1)"
tray_exit=$?
set -e
if [[ $tray_exit -eq 1 ]]; then
    echo "error: tillandsias-tray --diagnose --json hard-failed (exit 1):" >&2
    echo "$json" >&2
    exit 1
fi

if ! echo "$json" | jq empty 2>/dev/null; then
    echo "error: --diagnose --json did not emit a JSON object:" >&2
    echo "$json" >&2
    exit 1
fi

version="$(echo "$json" | jq -r '.version')"
in_app="$(echo "$json" | jq -r '.in_app')"
release_tag="$(echo "$json" | jq -r '.release_tag')"
manifest_pin="$(echo "$json" | jq -r '.manifest_pin_aarch64_img // "(none)"')"
provisioned="$(echo "$json" | jq -r '.provisioned')"
rootfs_present="$(echo "$json" | jq -r '.rootfs_present')"
kernel_present="$(echo "$json" | jq -r '.kernel_present')"
initrd_present="$(echo "$json" | jq -r '.initrd_present')"

write_check "Version" "true" "$version"
write_check "Bundle" "$in_app" "$([[ "$in_app" == "true" ]] && echo "inside Tillandsias.app" || echo "running outside .app (dev binary)")"
write_check "Release tag" "true" "$release_tag"
write_check "Manifest pin (aarch64.img)" "$([[ "$manifest_pin" != "(none)" ]] && echo "true" || echo "false")" "$manifest_pin"
write_check "rootfs.img present" "$rootfs_present"
write_check "vmlinuz present" "$kernel_present"
write_check "initramfs.img present" "$initrd_present"
write_check "Provisioned" "$provisioned"

printf "\n"
if [[ "$provisioned" == "true" ]]; then
    printf "${GREEN}HEALTHY${RESET} — image-root provisioned, ready to boot VM.\n"
    exit 0
else
    printf "${RED}DEGRADED${RESET} — see FAIL lines above. Launch the tray once (or \`open /Applications/Tillandsias.app\`) to materialize the rootfs on first launch.\n"
    exit 2
fi
