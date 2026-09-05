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
#       NOT a health verdict: this tool cannot observe the VM or the guest, and
#       0 must not be read as "the system is working" (980-ja2m).
#   2 - degraded (the tool ran end-to-end but at least one check failed).
#   1 - could not locate or invoke tillandsias-tray.
#   3 - the tray ANSWERED but no JSON processor is available, so only the
#       formatted view is missing; the raw diagnose JSON is printed to stdout.
#       Distinct from 1 on purpose: a missing parser is not a broken tray
#       (order 799-tb7q).
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

# ORDER 799-tb7q — A DIAGNOSTIC MUST ALWAYS PRODUCE ITS DATA.
#
# This exited 1 with "brew install jq". Two things were wrong with that, and the
# second is the one that costs.
#
# 1. It told an END USER to install a developer tool. These diagnostics ship;
#    they run where no builder toolbox exists and where nobody agreed to have a
#    JSON processor.
#
# 2. IT NAMED THE WRONG FAILURE. Exit 1's documented meaning is "could not
#    locate or invoke tillandsias-tray, or jq missing" — so a missing PARSER and
#    a broken TRAY were the same verdict. The tray can be perfectly healthy and
#    still produce exit 1. You run a diagnostic precisely when something is
#    already wrong, which makes a misattributed verdict more expensive here than
#    anywhere else in the tree.
#
# The dispatch is host jq -> toolbox jq (the documented pattern, which now works
# because the init set carries jq) -> DEGRADE. Degrading prints the RAW JSON:
# the data is complete, only the presentation is lost, and the user or agent can
# read or pipe it. That deliberately avoids shipping a second hand-rolled JSON
# parser — two parsers that can disagree is a misattribution generator, and a
# diagnostic is the last place to put one.
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

if [ -z "$TILLANDSIAS_JQ" ]; then
    # No parser anywhere. The tray ANSWERED — that is the fact worth reporting —
    # so emit its answer verbatim and say plainly that only the formatting is
    # missing. Exit 3, not 1: 1 means the tray could not be invoked, and this
    # script must not claim that about a tray that just replied.
    printf '%s\n' "$json"
    echo "" >&2
    echo "note: no JSON processor available (no host \`jq\`, no tillandsias-builder toolbox)." >&2
    echo "      The tray ANSWERED and its raw output is above — the data is complete;" >&2
    echo "      only this script's formatted view is unavailable. This is NOT a tray" >&2
    echo "      fault and must not be read as one (order 799-tb7q)." >&2
    echo "      For the formatted view, install jq." >&2
    exit 3
fi
if ! echo "$json" | $TILLANDSIAS_JQ empty 2>/dev/null; then # sigpipe-ok: safe pipeline
    echo "error: --diagnose --json did not emit a JSON object:" >&2
    echo "$json" >&2
    exit 1
fi

version="$(echo "$json" | $TILLANDSIAS_JQ -r '.version')"
in_app="$(echo "$json" | $TILLANDSIAS_JQ -r '.in_app')"
release_tag="$(echo "$json" | $TILLANDSIAS_JQ -r '.release_tag')"
manifest_pin="$(echo "$json" | $TILLANDSIAS_JQ -r '.manifest_pin_aarch64_qcow2 // "(none)"')"
provisioned="$(echo "$json" | $TILLANDSIAS_JQ -r '.provisioned')"
rootfs_present="$(echo "$json" | $TILLANDSIAS_JQ -r '.rootfs_present')"
kernel_present="$(echo "$json" | $TILLANDSIAS_JQ -r '.kernel_present')"
initrd_present="$(echo "$json" | $TILLANDSIAS_JQ -r '.initrd_present')"
# 980-ja2m. Renamed from .vm_owner_live, which named a fact it did not measure.
# An ABSENT field must read as unknown (an older tray emits the old key), but a
# field that is present and FALSE must read as false. `//` cannot express that:
# jq's alternative operator fires on false as well as null, so `// "unknown"`
# reported a not-running tray as unknown. Measured here 2026-09-04 against a
# tray emitting tray_process_running:false. Use has() to test presence.
tray_process_running="$(echo "$json" | $TILLANDSIAS_JQ -r 'if has("tray_process_running") then .tray_process_running else "unknown" end')"

write_check "Version" "true" "$version"
write_check "Bundle" "$in_app" "$([[ "$in_app" == "true" ]] && echo "inside Tillandsias.app" || echo "running outside .app (dev binary)")"
write_check "Release tag" "true" "$release_tag"
write_check "Manifest pin (aarch64.qcow2)" "$([[ "$manifest_pin" != "(none)" ]] && echo "true" || echo "false")" "$manifest_pin"
write_check "rootfs.img present" "$rootfs_present"
write_check "vmlinuz present" "$kernel_present"
write_check "initramfs.img present" "$initrd_present"
write_check "Provisioned" "$provisioned"

printf "\n"
if [[ "$provisioned" == "true" ]]; then
    # 980-ja2m. This used to print "HEALTHY — image-root provisioned, ready to
    # boot VM" on the strength of `.provisioned` alone, which is a stat() of
    # rootfs.img. Nothing this tool can see observes the VM or the guest, so it
    # now reports what it checked and names what it did not.
    printf "${GREEN}BOOT ARTIFACTS PRESENT${RESET} — the image-root is provisioned.\n"
    if [[ "$tray_process_running" == "true" ]]; then
        printf "A tray process is running (singleton lock held).\n"
    elif [[ "$tray_process_running" == "false" ]]; then
        printf "No tray process is running.\n"
    else
        printf "Tray process state unknown (this tray predates the field).\n"
    fi
    printf "NOT CHECKED: whether a VM is running, or whether the guest is healthy.\n"
    printf "This tool cannot see either — macOS has no AF_VSOCK, so the live phase is\n"
    printf "readable only from inside the tray process. Open the menubar chip for live status.\n"
    exit 0
else
    printf "${RED}DEGRADED${RESET} — see FAIL lines above. Launch the tray once (or \`open /Applications/Tillandsias.app\`) to materialize the rootfs on first launch.\n"
    exit 2
fi
