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
#   ^(ok:macos-vz-orphan-diagnosis:[0-9]+|violation:macos-vz-orphan-diagnosis:.*|unsupported:macos-vz-orphan-diagnosis:.*|skip:macos-vz-orphan-diagnosis:.*|refused:macos-vz-orphan-diagnosis:.*)$
#
# EVERY verdict line ends with a subject clause naming the binary that answered
# (1332-tdde). The runner's patterns match by substring, so appending it does
# not disturb them; a reader of any past run can now say WHAT was tested.
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

# WHICH BINARY ANSWERED (order 1332-tdde). Every verdict carries it, so a reader
# of any past run can say what was tested instead of inferring it from a path.
#
# THE WHOLE `--version` LINE, sha and build stamp included, never a parsed
# field of it. MEASURED: a pre-fix binary at git 2f5f2a90a and a post-fix binary
# at git 65994e1e5 BOTH report "56.9.21.1", so a version comparison reads two
# different subjects as one. A path is not an identity either — the default
# target is a path in the checkout, and what sits there may be ten days old.
SUBJECT="unresolved"
subject_of() {
    [ -x "$1" ] || { printf 'absent(%s)' "$1"; return 0; }
    local line
    line="$("$1" --version 2>/dev/null | head -1)"
    [ -n "$line" ] && printf '%s' "$line" || printf 'unreadable(%s)' "$1"
}

# WHAT THE IMAGE CAN SAY ABOUT ITSELF (order 1332-tdde, deliverable 3).
#
# THE SKEW THIS ROW EXISTS FOR CANNOT BE DECIDED TODAY, and this says so in the
# verdict rather than guessing. A tray built from one tree driving a guest
# provisioned by another produced
# `violation:...:guest-never-reached-a-running-command` about a pairing that was
# never the subject. To REFUSE on that, the fixture would have to compare the
# two identities — and the image does not record one.
#
# READ, not assumed: provision/provision.state (written by
# crates/tillandsias-vm-layer/src/vz.rs at 862, 864 and 1306) records
# `written_at`, `written_at_iso`, `phase`, and on the `complete` phase a
# `guest_binary_sha256`. THERE IS NO VERSION FIELD. A content hash of the guest
# binary is not comparable to the host tray's git sha, and before the complete
# phase even that hash is absent.
#
# So the honest output is both identities and an explicit undetermined, NOT a
# refusal built on a comparison that has nothing to compare. When the state
# grows a field naming the tree that built the image, this becomes a refusal.
image_identity() {
    local st="$HOME/Library/Application Support/tillandsias/provision/provision.state"
    [ -f "$st" ] || { printf 'no-provision-state'; return 0; }
    local phase sha
    phase="$(sed -n 's/^phase //p' "$st" | head -1)"
    sha="$(sed -n 's/^guest_binary_sha256 //p' "$st" | head -1)"
    printf 'phase=%s guest_binary_sha256=%s' "${phase:-unknown}" "${sha:-absent}"
}
verdict() {
    echo "$1 subject=[$SUBJECT] image=[$(image_identity)] skew=undetermined-image-records-no-version"
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ROOT MUST BE A CHECKOUT BEFORE ANYTHING DERIVED FROM IT IS TRUSTED (1332-tdde).
#
# A COPY of this script run from outside the tree resolves ROOT to the parent of
# wherever it sits — `/` for a copy in /tmp — and every path built from it then
# describes that place instead of the product. MEASURED: such a copy found no
# app bundle under `/` and said so, which is TRUE about `/` and a FALSE
# description of what happened.
#
# THIS IS A REFUSAL, NOT A COULD-NOT-RUN, and the distinction is deliberate.
# `cannot_run` means "the HOST cannot answer this question" and its terminal
# `skip:` leaves the step out of the rate — correct for a host without a
# bundle, and catastrophic here, because a script that does not know where it
# is cannot be trusted about anything else it reports. Routing this through
# `cannot_run` would turn a red into a silent skip. `refused:` is in the
# runner's failure set (run-litmus-test.sh:966), checked FIRST and
# short-circuiting, so it stays red whatever follows it.
[ -f "$ROOT/build.sh" ] && [ -d "$ROOT/crates" ] || {
    verdict "refused:macos-vz-orphan-diagnosis:root-is-not-a-tillandsias-checkout-$ROOT"
    exit 1
}

# A precondition this fixture cannot satisfy: say what was not tested, then end
# on the line the runner scores (1330-i4hu). Never used for a failure — a red
# that returns `skip:` is six characters that make a defect disappear.
cannot_run() {
    verdict "unsupported:macos-vz-orphan-diagnosis:$1"
    verdict "skip:macos-vz-orphan-diagnosis:$1"
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
        verdict "violation:macos-vz-orphan-diagnosis:explain-start-failure-gone"
        exit 1
    }
    grep -q 'DO NOT --reset-guest' "$VZ" || {
        verdict "violation:macos-vz-orphan-diagnosis:branch-no-longer-steers-away-from-reset-guest"
        exit 1
    }
    # The helper is worthless if the failing path stops routing through it.
    grep -q 'map_err(|e| explain_start_failure(' "$VZ" || {
        verdict "violation:macos-vz-orphan-diagnosis:start-failure-site-not-wired-to-the-explainer"
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
SUBJECT="$(subject_of "$TRAY")"
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
    verdict "violation:macos-vz-orphan-diagnosis:guest-never-reached-a-running-command"
    exit 1
}
[ -n "$(holders)" ] || {
    # No holder while a guest is demonstrably running means lsof is not seeing
    # what this fixture reads, so neither arm below would mean anything.
    verdict "violation:macos-vz-orphan-diagnosis:live-guest-holds-no-nvram-probe-is-blind"
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
    verdict "violation:macos-vz-orphan-diagnosis:second-start-succeeded-with-the-orphan-alive-arm1-cannot-discriminate"
    exit 1
fi
grep -q "pid $HELD_PID" "$WORK/mutation.log" || {
    verdict "violation:macos-vz-orphan-diagnosis:failure-text-does-not-name-holder-$HELD_PID"
    exit 1
}
grep -q 'DO NOT --reset-guest' "$WORK/mutation.log" || {
    verdict "violation:macos-vz-orphan-diagnosis:failure-text-does-not-steer-away-from-reset-guest"
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
    verdict "violation:macos-vz-orphan-diagnosis:helper-${LEFT// /,}-outlived-a-sigkilled-tray-holding-nvram"
    exit 1
}
ARMS=$((ARMS + 1))

# --- Arm 3: and the image is genuinely usable again, not merely unheld -----
"$TRAY" --exec-guest 'echo AFTER_KILL_OK' >"$WORK/after.log" 2>&1
AFT_RC=$?
if [ "$AFT_RC" -ne 0 ] || ! grep -q 'AFTER_KILL_OK' "$WORK/after.log"; then
    verdict "violation:macos-vz-orphan-diagnosis:second-start-failed-after-the-tray-was-sigkilled"
    exit 1
fi
ARMS=$((ARMS + 1))

verdict "ok:macos-vz-orphan-diagnosis:$ARMS"
