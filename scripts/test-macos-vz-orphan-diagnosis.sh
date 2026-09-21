#!/usr/bin/env bash
# @trace spec:vm-provisioning-lifecycle
#
# test-macos-vz-orphan-diagnosis.sh — order 1253-gina.
#
# WHAT IT PROTECTS. A Virtualization.framework VM runs in an XPC child
# (`com.apple.Virtualization.VirtualMachine`) that holds the image directory's
# nvram.bin for as long as the guest lives. While one holds it, EVERY later
# start dies as:
#
#     Invalid virtual machine configuration. The boot loader is invalid.
#
# THE MESSAGE IS THE DEFECT, not the holder. That string describes a corrupt
# EFI store and sends the reader at the disk; the actual state is a HEALTHY
# image held open by a process the reader does not know exists. The obvious
# response to a bad boot loader is `--reset-guest`, which DESTROYS the guest
# disk and the in-VM vault to repair what one `kill` clears. A destructive
# remedy suggested by a misleading diagnosis is worse than no diagnosis, so
# what this fixture pins is the TEXT, not just the recovery.
#
# MEASURED on tlatoanis-macbook-air 2026-09-20 against 56.9.20.1, both halves:
#   live run, helper present            -> lsof nvram.bin = pid 31650
#   SIGKILL the tray directly           -> helper reaped, second run OK
#   helper left alive, second start     -> "boot loader is invalid", and the
#                                          enriched branch named pid 31650
#   follow the printed `kill 31650`     -> identical command then SUCCEEDED
# The last line is why the remedy the message prints is a measurement rather
# than advice: it was executed, not reasoned about.
#
# WHY ARM 2 EXISTS AND IS NOT OPTIONAL. Arm 1 alone — "SIGKILL, then a second
# run works" — is green on any quiet host that never orphaned anything. It
# proves a VM started twice, which is not the claim. Arm 2 leaves a live VM
# holding nvram and requires the SAME assertion to RED, so the arm that passes
# is known to discriminate. Without it this file measures nothing.
#
# GRAMMAR — one line, or two on a could-not-run (see below):
#   ^(ok:macos-vz-orphan-diagnosis:[0-9]+|violation:macos-vz-orphan-diagnosis:.*|unsupported:macos-vz-orphan-diagnosis:.*|skip:macos-vz-orphan-diagnosis:.*)$
#
# A COULD-NOT-RUN PRINTS TWO LINES, and the order is load-bearing (1330-i4hu).
# The `unsupported:` line carries the detail a reader needs; the `skip:` line
# is what scripts/run-litmus-test.sh scores, because step_terminal_verdict
# (:960) consults ONLY the last non-empty line and recognises only
# `skip:`/`advisory:` there. With the detail line last, the step falls through
# to check_signal, whose success pattern does not match, and :992 returns
# FAILURE — so a host that merely lacks the app bundle reds the suite with
# "Check implementation" against a fixture behaving exactly as designed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A precondition this fixture cannot satisfy: say what was not tested, then end
# on the line the runner scores (1330-i4hu). Never used for a failure — a red
# that returns `skip:` is six characters that make a defect disappear.
cannot_run() {
    echo "unsupported:macos-vz-orphan-diagnosis:$1"
    echo "skip:macos-vz-orphan-diagnosis:$1"
    exit 0
}
ARMS=0

# --- Arm 0: the source guard, which needs no VM and no macOS ----------------
# The enriched branch is the deliverable. If it leaves the tree, or the start
# site stops calling it, say so on every host rather than only on the one box
# that can boot a guest.
VZ="$ROOT/crates/tillandsias-vm-layer/src/vz.rs"
if [ -f "$VZ" ]; then
    grep -q 'fn explain_start_failure' "$VZ" || {
        echo "violation:macos-vz-orphan-diagnosis:explain-start-failure-gone"
        exit 1
    }
    grep -q 'DO NOT --reset-guest' "$VZ" || {
        echo "violation:macos-vz-orphan-diagnosis:branch-no-longer-steers-away-from-reset-guest"
        exit 1
    }
    # The helper is worthless if the failing path stops routing through it.
    grep -q 'map_err(|e| explain_start_failure(' "$VZ" || {
        echo "violation:macos-vz-orphan-diagnosis:start-failure-site-not-wired-to-the-explainer"
        exit 1
    }
    ARMS=$((ARMS + 1))
fi

# The source arm above still ran, and that is the half a Linux CI lane can
# honestly answer. Name the half that was skipped rather than report green.
[ "$(uname -s)" = "Darwin" ] || cannot_run "not-darwin-source-arm-only"

TRAY="${TILLANDSIAS_TRAY_BIN:-$ROOT/dist/Tillandsias.app/Contents/MacOS/tillandsias-tray}"
# A bare target/release binary carries no com.apple.security.virtualization
# entitlement and cannot start a VM at all — name that, rather than let the
# caller meet it as the very "boot loader is invalid" this file is about.
[ -x "$TRAY" ] || cannot_run "no-app-bundle-run-scripts/build-macos-tray.sh"

NVRAM="$HOME/Library/Application Support/tillandsias/nvram.bin"
[ -f "$NVRAM" ] || cannot_run "no-provisioned-guest-image"

holders() {
    # Space-separated, with NO trailing separator: the caller turns spaces into
    # commas for the message, and a trailing space became a trailing comma.
    /usr/sbin/lsof -t "$NVRAM" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'
}

# PRECONDITION. A VM already running here (a live tray, another session) makes
# arm 1 fail for a reason that is not the subject. Refuse rather than guess.
PRE="$(holders)"
[ -z "$PRE" ] || cannot_run "image-already-held-by-pid-${PRE// /,}-precondition-unmet"

WORK="$(mktemp -d -t macos-vz-orphan)"
LIVE_TRAY=""
cleanup() {
    # Never leave this host in the state the fixture studies.
    [ -n "$LIVE_TRAY" ] && kill -9 "$LIVE_TRAY" 2>/dev/null
    for p in $(holders); do kill -9 "$p" 2>/dev/null; done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Start a guest and wait until the in-guest command is actually RUNNING. A tray
# killed before the VM boots orphans nothing, and would score this green for
# the wrong reason.
start_live_guest() {
    "$TRAY" --exec-guest 'sleep 600' >"$WORK/live.log" 2>&1 &
    LIVE_TRAY=$!
    local i
    for i in $(seq 1 60); do
        grep -q 'running:' "$WORK/live.log" 2>/dev/null && return 0
        kill -0 "$LIVE_TRAY" 2>/dev/null || return 1
        sleep 2
    done
    return 1
}

start_live_guest || {
    echo "violation:macos-vz-orphan-diagnosis:guest-never-reached-a-running-command"
    exit 1
}
[ -n "$(holders)" ] || {
    # No holder while a guest is demonstrably running means lsof is not seeing
    # what this fixture reads, so neither arm below would mean anything.
    echo "violation:macos-vz-orphan-diagnosis:live-guest-holds-no-nvram-probe-is-blind"
    exit 1
}

# --- Arm 2 (MUTATION, run first while the guest is live) -------------------
# Leave the VM alive and make the SAME second-start assertion arm 1 makes. It
# MUST fail here, and the failure MUST name the holder without sending the
# reader at --reset-guest.
HELD_PID="$(holders)"
HELD_PID="${HELD_PID%% *}"
"$TRAY" --exec-guest 'echo MUTATION_ARM' >"$WORK/mutation.log" 2>&1
MUT_RC=$?
if [ "$MUT_RC" -eq 0 ]; then
    echo "violation:macos-vz-orphan-diagnosis:second-start-succeeded-with-the-orphan-alive-arm1-cannot-discriminate"
    exit 1
fi
grep -q "pid $HELD_PID" "$WORK/mutation.log" || {
    echo "violation:macos-vz-orphan-diagnosis:failure-text-does-not-name-holder-$HELD_PID"
    exit 1
}
grep -q 'DO NOT --reset-guest' "$WORK/mutation.log" || {
    echo "violation:macos-vz-orphan-diagnosis:failure-text-does-not-steer-away-from-reset-guest"
    exit 1
}
ARMS=$((ARMS + 1))

# --- Arm 1 (SUBJECT): SIGKILL the tray; the helper must not survive it ------
kill -9 "$LIVE_TRAY" 2>/dev/null
LIVE_TRAY=""
for i in $(seq 1 15); do
    [ -z "$(holders)" ] && break
    sleep 1
done
LEFT="$(holders)"
[ -z "$LEFT" ] || {
    echo "violation:macos-vz-orphan-diagnosis:helper-${LEFT// /,}-outlived-a-sigkilled-tray-holding-nvram"
    exit 1
}
ARMS=$((ARMS + 1))

# --- Arm 3: and the image is genuinely usable again, not merely unheld -----
"$TRAY" --exec-guest 'echo AFTER_KILL_OK' >"$WORK/after.log" 2>&1
AFT_RC=$?
if [ "$AFT_RC" -ne 0 ] || ! grep -q 'AFTER_KILL_OK' "$WORK/after.log"; then
    echo "violation:macos-vz-orphan-diagnosis:second-start-failed-after-the-tray-was-sigkilled"
    exit 1
fi
ARMS=$((ARMS + 1))

echo "ok:macos-vz-orphan-diagnosis:$ARMS"
